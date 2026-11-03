import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/player/desktop_now_playing.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/widgets/accessible_controls.dart';

Track _track(String title) => Track(
  id: 'layout-fixture',
  title: title,
  artist: 'Test artist',
  album: 'Test album',
  duration: const Duration(minutes: 3),
  coverSeed: 1,
);

class _TickState extends AppState {
  final clockPosition = ValueNotifier<Duration>(Duration.zero);
  @override
  final Track current = _track('Ticking dock');
  @override
  Duration get precisePosition => clockPosition.value;
  late final Listenable _all = Listenable.merge([this, clockPosition]);
  @override
  Listenable get all => _all;

  @override
  void dispose() {
    clockPosition.dispose();
    super.dispose();
  }
}

Widget _page(
  AppState state,
  Track track, {
  bool controlsVisible = true,
  bool reduceMotion = false,
}) => MaterialApp(
  theme: buildAppleTheme(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
    child: child!,
  ),
  home: Scaffold(
    body: DesktopNowPlaying(
      state: state,
      track: track,
      artwork: const ColoredBox(
        key: ValueKey('test-artwork'),
        color: Colors.blue,
      ),
      lyrics: const SizedBox.shrink(),
      comments: const SizedBox.shrink(),
      queue: const SizedBox.shrink(),
      pane: DesktopNowPlayingPane.lyrics,
      onPaneChanged: (_) {},
      onBack: () {},
      onSaveArtwork: () {},
      onFullscreen: () {},
      controlsVisible: controlsVisible,
      onActivity: () {},
    ),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('revealing the dock gives the cover time to shrink and settle', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 650);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(catalog: Catalog());
    addTearDown(state.dispose);
    final track = _track('Cover motion');
    final artwork = find.byKey(const ValueKey('test-artwork'));
    double edge() => tester.getSize(artwork).width;

    await tester.pumpWidget(_page(state, track));
    final small = edge();
    await tester.pumpWidget(_page(state, track, controlsVisible: false));
    await tester.pumpAndSettle();
    final large = edge();
    expect(large - small, greaterThan(60));

    await tester.pumpWidget(_page(state, track));
    await tester.pump();
    expect(edge(), closeTo(large, .01));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      (large - edge()) / (large - small),
      inExclusiveRange(.1, .5),
      reason: 'shrinking must remain readable beyond the first 100 ms',
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect((large - edge()) / (large - small), inExclusiveRange(.7, .98));

    var smallest = edge();
    for (var frame = 0; frame < 75; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (edge() < smallest) smallest = edge();
      expect(
        tester
            .widget<FadeTransition>(
              find.byKey(const ValueKey('desktop-dock-fade')),
            )
            .opacity
            .value,
        1,
        reason: 'the geometry bounce must not flicker the controls',
      );
    }
    expect(smallest, lessThan(small - .05));
    expect(
      smallest,
      greaterThan(small - (large - small) * .02),
      reason: 'the arrival bounce should be subtle, below 2% of the travel',
    );
    expect(edge(), closeTo(small, .01));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reversing the dock keeps cover momentum and one transport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 650);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(catalog: Catalog());
    addTearDown(state.dispose);
    final track = _track('Reversible cover');
    final artwork = find.byKey(const ValueKey('test-artwork'));
    final transport = find.byKey(const ValueKey('now-playing-transport'));
    double edge() => tester.getSize(artwork).width;

    await tester.pumpWidget(_page(state, track, controlsVisible: false));
    final large = edge();
    await tester.pumpWidget(_page(state, track));
    await tester.pump();
    final originalTransport = tester.element(transport);
    await tester.pump(const Duration(milliseconds: 119));
    final before = edge();
    await tester.pump(const Duration(milliseconds: 1));
    final atReversal = edge();
    final velocity = atReversal - before;
    expect(velocity, lessThan(0));

    await tester.pumpWidget(_page(state, track, controlsVisible: false));
    expect(edge(), closeTo(atReversal, .001));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(edge() - atReversal, closeTo(velocity, .02));
    await tester.pump(const Duration(milliseconds: 60));
    final interrupted = edge();
    await tester.pumpWidget(_page(state, track));
    expect(edge(), closeTo(interrupted, .001));
    expect(transport, findsOneWidget);
    expect(tester.element(transport), same(originalTransport));

    await tester.pumpWidget(_page(state, track, controlsVisible: false));
    await tester.pumpAndSettle();
    expect(edge(), closeTo(large, .01));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion immediately finishes an active cover resize', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 650);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(catalog: Catalog());
    addTearDown(state.dispose);
    final track = _track('Reduced cover motion');
    final artwork = find.byKey(const ValueKey('test-artwork'));
    double edge() => tester.getSize(artwork).width;

    await tester.pumpWidget(_page(state, track));
    final small = edge();
    await tester.pumpWidget(_page(state, track, controlsVisible: false));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(edge(), greaterThan(small));
    await tester.pumpWidget(
      _page(state, track, controlsVisible: false, reduceMotion: true),
    );
    final large = edge();
    await tester.pump(const Duration(seconds: 1));
    expect(edge(), large);
    await tester.pumpWidget(_page(state, track, reduceMotion: true));
    expect(edge(), closeTo(small, .01));
    final extent = tester.widget<SizeTransition>(
      find.byKey(const ValueKey('desktop-dock-size')),
    );
    final opacity = tester.widget<FadeTransition>(
      find.byKey(const ValueKey('desktop-dock-fade')),
    );
    expect((extent.sizeFactor as AnimationController).isAnimating, isFalse);
    expect((opacity.opacity as AnimationController).isAnimating, isFalse);
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'hiding controls removes input, focus and semantics immediately',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final semantics = tester.ensureSemantics();
      final state = AppState(catalog: Catalog());
      addTearDown(state.dispose);
      final track = _track('Accessible dock');
      final fullscreen = find.byKey(const ValueKey('desktop-fullscreen'));
      final fullscreenSemantics = find.semantics.byPredicate(
        (node) => node.getSemanticsData().tooltip == '全屏 (F)',
      );
      FocusNode controlFocus() =>
          Focus.of(tester.element(find.byIcon(Icons.fullscreen_rounded)));

      await tester.pumpWidget(_page(state, track));
      final controlElement = tester.element(fullscreen);
      expect(fullscreen.hitTestable(), findsOneWidget);
      expect(controlFocus().canRequestFocus, isTrue);
      expect(fullscreenSemantics, findsOne);

      await tester.pumpWidget(_page(state, track, controlsVisible: false));
      expect(fullscreen.hitTestable(), findsNothing);
      expect(controlFocus().canRequestFocus, isFalse);
      expect(fullscreenSemantics, findsNothing);
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);

      await tester.pumpWidget(_page(state, track));
      await tester.pumpAndSettle();
      expect(tester.element(fullscreen), same(controlElement));
      expect(fullscreen.hitTestable(), findsOneWidget);
      expect(controlFocus().canRequestFocus, isTrue);
      expect(fullscreenSemantics, findsOne);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets(
    'the retained hidden dock pauses progress updates and catches up',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = _TickState();
      addTearDown(state.dispose);
      final track = state.current;
      Slider seek() => tester.widget<Slider>(
        find.descendant(
          of: find.byKey(const ValueKey('desktop-seek-bar')),
          matching: find.byType(Slider),
        ),
      );

      await tester.pumpWidget(_page(state, track));
    state.clockPosition.value = const Duration(seconds: 30);
      await tester.pump();
      expect(seek().value, closeTo(1 / 6, .001));
      expect(find.text('0:30'), findsOneWidget);

      await tester.pumpWidget(_page(state, track, controlsVisible: false));
      await tester.pumpAndSettle();
    state.clockPosition.value = const Duration(seconds: 90);
      await tester.pump();
      expect(seek().value, closeTo(1 / 6, .001));
      expect(find.text('0:30'), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0);

      await tester.pumpWidget(_page(state, track));
      expect(seek().value, closeTo(.5, .001));
      expect(find.text('1:30'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('dock resizing keeps the cover inside short desktop windows', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(catalog: Catalog());
    addTearDown(state.dispose);
    final track = _track('A long song title that wraps across multiple lines');
    final artwork = find.byKey(const ValueKey('test-artwork'));
    for (final height in [480.0, 560.0, 650.0]) {
      tester.view.physicalSize = Size(1280, height);
      await tester.pumpWidget(_page(state, track));
      await tester.pumpAndSettle();
      for (final visible in [false, true]) {
        await tester.pumpWidget(_page(state, track, controlsVisible: visible));
        for (var frame = 0; frame < 75; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          final rect = tester.getRect(artwork);
          expect(rect.width, closeTo(rect.height, .01));
          expect(rect.width, greaterThan(0));
          expect(rect.top, greaterThanOrEqualTo(0));
          expect(rect.bottom, lessThanOrEqualTo(height));
          expect(tester.takeException(), isNull);
        }
      }
    }
  });

  testWidgets('desktop song actions stay aligned to the artwork edge', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(catalog: Catalog());
    addTearDown(state.dispose);

    for (final size in <Size>[const Size(1280, 800), const Size(1280, 650)]) {
      tester.view.physicalSize = size;
      for (final title in <String>[
        'Short title',
        'A long song title that wraps and continues well beyond two lines',
      ]) {
        await tester.pumpWidget(_page(state, _track(title)));
        await tester.pump();

        final Rect artwork = tester.getRect(
          find.byKey(const ValueKey('test-artwork')),
        );
        final Rect listen = tester.getRect(
          find.byWidgetPredicate(
            (widget) =>
                widget is AccessibleIconButton && widget.tooltip == '一起听',
          ),
        );
        final Rect like = tester.getRect(
          find.byWidgetPredicate(
            (widget) =>
                widget is AccessibleIconButton && widget.tooltip == '登录后收藏',
          ),
        );
        final Rect titleRect = tester.getRect(find.text(title));

        expect(
          like.right,
          closeTo(artwork.right, .01),
          reason: 'actions should line up with the actual artwork at $size',
        );
        expect(listen.right, lessThanOrEqualTo(like.left));
        expect(titleRect.right, lessThanOrEqualTo(listen.left));
        expect(tester.takeException(), isNull);
      }
    }
  });
}
