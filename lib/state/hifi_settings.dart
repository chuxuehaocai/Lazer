// HiFi output settings, ported from the master branch's shared `LazerEqualizer`
// and `HiFiAudioModels`.
//
// The semantics are deliberately identical to master, including the hand-rolled
// one-line encodings: those strings are short, forward-compatible, and a malformed
// value falls back to a flat curve instead of throwing — which matters because they
// are read at start-up.
//
// Flutter-free so `tool/native/hifi_checks.dart` can exercise the parsing and the
// presets with plain Dart.
library;

/// Shape of one equaliser band; the names mirror the engine's band kinds, so no
/// second mapping table is needed.
enum HifiEqBandKind {
  peak,
  lowShelf,
  highShelf,
  lowPass,
  highPass,
  notch,
  allPass;

  /// Parses both this branch's `lowShelf` and the master branch's Kotlin enum name
  /// `LowShelf`, because the encoded preference string is shared between them.
  static HifiEqBandKind parse(String? name) {
    if (name == null || name.isEmpty) return HifiEqBandKind.peak;
    final String normalised = name.toLowerCase();
    return HifiEqBandKind.values.firstWhere(
      (HifiEqBandKind kind) => kind.name.toLowerCase() == normalised,
      orElse: () => HifiEqBandKind.peak,
    );
  }
}

/// The ten ISO octave centres every preset below is written against.
const List<double> hifiEqBandFrequencies = <double>[
  31,
  62,
  125,
  250,
  500,
  1000,
  2000,
  4000,
  8000,
  16000,
];

const double kMinHifiEqGainDb = -12;
const double kMaxHifiEqGainDb = 12;
const double kMinHifiPreampDb = -12;
const double kMaxHifiPreampDb = 12;

double clampHifiEqGainDb(double value) =>
    value.clamp(kMinHifiEqGainDb, kMaxHifiEqGainDb);

double clampHifiPreampDb(double value) =>
    value.clamp(kMinHifiPreampDb, kMaxHifiPreampDb);

/// One band: centre (or corner) frequency, boost/cut, bandwidth and shape.
///
/// A band the listener disabled stays in the list so its slider keeps its place.
class HifiEqBand {
  const HifiEqBand({
    required this.frequencyHz,
    this.gainDb = 0,
    this.q = 1,
    this.kind = HifiEqBandKind.peak,
    this.enabled = true,
  });

  final double frequencyHz;
  final double gainDb;
  final double q;
  final HifiEqBandKind kind;
  final bool enabled;

  HifiEqBand copyWith({double? gainDb, bool? enabled, HifiEqBandKind? kind}) =>
      HifiEqBand(
        frequencyHz: frequencyHz,
        gainDb: gainDb ?? this.gainDb,
        q: q,
        kind: kind ?? this.kind,
        enabled: enabled ?? this.enabled,
      );

  /// `frequency:gain:q:kind:enabled`
  String encode() =>
      '$frequencyHz:$gainDb:$q:${kind.name}:${enabled ? 1 : 0}';

  static HifiEqBand? decode(String entry) {
    final List<String> fields = entry.split(':');
    if (fields.length < 5) return null;
    final double? frequency = double.tryParse(fields[0]);
    if (frequency == null) return null;
    return HifiEqBand(
      frequencyHz: frequency,
      gainDb: clampHifiEqGainDb(double.tryParse(fields[1]) ?? 0),
      q: (double.tryParse(fields[2]) ?? 1).clamp(0.1, 10),
      kind: HifiEqBandKind.parse(fields[3]),
      enabled: fields[4] == '1',
    );
  }
}

/// Edge bands are shelves and the rest peaks — the layout a listener expects.
List<HifiEqBand> defaultHifiEqBands() => <HifiEqBand>[
  for (int index = 0; index < hifiEqBandFrequencies.length; index++)
    HifiEqBand(
      frequencyHz: hifiEqBandFrequencies[index],
      kind: switch (index) {
        0 => HifiEqBandKind.lowShelf,
        _ when index == hifiEqBandFrequencies.length - 1 =>
          HifiEqBandKind.highShelf,
        _ => HifiEqBandKind.peak,
      },
    ),
];

/// A named set of gains indexed against [hifiEqBandFrequencies].
class HifiEqPreset {
  const HifiEqPreset(this.id, this.label, this.gainsDb, {this.preampDb = 0});

  final String id;

  /// Chinese source string, translated through `context.tr`.
  final String label;

  final List<double> gainsDb;
  final double preampDb;
}

/// Ported verbatim from `LazerEqualizerPresets` on master so a preset means the
/// same curve on both branches.
const List<HifiEqPreset> hifiEqPresets = <HifiEqPreset>[
  HifiEqPreset('flat', '平直', <double>[0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
  HifiEqPreset(
    'pop',
    '流行',
    <double>[-1, -0.5, 0, 2, 3.5, 3, 1, -0.5, -1, -1.5],
    preampDb: -1,
  ),
  HifiEqPreset(
    'rock',
    '摇滚',
    <double>[4, 3, 1, -1, -1.5, 0.5, 2.5, 3.5, 3, 2.5],
    preampDb: -2,
  ),
  HifiEqPreset(
    'classical',
    '古典',
    <double>[3, 2.5, 1.5, 0.5, -0.5, -0.5, 0, 1.5, 2.5, 3],
    preampDb: -1.5,
  ),
  HifiEqPreset(
    'jazz',
    '爵士',
    <double>[3, 2, 0.5, 1, -0.5, -0.5, 0.5, 1.5, 2, 2.5],
    preampDb: -1.5,
  ),
  HifiEqPreset(
    'bass',
    '低音增强',
    <double>[7, 6, 4.5, 2.5, 0.5, -0.5, -1, -1.5, -2, -2.5],
    preampDb: -3,
  ),
  HifiEqPreset(
    'vocal',
    '人声',
    <double>[-2, -1.5, -0.5, 1, 3, 3.5, 2.5, 1, -0.5, -1.5],
    preampDb: -2,
  ),
  HifiEqPreset(
    'treble',
    '高音增强',
    <double>[-2.5, -2, -1.5, -1, -0.5, 0.5, 2, 3.5, 5, 6],
    preampDb: -2.5,
  ),
];

/// How DSD sources are handed to the device.
///
/// The engine only knows the three explicit policies; [auto] is this layer's
/// fallback chain (Native → DoP → PCM), implemented by retrying the open when the
/// device refuses the more direct transport. Ported from the Twilight Echo HiFi
/// settings (`DSD_OUTPUT_MODE_OPTIONS`, Apache-2.0), whose engine entry point has
/// the same three explicit modes.
enum HifiDsdOutputMode {
  /// Try Native, then DoP, then PCM, and use the first the device accepts.
  auto('自动'),

  /// Decode DSD to PCM. Works on every endpoint.
  convertToPcm('转 PCM'),

  /// Require an exact 24-bit DoP carrier. No fallback: a device that cannot take it
  /// fails instead of silently receiving converted PCM.
  requireDoP('DoP'),

  /// Require ALSA Native DSD (Linux `hw:` only).
  requireNative('原生 DSD');

  const HifiDsdOutputMode(this.label);

  final String label;

  /// The engine's `LazerAudioDsdOutputMode` value (0 PCM, 1 DoP, 2 Native).
  int get nativeValue => switch (this) {
    HifiDsdOutputMode.convertToPcm => 0,
    HifiDsdOutputMode.requireDoP => 1,
    HifiDsdOutputMode.requireNative => 2,
    // `auto` is resolved before the value reaches the engine.
    HifiDsdOutputMode.auto => 0,
  };

  /// The order [auto] tries; empty for the explicit policies.
  List<HifiDsdOutputMode> get fallbackChain => switch (this) {
    HifiDsdOutputMode.auto => <HifiDsdOutputMode>[
      HifiDsdOutputMode.requireNative,
      HifiDsdOutputMode.requireDoP,
      HifiDsdOutputMode.convertToPcm,
    ],
    _ => <HifiDsdOutputMode>[this],
  };

  static HifiDsdOutputMode parse(String? name) =>
      HifiDsdOutputMode.values.firstWhere(
        (HifiDsdOutputMode mode) => mode.name == name,
        orElse: () => HifiDsdOutputMode.auto,
      );
}

/// What to do when a DSD source's rate multiplier is not available on the device.
///
/// [exact] and [downrate] need engine support this port does not have (the vendored
/// engine has no DSD-domain downrate stage), so the settings layer reports them as
/// unavailable instead of silently behaving like [pcmFallback].
enum HifiDsdRatePolicy {
  pcmFallback('PCM 回退', 'Native → DoP → PCM 逐级回退'),
  exact('精确倍率', '只允许源倍率，不可用时报错'),
  downrate('DSD 降频', '在 DSD 域降采样到较低倍率');

  const HifiDsdRatePolicy(this.label, this.detail);

  final String label;
  final String detail;

  /// Whether the vendored engine can enforce this policy.
  bool get isSupported => this == HifiDsdRatePolicy.pcmFallback;

  static HifiDsdRatePolicy parse(String? name) =>
      HifiDsdRatePolicy.values.firstWhere(
        (HifiDsdRatePolicy policy) => policy.name == name,
        orElse: () => HifiDsdRatePolicy.pcmFallback,
      );
}

/// Volume normalisation mode, ported from Twilight Echo's
/// `VolumeNormalizationMode` (`off | track | album | loudnorm`).
///
/// [track] and [album] use the source's ReplayGain tags, which this app can read
/// from local files; [loudnorm] needs an EBU R128 measurement pass that the vendored
/// engine does not implement, so it is offered but reported as unavailable.
enum HifiVolumeNormalization {
  off('关闭', '不施加响度增益'),
  track('单曲响度', '使用源标签的 ReplayGain / R128 单曲增益'),
  album('专辑响度', '使用源标签的 ReplayGain / R128 专辑增益'),
  loudnorm('响度归一', '按 EBU R128 目标测量并归一（本引擎未实现测量）');

  const HifiVolumeNormalization(this.label, this.detail);

  final String label;
  final String detail;

  /// Whether the native engine can perform this mode.
  bool get isSupported => this != HifiVolumeNormalization.loudnorm;

  /// Whether the mode needs a per-source gain from metadata.
  bool get needsSourceGain => this == HifiVolumeNormalization.track ||
      this == HifiVolumeNormalization.album;

  static HifiVolumeNormalization parse(String? name) =>
      HifiVolumeNormalization.values.firstWhere(
        (HifiVolumeNormalization mode) => mode.name == name,
        orElse: () => HifiVolumeNormalization.off,
      );
}

/// Cross-channel feed for headphone listening (`crossfeed_*` in the DSP config).
///
/// Ported from Twilight Echo's crossfeed settings; the algorithms and their fixed
/// delay/cutoff pairs come from its `CrossfeedProcessor`.
enum HifiCrossfeedAlgorithm {
  custom('自定义', 0.22, 700),
  bauer('Bauer', 0.22, 700),
  bs2b('BS2B', 0.22, 700),
  meier('Meier', 0.35, 650);

  const HifiCrossfeedAlgorithm(this.label, this.delayMs, this.cutoffHz);

  final String label;

  /// The delay this algorithm uses; only [custom] honours the user's value.
  final double delayMs;

  /// The cutoff this algorithm uses; only [custom] honours the user's value.
  final double cutoffHz;

  /// The engine's `crossfeed_algorithm` value.
  int get nativeValue => index;

  static HifiCrossfeedAlgorithm parse(String? name) =>
      HifiCrossfeedAlgorithm.values.firstWhere(
        (HifiCrossfeedAlgorithm algorithm) => algorithm.name == name,
        orElse: () => HifiCrossfeedAlgorithm.custom,
      );
}

/// The crossfeed stage's settings.
class HifiCrossfeedState {
  const HifiCrossfeedState({
    this.enabled = false,
    this.strength = 0.3,
    this.algorithm = HifiCrossfeedAlgorithm.custom,
    this.delayMs = 0.22,
    this.cutoffHz = 700,
  });

  final bool enabled;

  /// 0..1; below 0.0001 the engine treats it as off.
  final double strength;

  final HifiCrossfeedAlgorithm algorithm;
  final double delayMs;
  final double cutoffHz;

  /// The delay/cutoff actually used, following the algorithm.
  double get effectiveDelayMs =>
      algorithm == HifiCrossfeedAlgorithm.custom ? delayMs : algorithm.delayMs;

  double get effectiveCutoffHz =>
      algorithm == HifiCrossfeedAlgorithm.custom ? cutoffHz : algorithm.cutoffHz;

  HifiCrossfeedState copyWith({
    bool? enabled,
    double? strength,
    HifiCrossfeedAlgorithm? algorithm,
    double? delayMs,
    double? cutoffHz,
  }) => HifiCrossfeedState(
    enabled: enabled ?? this.enabled,
    strength: strength ?? this.strength,
    algorithm: algorithm ?? this.algorithm,
    delayMs: delayMs ?? this.delayMs,
    cutoffHz: cutoffHz ?? this.cutoffHz,
  );

  /// Crossfeed mixes into the neighbouring channel, so it is processing too.
  bool get altersSignal => enabled && strength > 0.0001;

  String encode() =>
      '${enabled ? 1 : 0}|$strength|${algorithm.name}|$delayMs|$cutoffHz';

  static HifiCrossfeedState decode(String? value) {
    if (value == null || value.trim().isEmpty) return const HifiCrossfeedState();
    final List<String> parts = value.split('|');
    if (parts.length < 5) return const HifiCrossfeedState();
    return HifiCrossfeedState(
      enabled: parts[0] == '1',
      strength: (double.tryParse(parts[1]) ?? 0.3).clamp(0, 1),
      algorithm: HifiCrossfeedAlgorithm.parse(parts[2]),
      delayMs: (double.tryParse(parts[3]) ?? 0.22).clamp(0.05, 2),
      cutoffHz: (double.tryParse(parts[4]) ?? 700).clamp(80, 4000),
    );
  }
}

/// Buffer depth offered in Settings; the engine default is 120 ms.
enum HifiBufferSize {
  small(120, '低延迟'),
  medium(240, '均衡'),
  large(480, '稳定');

  const HifiBufferSize(this.millis, this.label);

  final int millis;
  final String label;

  static HifiBufferSize parse(int? millis) => HifiBufferSize.values.firstWhere(
    (HifiBufferSize size) => size.millis == millis,
    orElse: () => HifiBufferSize.small,
  );
}

/// The whole equaliser state: on/off, preamp, limiter and bands.
///
/// `limiterEnabled` defaults to true, matching master: it is the sample-peak guard
/// that keeps an EQ boost from clipping, so switching the EQ on does not require a
/// second decision.
class HifiEqualizerState {
  const HifiEqualizerState({
    this.enabled = false,
    this.preampDb = 0,
    this.limiterEnabled = true,
    this.limiterThresholdDb = -1,
    this.bands = const <HifiEqBand>[],
  });

  final bool enabled;
  final double preampDb;
  final bool limiterEnabled;

  /// Sample-peak ceiling in dBFS (master used −1 dBFS).
  final double limiterThresholdDb;

  final List<HifiEqBand> bands;

  List<HifiEqBand> get effectiveBands =>
      bands.isEmpty ? defaultHifiEqBands() : bands;

  HifiEqualizerState copyWith({
    bool? enabled,
    double? preampDb,
    bool? limiterEnabled,
    double? limiterThresholdDb,
    List<HifiEqBand>? bands,
  }) => HifiEqualizerState(
    enabled: enabled ?? this.enabled,
    preampDb: preampDb ?? this.preampDb,
    limiterEnabled: limiterEnabled ?? this.limiterEnabled,
    limiterThresholdDb: limiterThresholdDb ?? this.limiterThresholdDb,
    bands: bands ?? this.bands,
  );

  /// `enabled|preamp|limiter|bands` — master's encoding, so a value written by
  /// the other branch still parses.
  String encode() {
    final StringBuffer buffer = StringBuffer()
      ..write(enabled ? '1' : '0')
      ..write('|')
      ..write(preampDb)
      ..write('|')
      ..write(limiterEnabled ? '1' : '0')
      ..write('|');
    final List<HifiEqBand> list = effectiveBands;
    for (int index = 0; index < list.length; index++) {
      if (index > 0) buffer.write(';');
      buffer.write(list[index].encode());
    }
    return buffer.toString();
  }

  static HifiEqualizerState decode(String? value) {
    if (value == null || value.trim().isEmpty) return const HifiEqualizerState();
    final List<String> parts = value.split('|');
    if (parts.length < 4) return const HifiEqualizerState();
    final List<HifiEqBand> bands = <HifiEqBand>[];
    for (final String entry in parts[3].split(';')) {
      final HifiEqBand? band = HifiEqBand.decode(entry);
      if (band != null) bands.add(band);
    }
    if (bands.isEmpty) return const HifiEqualizerState();
    return HifiEqualizerState(
      enabled: parts[0] == '1',
      preampDb: clampHifiPreampDb(double.tryParse(parts[1]) ?? 0),
      limiterEnabled: parts[2] != '0',
      bands: bands,
    );
  }

  /// The preset whose gains match these bands, or null for a custom curve.
  String? get matchingPresetId {
    final List<HifiEqBand> list = effectiveBands;
    for (final HifiEqPreset preset in hifiEqPresets) {
      if (preset.gainsDb.length != list.length) continue;
      bool same = true;
      for (int index = 0; index < list.length; index++) {
        if ((preset.gainsDb[index] - list[index].gainDb).abs() >= 0.05) {
          same = false;
          break;
        }
      }
      if (same) return preset.id;
    }
    return null;
  }

  /// Applies a preset, keeping band shapes and enabled flags.
  HifiEqualizerState withPreset(HifiEqPreset preset) {
    final List<HifiEqBand> list = effectiveBands;
    if (preset.gainsDb.length != list.length) return this;
    return copyWith(
      preampDb: preset.preampDb,
      bands: <HifiEqBand>[
        for (int index = 0; index < list.length; index++)
          list[index].copyWith(gainDb: preset.gainsDb[index]),
      ],
    );
  }

  HifiEqualizerState withBandGain(int index, double gainDb) {
    final List<HifiEqBand> list = effectiveBands;
    if (index < 0 || index >= list.length) return this;
    return copyWith(
      bands: <HifiEqBand>[
        for (int index2 = 0; index2 < list.length; index2++)
          index2 == index
              ? list[index2].copyWith(gainDb: clampHifiEqGainDb(gainDb))
              : list[index2],
      ],
    );
  }
}

/// Everything the HiFi settings page owns and the engine needs.
///
/// `outputToken` is null for "system default"; the native engine's own device
/// catalog supplies the tokens (Windows endpoint id, ALSA `hw:` pair, CoreAudio
/// UID).
class HifiSettings {
  const HifiSettings({
    this.preferNativeEngine = true,
    this.outputToken,
    this.outputName,
    this.exclusiveMode = false,
    this.bitPerfect = false,
    this.dsdOutputMode = HifiDsdOutputMode.auto,
    this.dsdRatePolicy = HifiDsdRatePolicy.pcmFallback,
    this.volumeNormalization = HifiVolumeNormalization.off,
    this.buffer = HifiBufferSize.small,
    this.equalizer = const HifiEqualizerState(),
    this.crossfeed = const HifiCrossfeedState(),
  });

  final bool preferNativeEngine;
  final String? outputToken;

  /// Display name of [outputToken], so the page can show a remembered choice
  /// before the catalog is re-read.
  final String? outputName;

  final bool exclusiveMode;
  final bool bitPerfect;
  final HifiDsdOutputMode dsdOutputMode;
  final HifiDsdRatePolicy dsdRatePolicy;
  final HifiVolumeNormalization volumeNormalization;
  final HifiBufferSize buffer;
  final HifiEqualizerState equalizer;
  final HifiCrossfeedState crossfeed;

  /// Bit-perfect streams the decoded integer samples untouched, which also means
  /// the software volume and the EQ are bypassed — so the two cannot both be
  /// claimed. The page disables the contradictory combination instead of letting
  /// the engine reject it at open time.
  bool get eqActive => equalizer.enabled && !bitPerfect;

  /// Crossfeed mixes the channels into each other, so it is processing too and is
  /// bypassed by the same promise bit-perfect makes.
  bool get crossfeedActive => crossfeed.altersSignal && !bitPerfect;

  /// Whether anything in the DSP chain alters the samples: the EQ, its limiter, the
  /// preamp or crossfeed.
  bool get dspActive =>
      eqActive ||
      crossfeedActive ||
      equalizer.limiterEnabled ||
      equalizer.preampDb.abs() > 0.0001;

  HifiSettings copyWith({
    bool? preferNativeEngine,
    String? outputToken,
    String? outputName,
    bool clearOutput = false,
    bool? exclusiveMode,
    bool? bitPerfect,
    HifiDsdOutputMode? dsdOutputMode,
    HifiDsdRatePolicy? dsdRatePolicy,
    HifiVolumeNormalization? volumeNormalization,
    HifiBufferSize? buffer,
    HifiEqualizerState? equalizer,
    HifiCrossfeedState? crossfeed,
  }) => HifiSettings(
    preferNativeEngine: preferNativeEngine ?? this.preferNativeEngine,
    outputToken: clearOutput ? null : (outputToken ?? this.outputToken),
    outputName: clearOutput ? null : (outputName ?? this.outputName),
    exclusiveMode: exclusiveMode ?? this.exclusiveMode,
    bitPerfect: bitPerfect ?? this.bitPerfect,
    dsdOutputMode: dsdOutputMode ?? this.dsdOutputMode,
    dsdRatePolicy: dsdRatePolicy ?? this.dsdRatePolicy,
    volumeNormalization: volumeNormalization ?? this.volumeNormalization,
    buffer: buffer ?? this.buffer,
    equalizer: equalizer ?? this.equalizer,
    crossfeed: crossfeed ?? this.crossfeed,
  );

  Map<String, Object?> toMap() => <String, Object?>{
    'hifi_native_engine': preferNativeEngine,
    'hifi_output_token': outputToken,
    'hifi_output_name': outputName,
    'hifi_exclusive': exclusiveMode,
    'hifi_bit_perfect': bitPerfect,
    'hifi_dsd_mode': dsdOutputMode.name,
    'hifi_dsd_rate_policy': dsdRatePolicy.name,
    'hifi_volume_normalization': volumeNormalization.name,
    'hifi_buffer_millis': buffer.millis,
    'hifi_equalizer': equalizer.encode(),
    'hifi_crossfeed': crossfeed.encode(),
  };

  static HifiSettings fromMap(Map<String, Object?> map) => HifiSettings(
    preferNativeEngine: map['hifi_native_engine'] as bool? ?? true,
    outputToken: map['hifi_output_token'] as String?,
    outputName: map['hifi_output_name'] as String?,
    exclusiveMode: map['hifi_exclusive'] as bool? ?? false,
    bitPerfect: map['hifi_bit_perfect'] as bool? ?? false,
    dsdOutputMode: HifiDsdOutputMode.parse(map['hifi_dsd_mode'] as String?),
    dsdRatePolicy: HifiDsdRatePolicy.parse(
      map['hifi_dsd_rate_policy'] as String?,
    ),
    volumeNormalization: HifiVolumeNormalization.parse(
      map['hifi_volume_normalization'] as String?,
    ),
    buffer: HifiBufferSize.parse(map['hifi_buffer_millis'] as int?),
    equalizer: HifiEqualizerState.decode(map['hifi_equalizer'] as String?),
    crossfeed: HifiCrossfeedState.decode(map['hifi_crossfeed'] as String?),
  );

  /// The engine-side output settings for the next opened stream.
  ///
  /// Bit-perfect and DoP are mutually exclusive policies and DSD modes are only
  /// meaningful for DSD sources; the engine validates the rest.
  LazerOutputRequest toOutputRequest() => LazerOutputRequest(
    token: outputToken,
    exclusive: exclusiveMode,
    bitPerfect: bitPerfect,
    dsdOutputMode: dsdOutputMode,
    bufferMillis: buffer.millis,
  );

  /// The DSP chain request for the engine.
  ///
  /// Crossfeed is dropped when the settings would break the bit-perfect promise, and
  /// its delay/cutoff follow the chosen algorithm.
  ///
  /// A bit-perfect session routes the decoded samples straight to the device, and
  /// the engine refuses processing requests while it is active. The request is
  /// therefore neutralised here rather than sent and rejected: reporting "EQ could
  /// not be applied" for settings the user has not touched would be noise. Nothing
  /// is discarded — turning bit-perfect off re-sends the same settings, and
  /// [dspBypassedByBitPerfect] is what the page states meanwhile.
  LazerDspRequest toDspRequest() => LazerDspRequest(
    preampDb: bitPerfect ? 0 : equalizer.preampDb,
    limiterEnabled: !bitPerfect && equalizer.limiterEnabled,
    limiterThresholdDb: equalizer.limiterThresholdDb,
    crossfeedEnabled: crossfeedActive,
    crossfeedStrength: crossfeed.strength,
    crossfeedAlgorithm: crossfeed.algorithm.nativeValue,
    crossfeedDelayMs: crossfeed.effectiveDelayMs,
    crossfeedCutoffHz: crossfeed.effectiveCutoffHz,
    bands: equalizer.toEngineMessage(eqActive: eqActive).bands,
  );

  /// True when the user has DSP configured that bit-perfect keeps out of the
  /// signal path: the page says so instead of showing the EQ as applied.
  bool get dspBypassedByBitPerfect => bitPerfect && dspActive;
}

/// One band, in the shape the engine's DSP config takes.
///
/// `kind` and the enable flag are the engine's own numbering
/// (`LazerAudioEqBandKind`), so no second mapping table is needed at the FFI edge.
class HifiEqBandMessage {
  const HifiEqBandMessage({
    required this.kind,
    required this.frequencyHz,
    required this.gainDb,
    required this.q,
    required this.enabled,
  });

  final int kind;
  final double frequencyHz;
  final double gainDb;
  final double q;
  final int enabled;
}

/// Everything the engine's DSP call needs, derived from [HifiEqualizerState].
class HifiDspMessage {
  const HifiDspMessage({
    required this.preampDb,
    required this.limiterEnabled,
    required this.limiterThresholdDb,
    required this.bands,
  });

  final double preampDb;
  final bool limiterEnabled;
  final double limiterThresholdDb;
  final List<HifiEqBandMessage> bands;
}

extension HifiEqBandEngineMapping on HifiEqBandKind {
  /// The engine's `LazerAudioEqBandKind` value.
  int get nativeKind => switch (this) {
    HifiEqBandKind.peak => 0,
    HifiEqBandKind.lowShelf => 1,
    HifiEqBandKind.highShelf => 2,
    HifiEqBandKind.lowPass => 3,
    HifiEqBandKind.highPass => 4,
    HifiEqBandKind.notch => 5,
    HifiEqBandKind.allPass => 6,
  };
}

extension HifiEqualizerEngineMapping on HifiEqualizerState {
  /// What to hand the engine for the current state.
  ///
  /// A disabled EQ still sends its preamp/limiter (the limiter is a safety net that
  /// runs even with the EQ off, exactly like master's default), but no bands — the
  /// engine's chain stays transparent for the samples it receives.
  HifiDspMessage toEngineMessage({required bool eqActive}) => HifiDspMessage(
    preampDb: clampHifiPreampDb(preampDb),
    limiterEnabled: limiterEnabled,
    limiterThresholdDb: limiterThresholdDb,
    bands: <HifiEqBandMessage>[
      if (eqActive)
        for (final HifiEqBand band in effectiveBands)
          if (band.enabled)
            HifiEqBandMessage(
              kind: band.kind.nativeKind,
              frequencyHz: band.frequencyHz,
              gainDb: clampHifiEqGainDb(band.gainDb),
              q: band.q.clamp(0.1, 10),
              enabled: 1,
            ),
    ],
  );
}

/// Flutter-free mirror of the engine's DSP request for the settings layer.
class LazerDspRequest {
  const LazerDspRequest({
    this.preampDb = 0,
    this.limiterEnabled = false,
    this.limiterThresholdDb = -1,
    this.crossfeedEnabled = false,
    this.crossfeedStrength = 0,
    this.crossfeedAlgorithm = 0,
    this.crossfeedDelayMs = 0.22,
    this.crossfeedCutoffHz = 700,
    this.bands = const <HifiEqBandMessage>[],
  });

  final double preampDb;
  final bool limiterEnabled;
  final double limiterThresholdDb;
  final bool crossfeedEnabled;
  final double crossfeedStrength;
  final int crossfeedAlgorithm;
  final double crossfeedDelayMs;
  final double crossfeedCutoffHz;
  final List<HifiEqBandMessage> bands;

  /// `[enabled, strength, algorithm, delayMs, cutoffHz]` for the worker's DSP call.
  List<Object?> toCrossfeedMessage() => <Object?>[
    crossfeedEnabled ? 1 : 0,
    crossfeedStrength,
    crossfeedAlgorithm,
    crossfeedDelayMs,
    crossfeedCutoffHz,
  ];
}

/// Flutter-free mirror of `LazerDeviceSettings` for the settings layer.
///
/// The engine package's own class lives next to the ABI; this one keeps the state
/// layer independent of `dart:ffi` so it can be unit-tested anywhere.
class LazerOutputRequest {
  const LazerOutputRequest({
    this.token,
    this.exclusive = false,
    this.bitPerfect = false,
    this.resampleMode = 0,
    this.targetSampleRate = 0,
    this.bufferMillis = 120,
    this.dsdOutputMode = HifiDsdOutputMode.convertToPcm,
  });

  final String? token;
  final bool exclusive;
  final bool bitPerfect;
  final int resampleMode;
  final int targetSampleRate;
  final int bufferMillis;
  final HifiDsdOutputMode dsdOutputMode;

  /// The six fields the engine's `LazerAudioDeviceConfig` holds.
  List<Object?> toDeviceMessage() => <Object?>[
    exclusive ? 1 : 0,
    resampleMode,
    targetSampleRate,
    bufferMillis,
    bitPerfect ? 1 : 0,
    dsdOutputMode.nativeValue,
  ];

  Map<String, Object?> toMap() => <String, Object?>{
    'token': token,
    'exclusive': exclusive,
    'bitPerfect': bitPerfect,
    'resampleMode': resampleMode,
    'targetSampleRate': targetSampleRate,
    'bufferMillis': bufferMillis,
    'dsdOutputMode': dsdOutputMode.name,
  };
}
