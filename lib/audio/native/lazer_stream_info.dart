// The negotiated source/output format of one opened stream.
//
// Kept in its own file, free of Flutter imports, so the format description and its
// message shapes can be checked with plain Dart (`tool/native_engine_check.dart`)
// on hosts where the Flutter toolchain or the engine binary is unavailable.
import 'lazer_audio_abi.dart';

/// Source and output format of one opened stream.
///
/// This is what the engine negotiated *with the platform*; it is not a readback
/// from the DAC and says nothing about resampling inside the OS mixer.
class LazerStreamInfo {
  const LazerStreamInfo({
    required this.codec,
    required this.sourceSampleRate,
    required this.sourceChannels,
    required this.sourceBitsPerSample,
    required this.sourceFormatKind,
    required this.sourceDsdRateMultiplier,
    required this.outputSampleRate,
    required this.outputChannels,
    required this.outputBitsPerSample,
    required this.outputContainerBitsPerSample,
    required this.outputIsFloat,
    required this.outputExclusive,
    required this.outputFormatInitialized,
    required this.outputFormatSelection,
    required this.outputFormatKind,
    required this.outputDsdRateMultiplier,
    required this.lossless,
    required this.bitPerfectActive,
    required this.peakMilliDbfs,
    required this.limiterGainReductionMilliDb,
    required this.clippedSampleCount,
    required this.telemetryValid,
  });

  final String codec;
  final int sourceSampleRate;
  final int sourceChannels;
  final int sourceBitsPerSample;
  final int sourceFormatKind;
  final int sourceDsdRateMultiplier;
  final int outputSampleRate;
  final int outputChannels;
  final int outputBitsPerSample;
  final int outputContainerBitsPerSample;
  final bool outputIsFloat;
  final bool outputExclusive;
  final bool outputFormatInitialized;
  final int outputFormatSelection;
  final int outputFormatKind;
  final int outputDsdRateMultiplier;
  final bool lossless;
  final bool bitPerfectActive;
  final int peakMilliDbfs;
  final int limiterGainReductionMilliDb;
  final int clippedSampleCount;
  final bool telemetryValid;

  /// Whether the source is DSD, whether it is output directly or converted.
  bool get hasDsdSource =>
      sourceFormatKind == lazerAudioSourceFormatDsd ||
      sourceDsdRateMultiplier > 0;

  bool get isDoPOutput => outputFormatKind == lazerAudioOutputFormatDoP;

  bool get isNativeDsdOutput =>
      outputFormatKind == lazerAudioOutputFormatNativeDsd;

  /// Reads the negotiated format out of the engine's `LazerAudioStreamInfo`.
  factory LazerStreamInfo.fromNative(LazerAudioStreamInfo info) =>
      LazerStreamInfo(
    codec: lazerCodecName(info),
    sourceSampleRate: info.sourceSampleRate,
    sourceChannels: info.sourceChannels,
    sourceBitsPerSample: info.sourceBitsPerSample,
    sourceFormatKind: info.sourceFormatKind,
    sourceDsdRateMultiplier: info.sourceDsdRateMultiplier,
    outputSampleRate: info.outputSampleRate,
    outputChannels: info.outputChannels,
    outputBitsPerSample: info.outputBitsPerSample,
    outputContainerBitsPerSample: info.outputContainerBitsPerSample,
    outputIsFloat: info.outputIsFloat != 0,
    outputExclusive: info.outputExclusive != 0,
    outputFormatInitialized: info.outputFormatInitialized != 0,
    outputFormatSelection: info.outputFormatSelection,
    outputFormatKind: info.outputFormatKind,
    outputDsdRateMultiplier: info.outputDsdRateMultiplier,
    lossless: info.lossless != 0,
    bitPerfectActive: info.bitPerfectActive != 0,
    peakMilliDbfs: info.outputPeakMillidbfs,
    limiterGainReductionMilliDb: info.limiterGainReductionMillidb,
    clippedSampleCount: info.outputClippedSampleCount,
    telemetryValid: info.outputTelemetryValid != 0,
  );

  /// One-line summary for diagnostics: `flac 44100 Hz/16-bit → 44100 Hz/16-bit`.
  String get summary {
    final String source = hasDsdSource
        ? 'DSD${sourceDsdRateMultiplier}x'
        : '$sourceSampleRate Hz/$sourceBitsPerSample-bit';
    final String output = switch (outputFormatKind) {
      lazerAudioOutputFormatDoP => 'DoP @ $outputSampleRate Hz',
      lazerAudioOutputFormatNativeDsd => 'Native DSD${outputDsdRateMultiplier}x',
      _ => '$outputSampleRate Hz/$outputBitsPerSample-bit',
    };
    return '$codec $source → $output';
  }

  @override
  String toString() => 'LazerStreamInfo($summary)';
}
