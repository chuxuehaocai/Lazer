// SPDX-License-Identifier: AGPL-3.0-or-later
// Adapted lyric animation; reference: README.md. License: licenses/lyric_animation/AGPL-3.0.txt.
import 'dart:math' as math;

double _bezier(double x, double x1, double y1, double x2, double y2) {
  if (x <= 0) return 0;
  if (x >= 1) return 1;
  final cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx;
  final cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by;
  double sampleX(double t) => ((ax * t + bx) * t + cx) * t;
  double sampleY(double t) => ((ay * t + by) * t + cy) * t;
  var lo = 0.0, hi = 1.0;
  var t = x;
  // Safeguarded Newton steps preserve the curve, including its flat ends,
  // without paying for forty bisections per glyph on every frame.
  for (var i = 0; i < 8; i++) {
    final error = sampleX(t) - x;
    if (error.abs() < 1e-13) return sampleY(t);
    if (error < 0) {
      lo = t;
    } else {
      hi = t;
    }
    final slope = (3 * ax * t + 2 * bx) * t + cx;
    final next = slope.abs() > 1e-12 ? t - error / slope : double.nan;
    t = next > lo && next < hi ? next : (lo + hi) / 2;
  }
  for (var i = 0; i < 40; i++) {
    final error = sampleX(t) - x;
    if (error.abs() < 1e-13) break;
    if (error < 0) {
      lo = t;
    } else {
      hi = t;
    }
    t = (lo + hi) / 2;
  }
  return sampleY(t);
}

double _emp(double x) => x < .5
    ? _bezier(x * 2, .2, .4, .58, 1)
    : 1 - _bezier((x - .5) * 2, .3, 0, .58, 1);
final List<double> _emphasisSamples = List<double>.unmodifiable([
  for (var i = 0; i <= 32; i++) _emp(i / 32),
]);
final List<double> _floatSamples = List<double>.unmodifiable([
  for (var i = 0; i <= 32; i++) math.sin(i / 32 * math.pi),
]);

double _sample32(double x, List<double> samples) {
  final frame = x.clamp(0.0, 1.0) * 32;
  final lower = frame.floor().clamp(0, 32), upper = (lower + 1).clamp(0, 32);
  return samples[lower] + (samples[upper] - samples[lower]) * (frame - lower);
}

class LyricWordMotion {
  const LyricWordMotion({
    this.scale = 1,
    this.xEm = 0,
    this.yEm = 0,
    this.glow = 0,
    this.glowRadiusEm = 0,
  });
  final double scale, xEm, yEm, glow, glowRadiusEm;
  static double maskBoundary(
    double elapsedMs,
    double durationMs,
    double textWidth,
  ) => elapsedMs / math.max(1, durationMs) * textWidth;

  static LyricWordMotion ordinary(double elapsedMs, double durationMs) =>
      LyricWordMotion(
        yEm:
            -.05 *
            _bezier(
              (elapsedMs / math.max(1000, durationMs)).clamp(0.0, 1.0),
              0,
              0,
              .58,
              1,
            ),
      );

  static LyricWordMotion emphasized(
    double elapsedMs,
    double durationMs,
    int index,
    int count, {
    bool last = false,
    bool holdFloat = false,
  }) {
    var du = math.max(1000.0, durationMs);
    var amount = du / 2000, blur = du / 3000;
    amount = (amount > 1 ? math.sqrt(amount) : amount * amount * amount) * .6;
    blur = (blur > 1 ? math.sqrt(blur) : blur * blur * blur) * .5;
    if (last) {
      amount *= 1.6;
      blur *= 1.5;
      du *= 1.2;
    }
    amount = math.min(1.2, amount);
    blur = math.min(.8, blur);
    final delay = du / 2.5 / math.max(1, count) * index;
    final emp = _sample32((elapsedMs - delay) / du, _emphasisSamples);
    final float = _sample32(
      (elapsedMs - delay + 400) / (du * 1.4),
      _floatSamples,
    );
    return LyricWordMotion(
      scale: 1 + emp * .1 * amount,
      xEm: -emp * .03 * amount * (count / 2 - index),
      // Ordinary words rise monotonically to the float target instead of
      // peaking with the emphasis curve and drifting back to the baseline.
      yEm: holdFloat
          ? -.05 *
                _bezier(
                  ((elapsedMs - delay) / du).clamp(0.0, 1.0),
                  0,
                  0,
                  .58,
                  1,
                )
          : -emp * .025 * amount - float * .05,
      glow: emp * blur,
      glowRadiusEm: math.min(.3, blur * .3),
    );
  }
}
