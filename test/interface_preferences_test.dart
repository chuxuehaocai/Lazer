import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/audio/system_media_handler.dart';
import 'package:lazer_nextgen/main.dart';
import 'package:lazer_nextgen/l10n/app_localizations.dart';
import 'package:lazer_nextgen/player/desktop_now_playing.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/playback_queue_store.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/tv/tv_mode.dart';
import 'package:lazer_nextgen/widgets/catalog_links.dart';
import 'package:lazer_nextgen/widgets/ui_scaling.dart';
import 'package:lazer_nextgen/widgets/volume_control.dart';

class _RootState extends AppState {
  _RootState({super.deviceIsTelevision});
  @override
  Future<void> bootstrap() async {}
}

class _UnusedAudio extends Fake implements AudioEngine {
  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'content, browse and player opacity persist independently of old veil',
    () async {
      SharedPreferences.setMockInitialValues({'lazer_legacy_ui_alpha': .4});
      AppState create() => AppState(
        queueStore: PlaybackQueueStore(
          read: () async => null,
          write: (_) async {},
        ),
        artworkSeedLoader: (_) async => null,
      );
      final first = create();
      await first.bootstrap();
      expect(first.uiAlpha, 1);
      expect(first.browseBackgroundFps, 0);
      expect(first.playerBackgroundFps, 0);
      await first.setBackgroundFps(144);
      expect(first.browseBackgroundFps, 144);
      await first.setBackgroundFps(0);
      await first.setAppUiAlpha(.65);
      await first.setBackgroundOpacity(.25);
      await first.setBackgroundOpacity(.8, player: true);
      await first.setTitleBarStyle(DesktopTitleBarStyle.classic);
      await first.setBackgroundFps(0, player: true);
      first.dispose();
      final restored = create();
      addTearDown(restored.dispose);
      await restored.bootstrap();
      expect(restored.uiAlpha, .65);
      expect(restored.backgroundOpacity, .25);
      expect(restored.playerBackgroundOpacity, .8);
      expect(restored.titleBarStyle, DesktopTitleBarStyle.classic);
      expect(restored.playerBackgroundFps, 0);
      expect(restored.browseBackgroundFps, 0);
      await restored.setAppUiAlpha(double.nan);
      await restored.setBackgroundOpacity(double.infinity);
      expect(restored.uiAlpha, .65);
      expect(restored.backgroundOpacity, .25);
    },
  );

  test('inline capsule paint settings persist, clamp and reset', () async {
    AppState create() => AppState(
      queueStore: PlaybackQueueStore(
        read: () async => null,
        write: (_) async {},
      ),
      artworkSeedLoader: (_) async => null,
    );
    final first = create();
    await first.bootstrap();
    expect(first.windowChromeBlurEnabled, isTrue);
    expect(first.windowChromeBlur, kWindowChromeBlurDefault);
    expect(first.windowChromeOpacity, kWindowChromeOpacityDefault);
    expect(first.windowChromeColor, isNull);

    await first.setWindowChromeBlurEnabled(false);
    await first.setWindowChromeBlur(22);
    await first.setWindowChromeOpacity(.4);
    await first.setWindowChromeColor(const Color(0xFF3366FF));
    first.dispose();

    final restored = create();
    addTearDown(restored.dispose);
    await restored.bootstrap();
    expect(restored.windowChromeBlurEnabled, isFalse);
    expect(restored.windowChromeBlur, 22);
    expect(restored.windowChromeOpacity, .4);
    expect(restored.windowChromeColor, const Color(0xFF3366FF));

    // Sliders clamp instead of persisting nonsense; null returns to the accent.
    await restored.setWindowChromeBlur(double.nan);
    await restored.setWindowChromeOpacity(9);
    expect(restored.windowChromeBlur, 22);
    expect(restored.windowChromeOpacity, kWindowChromeOpacityMax);
    await restored.setWindowChromeColor(null);
    expect(restored.windowChromeColor, isNull);
  });

  testWidgets(
    'root immediately applies layout and retains remote input on a TV',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(
        () => AppLocalizations.delegate.load(const Locale('en')),
      );
      final state = _RootState(deviceIsTelevision: true)..autoDpiScale = false;
      await state.setIndependentPlayback(true);
      final media = SystemMediaController(state);
      await tester.pumpWidget(
        LazerApp(state: state, audio: _UnusedAudio(), media: media),
      );
      await tester.pump();
      expect(tester.widget<UiMetrics>(find.byType(UiMetrics)).tv, isTrue);
      await state.setLayoutStyle(AppLayoutStyle.desktop);
      await tester.pump();
      await tester.pump();
      final context = tester.element(find.byType(UiMetrics));
      expect(tester.widget<UiMetrics>(find.byType(UiMetrics)).tv, isFalse);
      expect(largeScreenModeOf(context), isFalse);
      expect(TvScope.isActive(context), isTrue);
      await state.setLayoutStyle(AppLayoutStyle.tv);
      await tester.pump();
      expect(tester.widget<UiMetrics>(find.byType(UiMetrics)).tv, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  for (final tv in [false, true]) {
    testWidgets('player auxiliary controls and metadata focus: tv=$tv', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = AppState();
      addTearDown(state.dispose);
      const track = Track(
        id: 'fixture',
        title: 'A song',
        artist: 'Artist',
        album: 'Album',
        duration: Duration(minutes: 3),
        coverSeed: 2,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(brightness: Brightness.dark),
          home: TvScope(
            active: tv,
            child: Scaffold(
              body: DesktopNowPlaying(
                state: state,
                track: track,
                artwork: const ColoredBox(color: Colors.blue),
                lyrics: const Text('Lyrics'),
                comments: const Text('Comments'),
                queue: const Text('Queue'),
                pane: DesktopNowPlayingPane.lyrics,
                onPaneChanged: (_) {},
                onBack: () {},
                onSaveArtwork: () {},
                onFullscreen: () {},
                controlsVisible: true,
                onActivity: () {},
              ),
            ),
          ),
        ),
      );
      expect(find.byType(VolumeControl), tv ? findsNothing : findsOneWidget);
      expect(
        find.byKey(const ValueKey('desktop-fullscreen')),
        tv ? findsNothing : findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        MaterialApp(
          home: TvScope(
            active: tv,
            child: Scaffold(
              body: Center(
                child: CatalogTextLink(text: 'Artist', onTap: () {}),
              ),
            ),
          ),
        ),
      );
      expect(find.byType(TvTapTarget), tv ? findsOneWidget : findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
