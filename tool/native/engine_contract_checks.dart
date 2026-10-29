// Contracts the app depends on when it drives the native engine.
//
// These are the parts that are pure Dart on purpose: the message shapes the
// engine sends to the worker isolate (positional, so a missing field would be read
// as the wrong type mid-open) and the format description shown to the user. Both
// are checked here so they also run without a Flutter toolchain.
import 'package:lazer_nextgen/audio/native/lazer_audio_abi.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_worker.dart';
import 'package:lazer_nextgen/audio/native/lazer_stream_info.dart';

/// Returns a human-readable list of mismatches; empty means the contracts hold.
List<String> verifyEngineContracts() {
  final List<String> failures = <String>[];

  void expect(String what, Object? actual, Object? expected) {
    if ('$actual' != '$expected') {
      failures.add('$what: $actual (expected $expected)');
    }
  }

  // The worker's `_execute` destructures the device message positionally.
  const LazerDeviceSettings device = LazerDeviceSettings(
    exclusive: true,
    bitPerfect: true,
    bufferMillis: 240,
    targetSampleRate: 96000,
    dsdOutputMode: lazerAudioDsdOutputRequireDoP,
    deviceToken: 'hw:CARD=DAC,DEV=0',
  );
  expect('device message', device.toDeviceMessage(), <Object?>[
    1,
    lazerAudioResampleNative,
    96000,
    240,
    1,
    lazerAudioDsdOutputRequireDoP,
  ]);
  expect('device message with token length', device.toMessage().length, 7);
  expect('device token is last', device.toMessage().last, 'hw:CARD=DAC,DEV=0');

  const LazerDeviceSettings defaults = LazerDeviceSettings();
  expect('default device mode', defaults.toDeviceMessage(), <Object?>[
    0,
    lazerAudioResampleNative,
    0,
    120,
    0,
    lazerAudioDsdOutputConvertToPcm,
  ]);

  const LazerOpenSettings open = LazerOpenSettings(
    start: Duration(milliseconds: 1500),
    durationHint: Duration(minutes: 3),
    cueStartFrame75: 75,
    cueEndFrame75: 300,
    replayGainDb: -6.5,
  );
  expect('open message', open.toMessage(), <Object?>[1500, 180000, 75, 300, -6.5]);

  const LazerEqBandSettings band = LazerEqBandSettings(
    kind: lazerAudioEqBandLowShelf,
    frequencyHz: 120,
    gainDb: 3.5,
    q: 0.7,
    enabled: false,
  );
  expect('eq band message', band.toMessage(), <Object?>[1, 120.0, 3.5, 0.7, 0]);

  // The summary is what the settings UI will show; it must not claim more than the
  // engine reported.
  const LazerStreamInfo pcm = LazerStreamInfo(
    codec: 'flac',
    sourceSampleRate: 44100,
    sourceChannels: 2,
    sourceBitsPerSample: 16,
    sourceFormatKind: lazerAudioSourceFormatPcm,
    sourceDsdRateMultiplier: 0,
    outputSampleRate: 44100,
    outputChannels: 2,
    outputBitsPerSample: 16,
    outputContainerBitsPerSample: 16,
    outputIsFloat: false,
    outputExclusive: true,
    outputFormatInitialized: true,
    outputFormatSelection: lazerAudioFormatSelectionExclusiveSource,
    outputFormatKind: lazerAudioOutputFormatPcm,
    outputDsdRateMultiplier: 0,
    lossless: true,
    bitPerfectActive: true,
    peakMilliDbfs: -1000,
    limiterGainReductionMilliDb: 0,
    clippedSampleCount: 0,
    telemetryValid: false,
  );
  expect('pcm summary', pcm.summary, 'flac 44100 Hz/16-bit → 44100 Hz/16-bit');
  expect('pcm has no DSD source', pcm.hasDsdSource, false);
  expect('pcm is not DoP', pcm.isDoPOutput, false);

  const LazerStreamInfo dsd = LazerStreamInfo(
    codec: 'dsd_lsbf_planar',
    sourceSampleRate: 0,
    sourceChannels: 2,
    sourceBitsPerSample: 0,
    sourceFormatKind: lazerAudioSourceFormatDsd,
    sourceDsdRateMultiplier: 128,
    outputSampleRate: 176400,
    outputChannels: 2,
    outputBitsPerSample: 24,
    outputContainerBitsPerSample: 24,
    outputIsFloat: false,
    outputExclusive: true,
    outputFormatInitialized: true,
    outputFormatSelection: lazerAudioFormatSelectionDoPCarrier,
    outputFormatKind: lazerAudioOutputFormatDoP,
    outputDsdRateMultiplier: 128,
    lossless: true,
    bitPerfectActive: false,
    peakMilliDbfs: 0,
    limiterGainReductionMilliDb: 0,
    clippedSampleCount: 0,
    telemetryValid: false,
  );
  expect('dsd summary', dsd.summary, 'dsd_lsbf_planar DSD128x → DoP @ 176400 Hz');
  expect('dsd has a DSD source', dsd.hasDsdSource, true);
  expect('dsd is DoP', dsd.isDoPOutput, true);
  expect('dsd is not native DSD', dsd.isNativeDsdOutput, false);

  return failures;
}
