import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/lyrics.dart';
import 'package:lazer_nextgen/lyrics/word_motion.dart';
import 'package:lazer_nextgen/widgets/timed_lyric_text.dart';

double _referenceEaseOut(double x) {
  var low = 0.0;
  var high = 1.0;
  for (var i = 0; i < 40; i++) {
    final t = (low + high) / 2;
    final value = 3 * (1 - t) * t * t * .58 + t * t * t;
    if (value < x) {
      low = t;
    } else {
      high = t;
    }
  }
  final t = (low + high) / 2;
  return 3 * (1 - t) * t * t + t * t * t;
}

LyricLine _line(int index) {
  final words = <LyricWord>[
    for (var i = 0; i < 24; i++)
      LyricWord(
        Duration(milliseconds: i * 180),
        const Duration(milliseconds: 180),
        'word$i ',
      ),
  ];
  return LyricLine(
    Duration.zero,
    words.map((word) => word.text).join(),
    words: words,
  );
}

void main() {
  test('ordinary and held motion retain the original cubic trajectory', () {
    for (var i = 0; i <= 10000; i++) {
      final x = i / 10000;
      final expected = -.05 * _referenceEaseOut(x);
      expect(
        LyricWordMotion.ordinary(x * 2000, 2000).yEm,
        closeTo(expected, 1e-11),
      );
      expect(
        LyricWordMotion.emphasized(x * 2000, 2000, 0, 1, holdFloat: true).yEm,
        closeTo(expected, 1e-11),
      );
    }
    for (final elapsed in [-1000.0, -1.0, 0.0, 1e-12, 1e-8, 2000.0, 9000.0]) {
      final expected = -.05 * _referenceEaseOut((elapsed / 2000).clamp(0, 1));
      expect(
        LyricWordMotion.ordinary(elapsed, 2000).yEm,
        closeTo(expected, 1e-11),
      );
    }
  });

  testWidgets(
    'settled focus skips opacity layers and survives backwards seeks',
    (tester) async {
      final repaint = ValueNotifier(0);
      addTearDown(repaint.dispose);
      var position = const Duration(seconds: 12);
      var focus = 1.0;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 500,
              child: TimedLyricText(
                line: _line(0),
                style: const TextStyle(fontSize: 16),
                active: true,
                emphasis: () => focus,
                position: () => position,
                repaint: repaint,
              ),
            ),
          ),
        ),
      );
      final finder = find.descendant(
        of: find.byType(TimedLyricText),
        matching: find.byType(CustomPaint),
      );
      final painter = tester.widget<CustomPaint>(finder).painter!;
      final size = tester.getSize(finder);
      TestRecordingCanvas record() {
        final canvas = TestRecordingCanvas();
        painter.paint(canvas, size);
        expect(canvas.getSaveCount(), 0);
        return canvas;
      }

      int layers(TestRecordingCanvas canvas) => canvas.invocations
          .where((call) => call.invocation.memberName == #saveLayer)
          .length;
      final settled = record();
      expect(layers(settled), 0);
      position = const Duration(milliseconds: 90);
      final rewound = record();
      expect(
        layers(rewound),
        greaterThan(0),
        reason: 'the highlight mask returns after a rewind',
      );
      position = const Duration(seconds: 12);
      expect(layers(record()), 0);
      focus = .5;
      expect(
        layers(record()),
        2,
        reason: 'both fade groups are retained during focus transitions',
      );
      focus = 0;
      final inactive = record();
      expect(layers(inactive), 0);
      expect(
        inactive.invocations.where(
          (call) => call.invocation.memberName == #drawParagraph,
        ),
        hasLength(1),
      );
    },
  );

  testWidgets('records lyric layout and paint costs with synthetic text', (
    tester,
  ) async {
    final repaint = ValueNotifier(0);
    addTearDown(repaint.dispose);
    var position = const Duration(milliseconds: 1800);
    final lines = List<LyricLine>.generate(16, _line);
    final layouts = <int>[];
    for (var iteration = 0; iteration < 8; iteration++) {
      await tester.pumpWidget(const SizedBox.shrink());
      final watch = Stopwatch()..start();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              for (var i = 0; i < lines.length; i++)
                SizedBox(
                  width: 760,
                  height: 30,
                  child: TimedLyricText(
                    line: lines[i],
                    style: const TextStyle(fontSize: 12),
                    active: i == 0,
                    position: () => position,
                    repaint: repaint,
                  ),
                ),
            ],
          ),
        ),
      );
      layouts.add(watch.elapsedMicroseconds);
    }
    final finder = find.descendant(
      of: find.byType(TimedLyricText).first,
      matching: find.byType(CustomPaint),
    );
    final painter = tester.widget<CustomPaint>(finder).painter!;
    final size = tester.getSize(finder);
    final canvas = TestRecordingCanvas();
    painter.paint(canvas, size);
    final layers = canvas.invocations
        .where((call) => call.invocation.memberName == #saveLayer)
        .length;
    final paints = <int>[];
    for (var round = 0; round < 7; round++) {
      final watch = Stopwatch()..start();
      for (var frame = 0; frame < 300; frame++) {
        position = Duration(milliseconds: 1200 + frame * 10);
        final recorder = ui.PictureRecorder();
        painter.paint(Canvas(recorder), size);
        recorder.endRecording().dispose();
      }
      paints.add(watch.elapsedMicroseconds);
    }
    layouts.sort();
    paints.sort();
    final result = {
      'layout_16_rows_median_ms': layouts[layouts.length ~/ 2] / 1000,
      'paint_300_frames_median_ms': paints[paints.length ~/ 2] / 1000,
      'active_row_save_layers': layers,
    };
    // Timings are observational; regression gates assert work, not host speed.
    // ignore: avoid_print
    print('LYRIC_RENDER_PROFILE ${jsonEncode(result)}');
    const output = String.fromEnvironment('LYRIC_PROFILE_OUTPUT');
    if (output.isNotEmpty) {
      await tester.runAsync(
        () => File(output).writeAsString(jsonEncode(result)),
      );
    }
    expect(canvas.getSaveCount(), 0);
    expect(tester.takeException(), isNull);
  });
}
