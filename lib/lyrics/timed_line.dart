// SPDX-License-Identifier: AGPL-3.0-or-later
// Adapted lyric animation; reference: README.md. License: licenses/lyric_animation/AGPL-3.0.txt.
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'word_motion.dart';
import '../data/lyrics.dart';

class TimedLyricText extends StatefulWidget {
  const TimedLyricText({
    super.key,
    required this.line,
    required this.style,
    required this.active,
    required this.position,
    required this.repaint,
    this.emphasis,
  });
  final LyricLine line;
  final TextStyle style;
  final bool active;
  final Duration Function() position;
  final Listenable repaint;
  final double Function()? emphasis;
  @override
  State<TimedLyricText> createState() => _TimedLyricTextState();
}

class _TimedLyricTextState extends State<TimedLyricText> {
  _WordLayout? _layout;
  Object? _layoutKey;
  @override
  void dispose() {
    _layout?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final scaler = MediaQuery.textScalerOf(context);
        final locale = Localizations.maybeLocaleOf(context);
        final key = (widget.line, widget.style, box.maxWidth, scaler, locale);
        if (_layoutKey != key) {
          _layout?.dispose();
          _layout = _WordLayout(
            widget.line,
            widget.style,
            box.maxWidth,
            scaler,
            locale,
          );
          _layoutKey = key;
        }
        return Semantics(
          label: widget.line.text,
          child: ExcludeSemantics(
            child: CustomPaint(
              size: Size(box.maxWidth, _layout!.bright.height),
              painter: _WordPainter(
                layout: _layout!,
                position: widget.position,
                emphasis: widget.emphasis ?? () => widget.active ? 1.0 : 0.0,
                repaint: widget.repaint,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Segment {
  const _Segment(
    this.character,
    this.count,
    this.rect,
    this.wordLeft,
    this.consumed,
    this.totalWidth,
    this.startMs,
    this.durationMs,
    this.emphasized,
    this.last,
  );
  final int character, count;
  final Rect rect;
  final double wordLeft, consumed, totalWidth, startMs, durationMs;
  final bool emphasized, last;
}

class _Word {
  const _Word({
    required this.startMs,
    required this.durationMs,
    required this.emphasized,
    required this.last,
    required this.segments,
  });

  final double startMs;
  final double durationMs;
  final bool emphasized;
  final bool last;
  final List<_Segment> segments;

  /// The emphasized motion includes per-glyph stagger and a trailing float.
  /// Two durations cover both, including the special treatment for the last
  /// word, after which its glyphs are static and can be painted as one clip.
  double get settledAtMs =>
      math.max(1000, durationMs) * (last ? 1.2 : 1) * (emphasized ? 2 : 1);
}

class _WordLayout {
  _WordLayout(
    this.line,
    TextStyle style,
    double width,
    TextScaler scaler,
    Locale? locale,
  ) {
    bright = TextPainter(
      text: TextSpan(text: line.text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      locale: locale,
    )..layout(maxWidth: width);
    dim = TextPainter(
      text: TextSpan(
        text: line.text,
        style: style.copyWith(
          color: (style.color ?? Colors.black).withValues(alpha: .28),
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      locale: locale,
    )..layout(maxWidth: width);
    fontSize = scaler.scale(style.fontSize ?? 22);
    var offset = 0;
    for (var wi = 0; wi < line.words.length; wi++) {
      final word = line.words[wi];
      final double startMs = word.start.inMicroseconds / 1000;
      final double durationMs = word.duration.inMicroseconds / 1000;
      final chars = word.text.characters.toList();
      final trimmedLength = word.text.trim().characters.length;
      final bool emphasized =
          word.duration >= const Duration(milliseconds: 1000) &&
          (_WordPainter.cjk.hasMatch(word.text) ||
              trimmedLength > 1 && trimmedLength <= 7);
      final List<_Segment> wordSegments = <_Segment>[];
      final rects = bright
          .getBoxesForSelection(
            TextSelection(
              baseOffset: offset,
              extentOffset: offset + word.text.length,
            ),
          )
          .map((box) => box.toRect())
          .toList();
      final totalWidth = rects.fold<double>(0, (sum, rect) => sum + rect.width);
      for (var ci = 0; ci < chars.length; ci++) {
        final end = offset + chars[ci].length;
        for (final box in bright.getBoxesForSelection(
          TextSelection(baseOffset: offset, extentOffset: end),
        )) {
          if (box.right > box.left) {
            final rect = box.toRect();
            final glyphClip = Rect.fromLTRB(
              rect.left,
              rect.top - fontSize * .15,
              rect.right,
              rect.bottom + fontSize * .15,
            );
            baseClip.addRect(glyphClip);
            var consumed = 0.0;
            var wordLeft = rect.left;
            for (final part in rects) {
              if ((part.top - rect.top).abs() < 1 &&
                  rect.left >= part.left - 1 &&
                  rect.right <= part.right + 1) {
                wordLeft = part.left;
                break;
              }
              consumed += part.width;
            }
            wordSegments.add(
              _Segment(
                ci,
                chars.length,
                rect,
                wordLeft,
                consumed,
                totalWidth,
                startMs,
                durationMs,
                emphasized,
                wi == line.words.length - 1,
              ),
            );
          }
        }
        offset = end;
      }
      words.add(
        _Word(
          startMs: startMs,
          durationMs: durationMs,
          emphasized: emphasized,
          last: wi == line.words.length - 1,
          segments: wordSegments,
        ),
      );
    }
  }
  final LyricLine line;
  late final TextPainter bright, dim;
  late final double fontSize;
  final List<_Word> words = <_Word>[];
  final Path baseClip = Path();
  void dispose() {
    bright.dispose();
    dim.dispose();
  }
}

class _WordPainter extends CustomPainter {
  _WordPainter({
    required this.layout,
    required this.position,
    required this.emphasis,
    required Listenable repaint,
  }) : super(repaint: repaint);
  final _WordLayout layout;
  final Duration Function() position;
  final double Function() emphasis;
  static final cjk = RegExp(r'[぀-ヿ㐀-鿿가-힯]');
  @override
  void paint(Canvas canvas, Size size) {
    final focus = emphasis().clamp(0.0, 1.0);
    if (focus <= 0) {
      // Fully unfocused rows are painted by the parent's colour filter; the
      // old code still pushed an opaque saveLayer here for every visible
      // word-timed line on every frame of the song.
      layout.bright.paint(canvas, Offset.zero);
      return;
    }
    if (focus < 1) {
      canvas.saveLayer(
        null,
        Paint()..color = Colors.white.withValues(alpha: 1 - focus),
      );
      layout.bright.paint(canvas, Offset.zero);
      canvas.restore();
    }
    // Retain the word painter while the row exits; fade its emphasis using
    // the same spring as the row's scale and color instead of swapping to Text.
    canvas.saveLayer(
      null,
      Paint()..color = Colors.white.withValues(alpha: focus),
    );
    final now = position().inMicroseconds / 1000;
    // Each clipped glyph used to repaint the entire dim lyric line. Paint the
    // same base once, then retain the existing per-glyph highlight effects.
    canvas.save();
    canvas.clipPath(layout.baseClip);
    layout.dim.paint(canvas, Offset.zero);
    canvas.restore();

    // Completed words no longer move or glow. Collect their glyph clips and
    // paint the bright line once per final baseline instead of calling
    // TextPainter.paint for every already-finished character on every frame.
    final Path settledEmphasized = Path();
    final Path settledOrdinary = Path();
    final List<_Word> animatingWords = <_Word>[];
    for (final _Word word in layout.words) {
      final double elapsed = now - word.startMs;
      if (elapsed < 0 || word.segments.isEmpty) continue;
      if (elapsed < word.settledAtMs) {
        animatingWords.add(word);
        continue;
      }
      final Path target = word.emphasized ? settledEmphasized : settledOrdinary;
      for (final _Segment segment in word.segments) {
        final Rect rect = segment.rect;
        target.addRect(
          Rect.fromLTRB(
            rect.left,
            rect.top - layout.fontSize * .15,
            rect.right,
            rect.bottom + layout.fontSize * .15,
          ),
        );
      }
    }
    if (!settledEmphasized.getBounds().isEmpty) {
      canvas.save();
      canvas.clipPath(settledEmphasized);
      layout.bright.paint(canvas, Offset.zero);
      canvas.restore();
    }
    if (!settledOrdinary.getBounds().isEmpty) {
      canvas.save();
      canvas.translate(0, -layout.fontSize * .05);
      canvas.clipPath(settledOrdinary);
      layout.bright.paint(canvas, Offset.zero);
      canvas.restore();
    }

    for (final _Word word in animatingWords) {
      for (final _Segment segment in word.segments) {
        final elapsed = now - segment.startMs;
        final duration = segment.durationMs;
        final motion = segment.emphasized
            ? LyricWordMotion.emphasized(
                elapsed,
                duration,
                segment.character,
                segment.count,
                last: segment.last,
              )
            : LyricWordMotion.ordinary(elapsed, duration);
        final rect = segment.rect;
        final boundary =
            segment.wordLeft +
            LyricWordMotion.maskBoundary(
              elapsed,
              duration,
              segment.totalWidth,
            ) -
            segment.consumed;
        final fade = math.max(1.0, rect.height * .5);
        canvas.save();
        canvas.translate(
          motion.xEm * layout.fontSize * focus,
          motion.yEm * layout.fontSize * focus,
        );
        canvas.translate(rect.center.dx, rect.center.dy);
        canvas.scale(1 + (motion.scale - 1) * focus);
        canvas.translate(-rect.center.dx, -rect.center.dy);
        final clip = Rect.fromLTRB(
          rect.left,
          rect.top - layout.fontSize * .15,
          rect.right,
          rect.bottom + layout.fontSize * .15,
        );
        canvas.clipRect(clip);
        if (boundary + fade / 2 >= rect.left) {
          if (boundary - fade / 2 >= rect.right) {
            // Fully highlighted glyphs need no mask or glow: paint straight
            // into the clip. The old path pushed an offscreen saveLayer per
            // glyph on every frame — dozens of full-line rasterizations even
            // though only the moving boundary needs blending.
            canvas.save();
            canvas.clipRect(clip);
            layout.bright.paint(canvas, Offset.zero);
            canvas.restore();
          } else {
            canvas.saveLayer(clip, Paint());
            if (motion.glow > .001) {
              canvas.saveLayer(
                clip,
                Paint()
                  ..imageFilter = ui.ImageFilter.blur(
                    sigmaX: motion.glowRadiusEm * layout.fontSize,
                    sigmaY: motion.glowRadiusEm * layout.fontSize,
                  )
                  ..colorFilter = ColorFilter.mode(
                    Colors.white.withValues(alpha: motion.glow),
                    BlendMode.srcIn,
                  ),
              );
              layout.bright.paint(canvas, Offset.zero);
              canvas.restore();
            }
            layout.bright.paint(canvas, Offset.zero);
            canvas.drawRect(
              clip,
              Paint()
                ..blendMode = BlendMode.dstIn
                ..shader = ui.Gradient.linear(
                  Offset(boundary - fade / 2, 0),
                  Offset(boundary + fade / 2, 0),
                  [Colors.white, Colors.transparent],
                ),
            );
            canvas.restore();
          }
        }
        canvas.restore();
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WordPainter oldDelegate) =>
      oldDelegate.layout != layout ||
      oldDelegate.position != position ||
      oldDelegate.emphasis != emphasis;
}
