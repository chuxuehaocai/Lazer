// Phase 2: bit-perfect is derived from three facts, not copied from a flag.
//
// The acceptance rule is "the indicator lights only when exclusive + no DSP +
// format matches, and names the failing condition otherwise", so that is what
// these tests assert — including the case where the engine's own flag disagrees
// with the facts, which must be visible rather than papered over.
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/native/engine_metrics.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_abi.dart';
import 'package:lazer_nextgen/audio/native/lazer_stream_info.dart';
import 'package:lazer_nextgen/audio/native/output_path_state.dart';
import 'package:lazer_nextgen/state/hifi_settings.dart';
import 'package:lazer_nextgen/widgets/hifi_settings_section.dart';

LazerStreamInfo info({
  bool live = true,
  bool exclusive = true,
  bool dspActive = false,
  bool formatMatchesSource = true,
  bool engineReportsBitPerfect = true,
  int outputFormatKind = lazerAudioOutputFormatPcm,
  int outputSampleRate = 44100,
  int outputBitsPerSample = 16,
  int outputChannels = 2,
  bool telemetryValid = false,
}) => LazerStreamInfo(
  codec: 'flac',
  sourceSampleRate: 44100,
  sourceChannels: 2,
  sourceBitsPerSample: 16,
  sourceFormatKind: lazerAudioSourceFormatPcm,
  sourceDsdRateMultiplier: 0,
  outputSampleRate: outputSampleRate,
  outputChannels: outputChannels,
  outputBitsPerSample: outputBitsPerSample,
  outputContainerBitsPerSample: outputBitsPerSample,
  outputIsFloat: false,
  outputExclusive: exclusive,
  outputFormatInitialized: live,
  outputFormatSelection: lazerAudioFormatSelectionExclusiveSource,
  outputFormatKind: outputFormatKind,
  outputDsdRateMultiplier: 0,
  lossless: true,
  bitPerfectActive: engineReportsBitPerfect,
  dspActive: dspActive,
  formatMatchesSource: formatMatchesSource,
  peakMilliDbfs: -1000,
  limiterGainReductionMilliDb: 0,
  clippedSampleCount: 0,
  telemetryValid: telemetryValid,
);

String rowValue(List<SignalPathReadout> rows, String label) =>
    rows.firstWhere((SignalPathReadout row) => row.label == label).value;

void main() {
  group('OutputPathState', () {
    test('is bit-perfect only when all three conditions hold', () {
      final OutputPathState state = info().outputPath;

      expect(state.exclusive, isTrue);
      expect(state.dspActive, isFalse);
      expect(state.formatMatchesSource, isTrue);
      expect(state.bitPerfect, isTrue);
      expect(state.agreesWithEngine, isTrue);
      expect(state.failingConditions, isEmpty);
    });

    test('loses bit-perfect when the session is not exclusive', () {
      final OutputPathState state = info(exclusive: false).outputPath;

      expect(state.bitPerfect, isFalse);
      expect(state.failingConditions, contains('输出不是独占'));
    });

    test('loses bit-perfect when the DSP is in the path', () {
      final OutputPathState state = info(dspActive: true).outputPath;

      expect(state.bitPerfect, isFalse);
      expect(state.failingConditions, contains('DSP 在信号路径中'));
    });

    test('loses bit-perfect when the output format is not the source\'s', () {
      final OutputPathState state = info(
        formatMatchesSource: false,
        outputSampleRate: 48000,
      ).outputPath;

      expect(state.bitPerfect, isFalse);
      expect(state.failingConditions, contains('输出格式与源不一致'));
      expect(state.formatLabel, '48000 Hz/16-bit/2ch');
    });

    test('a session with no live output session is never bit-perfect', () {
      final OutputPathState state = info(live: false).outputPath;

      expect(state.bitPerfect, isFalse);
      expect(state.failingConditions, contains('没有已初始化的输出会话'));
    });

    test('a DSD path reports that its bit-perfect meaning is undefined', () {
      final OutputPathState state = info(
        outputFormatKind: lazerAudioOutputFormatDoP,
        engineReportsBitPerfect: false,
      ).outputPath;

      expect(state.isDsdPath, isTrue);
      expect(state.bitPerfect, isFalse);
      expect(
        state.failingConditions,
        contains('DSD 路径的 bit-perfect 语义尚未定义'),
      );
    });

    test('a stale engine flag is visible instead of believed', () {
      // The engine says bit-perfect while the DSP is demonstrably in the path:
      // the derivation must win and the disagreement must be observable.
      final OutputPathState state = info(dspActive: true).outputPath;

      expect(state.engineReportedBitPerfect, isTrue);
      expect(state.bitPerfect, isFalse);
      expect(state.agreesWithEngine, isFalse);
    });

    test('reads the facts out of the native struct', () {
      final Pointer<LazerAudioStreamInfo> native = calloc<LazerAudioStreamInfo>();
      addTearDown(() => calloc.free(native));
      native.ref
        ..outputFormatInitialized = 1
        ..outputExclusive = 1
        ..outputDspActive = 1
        ..outputFormatMatchesSource = 1
        ..outputSampleRate = 96000
        ..outputBitsPerSample = 24
        ..outputChannels = 2
        ..bitPerfectActive = 0
        ..outputFormatKind = lazerAudioOutputFormatPcm;

      final OutputPathState state = OutputPathState.fromNative(native.ref);

      expect(state.exclusive, isTrue);
      expect(state.dspActive, isTrue);
      expect(state.formatMatchesSource, isTrue);
      expect(state.bitPerfect, isFalse);
      expect(state.actualSampleRate, 96000);
      expect(state.actualBitDepth, 24);
      expect(state.channels, 2);
      expect(state.agreesWithEngine, isTrue);
    });
  });

  group('LazerEngineMetrics', () {
    test('reports ring occupancy and underruns from the snapshot', () {
      final Pointer<LazerAudioSnapshot> native = calloc<LazerAudioSnapshot>();
      addTearDown(() => calloc.free(native));
      native.ref
        ..ringFillFrames = 4096
        ..ringCapacityFrames = 16384
        ..ringLowWatermarkFrames = 4096
        ..ringHighWatermarkFrames = 16384
        ..underrunActive = 1
        ..underrunFrames = 512;

      final LazerEngineMetrics metrics = LazerEngineMetrics.fromNative(native.ref);

      expect(metrics.ringFillFraction, closeTo(0.25, 0.0001));
      expect(metrics.ringFillMillis(44100), 93);
      expect(metrics.underrunActive, isTrue);
      expect(metrics.underrunFrames, 512);
      expect(metrics.producerPaused, isFalse);
      expect(metrics.summary, contains('4096/16384'));
      expect(metrics.summary, contains('水位 4096/16384'));
      expect(metrics.summary, contains('欠载中'));
      expect(metrics.summary, contains('累计欠载 512 帧'));
    });

    test('reports the producer as held back at the high watermark', () {
      const LazerEngineMetrics metrics = LazerEngineMetrics(
        ringFillFrames: 16384,
        ringCapacityFrames: 16384,
        ringLowWatermarkFrames: 4096,
        ringHighWatermarkFrames: 16384,
        underrunActive: false,
        underrunFrames: 0,
      );

      expect(metrics.producerPaused, isTrue);
      expect(metrics.summary, contains('已到高水位暂停喂入'));
    });

    test('an unconfigured ring reports zero instead of dividing by zero', () {
      final Pointer<LazerAudioSnapshot> native = calloc<LazerAudioSnapshot>();
      addTearDown(() => calloc.free(native));

      final LazerEngineMetrics metrics = LazerEngineMetrics.fromNative(native.ref);

      expect(metrics.ringFillFraction, 0);
      expect(metrics.ringFillMillis(44100), 0);
      expect(metrics.summary, '输出缓冲未配置');
    });
  });

  group('the 信号路径 panel', () {
    test('lights bit-perfect only for exclusive + no DSP + format match', () {
      final List<SignalPathReadout> rows = signalPathReadouts(
        info: info(),
        metrics: null,
      );

      expect(rowValue(rows, 'Bit-perfect'), '是（独占 · 无 DSP · 格式一致）');
      expect(rowValue(rows, '独占'), '是');
      expect(rowValue(rows, 'DSP'), '不在信号路径中');
      expect(rowValue(rows, '格式与源一致'), '是');
    });

    test('goes dark and names the DSP when a module is in the path', () {
      final List<SignalPathReadout> rows = signalPathReadouts(
        info: info(dspActive: true),
        metrics: null,
      );

      expect(rowValue(rows, 'Bit-perfect'), '否（DSP 在信号路径中）');
      expect(rowValue(rows, 'DSP'), '在信号路径中');
    });

    test('goes dark and names the format when the session resampled', () {
      final List<SignalPathReadout> rows = signalPathReadouts(
        info: info(formatMatchesSource: false, outputSampleRate: 48000),
        metrics: null,
      );

      expect(rowValue(rows, 'Bit-perfect'), '否（输出格式与源不一致）');
      expect(rowValue(rows, '格式与源一致'), '否');
    });

    test('shows the ring and underrun counters', () {
      final List<SignalPathReadout> rows = signalPathReadouts(
        info: info(),
        metrics: const LazerEngineMetrics(
          ringFillFrames: 2048,
          ringCapacityFrames: 8192,
          underrunActive: false,
          underrunFrames: 0,
        ),
      );

      expect(rowValue(rows, '输出缓冲'), contains('2048/8192'));
    });

    test('says nothing was negotiated before a stream is opened', () {
      final List<SignalPathReadout> rows = signalPathReadouts(
        info: null,
        metrics: null,
      );

      expect(rowValue(rows, 'Bit-perfect'), '—');
      expect(rowValue(rows, '解码格式'), '未播放');
    });
  });

  group('the settings layer holds DSP back while bit-perfect is on', () {
    const HifiSettings withDsp = HifiSettings(
      equalizer: HifiEqualizerState(
        enabled: true,
        preampDb: 3,
        limiterEnabled: true,
        bands: <HifiEqBand>[HifiEqBand(frequencyHz: 1000, gainDb: 4)],
      ),
    );

    test('bit-perfect sends a neutral request, not one the engine must refuse', () {
      final LazerDspRequest request = withDsp
          .copyWith(bitPerfect: true, exclusiveMode: true)
          .toDspRequest();

      expect(request.preampDb, 0);
      expect(request.limiterEnabled, isFalse);
      expect(request.bands, isEmpty);
      expect(request.crossfeedEnabled, isFalse);
    });

    test('the same settings reach the engine once bit-perfect is off', () {
      final LazerDspRequest request = withDsp.toDspRequest();

      expect(request.preampDb, 3);
      expect(request.limiterEnabled, isTrue);
      expect(request.bands, isNotEmpty);
    });

    test('the page can say the DSP is bypassed rather than applied', () {
      expect(
        withDsp.copyWith(bitPerfect: true).dspBypassedByBitPerfect,
        isTrue,
      );
      expect(withDsp.dspBypassedByBitPerfect, isFalse);
    });
  });


  group('the explicit DSP chain', () {
    test('defaults to the engine order and round-trips through persistence', () {
      expect(decodeDspStageOrder(null), defaultDspStageOrder);

      const HifiSettings custom = HifiSettings(dspStageOrder: <int>[3, 1]);
      final HifiSettings restored = HifiSettings.fromMap(custom.toMap());

      expect(restored.dspStageOrder, <int>[3, 1]);
      expect(restored.toDspRequest().stageOrder, <int>[3, 1]);
    });

    test('drops unknown stages instead of silently reordering', () {
      expect(decodeDspStageOrder('9,1,x'), <int>[1]);
      expect(decodeDspStageOrder('nonsense'), defaultDspStageOrder);
      expect(decodeDspStageOrder(''), defaultDspStageOrder);
    });

    test('the order survives bit-perfect while the processing does not', () {
      const HifiSettings reordered = HifiSettings(
        dspStageOrder: <int>[1, 3],
        equalizer: HifiEqualizerState(
          enabled: true,
          preampDb: 4,
          bands: <HifiEqBand>[HifiEqBand(frequencyHz: 1000, gainDb: 4)],
        ),
      );

      final LazerDspRequest withBitPerfect = reordered
          .copyWith(bitPerfect: true)
          .toDspRequest();

      // The engine refuses processing during a bit-perfect session, so the
      // settings layer neutralises it; the chain it would apply afterwards is
      // still the one the user ordered.
      expect(withBitPerfect.preampDb, 0);
      expect(withBitPerfect.bands, isEmpty);
      expect(withBitPerfect.stageOrder, <int>[1, 3]);
    });


    test('every preset is a legal chain and survives the encoder', () {
      for (final MapEntry<String, List<int>> preset in kDspChainPresets.entries) {
        for (final int stage in preset.value) {
          expect(stage, inInclusiveRange(0, 4), reason: preset.key);
        }
        expect(
          decodeDspStageOrder(encodeDspStageOrder(preset.value)),
          preset.value,
          reason: preset.key,
        );
      }
      // The first preset must be the engine's own order, or a fresh profile would
      // silently ask for something else.
      expect(kDspChainPresets.values.first, defaultDspStageOrder);
    });

    test('the summary names the chain the page is asking for', () {
      expect(
        const HifiSettings(dspStageOrder: <int>[0, 1, 2, 3, 4]).dspChainSummary,
        '前级 → EQ → 串扰 → 限幅 → 音量',
      );
      expect(
        const HifiSettings(dspStageOrder: <int>[0, 3, 1]).dspChainSummary,
        '前级 → 限幅 → EQ',
      );
    });
  });
}
