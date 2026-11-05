import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/animation/view_transitions.dart';
import 'package:lazer_nextgen/navigation/pull_down_page_route.dart';
import 'package:lazer_nextgen/navigation/system_back_gesture.dart';
import 'package:lazer_nextgen/player/now_playing_route.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/widgets/retained_content_switcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _root = ValueKey('back-root');
const _detail = ValueKey('back-detail');

Future<void> _system(
  WidgetTester tester,
  String method, [
  double? progress,
]) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/backgesture',
    const StandardMethodCodec().encodeMethodCall(
      MethodCall(
        method,
        progress == null
            ? null
            : <String, dynamic>{
                'touchOffset': <double>[5, 200],
                'progress': progress,
                'swipeEdge': 0,
              },
      ),
    ),
    (_) {},
  );
  await tester.pump();
}

class _Player extends NowPlayingRoute {
  _Player(AppState state) : super(state: state);
  double get physicalProgress => controller!.value;
  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => const SizedBox.expand(key: _detail);
}

class _Harness extends StatefulWidget {
  const _Harness({super.key});
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final progress = ValueNotifier<double?>(null);
  bool detail = false, committed = false;
  int commits = 0, transitions = 0;
  void push() => setState(() {
    detail = true;
    committed = false;
  });
  @override
  void dispose() {
    progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: false,
    child: SystemBackGesture(
      canStart: () => detail && ModalRoute.of(context)!.isCurrent,
      progress: progress,
      onStart: () => setState(() => committed = false),
      onCommit: () => setState(() {
        detail = false;
        committed = true;
        commits++;
      }),
      child: RetainedContentSwitcher(
        currentKey: detail ? 'detail' : 'root',
        retainKeys: const {'root'},
        backProgress: progress,
        backTargetKey: 'root',
        backCommitted: committed,
        onTransitionChanged: (moving) {
          if (moving) transitions++;
        },
        page: SizedBox.expand(
          key: detail ? _detail : _root,
          child: ColoredBox(color: detail ? Colors.red : Colors.blue),
        ),
      ),
    ),
  );
}

Future<GlobalKey<NavigatorState>> _host(
  WidgetTester tester, {
  Widget? home,
  bool reduced = false,
  TextDirection direction = TextDirection.ltr,
}) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final nav = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: nav,
      theme: buildAppleTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
        child: Directionality(textDirection: direction, child: child!),
      ),
      home: home ?? const SizedBox.expand(key: _root),
    ),
  );
  return nav;
}

void _androidTest(String name, Future<void> Function(WidgetTester) body) =>
    testWidgets(
      name,
      body,
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
void _iosTest(String name, Future<void> Function(WidgetTester) body) =>
    testWidgets(
      name,
      body,
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  _androidTest('Android internal history previews, cancels and commits once', (
    tester,
  ) async {
    final key = GlobalKey<_HarnessState>();
    await _host(tester, home: _Harness(key: key));
    key.currentState!.push();
    await tester.pumpAndSettle();
    final transitions = key.currentState!.transitions;
    await _system(tester, 'startBackGesture', 0);
    await _system(tester, 'updateBackGestureProgress', .6);
    expect(tester.getRect(find.byKey(_detail)).width, lessThan(400));
    expect(find.byKey(_root), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(_root)),
      Offset.zero,
      reason: 'the parked ancestor must not keep its ordinary vertical slide',
    );
    await _system(tester, 'cancelBackGesture');
    await tester.pumpAndSettle();
    expect(key.currentState!.commits, 0);
    expect(
      tester.getRect(find.byKey(_detail)),
      const Rect.fromLTWH(0, 0, 400, 800),
    );
    await _system(tester, 'startBackGesture', 0);
    await _system(tester, 'updateBackGestureProgress', 1);
    final opacity = tester
        .widgetList<FadeTransition>(
          find.ancestor(
            of: find.byKey(_detail),
            matching: find.byType(FadeTransition),
          ),
        )
        .fold<double>(1, (value, fade) => value * fade.opacity.value);
    expect(
      opacity,
      0,
      reason:
          'a complete Android preview must expose its destination before removal',
    );
    expect(tester.getTopLeft(find.byKey(_root)), Offset.zero);
    await _system(tester, 'commitBackGesture');
    await tester.pumpAndSettle();
    expect(key.currentState!.commits, 1);
    expect(
      key.currentState!.transitions,
      transitions,
      reason: 'completed preview must not start another page transition',
    );
    expect(find.byKey(_detail), findsNothing);
    expect(
      tester.getRect(find.byKey(_root)),
      const Rect.fromLTWH(0, 0, 400, 800),
    );
    expect(tester.takeException(), isNull);
  });

  for (final direction in TextDirection.values) {
    for (final reduced in [false, true]) {
      _iosTest('iOS edge cancellation and commit $direction reduced=$reduced', (
        tester,
      ) async {
        final key = GlobalKey<_HarnessState>();
        await _host(
          tester,
          home: _Harness(key: key),
          direction: direction,
          reduced: reduced,
        );
        key.currentState!.push();
        await tester.pumpAndSettle();
        final sign = direction == TextDirection.ltr ? 1.0 : -1.0;
        final origin = Offset(sign > 0 ? 5 : 395, 200);
        var drag = await tester.startGesture(origin);
        await drag.moveBy(Offset(150 * sign, 0));
        await tester.pump();
        expect(key.currentState!.progress.value, closeTo(.375, .001));
        expect(
          tester.getTopLeft(find.byKey(_detail)).dx,
          closeTo(reduced ? 0 : 150 * sign, .001),
        );
        expect(
          tester.getTopLeft(find.byKey(_root)).dy,
          0,
          reason:
              'the destination must keep its original scroll viewport position',
        );
        await drag.cancel();
        await tester.pumpAndSettle();
        expect(key.currentState!.commits, 0);
        expect(key.currentState!.progress.value, isNull);
        drag = await tester.startGesture(origin);
        await drag.moveBy(Offset(280 * sign, 0));
        await tester.pump(const Duration(milliseconds: 250));
        await drag.up();
        await tester.pumpAndSettle();
        expect(key.currentState!.commits, 1);
        expect(find.byKey(_root), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final type in ['page', 'player', 'pull-down']) {
    _iosTest('iOS reduced motion $type still cancels and completes edge back', (
      tester,
    ) async {
      final nav = await _host(tester, reduced: true);
      final state = AppState();
      addTearDown(state.dispose);
      final PageRoute<void> route = switch (type) {
        'player' => _Player(state),
        'pull-down' => PullDownPageRoute<void>(
          builder: (_) => const SizedBox.expand(key: _detail),
        ),
        _ => ApplePageRoute<void>(
          builder: (_) => const SizedBox.expand(key: _detail),
        ),
      };
      nav.currentState!.push(route);
      await tester.pumpAndSettle();
      var drag = await tester.startGesture(const Offset(5, 200));
      await drag.moveBy(const Offset(140, 0));
      await tester.pump();
      expect(tester.getTopLeft(find.byKey(_detail)), Offset.zero);
      await drag.cancel();
      await tester.pumpAndSettle();
      expect(route.isCurrent, isTrue);
      expect(nav.currentState!.userGestureInProgress, isFalse);
      drag = await tester.startGesture(const Offset(5, 200));
      await drag.moveBy(const Offset(280, 0));
      await tester.pump(const Duration(milliseconds: 250));
      await drag.up();
      await tester.pumpAndSettle();
      expect(find.byKey(_detail), findsNothing);
      expect(nav.currentState!.userGestureInProgress, isFalse);
      expect(tester.takeException(), isNull);
    });
    _androidTest(
      'Android $type route uses system progress and releases navigator',
      (tester) async {
        final nav = await _host(tester);
        final state = AppState();
        addTearDown(state.dispose);
        final PageRoute<void> route = switch (type) {
          'player' => _Player(state),
          'pull-down' => PullDownPageRoute<void>(
            builder: (_) => const SizedBox.expand(key: _detail),
          ),
          _ => ApplePageRoute<void>(
            builder: (_) => const SizedBox.expand(key: _detail),
          ),
        };
        nav.currentState!.push(route);
        await tester.pumpAndSettle();
        await _system(tester, 'startBackGesture', 0);
        await _system(tester, 'updateBackGestureProgress', .6);
        expect(route.animation!.value, closeTo(.4, .001));
        expect(nav.currentState!.userGestureInProgress, isTrue);
        await _system(tester, 'cancelBackGesture');
        if (route case final _Player player) {
          for (var i = 0; i < 80; i++) {
            await tester.pump(const Duration(milliseconds: 16));
            expect(
              player.physicalProgress.isFinite,
              isTrue,
              reason:
                  'an unbounded player controller must settle toward 1, never infinity',
            );
          }
        }
        await tester.pumpAndSettle();
        expect(route.isCurrent, isTrue);
        expect(route.animation!.value, 1);
        expect(nav.currentState!.userGestureInProgress, isFalse);
        await _system(tester, 'startBackGesture', 0);
        await _system(tester, 'updateBackGestureProgress', .7);
        await _system(tester, 'commitBackGesture');
        await tester.pumpAndSettle();
        expect(find.byKey(_detail), findsNothing);
        expect(nav.currentState!.userGestureInProgress, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  _androidTest('a pushed route receives Android back above internal history', (
    tester,
  ) async {
    final key = GlobalKey<_HarnessState>();
    final nav = await _host(tester, home: _Harness(key: key));
    key.currentState!.push();
    await tester.pumpAndSettle();
    nav.currentState!.push(
      ApplePageRoute<void>(
        builder: (_) => const SizedBox.expand(key: ValueKey('covering-route')),
      ),
    );
    await tester.pumpAndSettle();
    await _system(tester, 'startBackGesture', 0);
    await _system(tester, 'updateBackGestureProgress', .7);
    await _system(tester, 'commitBackGesture');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('covering-route')), findsNothing);
    expect(key.currentState!.commits, 0);
    expect(find.byKey(_detail), findsOneWidget);
  });

  _androidTest('disposing during Android internal back leaves no ticker', (
    tester,
  ) async {
    final key = GlobalKey<_HarnessState>();
    await _host(tester, home: _Harness(key: key));
    key.currentState!.push();
    await tester.pumpAndSettle();
    await _system(tester, 'startBackGesture', 0);
    await _system(tester, 'updateBackGestureProgress', .4);
    await tester.pumpWidget(const SizedBox());
    await _system(tester, 'cancelBackGesture');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.binding.transientCallbackCount, 0);
  });
}
