import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/audio/automix_audio_engine.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/track_transition.dart';
import 'package:lazer_nextgen/state/app_state.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('AutoMix transition planner keeps overlap bounded and equal-power', () {
    const planner = AutoMixTransitionPlanner();
    expect(
      planner.duration(
        outgoing: const Duration(minutes: 3),
        incoming: const Duration(minutes: 4),
      ),
      const Duration(seconds: 8),
    );
    expect(
      planner.duration(
        outgoing: const Duration(milliseconds: 500),
        incoming: const Duration(milliseconds: 700),
      ),
      lessThan(const Duration(milliseconds: 500)),
    );
    final (double outgoing, double incoming) = planner.gains(.5);
    expect(outgoing, closeTo(incoming, 0.0001));
    expect(outgoing * outgoing + incoming * incoming, closeTo(1, 0.0001));
  });

  test('AutoMix setting defaults off and survives bootstrap', () async {
    final AppState state = AppState(catalog: Catalog());
    addTearDown(state.dispose);
    expect(state.autoMixEnabled, isFalse);
    expect(state.trackTransition, TrackTransition.albumGapless);
    await state.setAutoMixEnabled(true);
    expect(state.autoMixEnabled, isTrue);
    expect(state.trackTransition, TrackTransition.autoMix);
    expect(
      (await SharedPreferences.getInstance()).getBool('lazer_automix_enabled'),
      isTrue,
    );

    final AppState restored = AppState(catalog: Catalog());
    addTearDown(restored.dispose);
    await restored.bootstrap();
    expect(restored.autoMixEnabled, isTrue);
    expect(restored.trackTransition, TrackTransition.autoMix);
  });
}
