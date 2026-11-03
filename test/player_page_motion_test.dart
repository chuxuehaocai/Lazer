import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/player/player_page_motion.dart';

void main() {
  testWidgets('mobile rebound remains visible and settles after regrabbing', (
    tester,
  ) async {
    final controller = AnimationController.unbounded(vsync: tester);
    addTearDown(controller.dispose);
    PlayerPageMotion.animate(controller, 1, compact: true, reduceMotion: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 360));
    expect(controller.value, greaterThan(1));
    controller.stop();
    PlayerPageMotion.animate(
      controller,
      1,
      compact: true,
      reduceMotion: false,
      velocity: 0,
      releasedPull: true,
    );
    await tester.pumpAndSettle();
    expect(controller.value, 1);
    expect(controller.status, AnimationStatus.completed);
    PlayerPageMotion.animate(controller, 0, compact: true, reduceMotion: true);
    expect(controller.value, 0);
    expect(controller.status, AnimationStatus.dismissed);
    PlayerPageMotion.animate(controller, 1, compact: true, reduceMotion: true);
    expect(controller.value, 1);
    expect(controller.status, AnimationStatus.completed);
  });

  test(
    'all platforms share a spring with zero initial speed and overshoot',
    () {
      for (final target in [0.0, 1.0]) {
        for (final compact in [false, true]) {
          final motion = PlayerPageMotion.simulation(
            from: 1 - target,
            to: target,
            compact: compact,
          );
          final other = PlayerPageMotion.simulation(
            from: 1 - target,
            to: target,
            compact: !compact,
            releasedPull: true,
          );
          expect(motion.dx(0), 0);
          var overshot = false;
          for (var ms = 0; ms <= 2000; ms += 8) {
            final t = ms / 1000;
            expect(motion.x(t), other.x(t));
            expect(motion.dx(t), other.dx(t));
            overshot |= target == 1 ? motion.x(t) > 1 : motion.x(t) < 0;
          }
          expect(overshot, isTrue);
          expect(motion.isDone(2), isTrue);
          expect(motion.x(2), target);
          expect(motion.dx(2), 0);
        }
      }
    },
  );

  test('spring retargeting preserves the supplied physical velocity', () {
    for (final position in [.001, .04, .5, .96, .999]) {
      for (final velocity in [-12.0, -3.0, 0.0, 3.0, 12.0]) {
        for (final target in [0.0, 1.0]) {
          final motion = PlayerPageMotion.simulation(
            from: position,
            to: target,
            velocity: velocity,
            compact: false,
          );
          expect(motion.x(0), position);
          expect(motion.dx(0), velocity);
          expect((motion.x(1e-8) - position) / 1e-8, closeTo(velocity, .002));
          expect(motion.isDone(2), isTrue);
          expect(motion.x(2), target);
          expect(motion.dx(2), 0);
        }
      }
    }
  });

  testWidgets('reduced motion immediately completes an interrupted slide', (
    tester,
  ) async {
    final controller = AnimationController.unbounded(vsync: tester);
    addTearDown(controller.dispose);
    PlayerPageMotion.animate(
      controller,
      1,
      compact: false,
      reduceMotion: false,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.value, inExclusiveRange(0, 1));
    PlayerPageMotion.animate(controller, 0, compact: false, reduceMotion: true);
    expect(controller.value, 0);
    expect(controller.status, AnimationStatus.dismissed);
    expect(controller.isAnimating, isFalse);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('closing before the first moving frame dismisses immediately', (
    tester,
  ) async {
    final controller = AnimationController.unbounded(vsync: tester);
    addTearDown(controller.dispose);
    PlayerPageMotion.animate(
      controller,
      1,
      compact: false,
      reduceMotion: false,
    );
    PlayerPageMotion.animate(
      controller,
      0,
      compact: false,
      reduceMotion: false,
    );
    expect(controller.value, 0);
    expect(controller.status, AnimationStatus.dismissed);
    expect(controller.isAnimating, isFalse);
    expect(tester.binding.transientCallbackCount, 0);
    PlayerPageMotion.animate(
      controller,
      1,
      compact: false,
      reduceMotion: false,
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(controller.value, 1);
    expect(controller.status, AnimationStatus.completed);
  });
}
