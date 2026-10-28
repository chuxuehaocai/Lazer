import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/hifi_controller.dart';
import 'package:lazer_nextgen/state/hifi_settings.dart';

void main() {
  test('rapid EQ updates persist only the final settings snapshot', () async {
    final List<HifiSettings> writes = <HifiSettings>[];
    final HifiController controller = HifiController(
      const HifiSettings(),
      engine: null,
      persist: (HifiSettings settings) async => writes.add(settings),
    );
    addTearDown(controller.dispose);

    await controller.update(
      const HifiSettings(
        equalizer: HifiEqualizerState(
          enabled: true,
          bands: <HifiEqBand>[HifiEqBand(frequencyHz: 1000, gainDb: 0.1)],
        ),
      ),
    );
    await controller.update(
      const HifiSettings(
        equalizer: HifiEqualizerState(
          enabled: true,
          bands: <HifiEqBand>[HifiEqBand(frequencyHz: 1000, gainDb: 0.2)],
        ),
      ),
    );

    expect(writes, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 220));

    expect(writes, hasLength(1));
    expect(writes.single.equalizer.effectiveBands.single.gainDb, 0.2);
  });

  test('disposing flushes a pending settings write', () async {
    final List<HifiSettings> writes = <HifiSettings>[];
    final HifiController controller = HifiController(
      const HifiSettings(),
      engine: null,
      persist: (HifiSettings settings) async => writes.add(settings),
    );

    await controller.update(
      const HifiSettings(
        equalizer: HifiEqualizerState(
          enabled: true,
          bands: <HifiEqBand>[HifiEqBand(frequencyHz: 1000, gainDb: 0.1)],
        ),
      ),
    );
    controller.dispose();
    await Future<void>.delayed(Duration.zero);

    expect(writes, hasLength(1));
    expect(writes.single.equalizer.effectiveBands.single.gainDb, 0.1);
  });
}
