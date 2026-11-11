import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/widgets/lyric_edge_fade.dart';
import 'package:lazer_nextgen/widgets/lyric_viewport.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/serialized_semantics.dart';

class _Catalog extends Catalog {
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
    bool Function()? isCancelled,
  }) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => GatewayLyrics(
    lrc: [
      for (var i = 0; i < 30; i++)
        '[00:${(i * 2).toString().padLeft(2, '0')}]真昼の無彩色を不器用な色にして',
    ].join('\n'),
    tlyric: [
      for (var i = 0; i < 30; i++)
        '[00:${(i * 2).toString().padLeft(2, '0')}]正午的灰质着作蹩脚的色彩',
    ].join('\n'),
  );
}

void main() {
  final binding = RecordingSemanticsBinding();
  testWidgets(
    'lyrics use AMLL blur levels and manual browsing clears blur gradually',
    (tester) async {
      final semantics = tester.ensureSemantics();
      binding.recorder.reset();
      SharedPreferences.setMockInitialValues({});
      await (FontLoader('MiSans')
            ..addFont(rootBundle.load('assets/fonts/MiSans-Regular.ttf'))
            ..addFont(rootBundle.load('assets/fonts/MiSans-Semibold.ttf')))
          .load();
      final state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      const track = Track(
        id: '1',
        title: 'Song',
        artist: 'Artist',
        album: 'Album',
        duration: Duration(minutes: 2),
        coverSeed: 0,
      );
      state.playQueue([track]);
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(),
          home: Material(
            child: Center(
              child: RepaintBoundary(
                key: key,
                child: SizedBox(
                  width: 340,
                  height: 500,
                  child: ColoredBox(
                    color: const Color(0xFFF0EEE6),
                    child: LyricViewport(state: state),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      state.seek(30 / 120);
      await tester.pumpAndSettle();
      final viewport = find.byType(LyricViewport);
      expect(
        find.descendant(of: viewport, matching: find.byType(LyricEdgeFade)),
        findsOneWidget,
      );
      final focused = find.byKey(const ValueKey('lyric-blur-15'));
      final adjacent = find.byKey(const ValueKey('lyric-blur-16'));
      expect(tester.widget<ImageFiltered>(focused).enabled, false);
      expect(tester.widget<ImageFiltered>(adjacent).enabled, true);
      expect(
        tester.widget<ImageFiltered>(adjacent).imageFilter,
        // Sigmas are quantized to 1/8 px so frames reuse one filter object;
        // 1.55 lands on 1.5.
        equals(ui.ImageFilter.blur(sigmaX: 1.5, sigmaY: 1.5)),
        reason: 'blur follows the row\'s distance from the focus band',
      );
      await state.setLyricBlurIntensity(.5);
      await tester.pump();
      expect(
        tester.widget<ImageFiltered>(adjacent).imageFilter,
        equals(ui.ImageFilter.blur(sigmaX: .75, sigmaY: .75)),
        reason: 'the intensity slider scales the distance blur',
      );
      await state.setLyricBlurIntensity(1);
      await tester.pump();
      if (const bool.fromEnvironment('SAVE_UI_PROBES')) {
        await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
          await File(
            'diag/lyrics_amll_transition.png',
          ).writeAsBytes(png.buffer.asUint8List());
          image.dispose();
        });
      }
      final row = find.byKey(const ValueKey('lyric-line-15'));
      final semanticRow = find.descendant(
        of: row,
        matching: find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.onTap != null,
        ),
      );
      final nodeId = tester.getSemantics(semanticRow).id;
      final rowX = tester.getTopLeft(row).dx;
      state.seek(32 / 120);
      for (var frame = 0; frame < 15; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getSemantics(semanticRow).id, nodeId);
        expect(tester.getTopLeft(row).dx, rowX);
        final transforms = tester.widgetList<Transform>(
          find.descendant(of: row, matching: find.byType(Transform)),
        );
        for (final transform in transforms) {
          expect(
            transform.transform.entry(0, 0),
            1,
            reason: 'focus motion must preserve horizontal glyph advances',
          );
          expect(transform.transform.entry(0, 3), 0);
        }
      }
      state.seek(30 / 120);
      await tester.pumpAndSettle();
      final before = tester.widget<ImageFiltered>(adjacent).imageFilter;
      final gesture = await tester.startGesture(tester.getCenter(viewport));
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(tester.widget<ImageFiltered>(adjacent).enabled, true);
      expect(tester.widget<ImageFiltered>(adjacent).imageFilter, isNot(before));
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.widget<ImageFiltered>(adjacent).enabled, false);
      await gesture.up();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(tester.widget<ImageFiltered>(adjacent).enabled, true);
      expect(tester.widget<ImageFiltered>(focused).enabled, false);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(binding.recorder.errors, isEmpty);
      expect(binding.recorder.commits, greaterThan(0));
      semantics.dispose();
    },
  );
}
