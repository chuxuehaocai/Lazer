// The three conditions behind a bit-perfect claim, as separate facts.
//
// The engine used to publish one boolean (`bit_perfect_active`) that it decided
// when the stream was opened. A boolean cannot be checked, only believed: it
// cannot distinguish "the endpoint refused exclusive mode" from "the source was
// resampled" from "the EQ is in the path". So the engine now publishes the three
// facts it derives that boolean from, and this class derives the verdict itself.
//
// Flutter-free on purpose: the same derivation is asserted by `flutter test` and
// by the plain-Dart checks.
import 'lazer_audio_abi.dart';

/// The live output path of one opened stream, and what follows from it.
class OutputPathState {
  const OutputPathState({
    required this.live,
    required this.exclusive,
    required this.dspActive,
    required this.formatMatchesSource,
    required this.actualSampleRate,
    required this.actualBitDepth,
    required this.channels,
    required this.engineReportedBitPerfect,
    required this.isDsdPath,
  });

  /// Reads the facts out of the engine's `LazerAudioStreamInfo`.
  factory OutputPathState.fromNative(LazerAudioStreamInfo info) {
    final bool dsdOutput =
        info.outputFormatKind == lazerAudioOutputFormatDoP ||
        info.outputFormatKind == lazerAudioOutputFormatNativeDsd;
    return OutputPathState(
      live: info.outputFormatInitialized != 0,
      exclusive: info.outputExclusive != 0,
      dspActive: info.outputDspActive != 0,
      formatMatchesSource: info.outputFormatMatchesSource != 0,
      actualSampleRate: info.outputSampleRate,
      actualBitDepth: info.outputBitsPerSample,
      channels: info.outputChannels,
      engineReportedBitPerfect: info.bitPerfectActive != 0,
      isDsdPath: dsdOutput,
    );
  }

  /// Whether the engine had an initialized output session when it answered.
  ///
  /// Everything else is meaningless without it, so [bitPerfect] is false.
  final bool live;

  /// The output session holds the endpoint exclusively.
  final bool exclusive;

  /// The float DSP/volume chain is on the signal path.
  final bool dspActive;

  /// The session runs the source's own sample rate, channel count and depth.
  final bool formatMatchesSource;

  final int actualSampleRate;
  final int actualBitDepth;
  final int channels;

  /// What the engine's own `bit_perfect_active` says, kept for comparison.
  final bool engineReportedBitPerfect;

  /// DoP or Native DSD output: the PCM triple above does not describe it, and
  /// its bit-perfect meaning is defined separately (phase 5).
  final bool isDsdPath;

  /// Bit-perfect requires all three conditions at once.
  ///
  /// For a DoP or Native DSD session [formatMatchesSource] means the carrier (or
  /// the endpoint's DSD word format) carries the decoded bitstream exactly — the
  /// engine refuses to open such a session otherwise — so the same three
  /// conditions decide it. Derived here instead of copied from the engine so a
  /// stale flag cannot light the indicator: the engine's own answer is only
  /// compared against it ([agreesWithEngine]).
  bool get bitPerfect =>
      live && exclusive && !dspActive && formatMatchesSource;

  /// Whether the engine's flag and the three conditions tell the same story.
  ///
  /// A false here is a bug worth surfacing, not a state to paper over.
  bool get agreesWithEngine => engineReportedBitPerfect == bitPerfect;

  /// Why the path is not bit-perfect, in the order the conditions are checked.
  ///
  /// Empty exactly when [bitPerfect] is true.
  List<String> get failingConditions => <String>[
    if (!live) '没有已初始化的输出会话',
    if (live && !exclusive) '输出不是独占',
    if (live && dspActive) 'DSP 在信号路径中',
    if (live && !formatMatchesSource)
      isDsdPath ? 'DoP 载波 / 原生 DSD 字格式与源不一致' : '输出格式与源不一致',
  ];

  /// What a bit-perfect verdict means for this path, for the panel's wording.
  String get bitPerfectMeaning => isDsdPath
      ? 'DSD 位流原样进入 DoP 载波 / 原生 DSD 字'
      : 'PCM 样本原样进入设备';

  /// The format the session actually runs, for the diagnostics panel.
  String get formatLabel => live
      ? '$actualSampleRate Hz/$actualBitDepth-bit/${channels}ch'
      : '未协商';

  @override
  String toString() =>
      'OutputPathState(bitPerfect: $bitPerfect, exclusive: $exclusive, '
      'dsp: $dspActive, formatMatches: $formatMatchesSource)';
}
