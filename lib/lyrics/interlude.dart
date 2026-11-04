import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'lyric_document.dart';
import '../l10n/app_localizations.dart';

/// The old player's timeline policy: preserve timed blanks, infer only long
/// instrumental gaps, and prefer exact YRC vocal endings over an LRC estimate.
List<LyricLine> lyricsWithInterludes(List<LyricLine> lines, Duration duration) {
  if (lines.isEmpty) return lines;
  final result = <LyricLine>[];
  if (lines.first.time.inMilliseconds >= 5000 &&
      lines.first.text.trim().isNotEmpty) {
    result.add(LyricLine(Duration.zero, '', end: lines.first.time));
  }
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final next = i + 1 < lines.length ? lines[i + 1].time : duration;
    if (line.text.trim().isEmpty) {
      result.add(LyricLine(line.time, '', end: next));
      continue;
    }
    result.add(line);
    var end = line.end;
    if (end == null && line.words.isNotEmpty) {
      end = line.words
          .map((word) => word.start + word.duration)
          .reduce((a, b) => a > b ? a : b);
    }
    if (end == null && (next - line.time).inMilliseconds >= 12000) {
      end = line.time + const Duration(seconds: 8);
    }
    if (end != null) {
      if (end < line.time) end = line.time;
      if ((next - end).inMilliseconds >= 5000 &&
          // An explicit blank already describes this instrumental passage.
          !(i + 1 < lines.length && lines[i + 1].text.trim().isEmpty)) {
        result.add(LyricLine(end, '', end: next));
      }
    }
  }
  return result;
}

class LyricInterludeSnapshot {
  const LyricInterludeSnapshot(this.dotOpacities, this.scale, this.opacity);
  final List<double> dotOpacities;
  final double scale;
  final double opacity;
}

/// Direct playback-time port of LyricInterludeDots.kt. No independent looping
/// clock is used, so pausing, seeking and backgrounding remain deterministic.
LyricInterludeSnapshot lyricInterludeSnapshot(
  int start,
  int end,
  int position,
) {
  final duration = math.max(0, end - start);
  final hold = start <= 0 ? 0 : 500;
  final body = duration - hold - 1000;
  if (body < 910 || position < start) {
    return const LyricInterludeSnapshot([0, 0, 0], 1, 0);
  }
  final elapsed = (position - start).clamp(0, duration);
  if (elapsed < hold) {
    return const LyricInterludeSnapshot([0, 0, 0], 1, 0);
  }
  final internal = elapsed - hold;
  final fallback = body < 3000;
  final segment = fallback ? 1 : math.max(1, ((body + 750) / 3).round());
  final thirdDuration = math.max(1, body - segment * 2);
  final thirdTarget = fallback
      ? 1.0
      : (thirdDuration / segment).clamp(0.0, 1.0);
  final enter = const Cubic(
    .59,
    .02,
    .07,
    1,
  ).transform((internal / 180).clamp(0.0, 1.0));
  List<double> opacities(List<double> fractions) => [
    for (var i = 0; i < 3; i++)
      (.2 + .7 * fractions[i].clamp(0.0, 1.0)) *
          math.pow(((internal - i * 80) / 750).clamp(0.0, 1.0), 2),
  ];
  if (elapsed >= hold + body) {
    final exit = elapsed - hold - body;
    final fade = const Cubic(
      .43,
      .08,
      .83,
      .31,
    ).transform(((exit - 750) / 250).clamp(0.0, 1.0));
    final scale = exit < 750
        ? 1 + const Cubic(.14, .06, .25, 1).transform(exit / 750) * .25
        : 1.25 -
              const Cubic(
                    .29,
                    .03,
                    1,
                    .38,
                  ).transform(((exit - 750) / 250).clamp(0.0, 1.0)) *
                  .85;
    return LyricInterludeSnapshot(
      opacities([
        1,
        1,
        thirdTarget + (1 - thirdTarget) * (exit / 750).clamp(0.0, 1.0),
      ]),
      scale,
      enter * (1 - fade),
    );
  }
  if (fallback) return LyricInterludeSnapshot(opacities([1, 1, 1]), 1, enter);
  final period = body / math.max(1, (body / 4000).floor());
  final cycle = (internal % math.max(1, period.floor())) / period;
  final angle = 4 * math.pi * cycle;
  final sine = math.sin(angle);
  final cosine = math.cos(angle);
  final breath =
      cycle -
      .084 * sine +
      .008 * (1 - cosine) +
      .0046 * sine * (cosine - sine);
  double fraction(int delay, int length, double target) =>
      const Cubic(
        .56,
        .01,
        .45,
        1,
      ).transform(((internal - delay) / length).clamp(0.0, 1.0)) *
      target;
  return LyricInterludeSnapshot(
    opacities([
      fraction(0, segment, 1),
      fraction(segment, segment, 1),
      fraction(segment * 2, thirdDuration, thirdTarget),
    ]),
    breath <= .5 ? 1 + breath * .5 : 1.25 - (breath - .5) * .5,
    enter,
  );
}

class LyricInterludeDots extends StatelessWidget {
  const LyricInterludeDots({
    super.key,
    required this.line,
    required this.position,
    required this.presence,
    required this.repaint,
    required this.diameter,
  });
  final LyricLine line;
  final Duration Function() position;
  final double Function() presence;
  final Listenable repaint;
  final double diameter;

  @override
  Widget build(BuildContext context) => Semantics(
    label: context.tr('间奏'),
    child: CustomPaint(
      painter: _InterludePainter(line, position, presence, diameter, repaint),
      size: const Size(double.infinity, 52),
    ),
  );
}

class _InterludePainter extends CustomPainter {
  _InterludePainter(
    this.line,
    this.position,
    this.presence,
    this.diameter,
    Listenable repaint,
  ) : super(repaint: repaint);
  final LyricLine line;
  final Duration Function() position;
  final double Function() presence;
  final double diameter;
  int? _lastPosition;

  @override
  void paint(Canvas canvas, Size size) {
    final start = line.time.inMilliseconds;
    final end =
        (line.end ?? line.time + const Duration(seconds: 5)).inMilliseconds;
    final now = position().inMilliseconds;
    if (now < end) _lastPosition = now;
    // Keep the last in-range visual while its transient layout row collapses.
    final snapshot = lyricInterludeSnapshot(
      start,
      end,
      now < end ? now : (_lastPosition ?? end),
    );
    final reveal = presence().clamp(0.0, 1.0);
    final scale = 1 + (snapshot.scale - 1) * reveal;
    // Keep the group's leading edge aligned with the lyric text while giving
    // the glow a small optical inset. The center follows the breathing scale
    // so the left edge remains fixed.
    final center = Offset(diameter * (.6 + 2.1 * scale), size.height / 2);
    for (var i = 0; i < 3; i++) {
      final alpha = (snapshot.dotOpacities[i] * snapshot.opacity * reveal)
          .clamp(0.0, 1.0);
      if (alpha == 0) continue;
      final offset = center + Offset((i - 1) * diameter * 1.6 * scale, 0);
      canvas.drawCircle(
        offset,
        diameter / 2 * scale,
        Paint()
          ..color = Colors.white.withValues(alpha: alpha * .58)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 11),
      );
      canvas.drawCircle(
        offset,
        diameter / 2 * scale,
        Paint()..color = Colors.white.withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(_InterludePainter oldDelegate) =>
      oldDelegate.line != line || oldDelegate.diameter != diameter;
}
