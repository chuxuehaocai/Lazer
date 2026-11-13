import 'package:flutter/material.dart';

import 'lyric_document.dart';
import 'timed_line.dart';
import '../theme/lazer_theme.dart';

/// Shared typography and text painting for the player and desktop lyrics.
TextStyle lyricTextStyle(
  TextStyle base,
  double size,
  int weight, {
  LazerThemeTokens? theme,
  bool translation = false,
}) {
  final tokens = theme ?? LazerThemeTokens.apple;
  return base.copyWith(
    fontSize: size,
    fontWeight: translation
        ? tokens.lyricTranslationFontWeight(weight)
        : tokens.lyricFontWeight(weight),
    height: translation
        ? tokens.lyricTranslationLineHeight
        : tokens.lyricLineHeight,
    color: Colors.white,
  );
}

String lyricSemanticLabel(LyricLine line) =>
    [line.text, if (line.translation != null) line.translation!].join('\n');

class LyricLineContent extends StatelessWidget {
  const LyricLineContent({
    super.key,
    required this.line,
    required this.style,
    required this.active,
    required this.position,
    required this.repaint,
    required this.emphasis,
    this.maxLines,
  });

  final LyricLine line;
  final TextStyle style;
  final bool active;
  final Duration Function() position;
  final Listenable repaint;
  final double Function() emphasis;
  final int? maxLines;

  @override
  Widget build(BuildContext context) => line.words.isNotEmpty
      ? TimedLyricText(
          line: line,
          style: style,
          active: active,
          position: position,
          repaint: repaint,
          emphasis: emphasis,
          maxLines: maxLines,
          textAlign: LazerThemeTokens.of(context).lyricAlignment,
        )
      : Text(
          line.text.isEmpty ? ' ' : line.text,
          style: style,
          textAlign: LazerThemeTokens.of(context).lyricAlignment,
          textDirection: TextDirection.ltr,
          maxLines: maxLines,
          overflow: maxLines == null ? null : TextOverflow.ellipsis,
        );
}
