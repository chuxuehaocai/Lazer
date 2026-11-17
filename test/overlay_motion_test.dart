import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/desktop_lyrics/overlay_motion.dart';
import 'package:lazer_nextgen/lyrics/spring.dart';

void main() {
  test('rapid seeks retain only the five visible rows and two neighbours', () {
    final motions = OverlayMotionBuffer();
    for (var i = 0; i < 10000; i++) {
      final focus = (i * 173) % 10000;
      motions.retarget(
        focus: focus,
        lineCount: 5,
        documentLength: 10000,
        slot: 72,
        padding: 18,
        inactiveScale: 93,
        params: const LyricSpringParams(),
        seeking: true,
        instant: false,
      );
      expect(motions.length, lessThanOrEqualTo(7));
      expect(motions[focus], isNotNull);
    }
  });
  test(
    'snap and custom theme scale use the same target as emphasis rendering',
    () {
      final motions = OverlayMotionBuffer();
      motions.retarget(
        focus: 5,
        lineCount: 3,
        documentLength: 20,
        slot: 72,
        padding: 18,
        inactiveScale: 93,
        params: const LyricSpringParams(),
        seeking: false,
        instant: true,
      );
      expect(motions[5]!.scale.value, 100);
      expect(motions[4]!.scale.value, 93);
      expect(motions.values.every((m) => m.arrived), isTrue);
      expect(motions[5]!.y.value, 90);
    },
  );
}
