import 'dart:math' as math;

abstract final class ScrollMotion {
  static const minRetention = 0.85;
  static const maxRetention = 0.98;

  /// The values the sliders start at. Together they select Flutter's stock
  /// scroll motion exactly: `ClampingScrollSimulation` for flings, the
  /// platform's direct wheel step, and no velocity carry-over. Any other pair
  /// switches to the configurable inertia model.
  static const defaultRetention = 0.90;
  static const defaultAcceleration = 1.0;
  static const minAcceleration = 0.5;
  static const maxAcceleration = 3.0;

  /// Whether [retention] and [acceleration] describe the stock Flutter
  /// behaviour rather than the custom inertia model.
  static bool isNative({
    double retention = defaultRetention,
    double acceleration = defaultAcceleration,
  }) =>
      (retention - defaultRetention).abs() < 1e-9 &&
      (acceleration - defaultAcceleration).abs() < 1e-9;

  // Keep the input impulse independent of friction. Otherwise increasing
  // retention reduces the initial velocity and cancels the extra distance.
  static double wheelVelocity(
    double delta, {
    double acceleration = defaultAcceleration,
  }) => delta * -math.log(0.95) * 60 * acceleration;

  /// Opposite impulses brake existing motion before accelerating in reverse.
  static double addWheelImpulse(
    double velocity,
    double delta, {
    double acceleration = defaultAcceleration,
  }) => (velocity + wheelVelocity(delta, acceleration: acceleration)).clamp(
    -12000.0,
    12000.0,
  );

  /// Flutter's default fling keeps the release velocity unchanged; the custom
  /// model scales it so the acceleration slider reads as a multiplier.
  static double carriedVelocity(
    double velocity, {
    double retention = defaultRetention,
    double acceleration = defaultAcceleration,
  }) => isNative(retention: retention, acceleration: acceleration)
      ? velocity
      : (velocity * .65 * acceleration).clamp(-8000.0, 8000.0);
}
