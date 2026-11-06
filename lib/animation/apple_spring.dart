import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

/// Global speed for duration-based Apple springs. Higher values make the
/// perceived response shorter without changing their bounce.
abstract final class MotionTiming {
  static const double minSpeed = .5;
  static const double maxSpeed = 2;
  static const double step = .1;
  static const double defaultSpeed = 1;

  static double _speed = defaultSpeed;

  static double get speed => _speed;

  static set speed(double value) {
    _speed = normalize(value);
  }

  static double normalize(double value) {
    if (!value.isFinite) return defaultSpeed;
    return (value.clamp(minSpeed, maxSpeed) / step).round() * step;
  }

  static Duration scale(Duration duration) {
    if (duration <= Duration.zero) return duration;
    return Duration(
      microseconds: (duration.inMicroseconds / _speed).round().clamp(
        1,
        1 << 62,
      ),
    );
  }
}

/// Duration/bounce springs, following Apple's WWDC23 spring model.
/// Duration describes the perceived response, not a hard animation deadline.
/// https://developer.apple.com/videos/play/wwdc2023/10158/
class AppleSpring {
  const AppleSpring({
    Duration duration = const Duration(milliseconds: 500),
    this.bounce = 0,
  }) : _baseDuration = duration,
       assert(bounce > -1 && bounce < 1);

  static const smooth = AppleSpring();
  static const bouncyDuration = Duration(milliseconds: 600);
  static const bouncy = AppleSpring(duration: bouncyDuration, bounce: .1);
  static const snappy = AppleSpring(
    duration: Duration(milliseconds: 350),
    bounce: .15,
  );
  static const responsive = AppleSpring(duration: Duration(milliseconds: 280));

  final Duration _baseDuration;
  final double bounce;

  Duration get duration => MotionTiming.scale(_baseDuration);

  SpringSimulation simulation(double from, double to, {double velocity = 0}) =>
      _simulation(from, to, duration: duration, velocity: velocity);

  /// The same spring at its base duration, deliberately ignoring
  /// [MotionTiming]. A critically damped spring is time-scale invariant, so
  /// this is what a speed-independent *shape* such as [AppleSpringCurve] needs:
  /// the animation-speed preference belongs to each call site's own `duration`,
  /// which reads [duration] and is therefore already scaled.
  SpringSimulation _unscaledSimulation(double from, double to) =>
      _simulation(from, to, duration: _baseDuration, velocity: 0);

  SpringSimulation _simulation(
    double from,
    double to, {
    required Duration duration,
    required double velocity,
  }) => SpringSimulation(
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

  // Two perceived durations of a critically damped spring. Its tail is nearly
  // stationary by then, so normalizing by that endpoint makes the curve's
  // endpoints exact.
  //
  // The window is expressed as a multiple of the spring's own duration rather
  // than as a fixed number of seconds. Sampling a fixed second instead only
  // coincides with "two perceived durations" at 1x: at 2x the spring has long
  // settled inside that second, so the curve jumps to ~1 in the first fifth of
  // its domain, and at 0.5x it lags. A critically damped spring is time-scale
  // invariant, so this window yields one universal shape for every speed -- and
  // the global speed keeps acting through each caller's `duration`, which reads
  // the scaled [AppleSpring.duration].
  static final SpringSimulation _unit = AppleSpring.smooth._unscaledSimulation(
    0,
    1,
  );
  static final double _window =
      2 *
      AppleSpring.smooth._baseDuration.inMicroseconds /
      Duration.microsecondsPerSecond;

  @override
  double transformInternal(double t) {
    final double time = t * _window;
    return (_unit.x(time) / _unit.x(_window)).clamp(0.0, 1.0);
  }
}
