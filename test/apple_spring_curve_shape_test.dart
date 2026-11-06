import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/animation/apple_spring.dart';

/// `f(u) = 1 - (1 + u)e^-u` is a critically damped spring's step response from
/// 0 to 1 with no initial velocity. Sampling over two perceived durations of a
/// 500 ms spring is a 1 s window, and `u = 2*pi/D * (t * 2D) = 4*pi*t`, so the
/// normalized shape is `f(4*pi*t) / f(4*pi)` at every speed.
double canonical(double t) {
  const double end = 4 * math.pi;
  double f(double u) => 1 - (1 + u) * math.exp(-u);
  return f(end * t) / f(end);
}

void main() {
  test('AppleSpringCurve is the canonical shape, not a one-second sample', () {
    // A fixed one-second window only coincides with "two perceived durations"
    // at 1x: at 2x the spring has long settled inside that second and the curve
    // reaches ~0.72 of its travel in the first tenth of its domain instead of
    // ~0.36. Setting the speed before the curve's lazily built sample is what
    // makes this a regression test.
    MotionTiming.speed = MotionTiming.maxSpeed;
    addTearDown(() => MotionTiming.speed = MotionTiming.defaultSpeed);

    for (final double t in <double>[0.05, 0.1, 0.25, 0.5, 0.75]) {
      expect(
        const AppleSpringCurve().transform(t),
        closeTo(canonical(t), 1e-4),
        reason: 'speed 2x, t=$t',
      );
    }
  });

  test('the shape does not move when the global speed changes', () {
    // `_unit` is cached, and it may only be cached because the corrected window
    // makes the shape time-scale invariant.
    MotionTiming.speed = MotionTiming.minSpeed;
    final slow = <double>[
      for (var i = 0; i <= 10; i++) const AppleSpringCurve().transform(i / 10),
    ];
    MotionTiming.speed = MotionTiming.maxSpeed;
    final fast = <double>[
      for (var i = 0; i <= 10; i++) const AppleSpringCurve().transform(i / 10),
    ];
    expect(fast, equals(slow));
  });

  test('endpoints stay exact whatever the speed', () {
    addTearDown(() => MotionTiming.speed = MotionTiming.defaultSpeed);
    for (final double speed in <double>[
      MotionTiming.minSpeed,
      MotionTiming.defaultSpeed,
      MotionTiming.maxSpeed,
    ]) {
      MotionTiming.speed = speed;
      expect(const AppleSpringCurve().transform(0), 0);
      expect(const AppleSpringCurve().transform(1), 1);
    }
  });
}
