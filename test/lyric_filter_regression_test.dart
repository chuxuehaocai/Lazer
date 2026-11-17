import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/lyrics.dart';
import 'package:lazer_nextgen/lyrics/edge_fade.dart';
import 'package:lazer_nextgen/lyrics/viewport.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';

Future<List<int>> _maskAlpha(
  WidgetTester tester, {
  required double extent,
  required int height,
}) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: LyricEdgeFade(
        verticalExtent: extent,
        horizontal: false,
        child: const SizedBox(width: 8, height: 64),
      ),
    ),
  );
  final mask = tester.widget<ShaderMask>(find.byType(ShaderMask));
  final shader = mask.shaderCallback(Rect.fromLTWH(0, 0, 8, height.toDouble()));
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, 8, height.toDouble()),
    Paint()..shader = shader,
  );
  final picture = recorder.endRecording();
  final image = (await tester.runAsync(() => picture.toImage(8, height)))!;
  final bytes = (await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  ))!;
  final alpha = [
    for (var y = 0; y < height; y++) bytes.getUint8((y * 8 + 4) * 4 + 3),
  ];
  image.dispose();
  picture.dispose();
  shader.dispose();
  return alpha;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('negligible lyric fades use a fully opaque mask', (tester) async {
    final alpha = await _maskAlpha(tester, extent: 1, height: 2048);
    expect(alpha.every((value) => value == 255), isTrue);
  });

  testWidgets('ordinary lyric fades retain a clear centre and fading edges', (
    tester,
  ) async {
    final alpha = await _maskAlpha(tester, extent: 20, height: 100);
    expect(alpha.first, lessThan(10));
    expect(alpha[50], 255);
    expect(alpha.last, lessThan(10));
  });

  testWidgets(
    'visible lyric blur filters explicitly sample transparent edges',
    (tester) async {
      final state = AppState()
        ..lyricBlurEnabled = true
        ..lyricBlurIntensity = 1
        ..lyrics = [
          for (var index = 0; index < 20; index++)
            LyricLine(Duration(seconds: index * 5), 'Lyric line $index'),
        ];
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(),
          home: Scaffold(
            body: SizedBox(height: 400, child: LyricViewport(state: state)),
          ),
        ),
      );
      await tester.pump();
      final blurred = tester
          .widgetList<ImageFiltered>(find.byType(ImageFiltered))
          .where((widget) => widget.enabled);
      expect(blurred, isNotEmpty);
      for (final widget in blurred) {
        // This checks the explicit sampling contract. Linux/Wayland GPU output
        // still needs a physical renderer test; the host cannot establish it.
        expect(widget.imageFilter.debugShortDescription, contains(', decal'));
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
