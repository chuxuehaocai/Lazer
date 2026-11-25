import 'package:flutter/material.dart';

import 'lyric_document.dart';
import 'timed_line.dart';
import '../theme/adaptive_contrast.dart';
import '../theme/apple_design.dart';
import '../theme/lazer_theme.dart';

/// 这一屏歌词正文该用的墨色。
///
/// 皮肤可以把 `label` 报得离背景太近，所以在纸上/暗幕上都留一个对比度下限。
/// 间奏三点、副行都从这里取色，屏幕上半点相同的元素不会再出现「歌词是黑的、
/// 三点是白的」。
///
/// 这里读的是 [BuildContext]，因此用它的 widget 会随主题切换自动重建 —— 缓存
/// 整行 Widget 的地方（`_rowCache`）也不会把一个过期的颜色冻在里面。
Color lyricCanvasInk(BuildContext context) {
  final AppleSemanticColors apple = AppleSemanticColors.of(context);
  final Color surface = apple.background;
  return colorContrast(apple.label, surface) >= 4.5
      ? apple.label
      : contrastingLabel(surface);
}

/// 副行（罗马音、翻译）的墨色：永远比主行淡，不带任何「当前行」高亮。
///
/// 以前这里在 48%/58% alpha 达不到 4.5:1 时**直接退回全不透明墨**，于是在深色
/// 画布上副行和主行一样亮 —— 当前行的罗马音与翻译看起来像被高亮了。现在改成在
/// `[requested, ceiling]` 之间找最小的可读 alpha，并且永不越过 [ceiling]，
/// 副行始终是副行。
Color lyricSecondaryInk(Color ink, Color surface, double requested) {
  const double ceiling = .72;
  double alpha = requested.clamp(0.0, ceiling);
  while (alpha < ceiling &&
      colorContrast(
            Color.alphaBlend(ink.withValues(alpha: alpha), surface),
            surface,
          ) <
          4.5) {
    alpha = (alpha + .04).clamp(0.0, ceiling);
  }
  return ink.withValues(alpha: alpha);
}

/// Shared typography and text painting for the player and desktop lyrics.
///
/// [weight] is the user's 歌词字重. A skin may ship its own lyric weight
/// (`elements.lyricWeight`), but only as a default: once the user moves that
/// slider the caller passes `honorThemeWeight: false` and their value is used
/// verbatim, so installing a skin cannot silently rewrite the font setting.
TextStyle lyricTextStyle(
  TextStyle base,
  double size,
  int weight, {
  LazerThemeTokens? theme,
  bool translation = false,
  bool honorThemeWeight = true,
}) {
  final tokens = theme ?? LazerThemeTokens.apple;
  return base.copyWith(
    fontSize: size,
    fontWeight: honorThemeWeight
        ? (translation
              ? tokens.lyricTranslationFontWeight(weight)
              : tokens.lyricFontWeight(weight))
        : LazerThemeTokens.fontWeight(weight),
    height: translation
        ? tokens.lyricTranslationLineHeight
        : tokens.lyricLineHeight,
    color: Colors.white,
  );
}

String lyricSemanticLabel(LyricLine line, {bool showRomanization = true}) => [
  line.text,
  if (showRomanization && line.romanization != null) line.romanization!,
  if (line.translation != null) line.translation!,
].join('\n');

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
