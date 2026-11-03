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

LyricLine _line() {
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
    'highlighted ordinary words share one paragraph while still floating',
    (tester) async {
      final repaint = ValueNotifier(0);
      addTearDown(repaint.dispose);
      var position = const Duration(milliseconds: 600);
      const text = 'ordinary floating words';
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 120,
              child: TimedLyricText(
                line: const LyricLine(
                  Duration.zero,
                  text,
                  words: [
                    LyricWord(Duration.zero, Duration(milliseconds: 180), text),
                  ],
                ),
                style: const TextStyle(fontSize: 22, color: Colors.white),
                active: true,
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

      final floated = record();
      expect(
        floated.invocations.where(
          (call) => call.invocation.memberName == #drawParagraph,
        ),
        hasLength(2),
        reason: 'one dim paragraph and one shared bright word, including wraps',
      );
      expect(
        floated.invocations.where(
          (call) => call.invocation.memberName == #saveLayer,
        ),
        isEmpty,
      );
      final measure = TextPainter(
        text: const TextSpan(
          text: text,
          style: TextStyle(fontSize: 22, color: Colors.white),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 120);
      final parts = measure.getBoxesForSelection(
        const TextSelection(baseOffset: 0, extentOffset: text.length),
      );
      final lastGlyph = measure
          .getBoxesForSelection(
            const TextSelection(
              baseOffset: text.length - 1,
              extentOffset: text.length,
            ),
          )
          .single;
      final width = parts.fold<double>(
        0,
        (sum, part) => sum + part.right - part.left,
      );
      final consumed = parts
          .take(parts.length - 1)
          .fold<double>(0, (sum, part) => sum + part.right - part.left);
      final completeUs =
          ((lastGlyph.right +
                      (lastGlyph.bottom - lastGlyph.top) / 4 -
                      parts.last.left +
                      consumed) *
                  180000 /
                  width)
              .ceil();
      measure.dispose();
      position = Duration(microseconds: completeUs - 1);
      expect(
        record().invocations.where(
          (call) => call.invocation.memberName == #saveLayer,
        ),
        isNotEmpty,
        reason: 'the final soft mask edge remains until it clears the glyph',
      );
      position = Duration(microseconds: completeUs);
      expect(
        record().invocations.where(
          (call) => call.invocation.memberName == #drawParagraph,
        ),
        hasLength(2),
      );
      position = const Duration(milliseconds: 90);
      expect(
        record().invocations.where(
          (call) => call.invocation.memberName == #saveLayer,
        ),
        isNotEmpty,
        reason: 'rewinding restores the per-glyph mask at its soft boundary',
      );
    },
  );

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
                line: _line(),
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
}
