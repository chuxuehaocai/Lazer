import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/audio/system_media_handler.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/l10n/app_localizations.dart';
import 'package:lazer_nextgen/main.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/ui/album_library_page.dart';
import 'package:lazer_nextgen/ui/library_page.dart';

import 'support/music_gateway.dart';

/// Enough albums to scroll the grid in a phone-sized window.
class _AlbumsGateway extends TestMusicGateway {
  @override
  Future<MusicPage<MusicAlbum>> savedAlbums({
    int limit = 30,
    int offset = 0,
  }) async => MusicPage<MusicAlbum>(
    <MusicAlbum>[
      for (var index = 0; index < 24; index++)
        MusicAlbum(
          id: MusicId(
            provider: 'fixture',
            connection: 'test',
            kind: MusicEntityKind.album,
            value: 'album-$index',
          ),
          title: 'Album $index',
          artists: <MusicArtist>[
            MusicArtist(
              id: MusicId(
                provider: 'fixture',
                connection: 'test',
                kind: MusicEntityKind.artist,
                value: 'artist-$index',
              ),
              name: 'Artist $index',
            ),
          ],
          year: 2026,
        ),
    ],
    offset: 0,
    hasMore: false,
  );
}

final _playlists = <Playlist>[
  for (var index = 0; index < 9; index++)
    Playlist(
      id: 'fixture-$index',
      name: 'Playlist $index',
      trackIds: const <String>[],
      coverSeed: index,
      trackCount: 10,
    ),
];

class _State extends AppState {
  _State() : super(catalog: Catalog(gateway: _AlbumsGateway())) {
    autoDpiScale = false;
    layoutStyle = AppLayoutStyle.phone;
    backgroundMode = AppBackgroundMode.off;
    playerBackground = AppBackgroundMode.off;
    collections = UserCollections(created: _playlists);
  }

  @override
  Future<void> bootstrap() async {}

  @override
  bool get autoUpdateCheckDue => false;

  @override
  HomeFeed get home => const HomeFeed(
    featuredTracks: [],
    quick: [],
    daily: [],
    playlists: [],
    recommended: [],
    albums: [],
  );
}

class _UnusedAudio extends Fake implements AudioEngine {
  @override
  void dispose() {}
}

const _codec = StandardMethodCodec();

Future<void> _back(WidgetTester tester, String method, [Object? args]) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.backGesture.name,
    _codec.encodeMethodCall(MethodCall(method, args)),
    (_) {},
  );
}

Map<String, Object?> _event(double progress) => <String, Object?>{
  'progress': progress,
  'swipeEdge': 0,
  'touchOffset': <double>[8, 300],
};

/// Whether [point] reaches [page]'s own subtree instead of a surface painted
/// over it.
bool _reaches(WidgetTester tester, Finder page, Offset point) {
  final hit = tester.hitTestOnBinding(point);
  final elements = <Element>{};
  for (final entry in hit.path) {
    if (entry.target case final RenderObject render) {
      final object = render.debugCreator;
      if (object is DebugCreator) elements.add(object.element);
    }
  }
  final target = tester.element(page);
  return elements.any((element) {
    if (element == target) return true;
    var found = false;
    element.visitAncestorElements((ancestor) {
      if (ancestor == target) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  });
}

/// Pumps a bounded number of frames, so a stuck ticker cannot hang the test.
Future<void> _settle(WidgetTester tester, {int frames = 40}) async {
  for (var index = 0; index < frames; index++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the back gesture returns from 收藏的专辑 with the page intact', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(
      () => AppLocalizations.delegate.load(const Locale('en')),
    );
    final state = _State();
    await state.setIndependentPlayback(true);
    await tester.pumpWidget(
      LazerApp(
        state: state,
        audio: _UnusedAudio(),
        media: SystemMediaController(state),
      ),
    );
    await tester.pump();
    await _settle(tester);

    await tester.tap(find.byIcon(Icons.library_music_outlined));
    await tester.pump();
    await _settle(tester);
    final saved = find.byKey(const ValueKey<String>('open-saved-albums'));
    expect(saved, findsOneWidget);

    // A scrolled shelf is the case that used to break: the returning page kept
    // its own offset only if the switcher never dropped it.
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    position.jumpTo(200);
    await tester.pump();
    await _settle(tester, frames: 6);
    final shelf = tester.element(find.byType(AppLibraryPage));
    final shelfScroll = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    final offset = position.pixels;
    expect(offset, greaterThan(0));

    await tester.tap(saved);
    await tester.pump();
    await _settle(tester, frames: 20);
    expect(find.byType(AppSavedAlbumsPage), findsOneWidget);

    await _back(tester, 'startBackGesture', _event(0));
    await tester.pump();
    await _back(tester, 'updateBackGestureProgress', _event(.5));
    await tester.pump(const Duration(milliseconds: 60));
    await _back(tester, 'commitBackGesture');
    await tester.pump();
    await _settle(tester);

    expect(
      find.byType(AppSavedAlbumsPage),
      findsNothing,
      reason: 'the committed gesture has to leave the album page',
    );
    final library = find.byType(AppLibraryPage);
    expect(library, findsOneWidget);

    // The shelf the gesture revealed is the very page that was there before:
    // same element, same scroll position. A page rebuilt on commit came back at
    // offset 0 with its lower half never painted, which read as a mask.
    expect(
      tester.element(find.byType(AppLibraryPage)),
      same(shelf),
      reason: 'the gesture must reveal the retained shelf, not a new one',
    );
    final returning = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    expect(
      returning.position,
      same(shelfScroll.position),
      reason: 'the returning shelf keeps its own scroll position',
    );
    expect(
      returning.position.pixels,
      offset,
      reason: 'the returning shelf keeps its scroll position',
    );

    // The lower half of the window belongs to the page again: a hit test there
    // must reach the library's own content instead of a leftover surface. The
    // bottom capsule legitimately owns the last few points, so stop above it.
    final rect = tester.getRect(library);
    for (final dy in <double>[.3, .45, .6, .75]) {
      final point = Offset(rect.center.dx, rect.top + rect.height * dy);
      expect(
        _reaches(tester, library, point),
        isTrue,
        reason: 'point $point does not reach the page',
      );
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('the back button returns from 收藏的专辑 with the same result', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(
      () => AppLocalizations.delegate.load(const Locale('en')),
    );
    final state = _State();
    await state.setIndependentPlayback(true);
    await tester.pumpWidget(
      LazerApp(
        state: state,
        audio: _UnusedAudio(),
        media: SystemMediaController(state),
      ),
    );
    await tester.pump();
    await _settle(tester);

    await tester.tap(find.byIcon(Icons.library_music_outlined));
    await tester.pump();
    await _settle(tester);
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    position.jumpTo(200);
    await tester.pump();
    await _settle(tester, frames: 6);
    final shelf = tester.element(find.byType(AppLibraryPage));
    final shelfScroll = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    final offset = position.pixels;

    await tester.tap(find.byKey(const ValueKey<String>('open-saved-albums')));
    await tester.pump();
    await _settle(tester, frames: 20);
    await tester.tap(find.byIcon(Icons.chevron_left_rounded).first);
    await tester.pump();
    await _settle(tester);

    expect(find.byType(AppSavedAlbumsPage), findsNothing);
    expect(find.byType(AppLibraryPage), findsOneWidget);
    expect(tester.element(find.byType(AppLibraryPage)), same(shelf));
    final returning = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    expect(returning.position, same(shelfScroll.position));
    expect(returning.position.pixels, offset);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
