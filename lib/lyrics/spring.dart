// SPDX-License-Identifier: AGPL-3.0-or-later
// Adapted lyric animation; reference: README.md. License: licenses/lyric_animation/AGPL-3.0.txt.
import 'dart:math' as math;

class LyricSpringParams {
  const LyricSpringParams({
    this.mass = 1,
    this.damping = 10,
    this.stiffness = 100,
    this.soft = false,
  });
  final double mass;
  final double damping;
  final double stiffness;
  final bool soft;
}

/// Same closed-form solver and central-difference derivatives as utils/spring.ts.
/// Retargeting preserves velocity; this is not Flutter's SpringSimulation.
class LyricSpring {
  LyricSpring(double position, {LyricSpringParams? params})
    : value = position,
      target = position,
      _params = params ?? const LyricSpringParams() {
    _solver = (_) => target;
    _arrived = true;
  }
  double value;
  double target;
  double _time = 0;
  LyricSpringParams _params;
  late double Function(double) _solver;
  (double time, double position)? _queued;
  bool _arrived = false;

  double _velocity(double time) =>
      (_solver(time + 0.001) - _solver(time - 0.001)) / 0.002;
  double _acceleration(double time) =>
      (_velocity(time + 0.001) - _velocity(time - 0.001)) / 0.002;
  bool get arrived => _arrived;

  void _resetSolver() {
    final velocity = _velocity(_time);
    _time = 0;
    _solver = solveLyricSpring(value, velocity, target, _params);
    _arrived = false;
  }

  void setParameters(LyricSpringParams params) {
    _queued = null;
    _params = params;
    _resetSolver();
  }

  void setPosition(double position) {
    target = position;
    value = position;
    _queued = null;
    _solver = (_) => target;
    _arrived = true;
  }

  void setTarget(double position, {double delay = 0}) {
    if (delay <= 0 && (target - position).abs() < 0.001) {
      _queued = null;
      return;
    }
    if (delay > 0) {
      _queued = (delay, position);
      _arrived = false;
    } else {
      _queued = null;
      target = position;
      _resetSolver();
    }
  }

  void update(double seconds) {
    // LyricViewport keeps one position and scale spring per lyric line. Most
    // rows are settled on almost every frame, so avoid re-running the closed-
    // form solver and its finite-difference derivatives until a target moves.
    if (_arrived || seconds <= 0) return;
    _time += seconds;
    value = _solver(_time);
    final queued = _queued;
    if (queued != null) {
      final remaining = queued.$1 - seconds;
      _queued = (remaining, queued.$2);
      if (remaining <= 0) setTarget(queued.$2);
    }
    _arrived =
        (target - value).abs() < 0.01 &&
        _velocity(_time).abs() < 0.01 &&
        _acceleration(_time).abs() < 0.01 &&
        _queued == null;
    if (_arrived) setPosition(target);
  }
}

double Function(double) solveLyricSpring(
  double from,
  double velocity,
  double to,
  LyricSpringParams params,
) {
  final delta = to - from;
  final stiffness = params.stiffness;
  final damping = params.damping;
  final mass = params.mass;
  if (params.soft || damping / (2 * math.sqrt(stiffness * mass)) >= 1) {
    final frequency = -math.sqrt(stiffness / mass);
    final leftover = -frequency * delta - velocity;
    return (t) => to - (delta + t * leftover) * math.exp(t * frequency);
  }
  final frequency = math.sqrt(4 * mass * stiffness - damping * damping);
  final leftover = (damping * delta - 2 * mass * velocity) / frequency;
  final dfm = 0.5 * frequency / mass;
  final dm = -0.5 * damping / mass;
  return (t) =>
      to -
      (math.cos(t * dfm) * delta + math.sin(t * dfm) * leftover) *
          math.exp(t * dm);
}

/// Exact base/spring.ts policy, with the player's default Y mass (0.9).
LyricSpringParams lyricPositionPolicy({
  bool seeking = false,
  bool interlude = false,
  int? intervalMs,
  bool endOfSong = false,
}) {
  if (seeking || interlude || (!endOfSong && intervalMs == null)) {
    return const LyricSpringParams(mass: 0.9, stiffness: 90, damping: 15);
  }
  if (endOfSong) {
    return const LyricSpringParams(mass: 0.9, stiffness: 140, damping: 22);
  }
  final interval = intervalMs!.clamp(100, 800);
  final ratio = math.pow(1 - (interval - 100) / 700, 0.2).toDouble();
  final stiffness = 170 + ratio * 50;
  return LyricSpringParams(
    mass: 0.9,
    stiffness: stiffness,
    damping: math.sqrt(stiffness) * 2.2,
  );
}

/// Exact 50ms stagger and 1/1.05 decay after the focused line.
List<double> lyricStaggerDelays(
  List<double> positions,
  List<double> heights,
  int active, {
  bool disabled = false,
}) {
  var delay = 0.0;
  var base = disabled ? 0.0 : 0.05;
  return List.generate(positions.length, (index) {
    final result = delay;
    if (positions[index] + heights[index] >= 0) {
      delay += base;
      if (index >= active) base /= 1.05;
    }
    return result;
  });
}
