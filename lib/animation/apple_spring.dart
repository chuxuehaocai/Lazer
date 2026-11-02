import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

/// Duration/bounce springs, following Apple's WWDC23 spring model.
/// Duration describes the perceived response, not a hard animation deadline.
/// https://developer.apple.com/videos/play/wwdc2023/10158/
class AppleSpring {
  const AppleSpring({
    this.duration = const Duration(milliseconds: 500),
    this.bounce = 0,
  }) : assert(bounce > -1 && bounce < 1);

  static const smooth = AppleSpring();
  static const snappy = AppleSpring(
    duration: Duration(milliseconds: 350),
    bounce: .15,
  );
  static const responsive = AppleSpring(duration: Duration(milliseconds: 280));

  final Duration duration;
  final double bounce;

  SpringSimulation simulation(double from, double to, {double velocity = 0}) =>
      SpringSimulation(
        SpringDescription.withDurationAndBounce(
          duration: duration,
          bounce: bounce,
        ),
        from,
        to,
        velocity,
        // A normalized page coordinate settles below a tenth of a pixel for
        // a 1000-pixel viewport before releasing its ticker and snapshots.
        tolerance: const Tolerance(distance: .0001, velocity: .001),
        snapToEnd: true,
      );
}

extension AppleSpringController on AnimationController {
  /// Retargets the currently presented value and velocity. A reverse or a new
  /// destination never starts from an old endpoint or resets its momentum.
  /// Gesture velocities use this controller's coordinate units per second.
  TickerFuture springTo(
    double target, {
    AppleSpring spring = AppleSpring.smooth,
    double? velocity,
    bool reduceMotion = false,
  }) {
    final initialVelocity = velocity ?? this.velocity;
    if (reduceMotion ||
        ((target - value).abs() < .0001 && initialVelocity.abs() < .001)) {
      value = target;
      return TickerFuture.complete();
    }
    final motion = spring.simulation(value, target, velocity: initialVelocity);
    return target < value ? animateBackWith(motion) : animateWith(motion);
  }
}

/// A non-bouncing spring for fixed-duration, bounded properties such as colour
/// and opacity. Gesture-driven geometry uses [AppleSpringController.springTo]
/// instead, so interrupted motion retains its actual velocity.
class AppleSpringCurve extends Curve {
  const AppleSpringCurve();

  // Sample two perceived durations of a critically damped spring. The tail is
  // nearly stationary; normalizing it makes the adapter's endpoints exact.
  static final SpringSimulation _unit = AppleSpring.smooth.simulation(0, 1);
  static final double _end = _unit.x(1);

  @override
  double transformInternal(double t) => (_unit.x(t) / _end).clamp(0.0, 1.0);
}
