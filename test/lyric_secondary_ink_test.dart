import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/lyrics/line_content.dart';
import 'package:lazer_nextgen/theme/adaptive_contrast.dart';

/// 罗马音与翻译是「副行」：永远比主行淡，不跟当前行走高亮。
///
/// 这条规则以前在深色画布上被一条「对比度不够就退回全不透明墨」的兜底破坏掉，
/// 结果当前行的副行和主行一样亮。这里把三个不变量钉住：
/// 1. 不超过 0.72（不会被当成高亮）；
/// 2. 仍然达到 4.5:1（读得清）；
/// 3. 请求值更淡时不会反而更浓。
void main() {
  const ink = Color(0xFFF0EEE6);
  const darkCanvas = Color(0xFF191918);
  const lightCanvas = Color(0xFFF0EEE6);

  test('深色画布：不越界，也不退回全不透明', () {
    final Color result = lyricSecondaryInk(ink, darkCanvas, .48);
    expect(result.a, lessThanOrEqualTo(.72 + 1e-9));
    expect(result.a, lessThan(1));
    expect(
      colorContrast(Color.alphaBlend(result, darkCanvas), darkCanvas),
      greaterThanOrEqualTo(4.5),
    );
  });

  test('浅色画布：深墨副行同样满足可读性', () {
    const darkInk = Color(0xFF141413);
    final Color result = lyricSecondaryInk(darkInk, lightCanvas, .48);
    expect(result.a, lessThanOrEqualTo(.72 + 1e-9));
    expect(
      colorContrast(Color.alphaBlend(result, lightCanvas), lightCanvas),
      greaterThanOrEqualTo(4.5),
    );
  });

  test('永远不高于上限，即使皮肤请求 100%', () {
    final Color result = lyricSecondaryInk(ink, darkCanvas, 1);
    expect(result.a, lessThanOrEqualTo(.72 + 1e-9));
  });

  test('皮肤给得更淡时，结果不会更浓', () {
    final Color dim = lyricSecondaryInk(ink, darkCanvas, .30);
    final Color brighter = lyricSecondaryInk(ink, darkCanvas, .60);
    expect(dim.a, lessThanOrEqualTo(brighter.a));
  });
}
