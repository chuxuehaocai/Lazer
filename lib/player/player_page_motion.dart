import 'package:flutter/widgets.dart';

import '../animation/apple_spring.dart';

/// One physical spring for every player host and input device. The controller
/// is the presentation coordinate, including overshoot and incoming velocity.
abstract final class PlayerPageMotion {
  static const spring = AppleSpring(
    duration: AppleSpring.bouncyDuration,
    bounce: .15,
  );

  // These are perceived response times; settlement is determined by physics.
  static const desktopDuration = AppleSpring.bouncyDuration;
  static const mobileSpring = spring;

  static Simulation simulation({
    required double from,
    required double to,
    required bool compact,
    double velocity = 0,
    bool releasedPull = false,
  }) => spring.simulation(from, to, velocity: velocity);

  static TickerFuture animate(
    AnimationController controller,
    double target, {
    required bool compact,
    required bool reduceMotion,
    double? velocity,
    bool releasedPull = false,
  }) {
    final initialVelocity = velocity ?? controller.velocity;
    if (reduceMotion ||
        (controller.value == target &&
            (initialVelocity == 0 ||
                controller.lastElapsedDuration == Duration.zero))) {
      return target == 0
          ? controller.animateBack(target, duration: Duration.zero)
          : controller.animateTo(target, duration: Duration.zero);
    }
    final motion = spring.simulation(
      controller.value,
      target,
      velocity: initialVelocity,
    );
    return target == 0
        ? controller.animateBackWith(motion)
        : controller.animateWith(motion);
  }
}
