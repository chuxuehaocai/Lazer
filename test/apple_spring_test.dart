import 'package:flutter/animation.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/animation/apple_spring.dart';

void main() {
  test('smooth is critically damped and snappy has a restrained overshoot', () {
    final smooth = AppleSpring.smooth.simulation(0, 1);
    final snappy = AppleSpring.snappy.simulation(0, 1);
    expect(smooth.type, SpringType.criticallyDamped);
    expect(snappy.type, SpringType.underDamped);
    var last = 0.0;
    var peak = 0.0;
    for (var i = 0; i <= 240; i++) {
      final time = i / 120;
      final value = smooth.x(time);
      expect(value, greaterThanOrEqualTo(last));
      expect(value, inInclusiveRange(0, 1));
      last = value;
      if (snappy.x(time) > peak) peak = snappy.x(time);
    }
    expect(peak, greaterThan(1));
    expect(peak, lessThan(1.02));
    expect(smooth.isDone(2), isTrue);
    expect(snappy.isDone(2), isTrue);
    expect(smooth.x(2), 1);
    expect(const AppleSpringCurve().transform(0), 0);
    expect(const AppleSpringCurve().transform(1), 1);
  });

  testWidgets('reversal keeps the presented position and velocity', (
    tester,
  ) async {
    final controller = AnimationController.unbounded(vsync: tester);
    addTearDown(controller.dispose);
    controller.springTo(1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final position = controller.value;
    final velocity = controller.velocity;
    expect(position, inExclusiveRange(0, 1));
    expect(velocity, greaterThan(0));
    controller.springTo(0);
    expect(controller.value, position);
    expect(controller.velocity, closeTo(velocity, 1e-8));
    expect(controller.status, AnimationStatus.reverse);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(
      controller.value,
      greaterThan(position),
      reason: 'existing momentum survives the new destination',
    );
    await tester.pumpAndSettle();
    expect(controller.value, 0);
    expect(controller.isAnimating, isFalse);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets(
    'gesture velocity continues and reduced motion stops immediately',
    (tester) async {
      final controller = AnimationController.unbounded(
        vsync: tester,
        value: .4,
      );
      addTearDown(controller.dispose);
      controller.springTo(1, velocity: -2);
      expect(controller.value, .4);
      expect(controller.velocity, closeTo(-2, 1e-8));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(controller.value, lessThan(.4));
      controller.springTo(1, reduceMotion: true);
      expect(controller.value, 1);
      expect(controller.isAnimating, isFalse);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );
}
