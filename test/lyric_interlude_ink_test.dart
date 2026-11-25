import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/lyrics/interlude.dart';
import 'package:lazer_nextgen/lyrics/lyric_document.dart';

/// 间奏三点必须用歌词正文的颜色。
///
/// 羊皮纸这类浅色主题里歌词是黑的，三点原来写死白色 —— 在纸上直接看不见。
/// 这里既测像素，也测「柔光在深墨上要收得很淡」这条经验值。
const _line = LyricLine(
  Duration(seconds: 1),
  '',
  end: Duration(seconds: 8),
);

/// 画一帧并取回 RGBA 字节。截图与取字节都要在 [WidgetTester.runAsync] 里，
/// 否则 engine 的异步栅格化不会推进，await 会一直挂着。
Future<Uint8List> _pixels(
  WidgetTester tester,
  Color ink, {
  Duration position = const Duration(seconds: 4),
}) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      home: RepaintBoundary(
        key: key,
        child: ColoredBox(
          color: const Color(0xFFEFE6D3), // 羊皮纸的底色
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 240,
              height: 52,
              child: LyricInterludeDots(
                line: _line,
                position: () => position,
                presence: () => 1,
                repaint: const AlwaysStoppedAnimation<double>(0),
                diameter: 12,
                ink: ink,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return data!.buffer.asUint8List();
  });
  return bytes!;
}

double _luminance(Uint8List data, int i) =>
    (0.2126 * data[i] + 0.7152 * data[i + 1] + 0.0722 * data[i + 2]) / 255;

void main() {
  testWidgets('浅色主题：三点画成深墨而不是白点', (tester) async {
    final data = await _pixels(tester, const Color(0xFF1A1A1A));
    var darkest = 1.0;
    for (var i = 0; i < data.length; i += 4) {
      final lum = _luminance(data, i);
      if (lum < darkest) darkest = lum;
    }
    expect(
      darkest,
      lessThan(.35),
      reason: '羊皮纸上必须看得到深色圆点（白点在纸上留不下任何暗像素）',
    );
  });

  testWidgets('浅墨仍然落笔（深色主题 / 悬浮歌词）', (tester) async {
    final data = await _pixels(tester, Colors.white);
    var bright = 0;
    for (var i = 0; i < data.length; i += 4) {
      if (data[i] > 248 && data[i + 1] > 248 && data[i + 2] > 248) bright++;
    }
    expect(bright, greaterThan(0), reason: '白墨必须画得出来');
  });

  test('深墨的柔光收得比浅墨淡', () {
    // 纸上糊一团灰雾就是这里失控的信号。
    expect(interludeHaloFactor(0.02), lessThan(interludeHaloFactor(0.95)));
    expect(interludeHaloFactor(0.02), lessThan(.25));
    expect(interludeHaloFactor(0.95), closeTo(.58, .001));
  });
}
