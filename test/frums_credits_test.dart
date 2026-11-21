import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/easter_egg/frums_credits.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loads the Frums score and renders a non-empty animation frame', () async {
    final score = await FrumsCreditsScore.load();

    expect(score.width, 32);
    expect(score.height, 16);
    expect(score.totalBars, 72);
    expect(score.duration, greaterThan(const Duration(seconds: 90)));

    final frames = [
      for (var index = 0; index < 12; index++)
        score.frameAt(
          Duration(
            microseconds: score.duration.inMicroseconds * index ~/ 12,
          ),
        ),
    ];
    expect(frames.any((frame) => frame.trim().isNotEmpty), isTrue);
  });
}
