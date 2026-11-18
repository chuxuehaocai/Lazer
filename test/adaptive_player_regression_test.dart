import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/player/desktop_now_playing.dart';
import 'package:lazer_nextgen/player/artwork_lyrics_layout.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/player_bar.dart';
import 'package:lazer_nextgen/ui/shell.dart';

import 'support/player_transition.dart';
import 'package:lazer_nextgen/widgets/player_controls_bar.dart';
import 'package:lazer_nextgen/widgets/player_seek_bar.dart';
import 'package:lazer_nextgen/widgets/window_frame.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _track = Track(
  id: 'adaptive-player',
  title: 'A track with a long title that stays on one line',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 3),
  coverSeed: 1,
);

class _PlayerState extends AppState {
  _PlayerState() {
    autoDpiScale = false;
    layoutStyle = AppLayoutStyle.desktop;
    playerBackground = AppBackgroundMode.off;
  }

  int toggles = 0;
  int skips = 0;
  final seeks = <double>[];
  Track selected = _track;
  @override
  Track get current => selected;
  @override
  bool get playing => toggles.isOdd;
  @override
  Listenable get all => this;
  @override
  Future<void> ensureCurrentLyrics({bool force = false}) async {}
  @override
  void playerPresentationChanged(bool visible) {}
  @override
  void togglePlay() {
    toggles++;
    notifyListeners();
  }

  @override
  Future<void> next() async {
    skips++;
  }

  @override
  void seek(double value) {
    seeks.add(value);
  }

  void updateStyle(AppLayoutStyle value) {
    layoutStyle = value;
    notifyListeners();
  }
}

Widget _host(Widget child, {double textScale = 1}) => MaterialApp(
  theme: buildAppleTheme(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(textScale),
      disableAnimations: true,
    ),
    child: child!,
  ),
  home: Scaffold(body: Center(child: child)),
);

List<String?> _controls(WidgetTester tester) => tester
    .widgetList<IconButton>(find.byType(IconButton))
    .map((button) => button.tooltip)
    .toList();

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final framed in [false, true]) {
    testWidgets(
      'player changes at the shared breakpoint with window frame $framed',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        const channel = MethodChannel('window_manager');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async => switch (call.method) {
            'isMaximized' || 'isFullScreen' => false,
            'isFocused' => true,
            _ => null,
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        final state = _PlayerState();
        addTearDown(state.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppleTheme(),
            builder: (context, child) =>
                WindowFrame(enabled: framed, state: state, child: child!),
            home: NowPlayingPage(state: state),
          ),
        );
        await tester.pump();
        expect(find.byType(DesktopNowPlaying), findsOneWidget);
        for (final width in [
          kCompactBreakpoint - 1,
          400.0,
          kCompactBreakpoint,
        ]) {
          tester.view.physicalSize = Size(width, 800);
          await tester.pumpAndSettle();
          final compact = width < kCompactBreakpoint;
          expect(
            find.byType(ArtworkLyricsLayout),
            compact ? findsOneWidget : findsNothing,
          );
          expect(
            find.byType(DesktopNowPlaying),
            compact ? findsNothing : findsOneWidget,
          );
          if (compact) {
            for (final label in ['随机播放', '上一首', '播放', '下一首', '循环播放']) {
              expect(find.byTooltip(label).hitTestable(), findsOneWidget);
            }
            expect(
              find.byKey(const ValueKey('now-playing-more')).hitTestable(),
              findsOneWidget,
            );
          }
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }

  testWidgets('phone and narrow desktop share bottom controls through resize', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = _PlayerState();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(AppPlayerBar(state: state, onOpen: () {})));
    expect(find.byType(PlayerSeekBar), findsOneWidget);
    tester.view.physicalSize = const Size(kCompactBreakpoint - 1, 800);
    await tester.pumpAndSettle();
    expect(find.byType(PlayerSeekBar), findsNothing);
    final narrowControls = _controls(tester);
    expect(narrowControls, ['播放', '下一首']);
    for (final button in find.byType(IconButton).evaluate()) {
      expect(
        tester.getSize(find.byWidget(button.widget)).width,
        greaterThanOrEqualTo(44),
      );
    }
    await tester.tap(find.byTooltip('播放'));
    await tester.tap(find.byTooltip('下一首'));
    await tester.pump();
    expect(state.toggles, 1);
    expect(state.skips, 1);
    state.togglePlay();
    state.updateStyle(AppLayoutStyle.phone);
    tester.view.physicalSize = const Size(1280, 800);
    await tester.pumpAndSettle();
    expect(_controls(tester), narrowControls);
    state.updateStyle(AppLayoutStyle.desktop);
    await tester.pumpAndSettle();
    expect(find.byType(PlayerSeekBar), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final width in [
    320.0,
    400.0,
    kCompactBreakpoint - 1,
    kCompactBreakpoint,
    1280.0,
  ]) {
    testWidgets('catalog footer shares transport without overflow at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = _PlayerState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        _host(PlayerControlsBar(state: state, onExpand: () {})),
      );
      expect(find.byType(AppPlayerBar), findsOneWidget);
      expect(
        find.byType(PlayerSeekBar),
        width < kCompactBreakpoint ? findsNothing : findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('player shortcuts follow the currently visible layout', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = _PlayerState();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(NowPlayingPage(state: state)));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
    await tester.pumpAndSettle();
    expect(
      tester.widget<DesktopNowPlaying>(find.byType(DesktopNowPlaying)).pane,
      DesktopNowPlayingPane.queue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.pumpAndSettle();
    expect(
      tester.widget<DesktopNowPlaying>(find.byType(DesktopNowPlaying)).pane,
      DesktopNowPlayingPane.lyrics,
    );
    // The same key folds the reading pane away and, pressed again mid-flight,
    // reverses that fold instead of queueing a second animation.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.pump();
    expect(
      tester.widget<DesktopNowPlaying>(find.byType(DesktopNowPlaying)).pane,
      DesktopNowPlayingPane.none,
    );
    await tester.pump(const Duration(milliseconds: 80));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.pumpAndSettle();
    expect(
      tester.widget<DesktopNowPlaying>(find.byType(DesktopNowPlaying)).pane,
      DesktopNowPlayingPane.lyrics,
    );
    tester.view.physicalSize = const Size(400, 800);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ArtworkLyricsLayout>(find.byType(ArtworkLyricsLayout))
          .lyricsVisible,
      isTrue,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('compact footer grows for large accessibility text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = _PlayerState()..layoutStyle = AppLayoutStyle.phone;
    addTearDown(state.dispose);
    await tester.pumpWidget(
      _host(PlayerControlsBar(state: state, onExpand: () {}), textScale: 2),
    );
    expect(tester.getSize(find.byType(AppPlayerBar)).height, greaterThan(60));
    expect(find.byTooltip('播放').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final style in [AppLayoutStyle.phone, AppLayoutStyle.desktop]) {
    testWidgets(
      'shell exposes the round phone player entry in ${style.name}',
      (tester) async {
        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final state = _PlayerState()..layoutStyle = style;
        addTearDown(state.dispose);
        await tester.pumpWidget(_host(AppShell(state: state)));
        await tester.pumpAndSettle();
        final cover = find.byKey(const ValueKey('bottom-track-cover'));
        expect(cover.hitTestable(), findsOneWidget);
        expect(tester.getSize(cover), const Size.square(48));
        expect(find.byType(AppPlayerBar), findsNothing);
        await tapNowPlayingControl(tester);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('now-playing-transport')).hitTestable(),
          findsOneWidget,
        );
        expect(find.byType(DesktopNowPlaying), findsNothing);
        await tester.tap(find.byTooltip('播放').hitTestable());
        await tester.tap(find.byTooltip('下一首').hitTestable());
        await tester.pump();
        expect(state.toggles, 1);
        expect(state.skips, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

  for (final width in [720.0, 800.0, 1000.0]) {
    testWidgets('desktop shell keeps the full bottom bar at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = _PlayerState();
      addTearDown(state.dispose);
      await tester.pumpWidget(_host(AppShell(state: state)));
      await tester.pumpAndSettle();
      final bar = find.byType(AppPlayerBar);
      expect(find.byType(PlayerSeekBar), findsOneWidget);
      expect(tester.widget<AppPlayerBar>(bar).compact, isFalse);
      for (final label in ['上一首', '播放', '下一首', '音量', '播放队列', '歌词']) {
        expect(
          find
              .descendant(of: bar, matching: find.byTooltip(label))
              .hitTestable(),
          findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'full transport grows for large accessibility text at the boundary',
    (tester) async {
      tester.view.physicalSize = const Size(kCompactBreakpoint, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = _PlayerState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        _host(AppPlayerBar(state: state, onOpen: () {}), textScale: 3),
      );
      expect(tester.getSize(find.byType(AppPlayerBar)).height, greaterThan(92));
      expect(find.byType(PlayerSeekBar), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('shared desktop seek cancels without changing playback', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = _PlayerState();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(AppPlayerBar(state: state, onOpen: () {})));
    final slider = find.byType(Slider);
    final gesture = await tester.startGesture(tester.getCenter(slider));
    await gesture.moveBy(const Offset(50, 0));
    await tester.pump();
    await gesture.cancel();
    await tester.pump();
    expect(state.seeks, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
