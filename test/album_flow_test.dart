import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/legacy/legacy_background.dart';
import 'package:lazer_nextgen/legacy/legacy_shell.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';

const Track _track = Track(
  id: '1939575649',
  title: 'まにまに',
  artist: 'r-906 / 初音ミク',
  album: 'まにまに',
  duration: Duration(minutes: 4),
  coverSeed: 1,
  translatedTitle: '测试译名',
);

class _Gateway extends NeteaseGateway {
  @override
  Future<Set<int>> likedSongIds(int uid) async => <int>{};
}

class _Catalog extends Catalog {
  _Catalog() : super(gateway: _Gateway());
  @override
  Future<HomeFeed?> loadHome({int? userId}) async => home;
  @override
  HomeFeed? get home => const HomeFeed(
    recommended: <Playlist>[],
    featuredTracks: <Track>[_track],
    quick: <Track>[_track],
    playlists: <Playlist>[],
    albums: <Album>[],
  );
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async =>
      const GatewayLyrics(lrc: '[00:00.00]第一句');
  @override
  Future<List<Track>> playlistTracks(String id) async => <Track>[_track];
}

Widget _app(Widget home) => MaterialApp(
  theme: buildLegacyTheme(brightness: Brightness.dark),
  home: home,
);

Widget _reducedMotion(Widget child) => Builder(
  builder: (BuildContext context) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: true),
    child: child,
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the flow palette is a five-step ramp on the seed hue', () {
    final List<Color> palette = albumFlowColors(const Color(0xFF8A9A3C));
    expect(palette, hasLength(5));
    final HSLColor seed = HSLColor.fromColor(const Color(0xFF8A9A3C));
    final List<double> lightness = <double>[
      for (final Color color in palette) HSLColor.fromColor(color).lightness,
    ];
    expect(
      lightness,
      orderedEquals(<double>[...lightness]..sort((a, b) => b.compareTo(a))),
    );
    expect(lightness.first, closeTo(0.90, 0.005));
    expect(lightness.last, closeTo(0.31, 0.005));
    for (final Color color in palette) {
      final double hue = HSLColor.fromColor(color).hue;
      final double delta = (hue - seed.hue).abs();
      expect(delta < 1 || delta > 359, isTrue, reason: 'hue drifted: $hue');
    }
    // An achromatic seed still gets the legacy floor chroma (hue 0).
    final List<Color> grey = albumFlowColors(const Color(0xFF808080));
    expect(HSLColor.fromColor(grey[2]).saturation, closeTo(0.20, 0.001));
  });

  test('the palette normalizer always yields five colours', () {
    expect(normalizeFlowPalette(const <Color>[]), hasLength(5));
    expect(
      normalizeFlowPalette(<Color>[const Color(0xFF112233)]),
      hasLength(5),
    );
    final List<Color> two = normalizeFlowPalette(<Color>[
      const Color(0xFF112233),
      const Color(0xFF445566),
    ]);
    expect(two[0], two[2]);
    expect(two[0], two[4]);
    expect(two[1], two[3]);
  });

  test('the palette fetches a 96px rendition of the cover', () {
    expect(
      albumPaletteArtworkUrl(
        'https://p1.music.126.net/a/b.jpg?param=1024y1024',
      ),
      'https://p1.music.126.net/a/b.jpg?param=96y96',
    );
    expect(
      albumPaletteArtworkUrl('//p1.music.126.net/a/b.jpg'),
      'https://p1.music.126.net/a/b.jpg?param=96y96',
    );
    expect(
      albumPaletteArtworkUrl('https://p1.music.126.net/a/b.jpg?x=1'),
      'https://p1.music.126.net/a/b.jpg?x=1&param=96y96',
    );
    expect(albumPaletteArtworkUrl(''), isNull);
    expect(albumPaletteArtworkUrl(null), isNull);
  });

  test('the seed extractor prefers the dominant vibrant colour', () {
    // 8×8: 56 red pixels and 8 neutral ones — red must win, saturation boosted.
    final Uint8List pixels = Uint8List(8 * 8 * 4);
    for (int i = 0; i < 8 * 8; i++) {
      final bool red = i < 56;
      pixels[i * 4] = red ? 200 : 128;
      pixels[i * 4 + 1] = red ? 40 : 128;
      pixels[i * 4 + 2] = red ? 40 : 128;
      pixels[i * 4 + 3] = 255;
    }
    final Color seed = albumSeedFromPixels(pixels, 8, 8);
    final HSLColor hsl = HSLColor.fromColor(seed);
    expect(hsl.hue < 3 || hsl.hue > 357, isTrue, reason: 'hue ${hsl.hue}');
    expect(
      hsl.saturation,
      greaterThan(HSLColor.fromColor(const Color(0xFFC82828)).saturation),
    );
    expect(albumSeedFromPixels(Uint8List(0), 0, 0), kAlbumDefaultSeed);
  });

  test('mesh palette preserves distinct cover hues', () {
    const int size = 16;
    final Uint8List pixels = Uint8List(size * size * 4);
    const List<Color> source = <Color>[
      Color(0xFFD12A3A),
      Color(0xFF2768D8),
      Color(0xFF38A85A),
      Color(0xFFE0B33A),
    ];
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final Color color = source[(y ~/ 8) * 2 + (x ~/ 8)];
        final int offset = (y * size + x) * 4;
        pixels[offset] = (color.r * 255).round();
        pixels[offset + 1] = (color.g * 255).round();
        pixels[offset + 2] = (color.b * 255).round();
        pixels[offset + 3] = 255;
      }
    }
    final List<Color> palette = albumMeshColorsFromPixels(pixels, size, size);
    expect(palette, hasLength(5));
    final Set<int> hueBuckets = <int>{
      for (final Color color in palette)
        (HSLColor.fromColor(color).hue / 45).floor(),
    };
    expect(hueBuckets.length, greaterThanOrEqualTo(3));
  });

  testWidgets('the flow background paints its layers and can be frozen', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        Center(
          child: SizedBox(
            width: 400,
            height: 240,
            child: AlbumFlowBackground(
              colors: albumFlowColors(const Color(0xFF8A9A3C)),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 33));
    await tester.pump(const Duration(milliseconds: 33));
    // The whole canvas is one painter now: five gradients in one pass, no
    // per-layer Transform widgets and no composited layers.
    expect(
      find.descendant(
        of: find.byType(AlbumFlowBackground),
        matching: find.byType(CustomPaint),
      ),
      findsOneWidget,
    );
    expect(find.byType(Transform), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
      _app(
        Center(
          child: SizedBox(
            width: 400,
            height: 240,
            child: AlbumFlowBackground(
              colors: albumFlowColors(const Color(0xFF8A9A3C)),
              solid: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(Transform), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the backdrop disappears when the mode is off', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await state.setLegacyBackground(LegacyBackgroundMode.off);
    await tester.pumpWidget(_app(_reducedMotion(LegacyShell(state: state))));
    await tester.pumpAndSettle();
    expect(find.byType(LegacyAlbumBackdrop), findsNothing);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor,
      isNot(Colors.transparent),
    );

    await state.setLegacyBackground(LegacyBackgroundMode.nowPlayingDynamic);
    await tester.pumpAndSettle();
    expect(find.byType(LegacyAlbumBackdrop), findsOneWidget);
    expect(find.byType(AlbumFlowBackground), findsOneWidget);
  });

  test('the backdrop preferences persist and clamp', () async {
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    expect(state.legacyBackground, LegacyBackgroundMode.nowPlayingDynamic);
    expect(state.legacyUiAlpha, 0.7);

    await state.setLegacyBackground(LegacyBackgroundMode.nowPlayingStatic);
    await state.setLegacyUiAlpha(0.1);
    expect(state.legacyUiAlpha, 0.4);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('lazer_legacy_background'), 'nowPlayingStatic');
    expect(prefs.getDouble('lazer_legacy_ui_alpha'), 0.4);

    final AppState restarted = AppState(catalog: _Catalog());
    addTearDown(restarted.dispose);
    await restarted.bootstrap();
    expect(restarted.legacyBackground, LegacyBackgroundMode.nowPlayingStatic);
    expect(restarted.legacyUiAlpha, 0.4);
    expect(
      LegacyBackgroundModeLabels.parse('nope'),
      LegacyBackgroundMode.nowPlayingDynamic,
    );
  });

  testWidgets('the legacy settings drive the backdrop', (tester) async {
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await tester.pumpWidget(_app(_reducedMotion(LegacyShell(state: state))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rail-account')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();

    expect(find.text('背景'), findsOneWidget);
    expect(find.text('内容不透明度'), findsOneWidget);
    expect(find.text('70%'), findsOneWidget);

    await tester.ensureVisible(
      find.byKey(const ValueKey('browse-background-mode')),
    );
    await tester.tap(find.byKey(const ValueKey('browse-background-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('不使用').last);
    await tester.pumpAndSettle();
    expect(state.legacyBackground, LegacyBackgroundMode.off);
    expect(find.byType(LegacyAlbumBackdrop), findsNothing);

    await tester.tap(find.byKey(const ValueKey('browse-background-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('静态背景').last);
    await tester.pumpAndSettle();
    expect(state.legacyBackground, LegacyBackgroundMode.nowPlayingStatic);

    final Finder alpha = find.descendant(
      of: find.byKey(const ValueKey('legacy-ui-alpha')),
      matching: find.byType(Slider),
    );
    await tester.ensureVisible(alpha);
    await tester.drag(alpha, const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(state.legacyUiAlpha, lessThan(0.7));
    expect(tester.takeException(), isNull);
  });
}
