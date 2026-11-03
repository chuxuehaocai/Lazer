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

  test('desktop slide settles on time without overshoot or an abrupt stop', () {
    for (final target in [0.0, 1.0]) {
      final motion = PlayerPageMotion.simulation(
        from: 1 - target,
        to: target,
        compact: false,
      );
      expect(motion.dx(0).abs(), closeTo(2 / .6, .00001));
      var previous = motion.x(0);
      for (var ms = 1; ms <= 600; ms++) {
        final position = motion.x(ms / 1000);
        expect(position, inInclusiveRange(0, 1));
        expect(
          (position - previous) * (2 * target - 1),
          greaterThanOrEqualTo(0),
        );
        expect(
          motion.dx(ms / 1000).abs(),
          lessThanOrEqualTo(motion.dx((ms - 1) / 1000).abs()),
        );
        previous = position;
      }
      expect(motion.isDone(.599), isFalse);
      expect(motion.isDone(.600), isTrue);
      expect(motion.x(.6), target);
      expect(motion.dx(.599).abs(), lessThan(.03));
      expect(motion.dx(.6), 0);
    }
  });

  test('retargets retain velocity while staying inside both screen edges', () {
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
          for (var ms = 1; ms <= 680; ms++) {
            expect(motion.x(ms / 1000), inInclusiveRange(0, 1));
          }
          expect(motion.isDone(.68), isTrue);
          expect(motion.x(.68), target);
          expect(motion.dx(.68), 0);
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
    await tester.pump(PlayerPageMotion.desktopDuration);
    expect(controller.value, 1);
    expect(controller.status, AnimationStatus.completed);
  });
}
