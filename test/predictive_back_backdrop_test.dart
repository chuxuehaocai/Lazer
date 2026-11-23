import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

import 'support/music_gateway.dart';

/// A canvas this test can recognise in the rendered frame: every pixel the
/// shell paints behind its pages is green.
const Color _canvas = Color(0xFF1F7A3D);

class _AlbumsGateway extends TestMusicGateway {
  @override
  Future<MusicPage<MusicAlbum>> savedAlbums({
    int limit = 30,
    int offset = 0,
  }) async => MusicPage<MusicAlbum>(
    <MusicAlbum>[
      for (var index = 0; index < 12; index++)
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
    backgroundMode = AppBackgroundMode.solidColor;
    browseBackgroundColor = _canvas;
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
final _root = GlobalKey();

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

Future<void> _settle(WidgetTester tester, {int frames = 60}) async {
  for (var index = 0; index < frames; index++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

/// The rendered frame, sampled at a point. Returns null when the capture is
/// unavailable in this host.
Future<Color? Function(int, int)> _frame(WidgetTester tester) async {
  final render =
      _root.currentContext?.findRenderObject() as RenderRepaintBoundary?;
  if (render == null) return (_, _) => null;
  final ui.Image? image = await tester.runAsync(
    () => render.toImage(pixelRatio: 1),
  );
  if (image == null) return (_, _) => null;
  final data = await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  );
  if (data == null) return (_, _) => null;
  final bytes = data.buffer.asUint8List();
  return (int x, int y) {
    final offset = (y * image.width + x) * 4;
    if (offset < 0 || offset + 3 >= bytes.length) return null;
    return Color.fromARGB(
      bytes[offset + 3],
      bytes[offset],
      bytes[offset + 1],
      bytes[offset + 2],
    );
  };
}

/// Every pixel of the frozen canvas the preview paints under the page that is
/// leaving, sampled from the image itself.
Future<Color? Function(int, int)> _imagePixels(
  WidgetTester tester,
  ui.Image image,
) async {
  final data = await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  );
  if (data == null) return (_, _) => null;
  final bytes = data.buffer.asUint8List();
  return (int x, int y) {
    final offset = (y * image.width + x) * 4;
    if (offset < 0 || offset + 3 >= bytes.length) return null;
    return Color.fromARGB(
      bytes[offset + 3],
      bytes[offset],
      bytes[offset + 1],
      bytes[offset + 2],
    );
  };
}

int _distance(Color a, Color b) =>
    ((a.r - b.r).abs() * 255).round() +
    ((a.g - b.g).abs() * 255).round() +
    ((a.b - b.b).abs() * 255).round();

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the Android back preview keeps the destination backdrop', (
    tester,
  ) async {
    await _previewKeepsBackdrop(tester, ios: false);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('the iOS edge drag keeps the destination backdrop', (
    tester,
  ) async {
    await _previewKeepsBackdrop(tester, ios: true);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}

/// Opens 收藏的专辑, drags back halfway and checks what the preview paints
/// behind the page that is leaving.
Future<void> _previewKeepsBackdrop(
  WidgetTester tester, {
  required bool ios,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.runAsync(
    () => AppLocalizations.delegate.load(const Locale('en')),
  );
  final state = _State();
  await state.setIndependentPlayback(true);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _root,
      child: LazerApp(
        state: state,
        audio: _UnusedAudio(),
        media: SystemMediaController(state),
      ),
    ),
  );
  await tester.pump();
  await _settle(tester);

  await tester.tap(find.byIcon(Icons.library_music_outlined));
  await tester.pump();
  await _settle(tester);
  final Finder albums = find.byType(AppSavedAlbumsPage);
  await tester.tap(find.byKey(const ValueKey<String>('open-saved-albums')));
  await tester.pump();
  await _settle(tester);
  expect(albums, findsOneWidget);

  // Where the page sits, and what the shell paints behind its empty top-left
  // corner before the gesture starts.
  final Rect page = tester.getRect(albums);
  final Color? idle = (await _frame(tester))(
    (page.left + 8).round(),
    (page.top + 8).round(),
  );
  expect(idle, isNotNull);
  expect(
    idle!.g,
    greaterThan(idle.r),
    reason: 'the test canvas has to be recognisable behind the page',
  );

  TestGesture? drag;
  if (ios) {
    // iOS owns the leading edge: the same preview runs from a real drag.
    drag = await tester.startGesture(const Offset(4, 400));
    await drag.moveTo(const Offset(199, 400));
    await tester.pump(const Duration(milliseconds: 60));
  } else {
    await _back(tester, 'startBackGesture', _event(0));
    await tester.pump();
    await _back(tester, 'updateBackGestureProgress', _event(.5));
    await tester.pump(const Duration(milliseconds: 60));
  }

  final Finder backdrop = find.byKey(
    const ValueKey<String>('browse-preview-backdrop'),
  );
  expect(
    backdrop,
    findsOneWidget,
    reason: 'the leaving page must carry the shared canvas, not a flat surface',
  );
  final RawImage painted = tester.widget<RawImage>(backdrop);
  final ui.Image image = painted.image!;
  expect(tester.getSize(backdrop), page.size);
  expect(
    image.width,
    greaterThanOrEqualTo(page.width.round()),
    reason: 'the frozen canvas covers the page it is painted in',
  );

  // The frozen frame is the canvas itself: the very pixel the shell paints
  // behind the page's top-left corner, never the flat surface it replaced.
  final double ratio = image.width / page.width;
  final Color? frozen = (await _imagePixels(tester, image))(
    (8 * ratio).round(),
    (8 * ratio).round(),
  );
  expect(frozen, isNotNull);
  expect(_distance(frozen!, idle), lessThan(24));
  expect(
    frozen.g,
    greaterThan(frozen.r),
    reason: 'the preview painted a flat surface instead of the canvas',
  );

  if (drag != null) {
    await drag.up();
  } else {
    await _back(tester, 'cancelBackGesture');
  }
  await _settle(tester);
  expect(
    find.byKey(const ValueKey<String>('browse-preview-backdrop')),
    findsNothing,
    reason: 'the frozen frame belongs to the gesture',
  );
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}
