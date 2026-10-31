// Live output-side counters, read from the engine's snapshot.
//
// These are the numbers the HiFi work has to be able to point at: how full the
// lock-free output ring is (is the decoder keeping up, or is the device about to
// starve?) and how much padding the device has already been fed because a source
// had not delivered frames yet. Flutter-free so the plain-Dart checks can assert
// the derivation.
import 'lazer_audio_abi.dart';

/// Ring occupancy and starvation accounting for the current session.
class LazerEngineMetrics {
  const LazerEngineMetrics({
    required this.ringFillFrames,
    required this.ringCapacityFrames,
    required this.underrunActive,
    required this.underrunFrames,
    this.ringLowWatermarkFrames = 0,
    this.ringHighWatermarkFrames = 0,
  });

  factory LazerEngineMetrics.fromNative(LazerAudioSnapshot snapshot) =>
      LazerEngineMetrics(
        ringFillFrames: snapshot.ringFillFrames,
        ringCapacityFrames: snapshot.ringCapacityFrames,
        underrunActive: snapshot.underrunActive != 0,
        underrunFrames: snapshot.underrunFrames,
        ringLowWatermarkFrames: snapshot.ringLowWatermarkFrames,
        ringHighWatermarkFrames: snapshot.ringHighWatermarkFrames,
      );

  /// Whole frames waiting in the ring; producer is the decode/DSP thread.
  final int ringFillFrames;

  /// Ring size in frames; zero before the first stream is configured.
  final int ringCapacityFrames;

  /// The producer stops feeding at [ringHighWatermarkFrames] and resumes at
  /// [ringLowWatermarkFrames] (or as soon as a track seam is in flight). Zero
  /// while no stream is configured.
  final int ringLowWatermarkFrames;
  final int ringHighWatermarkFrames;

  /// True while the last submitted output contained starvation padding.
  final bool underrunActive;

  /// Cumulative padded frames, excluding the clean-EOF tail and queue waits.
  final int underrunFrames;

  /// Whether the producer is currently held back by the high watermark.
  bool get producerPaused => ringHighWatermarkFrames > 0 &&
      ringFillFrames >= ringHighWatermarkFrames;

  /// How full the ring is, 0..1. Zero when no stream is configured.
  double get ringFillFraction => ringCapacityFrames <= 0
      ? 0
      : (ringFillFrames / ringCapacityFrames).clamp(0, 1).toDouble();

  /// Milliseconds of audio currently buffered ahead of the device, when the
  /// sample rate is known; null otherwise.
  int? ringFillMillis(int sampleRate) => sampleRate <= 0
      ? null
      : (ringFillFrames * 1000 / sampleRate).round();

  /// One line for the log and the diagnostics panel.
  String get summary {
    if (ringCapacityFrames <= 0) return '输出缓冲未配置';
    final int percent = (ringFillFraction * 100).round();
    final String marks = ringHighWatermarkFrames <= 0
        ? ''
        : ' · 水位 $ringLowWatermarkFrames/$ringHighWatermarkFrames';
    return '$ringFillFrames/$ringCapacityFrames 帧（$percent%）$marks'
        '${producerPaused ? ' · 已到高水位暂停喂入' : ''}'
        '${underrunActive ? ' · 欠载中' : ''}'
        '${underrunFrames == 0 ? '' : ' · 累计欠载 $underrunFrames 帧'}';
  }

  @override
  String toString() => 'LazerEngineMetrics($summary)';
}
