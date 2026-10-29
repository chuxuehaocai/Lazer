// CI wrapper for the HiFi settings checks.
//
// The assertions live in `tool/native_hifi_check.dart`'s sibling logic; this test
// re-runs them through `flutter test` while `dart tool/native_hifi_check.dart`
// covers hosts without a Flutter toolchain.
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/state/hifi_settings.dart';

void main() {
  test('master-branch encoding still parses', () {
    const String master =
        '1|-3.0|1|31.0:7.0:1.0:LowShelf:1;62.0:6.0:1.0:Peak:1';
    final HifiEqualizerState state = HifiEqualizerState.decode(master);
    expect(state.enabled, true);
    expect(state.preampDb, -3);
    expect(state.effectiveBands.first.kind, HifiEqBandKind.lowShelf);
  });

  test('a malformed value falls back to a flat curve', () {
    for (final String? broken in <String?>[null, '', 'garbage', '1|0']) {
      final HifiEqualizerState state = HifiEqualizerState.decode(broken);
      expect(state.enabled, false);
      expect(state.effectiveBands.length, hifiEqBandFrequencies.length);
    }
  });

  test('bit-perfect bypasses the equalizer', () {
    final HifiSettings settings = HifiSettings(
      bitPerfect: true,
      equalizer: const HifiEqualizerState(enabled: true),
    );
    expect(settings.eqActive, false);
    expect(
      settings.equalizer
          .toEngineMessage(eqActive: settings.eqActive)
          .bands
          .length,
      0,
    );
  });

  test('every preset round-trips through the encoding', () {
    for (final HifiEqPreset preset in hifiEqPresets) {
      final HifiEqualizerState state = const HifiEqualizerState()
          .withPreset(preset)
          .copyWith(enabled: true);
      expect(HifiEqualizerState.decode(state.encode()).matchingPresetId, preset.id);
    }
  });
}
