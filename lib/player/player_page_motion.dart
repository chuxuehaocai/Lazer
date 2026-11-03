import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../animation/apple_spring.dart';

/// A finite, non-bouncing desktop slide; direct manipulation and the compact
/// player retain their spring response. The controller is always the displayed
/// coordinate, so neither host applies a second easing curve while painting.
abstract final class PlayerPageMotion {
  static const desktopDuration = Duration(milliseconds: 460);

  static Simulation simulation({
    required double from,
    required double to,
    required bool compact,
    double velocity = 0,
    bool releasedPull = false,
  }) => compact || releasedPull
      ? AppleSpring.smooth.simulation(from, to, velocity: velocity)
      : _DesktopPlayerSlide(from, to, velocity);

  static TickerFuture animate(
    AnimationController controller,
    double target, {
    required bool compact,
    required bool reduceMotion,
  }) {
    if (reduceMotion ||
        (controller.value == target && controller.velocity == 0)) {
      controller.value = target;
      return TickerFuture.complete();
    }
    final motion = simulation(
      from: controller.value,
      to: target,
      velocity: controller.velocity,
      compact: compact,
    );
    return target < controller.value
        ? controller.animateBackWith(motion)
        : controller.animateWith(motion);
  }
}

class _DesktopPlayerSlide extends Simulation {
  _DesktopPlayerSlide(this.from, this.to, double velocity) {
    if (velocity != 0 && velocity * (to - from) <= 0) {
      // On reversal, brake briefly before changing direction. Limit that
      // travel to half the remaining space so the page cannot cross an edge.
      final headroom = velocity > 0 ? 1 - from : from;
      brakingTime = math.min(.08, headroom / velocity.abs());
      if (brakingTime == 0) velocity = 0;
    }
    initialVelocity = velocity;
    start = from + initialVelocity * brakingTime / 2;
    startVelocity = brakingTime > 0 ? 0 : initialVelocity;
    duration = PlayerPageMotion.desktopDuration.inMilliseconds / 1000;
    if (start == to) {
      duration = 0;
    } else if (startVelocity * (to - start) > 0) {
      // This Hermite slope bound keeps a continuing move monotonic without
      // throwing away the incoming velocity near its destination.
      duration = math.min(
        duration,
        3 * (to - start).abs() / startVelocity.abs(),
      );
    }
  }

  final double from, to;
  late final double initialVelocity, start, startVelocity;
  double brakingTime = 0;
  late double duration;

  @override
  double x(double time) {
    if (time <= 0) return from;
    if (time < brakingTime) {
      return from + initialVelocity * time * (1 - time / (2 * brakingTime));
    }
    if (isDone(time)) return to;
    final t = (time - brakingTime) / duration;
    return start +
        (to - start) * t * t * (3 - 2 * t) +
        startVelocity * duration * t * (1 - t) * (1 - t);
  }

  @override
  double dx(double time) {
    if (time <= 0) return initialVelocity;
    if (time < brakingTime) return initialVelocity * (1 - time / brakingTime);
    if (isDone(time)) return 0;
    final t = (time - brakingTime) / duration;
    return (to - start) * 6 * t * (1 - t) / duration +
        startVelocity * (1 - t) * (1 - 3 * t);
  }

  @override
  bool isDone(double time) => time >= brakingTime + duration;
}
