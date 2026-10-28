// Checks for the HiFi settings layer: encodings, presets and the mapping onto the
// engine's DSP/device messages.
//
// Flutter-free so it runs with plain Dart:
//
//   dart tool/native_hifi_check.dart
//
// The encodings matter because they are persisted and read at start-up: a value
// written by the master branch must still parse here, and a malformed value must
// fall back to a flat curve instead of throwing.
import 'dart:io';

import 'package:lazer_nextgen/state/hifi_settings.dart';

int _failures = 0;

void _expect(String what, Object? actual, Object? expected) {
  final bool ok = '$actual' == '$expected';
  stdout.writeln('${ok ? 'ok  ' : 'FAIL'} $what: $actual'
      '${ok ? '' : ' (expected $expected)'}');
  if (!ok) _failures++;
}

void main() {
  // ---- band layout ---------------------------------------------------------
  final List<HifiEqBand> bands = defaultHifiEqBands();
  _expect('band count', bands.length, 10);
  _expect('band frequencies', bands.map((HifiEqBand b) => b.frequencyHz).join(','),
      '31.0,62.0,125.0,250.0,500.0,1000.0,2000.0,4000.0,8000.0,16000.0');
  _expect('first band is a low shelf', bands.first.kind, HifiEqBandKind.lowShelf);
  _expect('last band is a high shelf', bands.last.kind, HifiEqBandKind.highShelf);
  _expect('middle band is a peak', bands[4].kind, HifiEqBandKind.peak);
  _expect('bands start flat', bands.every((HifiEqBand b) => b.gainDb == 0), true);

  // ---- clamping ------------------------------------------------------------
  _expect('gain clamps high', clampHifiEqGainDb(99), 12.0);
  _expect('gain clamps low', clampHifiEqGainDb(-99), -12.0);
  _expect('preamp clamps', clampHifiPreampDb(-40), -12.0);

  // ---- round trip ----------------------------------------------------------
  const HifiEqualizerState original = HifiEqualizerState(
    enabled: true,
    preampDb: -2.5,
    limiterEnabled: false,
    bands: <HifiEqBand>[],
  );
  final HifiEqualizerState presetApplied = original.withPreset(
    hifiEqPresets.firstWhere((HifiEqPreset p) => p.id == 'rock'),
  );
  final HifiEqualizerState decoded = HifiEqualizerState.decode(
    presetApplied.encode(),
  );
  _expect('round trip keeps enabled', decoded.enabled, true);
  _expect('round trip keeps preamp', decoded.preampDb, presetApplied.preampDb);
  _expect('round trip keeps limiter', decoded.limiterEnabled, false);
  _expect(
    'round trip keeps gains',
    decoded.effectiveBands.map((HifiEqBand b) => b.gainDb).join(','),
    presetApplied.effectiveBands.map((HifiEqBand b) => b.gainDb).join(','),
  );
  _expect('round trip keeps band kinds',
      decoded.effectiveBands.map((HifiEqBand b) => b.kind).join(','),
      presetApplied.effectiveBands.map((HifiEqBand b) => b.kind).join(','));

  // ---- master compatibility ------------------------------------------------
  // A value written by the master branch (Kotlin `serialize()`) must parse here.
  const String masterValue =
      '1|-3.0|1|31.0:7.0:1.0:LowShelf:1;62.0:6.0:1.0:Peak:1;125.0:4.5:1.0:Peak:1;'
      '250.0:2.5:1.0:Peak:1;500.0:0.5:1.0:Peak:1;1000.0:-0.5:1.0:Peak:1;'
      '2000.0:-1.0:1.0:Peak:1;4000.0:-1.5:1.0:Peak:1;8000.0:-2.0:1.0:Peak:1;'
      '16000.0:-2.5:1.0:HighShelf:1';
  final HifiEqualizerState fromMaster = HifiEqualizerState.decode(masterValue);
  _expect('master value enables EQ', fromMaster.enabled, true);
  _expect('master value preamp', fromMaster.preampDb, -3.0);
  _expect('master value band count', fromMaster.effectiveBands.length, 10);
  _expect('master value detects the bass preset', fromMaster.matchingPresetId, 'bass');
  _expect(
    'master value kinds survive the Kotlin enum names',
    fromMaster.effectiveBands.first.kind,
    HifiEqBandKind.lowShelf,
  );

  // ---- malformed input falls back, never throws ----------------------------
  for (final String? broken in <String?>[null, '', 'garbage', '1|0', '1|0|0|a:b']) {
    final HifiEqualizerState fallback = HifiEqualizerState.decode(broken);
    _expect(
      'malformed "$broken" falls back flat',
      fallback.enabled == false && fallback.effectiveBands.length == 10,
      true,
    );
  }

  // ---- presets are self-consistent ----------------------------------------
  for (final HifiEqPreset preset in hifiEqPresets) {
    _expect(
      'preset ${preset.id} has one gain per band',
      preset.gainsDb.length,
      hifiEqBandFrequencies.length,
    );
    _expect(
      'preset ${preset.id} detects itself',
      const HifiEqualizerState()
          .withPreset(preset)
          .matchingPresetId,
      preset.id,
    );
  }

  // ---- engine mapping -----------------------------------------------------
  final HifiEqualizerState eq = const HifiEqualizerState(
    enabled: true,
    preampDb: 3,
    bands: <HifiEqBand>[],
  ).withPreset(hifiEqPresets.firstWhere((HifiEqPreset p) => p.id == 'vocal'));
  final HifiDspMessage active = eq.toEngineMessage(eqActive: true);
  _expect('EQ sends ten bands', active.bands.length, 10);
  _expect('EQ sends the preset preamp', active.preampDb, -2.0);
  _expect('EQ band kinds map to the engine numbering',
      active.bands.map((HifiEqBandMessage b) => b.kind).join(','),
      '1,0,0,0,0,0,0,0,0,2');
  final HifiDspMessage bypassed = eq.toEngineMessage(eqActive: false);
  _expect('bit-perfect sends no bands', bypassed.bands.length, 0);
  _expect('bit-perfect keeps the limiter decision', bypassed.limiterEnabled, true);

  // A disabled band is dropped rather than sent with gain 0, so the engine keeps
  // its coefficient state for the bands it does run.
  final HifiEqualizerState withDisabled = eq.copyWith(
    bands: <HifiEqBand>[
      for (int index = 0; index < eq.effectiveBands.length; index++)
        eq.effectiveBands[index].copyWith(enabled: index != 3),
    ],
  );
  _expect('a disabled band is not sent',
      withDisabled.toEngineMessage(eqActive: true).bands.length, 9);

  // ---- device message -----------------------------------------------------
  final HifiSettings settings = HifiSettings(
    outputToken: 'hw:CARD=DAC,DEV=0',
    exclusiveMode: true,
    bitPerfect: true,
    dsdOutputMode: HifiDsdOutputMode.requireDoP,
    buffer: HifiBufferSize.medium,
  );
  _expect('device message', settings.toOutputRequest().toDeviceMessage(),
      <Object?>[1, 0, 0, 240, 1, 1]);
  _expect('eqActive is off while bit-perfect', settings.eqActive, false);
  _expect(
    'bit-perfect implies the engine will bypass the EQ',
    settings.copyWith(equalizer: eq).eqActive,
    false,
  );
  final Map<String, Object?> stored = settings.toMap();
  final HifiSettings restored = HifiSettings.fromMap(<String, Object?>{
    'hifi_native_engine': false,
    'hifi_output_token': stored['hifi_output_token'],
    'hifi_output_name': 'DAC',
    'hifi_exclusive': stored['hifi_exclusive'],
    'hifi_bit_perfect': stored['hifi_bit_perfect'],
    'hifi_dsd_mode': stored['hifi_dsd_mode'],
    'hifi_buffer_millis': stored['hifi_buffer_millis'],
    'hifi_equalizer': eq.encode(),
  });
  _expect('settings round trip token', restored.outputToken, 'hw:CARD=DAC,DEV=0');
  _expect('settings round trip exclusive', restored.exclusiveMode, true);
  _expect('settings round trip bit-perfect', restored.bitPerfect, true);
  _expect('settings round trip DSD mode', restored.dsdOutputMode,
      HifiDsdOutputMode.requireDoP);
  _expect('settings round trip buffer', restored.buffer, HifiBufferSize.medium);
  _expect('settings round trip native flag', restored.preferNativeEngine, false);
  _expect('settings round trip EQ', restored.equalizer.matchingPresetId, 'vocal');

  // A cleared device selection must fall back to the system default, not to a
  // stale token.
  _expect('clearing the output clears both fields',
      settings.copyWith(clearOutput: true).outputToken, null);
  // `auto` resolves to the PCM value for the *first* attempt; the order it walks is
  // carried by `fallbackChain`, which the controller hands to the engine separately.
  _expect('DSD mode values match the ABI',
      HifiDsdOutputMode.values.map((HifiDsdOutputMode m) => m.nativeValue).join(','),
      '0,0,1,2');

  // ---- option model ported from Twilight Echo ----------------------------
  _expect('DSD modes', HifiDsdOutputMode.values.length, 4);
  _expect('DSD auto is the default', HifiDsdOutputMode.parse(null),
      HifiDsdOutputMode.auto);
  _expect(
    'auto tries native then DoP then PCM',
    HifiDsdOutputMode.auto.fallbackChain
        .map((HifiDsdOutputMode m) => m.nativeValue)
        .join(','),
    '2,1,0',
  );
  _expect('explicit policy has a single attempt',
      HifiDsdOutputMode.requireDoP.fallbackChain.length, 1);
  _expect('rate policies', HifiDsdRatePolicy.values.length, 3);
  _expect('only PCM fallback is implementable',
      HifiDsdRatePolicy.values.where((HifiDsdRatePolicy p) => p.isSupported)
          .map((HifiDsdRatePolicy p) => p.name)
          .join(','),
      'pcmFallback');
  _expect('normalisation modes',
      HifiVolumeNormalization.values
          .map((HifiVolumeNormalization m) => m.name)
          .join(','),
      'off,track,album,loudnorm');
  _expect('loudnorm is reported unavailable',
      HifiVolumeNormalization.loudnorm.isSupported, false);
  _expect('track/album need source gain',
      HifiVolumeNormalization.track.needsSourceGain &&
          HifiVolumeNormalization.album.needsSourceGain &&
          !HifiVolumeNormalization.off.needsSourceGain,
      true);

  // ---- crossfeed ----------------------------------------------------------
  _expect('crossfeed algorithms',
      HifiCrossfeedAlgorithm.values
          .map((HifiCrossfeedAlgorithm a) => a.nativeValue)
          .join(','),
      '0,1,2,3');
  _expect('Bauer fixes 0.22 ms / 700 Hz',
      '${HifiCrossfeedAlgorithm.bauer.delayMs}/${HifiCrossfeedAlgorithm.bauer.cutoffHz}',
      '0.22/700.0');
  _expect('Meier fixes 0.35 ms / 650 Hz',
      '${HifiCrossfeedAlgorithm.meier.delayMs}/${HifiCrossfeedAlgorithm.meier.cutoffHz}',
      '0.35/650.0');
  const HifiCrossfeedState custom = HifiCrossfeedState(
    enabled: true,
    strength: 0.4,
    delayMs: 1.5,
    cutoffHz: 1200,
  );
  _expect('custom honours its own delay', custom.effectiveDelayMs, 1.5);
  _expect('a named algorithm overrides the custom delay',
      custom.copyWith(algorithm: HifiCrossfeedAlgorithm.meier).effectiveDelayMs,
      0.35);
  _expect('crossfeed round trip',
      HifiCrossfeedState.decode(custom.encode()).effectiveCutoffHz, 1200.0);
  _expect('a malformed crossfeed value falls back',
      HifiCrossfeedState.decode('nonsense').enabled, false);
  _expect('crossfeed alters the signal when on', custom.altersSignal, true);
  _expect('zero strength does not alter the signal',
      custom.copyWith(strength: 0).altersSignal, false);

  // ---- DSP request --------------------------------------------------------
  final HifiSettings full = HifiSettings(
    equalizer: eq,
    crossfeed: custom,
    dsdOutputMode: HifiDsdOutputMode.auto,
    volumeNormalization: HifiVolumeNormalization.album,
  );
  final LazerDspRequest request = full.toDspRequest();
  _expect('DSP request carries crossfeed', request.crossfeedEnabled, true);
  _expect('DSP request crossfeed message', request.toCrossfeedMessage(),
      <Object?>[1, 0.4, 0, 1.5, 1200.0]);
  _expect('DSP request reports activity', full.dspActive, true);
  _expect('DSP request carries the bands', request.bands.length, 10);
  _expect(
    'bit-perfect drops crossfeed from the request',
    full.copyWith(bitPerfect: true).toDspRequest().crossfeedEnabled,
    false,
  );
  _expect('DSD auto maps to the PCM engine value for the first attempt',
      full.toOutputRequest().dsdOutputMode.nativeValue, 0);

  // Persisted form must survive a restart with the new fields.
  final HifiSettings restoredFull = HifiSettings.fromMap(<String, Object?>{
    'hifi_dsd_mode': full.dsdOutputMode.name,
    'hifi_dsd_rate_policy': full.dsdRatePolicy.name,
    'hifi_volume_normalization': full.volumeNormalization.name,
    'hifi_crossfeed': full.crossfeed.encode(),
    'hifi_equalizer': full.equalizer.encode(),
  });
  _expect('settings keep the DSD policy', restoredFull.dsdOutputMode,
      HifiDsdOutputMode.auto);
  _expect('settings keep the normalisation mode',
      restoredFull.volumeNormalization, HifiVolumeNormalization.album);
  _expect('settings keep the crossfeed strength',
      restoredFull.crossfeed.strength, 0.4);

  stdout.writeln(_failures == 0
      ? 'hifi settings check passed'
      : 'hifi settings check failed ($_failures expectations)');
  exit(_failures == 0 ? 0 : 1);
}
