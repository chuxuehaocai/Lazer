import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/ui/background.dart';
import 'package:lazer_nextgen/ui/pages.dart';
import 'package:lazer_nextgen/ui/shell.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/tv/large_screen_pages.dart';

const Track _track = Track(
  id: 'custom-theme-fixture',
  title: 'Fixture',
  artist: 'Test artist',
  album: 'Test album',
  duration: Duration(minutes: 3),
  coverSeed: 2,
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
      const GatewayLyrics(lrc: '[00:00.00]First lyric');
  @override
  Future<List<Track>> playlistTracks(String id) async => <Track>[_track];
}

Widget _app(Widget home, {Brightness brightness = Brightness.dark}) =>
    MaterialApp(
      theme: buildAppleTheme(brightness: brightness),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: home,
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a custom accent persists and seeds the palette', () async {
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    expect(state.paletteMode, AppPaletteMode.fixed);
    expect(state.accentSeed, isNull);

    await state.setAppPalette(AppPaletteMode.custom);
    expect(
      state.accentSeed,
      isNull,
      reason: 'the shipped red stays until a colour is chosen',
    );

    await state.setAppAccent(const Color(0xFF3366CC));
    expect(state.accentSeed, const Color(0xFF3366CC));
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('lazer_legacy_accent'), 0xFF3366CC);
    expect(prefs.getString('lazer_legacy_palette'), 'custom');

    final AppState restarted = AppState(catalog: _Catalog());
    addTearDown(restarted.dispose);
    await restarted.bootstrap();
    expect(restarted.paletteMode, AppPaletteMode.custom);
    expect(restarted.accentSeed, const Color(0xFF3366CC));
    expect(AppPaletteModeLabels.parse('custom'), AppPaletteMode.custom);
    expect(AppPaletteModeLabels.parse('nope'), AppPaletteMode.fixed);
  });

  test('a custom picture is its own persistent background mode', () async {
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await state.setAppBackgroundImage('/tmp/backdrop.png');
    await state.setAppBackground(AppBackgroundMode.customImage);
    expect(state.backgroundImagePath, '/tmp/backdrop.png');
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('lazer_legacy_background_image'),
      '/tmp/backdrop.png',
    );
    expect(prefs.getString('lazer_legacy_background'), 'customImage');

    final AppState restarted = AppState(catalog: _Catalog());
    addTearDown(restarted.dispose);
    await restarted.bootstrap();
    expect(restarted.backgroundImagePath, '/tmp/backdrop.png');
    expect(restarted.backgroundMode, AppBackgroundMode.customImage);

    await restarted.setAppBackgroundImage(null);
    expect(prefs.getString('lazer_legacy_background_image'), isNull);
    expect(restarted.backgroundImagePath, isNull);
  });

  test(
    'an app-owned backdrop persists its file name, not its container path',
    () async {
      final Directory directory = Directory.systemTemp.createTempSync(
        'lazer-owned-backdrop',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final File image = File(
        '${directory.path}${Platform.pathSeparator}background_42.png',
      )..writeAsBytesSync(_onePixelPng);

      final AppState state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      await state.setAppBackgroundImage(image.path);
      await state.setAppBackground(AppBackgroundMode.customImage);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('lazer_legacy_background_image'),
        'background_42.png',
        reason: 'iOS may move the container between launches',
      );
      expect(state.backgroundImagePath, image.path);

      final AppState restarted = AppState(catalog: _Catalog());
      addTearDown(restarted.dispose);
      await restarted.bootstrap();
      // The test platform has no app-support directory handler; restore keeps
      // the portable name rather than losing the choice.
      expect(restarted.backgroundImagePath, 'background_42.png');
      expect(restarted.backgroundMode, AppBackgroundMode.customImage);
    },
  );

  testWidgets('an off dark backdrop is a lifted canvas, never pure black', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await state.setAppBackground(AppBackgroundMode.off);

    await tester.pumpWidget(_app(AppShell(state: state)));
    await tester.pumpAndSettle();
    final Scaffold scaffold = tester.widget<Scaffold>(
      find.byType(Scaffold).first,
    );
    expect(scaffold.backgroundColor, AppleColors.darkCanvas);
    expect(scaffold.backgroundColor, isNot(Colors.black));
    expect(find.byType(AppAlbumBackdrop), findsNothing);

    // The light theme keeps the system background, which is already not black.
    await tester.pumpWidget(
      _app(AppShell(state: state), brightness: Brightness.light),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor,
      AppleSemanticColors.light.background,
    );
  });

  testWidgets('a custom picture paints behind the shell content', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final Directory directory = Directory.systemTemp.createTempSync(
      'lazer-backdrop',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final File image = File('${directory.path}${Platform.pathSeparator}bg.png')
      ..writeAsBytesSync(_onePixelPng);

    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await state.setAppBackgroundImage(image.path);
    await state.setAppBackground(AppBackgroundMode.customImage);

    await tester.pumpWidget(_app(AppShell(state: state)));
    await tester.pump();
    expect(find.byType(AppAlbumBackdrop), findsOneWidget);
    expect(find.byType(AlbumFlowBackground), findsNothing);
    final Image painted = tester.widget<Image>(find.byType(Image).first);
    expect(painted.image, isA<FileImage>());
    expect((painted.image as FileImage).file.path, image.path);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the player keeps its album flow when the backdrop is off', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await state.setAppBackground(AppBackgroundMode.off);
    state.playQueue(const <Track>[_track]);

    await tester.pumpWidget(_app(AppShell(state: state)));
    await tester.pump();
    await tester.tap(find.byTooltip('歌词'));
    await tester.pumpAndSettle();
    expect(find.byType(NowPlayingPage), findsOneWidget);
    final Finder flow = find.byType(AlbumFlowBackground);
    expect(flow, findsOneWidget);
    expect(
      find.ancestor(of: flow, matching: find.byType(NowPlayingPage)),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings expose the accent swatch and the picture row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);

    await tester.pumpWidget(
      _app(
        AnimatedBuilder(
          animation: state,
          builder: (BuildContext context, _) =>
              Scaffold(body: AppSettingsPage(state: state)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('强调色'), findsNothing);

    await state.setAppPalette(AppPaletteMode.custom);
    await tester.pumpAndSettle();
    expect(find.text('强调色'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('accent-swatch')));
    await tester.pumpAndSettle();
    expect(find.text('自定义主题色'), findsOneWidget);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(state.accentColor, AppleColors.musicRed);
    expect(find.text('#FA2D48'), findsOneWidget);

    await state.setAppBackground(AppBackgroundMode.customImage);
    await tester.pumpAndSettle();
    expect(find.text('背景图片'), findsOneWidget);
    expect(find.byKey(const ValueKey('background-image-pick')), findsOneWidget);
    expect(find.byKey(const ValueKey('background-image-clear')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the picture action adopts the chosen file', (tester) async {
    tester.view.physicalSize = const Size(1280, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final Directory directory = Directory.systemTemp.createTempSync(
      'lazer-pick-backdrop',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final File image = File(
      '${directory.path}${Platform.pathSeparator}background_77.png',
    )..writeAsBytesSync(_onePixelPng);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await state.setAppBackground(AppBackgroundMode.customImage);
    int picks = 0;

    await tester.pumpWidget(
      _app(
        AnimatedBuilder(
          animation: state,
          builder: (BuildContext context, _) => Scaffold(
            body: AppSettingsPage(
              state: state,
              backgroundImagePicker: () async {
                picks++;
                return image.path;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('background-image-pick')));
    await tester.pumpAndSettle();
    expect(picks, 1);
    expect(state.backgroundImagePath, image.path);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('lazer_legacy_background_image'),
      'background_77.png',
    );
  });

  testWidgets('large-screen settings can replace the backdrop too', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await state.setAppBackground(AppBackgroundMode.customImage);
    const String picked = '/tmp/background_large.png';

    await tester.pumpWidget(
      _app(
        AnimatedBuilder(
          animation: state,
          builder: (BuildContext context, _) => Scaffold(
            body: LargeScreenSettingsPage(
              state: state,
              onOpenLocalMusic: () {},
              backgroundImagePicker: () async => picked,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('background-image-pick')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('background-image-pick')));
    await tester.pumpAndSettle();
    expect(state.backgroundImagePath, picked);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the accent picker fits a phone-width settings page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await state.setAppPalette(AppPaletteMode.custom);

    await tester.pumpWidget(
      _app(
        AnimatedBuilder(
          animation: state,
          builder: (BuildContext context, _) =>
              Scaffold(body: AppSettingsPage(state: state)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('accent-swatch')));
    await tester.pumpAndSettle();
    expect(find.text('自定义主题色'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(state.accentColor, isNull);
  });
}

/// 1×1 transparent PNG; enough for [Image.file] to resolve without errors.
const List<int> _onePixelPng = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];
