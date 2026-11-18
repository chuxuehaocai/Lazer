import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/desktop_lyrics/lyrics_overlay.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/tv/large_screen_chrome.dart';
import 'package:lazer_nextgen/tv/tv_mode.dart';
import 'package:lazer_nextgen/ui/playlist_page.dart';
import 'package:lazer_nextgen/ui/shell.dart';

import 'support/music_gateway.dart';

class _RoomGateway extends TestMusicGateway {
  _RoomGateway(this.enabled);
  final bool enabled;

  @override
  Set<MusicCapability> get capabilities => {
    if (enabled) MusicCapability.listenTogether,
  };
}

class _PlaylistCatalog extends Catalog {
  final List<Track> tracks = List<Track>.generate(
    40,
    (index) => Track(
      id: 'track-$index',
      title: 'Track $index',
      artist: 'Artist',
      album: 'Album',
      duration: const Duration(minutes: 3),
      coverSeed: index,
    ),
  );

  @override
  Future<List<Track>?> cachedPlaylistTracks(String playlistId) async => null;

  @override
  Stream<List<Track>> playlistTrackPages(String playlistId) async* {
    yield tracks;
  }
}

void main() {
  test(
    'floating lyrics expose text and handle, without blocking blank space',
    () {
      const size = Size(420, 300);
      final regions = lyricsOverlayInteractiveRegions(
        size,
        desktop: false,
        locked: false,
        lyricBounds: const <Rect>[
          Rect.fromLTWH(30, 40, 120, 40),
          Rect.fromLTWH(30, 150, 800, 40),
        ],
      );
      bool hit(Offset point) => regions.any((rect) => rect.contains(point));
      expect(hit(const Offset(60, 60)), isTrue);
      expect(hit(const Offset(380, 60)), isFalse);
      expect(hit(const Offset(400, 170)), isTrue);
      expect(hit(const Offset(440, 170)), isFalse);
      expect(hit(const Offset(10, 150)), isTrue);
      expect(hit(const Offset(10, 5)), isFalse);
      expect(
        lyricsOverlayInteractiveRegions(size, desktop: false, locked: true),
        isEmpty,
      );
    },
  );

  test('desktop lyrics retain a drag handle while the lyrics pass through', () {
    final regions = lyricsOverlayInteractiveRegions(
      const Size(420, 300),
      desktop: true,
      locked: true, // The floating lock must not lock the desktop handle.
      lyricBounds: const <Rect>[Rect.fromLTWH(30, 40, 120, 40)],
    );
    expect(regions, hasLength(1));
    expect(regions.single.contains(const Offset(12, 150)), isTrue);
    expect(regions.single.contains(const Offset(60, 60)), isFalse);
  });

  testWidgets(
    'TV player lives to the right of destinations and accepts Select',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var opened = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(),
          home: TvScope(
            active: true,
            child: Scaffold(
              body: LargeScreenNavBar(
                selected: LargeScreenTab.home,
                searchActive: false,
                canGoBack: false,
                onBack: () {},
                onTab: (_) {},
                onSearch: () {},
                onNowPlaying: () => opened++,
                account: const SizedBox.square(dimension: 44),
              ),
            ),
          ),
        ),
      );
      final player = find.byKey(const ValueKey('large-screen-now-playing'));
      final search = find.byKey(const ValueKey('large-screen-search'));
      expect(
        tester.getTopLeft(player).dx,
        greaterThan(tester.getTopRight(search).dx),
      );
      expect(find.text('正在播放'), findsNothing);
      expect(
        find.byKey(const ValueKey('large-screen-listen-together')),
        findsNothing,
      );
      final target = tester.element(
        find.descendant(of: player, matching: find.byType(GestureDetector)),
      );
      Focus.of(target).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(
        find.descendant(of: player, matching: find.byType(TvFocusOutline)),
        findsOneWidget,
      );
      expect(opened, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('playlist back affordance and hero scroll away with tracks', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1100, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(catalog: _PlaylistCatalog());
    addTearDown(state.dispose);
    var returned = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(),
        home: Scaffold(
          body: AppPlaylistPage(
            state: state,
            playlist: const Playlist(
              id: 'fixture',
              name: 'A playlist',
              trackIds: [],
              coverSeed: 1,
            ),
            onBack: () => returned = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final back = find.byKey(const ValueKey('playlist-scroll-back'));
    await tester.tap(back);
    expect(returned, isTrue);
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    scroll.position.jumpTo(650);
    await tester.pumpAndSettle();
    expect(back.hitTestable(), findsNothing);
    expect(find.text('A playlist').hitTestable(), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final style in [AppLayoutStyle.phone, AppLayoutStyle.desktop]) {
    testWidgets('remote account focus survives forced ${style.name} layout', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = AppState(deviceIsTelevision: true)..layoutStyle = style;
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(),
          home: TvScope(
            active: true,
            largeScreen: false,
            child: AppShell(state: state),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final account = find.byKey(
        ValueKey(
          style == AppLayoutStyle.desktop ? 'rail-account' : 'header-account',
        ),
      );
      Focus.of(
        tester.element(
          find.descendant(of: account, matching: find.byType(MouseRegion)).last,
        ),
      ).requestFocus();
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.ancestor(
            of: account,
            matching: find.byType(TvFocusHighlight),
          ),
          matching: find.byType(TvFocusOutline),
        ),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.text('音乐平台'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final bool tv in <bool>[false, true]) {
    for (final bool supportsRooms in <bool>[false, true]) {
      testWidgets(
        '${tv ? 'TV' : 'desktop'} room entry follows active plugin before playback: $supportsRooms',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          tester.view.physicalSize = const Size(1280, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final state = AppState(
            catalog: Catalog(gateway: _RoomGateway(supportsRooms)),
          )..layoutStyle = tv ? AppLayoutStyle.tv : AppLayoutStyle.desktop;
          addTearDown(state.dispose);
          await tester.pumpWidget(
            MaterialApp(
              theme: buildAppleTheme(),
              home: TvScope(
                active: tv,
                child: AppShell(state: state),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(state.current, isNull);
          // The desktop source list carries no room entry any more; the TV
          // chrome still surfaces one when the active plugin supports rooms.
          expect(
            find.byKey(
              ValueKey(
                tv ? 'large-screen-listen-together' : 'rail-listen-together',
              ),
            ),
            tv && supportsRooms ? findsOneWidget : findsNothing,
          );
          if (tv) {
            final account = find.byKey(const ValueKey('header-account'));
            final target = tester.element(
              find
                  .descendant(of: account, matching: find.byType(MouseRegion))
                  .last,
            );
            Focus.of(target).requestFocus();
            await tester.pumpAndSettle();
            final outline = find.descendant(
              of: find.ancestor(
                of: account,
                matching: find.byType(TvFocusHighlight),
              ),
              matching: find.byType(TvFocusOutline),
            );
            expect(outline, findsOneWidget);
            expect(
              tester.widget<TvFocusOutline>(outline).borderRadius,
              BorderRadius.circular(28),
            );
            await tester.sendKeyEvent(LogicalKeyboardKey.select);
            await tester.pumpAndSettle();
            expect(find.text('音乐平台'), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}
