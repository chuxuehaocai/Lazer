import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/player/player_page_motion.dart';
import 'package:lazer_nextgen/navigation/pull_down_page_route.dart';
import 'package:lazer_nextgen/player/now_playing_route.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';

const _bodyKey = ValueKey('apple-player-body');

class _PlayerRoute extends NowPlayingRoute {
  _PlayerRoute(AppState state, {this.bodyKey = _bodyKey}) : super(state: state);
  final Key bodyKey;
  double get openness => controller!.value;
  double get speed => controller!.velocity;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => SizedBox.expand(key: bodyKey);
}

Future<GlobalKey<NavigatorState>> _host(
  WidgetTester tester, {
  bool reduced = false,
}) async {
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      theme: ThemeData(platform: TargetPlatform.iOS),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
        child: child!,
      ),
      home: const SizedBox.expand(),
    ),
  );
  return navigator;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'route paints the bounce but exports bounded navigator progress',
    (tester) async {
      final state = AppState()..uiMode = AppUiMode.mobile;
      addTearDown(state.dispose);
      final nav = await _host(tester);
      final route = _PlayerRoute(state);
      nav.currentState!.push(route);
      await tester.pump();
      var bounced = false;
      var paintedOvershoot = false;
      for (
        var frame = 0;
        frame < 120 && route.animation!.status != AnimationStatus.completed;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 16));
        bounced |= route.openness > 1;
        paintedOvershoot |= tester.getTopLeft(find.byKey(_bodyKey)).dy < 0;
      }
      expect(bounced, isTrue);
      expect(paintedOvershoot, isTrue);
      expect(route.animation!.value, 1);
      route.startPull();
      final position = route.openness;
      route.updatePull(0);
      expect(route.openness, position);
      route.cancelPull();
      await tester.pumpAndSettle();
      expect(route.animation!.status, AnimationStatus.completed);
      nav.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.byKey(_bodyKey), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('player entrance and exit follow the same physical spring', (
    tester,
  ) async {
    final state = AppState();
    addTearDown(state.dispose);
    state.uiMode = AppUiMode.mobile;
    final nav = await _host(tester);
    final route = _PlayerRoute(state);
    nav.currentState!.push(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(
      route.openness,
      closeTo(PlayerPageMotion.mobileSpring.simulation(0, 1).x(.12), .00001),
    );
    await tester.pumpAndSettle();
    expect(route.openness, 1);
    nav.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(
      route.openness,
      closeTo(PlayerPageMotion.mobileSpring.simulation(1, 0).x(.12), .00001),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(_bodyKey), findsNothing);
  });

  testWidgets(
    'desktop standalone route uses the same bouncing spring as mobile',
    (tester) async {
      final state = AppState()..uiMode = AppUiMode.desktop;
      addTearDown(state.dispose);
      final nav = await _host(tester);
      final route = _PlayerRoute(state);
      nav.currentState!.push(route);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 160));
      final firstLeg = route.openness;
      expect(
        firstLeg,
        closeTo(PlayerPageMotion.spring.simulation(0, 1).x(.16), .00001),
      );
      await tester.pumpAndSettle();
      expect(route.openness, 1);
      expect(route.animation!.status, AnimationStatus.completed);
      expect(route.speed, 0);
      nav.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 160));
      expect(1 - route.openness, closeTo(firstLeg, .00001));
      await tester.pumpAndSettle();
      await tester.pump();
      expect(find.byKey(_bodyKey), findsNothing);
    },
  );

  testWidgets('unfinished player push can be grabbed and reversed in place', (
    tester,
  ) async {
    final state = AppState();
    addTearDown(state.dispose);
    final nav = await _host(tester);
    final route = _PlayerRoute(state);
    nav.currentState!.push(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final before = route.openness;
    expect(route.canStart, isTrue);
    route.startPull();
    route.updatePull(0);
    expect(route.openness, before);
    route.updatePull(.04);
    expect(route.openness, closeTo(before - .04, .00001));
    route.updatePull(-.03);
    expect(route.openness, closeTo(before + .03, .00001));
    route.endPull(-1200);
    expect(route.speed, closeTo(1200 / 600, .00001));
    await tester.pumpAndSettle();
    expect(route.openness, 1);
  });

  testWidgets('programmatic player reverse preserves position and velocity', (
    tester,
  ) async {
    final state = AppState();
    addTearDown(state.dispose);
    final nav = await _host(tester);
    final route = _PlayerRoute(state);
    nav.currentState!.push(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final before = route.openness;
    final speed = route.speed;
    nav.currentState!.pop();
    expect(route.openness, before);
    expect(route.speed, closeTo(speed, .00001));
    await tester.pumpAndSettle();
    expect(find.byKey(_bodyKey), findsNothing);
  });

  for (final pulled in [.1, .4]) {
    testWidgets(
      'release at $pulled continues from the current finger position',
      (tester) async {
        final state = AppState();
        addTearDown(state.dispose);
        final nav = await _host(tester);
        final route = _PlayerRoute(state);
        nav.currentState!.push(route);
        await tester.pumpAndSettle();
        route.startPull();
        route.updatePull(pulled);
        route.endPull(0);
        expect(route.openness, closeTo(1 - pulled, .00001));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          route.openness,
          pulled < .22 ? greaterThan(1 - pulled) : lessThan(1 - pulled),
        );
        await tester.pumpAndSettle();
        if (pulled < .22) {
          expect(route.openness, 1);
          expect(route.canStart, isTrue);
          nav.currentState!.pop();
          await tester.pumpAndSettle();
        }
        expect(find.byKey(_bodyKey), findsNothing);
      },
    );
  }

  testWidgets(
    'player rebound can be grabbed again and inherits fling velocity',
    (tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      final nav = await _host(tester);
      final route = _PlayerRoute(state);
      nav.currentState!.push(route);
      await tester.pumpAndSettle();
      route.startPull();
      route.updatePull(.1);
      route.endPull(0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final before = route.openness;
      expect(route.canStart, isTrue);
      route.startPull();
      route.updatePull(.02);
      expect(route.openness, closeTo(before - .02, .00001));
      route.endPull(1800);
      expect(route.speed, closeTo(-1800 / 600, .00001));
      await tester.pumpAndSettle();
      expect(find.byKey(_bodyKey), findsNothing);
    },
  );

  testWidgets('new player can open while the previous route is leaving', (
    tester,
  ) async {
    final state = AppState();
    addTearDown(state.dispose);
    final nav = await _host(tester);
    final first = _PlayerRoute(state);
    nav.currentState!.push(first);
    await tester.pumpAndSettle();
    nav.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final second = _PlayerRoute(
      state,
      bodyKey: const ValueKey('second-player'),
    );
    nav.currentState!.push(second);
    await tester.pump();
    await tester.pump();
    expect(second.openness, 0);
    await tester.pumpAndSettle();
    expect(find.byKey(_bodyKey, skipOffstage: false), findsNothing);
    expect(second.openness, 1);
    expect(second.canStart, isTrue);
  });

  testWidgets('reduced motion player settles without a translated frame', (
    tester,
  ) async {
    final state = AppState();
    addTearDown(state.dispose);
    final nav = await _host(tester, reduced: true);
    final route = _PlayerRoute(state);
    nav.currentState!.push(route);
    await tester.pumpAndSettle();
    expect(route.openness, 1);
    expect(find.byType(FractionalTranslation), findsNothing);
    route.startPull();
    route.updatePull(.1);
    route.endPull(0);
    expect(route.openness, 1);
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byKey(_bodyKey), findsNothing);
  });

  testWidgets('top-edge route rebound can be regrabbed without releasing nav', (
    tester,
  ) async {
    final nav = await _host(tester);
    final route = PullDownPageRoute<void>(
      builder: (_) => const ColoredBox(key: _bodyKey, color: Colors.teal),
    );
    nav.currentState!.push(route);
    await tester.pumpAndSettle();
    final first = await tester.startGesture(const Offset(100, 30));
    await first.moveBy(const Offset(0, 55));
    await tester.pump();
    await first.cancel();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final before = route.animation!.value;
    final second = await tester.startGesture(
      Offset(100, (1 - before) * 600 + 25),
    );
    await second.moveBy(const Offset(0, 25));
    await tester.pump();
    expect(route.animation!.value, closeTo(before - 25 / 600, .005));
    expect(nav.currentState!.userGestureInProgress, isTrue);
    await second.cancel();
    await tester.pumpAndSettle();
    expect(route.animation!.value, 1);
    expect(nav.currentState!.userGestureInProgress, isFalse);
    expect(tester.takeException(), isNull);
  });
}
