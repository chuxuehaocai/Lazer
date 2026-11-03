import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/animation/apple_spring.dart';
import 'package:lazer_nextgen/animation/view_transitions.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';

const _bodyKey = ValueKey('motion-route-body');
const _body = SizedBox.expand(
  key: _bodyKey,
  child: ColoredBox(color: Colors.teal),
);

class _Route extends ApplePageRoute<void> {
  _Route() : super(builder: (_) => _body);
  double get openness => controller!.value;
  double get speed => controller!.velocity;
}

class _TrackedAnimation extends AlwaysStoppedAnimation<double> {
  _TrackedAnimation() : super(1);
  final statuses = <AnimationStatusListener>{};
  final listeners = <VoidCallback>{};
  @override
  void addStatusListener(AnimationStatusListener listener) =>
      statuses.add(listener);
  @override
  void removeStatusListener(AnimationStatusListener listener) =>
      statuses.remove(listener);
  @override
  void addListener(VoidCallback listener) => listeners.add(listener);
  @override
  void removeListener(VoidCallback listener) => listeners.remove(listener);
}

Future<GlobalKey<NavigatorState>> _host(
  WidgetTester tester, {
  TargetPlatform platform = TargetPlatform.windows,
  bool reduced = false,
  TextDirection direction = TextDirection.ltr,
  Widget? home,
}) async {
  tester.view.physicalSize = const Size(800, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final nav = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: nav,
      theme: buildAppleTheme().copyWith(platform: platform),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
        child: Directionality(textDirection: direction, child: child!),
      ),
      home: home ?? const SizedBox.expand(),
    ),
  );
  return nav;
}

void main() {
  testWidgets('transparent routes never blend two pages of text', (
    tester,
  ) async {
    final nav = await _host(tester, home: const Text('Overview'));
    final route = _Route();
    nav.currentState!.push(route);
    await tester.pump();
    double opacity(Finder child) => tester
        .widgetList<FadeTransition>(
          find.ancestor(
            of: child,
            matching: find.byType(FadeTransition, skipOffstage: false),
          ),
        )
        .fold(1.0, (value, fade) => value * fade.opacity.value);
    Future<void> checkFrames() async {
      for (var frame = 0; frame < 65; frame++) {
        final detail = find.byKey(_bodyKey, skipOffstage: false);
        if (detail.evaluate().isNotEmpty) {
          expect(
            opacity(find.text('Overview', skipOffstage: false)) *
                opacity(detail),
            0,
            reason:
                'a shared background must not expose the departing page ink',
          );
        }
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    await checkFrames();
    nav.currentState!.pop();
    await tester.pump();
    await checkFrames();
    expect(find.byKey(_bodyKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final platform in TargetPlatform.values) {
    testWidgets('same page spring on ${platform.name}', (tester) async {
      final nav = await _host(tester, platform: platform);
      final route = _Route();
      nav.currentState!.push(route);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(
        route.openness,
        closeTo(AppleSpring.smooth.simulation(0, 1).x(.12), .00001),
      );
      final bounds = tester.getRect(find.byKey(_bodyKey));
      expect(
        bounds.left,
        closeTo((1 - route.openness) * tester.view.physicalSize.width, .001),
      );
      await tester.pumpAndSettle();
      expect(route.openness, 1);
      nav.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.byKey(_bodyKey), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
    });
  }

  testWidgets(
    'Back interrupts a page push with continuous position and velocity',
    (tester) async {
      final nav = await _host(tester);
      final route = _Route();
      nav.currentState!.push(route);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final position = route.openness, velocity = route.speed;
      nav.currentState!.pop();
      expect(route.openness, closeTo(position, .000001));
      expect(route.speed, closeTo(velocity, .000001));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(route.openness, greaterThan(position));
      await tester.pumpAndSettle();
      expect(find.byKey(_bodyKey), findsNothing);
    },
  );

  for (final direction in TextDirection.values) {
    testWidgets('grab an entering page at its visible edge in $direction', (
      tester,
    ) async {
      final nav = await _host(tester, direction: direction);
      final route = _Route();
      nav.currentState!.push(route);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      final before = route.openness;
      final width = tester.view.physicalSize.width;
      final edge = direction == TextDirection.ltr
          ? width * (1 - before) + 8
          : width * before - 8;
      final sign = direction == TextDirection.ltr ? 1.0 : -1.0;
      final gesture = await tester.startGesture(Offset(edge, 200));
      await gesture.moveBy(Offset(40 * sign, 0));
      await tester.pump();
      expect(route.openness, closeTo(before - 40 / width, .001));
      expect(nav.currentState!.userGestureInProgress, isTrue);
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(route.openness, 1);
      expect(nav.currentState!.userGestureInProgress, isFalse);
      nav.currentState!.pop();
      await tester.pumpAndSettle();
    });
  }

  testWidgets('Reduce Motion removes page travel and completes promptly', (
    tester,
  ) async {
    final nav = await _host(tester, reduced: true);
    final route = _Route();
    nav.currentState!.push(route);
    await tester.pumpAndSettle();
    expect(route.openness, 1);
    expect(tester.getTopLeft(find.byKey(_bodyKey)), Offset.zero);
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byKey(_bodyKey), findsNothing);
  });

  testWidgets('rebuilding fallback transitions releases every listener', (
    tester,
  ) async {
    final animation = _TrackedAnimation();
    final route = MaterialPageRoute<void>(builder: (_) => _body);
    var count = (0, 0);
    for (var i = 0; i < 10; i++) {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) =>
                const LazerPageTransitionsBuilder().buildTransitions<void>(
                  route,
                  context,
                  animation,
                  kAlwaysDismissedAnimation,
                  Text('body $i'),
                ),
          ),
        ),
      );
      if (i == 0) {
        count = (animation.listeners.length, animation.statuses.length);
      }
      expect((animation.listeners.length, animation.statuses.length), count);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    expect(animation.listeners, isEmpty);
    expect(animation.statuses, isEmpty);
    route.dispose();
  });
}
