// Wire contract for `native/lazer-audio/include/lazer_audio_api.h` (ABI v23).
//
// The C header is the source of truth: this file mirrors its enums, structs and
// constants one-for-one. Struct field order is the ABI — the native engine
// `memcpy`s these structs, so a reordered or re-typed field shows up as garbage
// audio rather than a link error. `lazer_audio_abi_test.dart` pins every
// `sizeOf`/`offsetOf` against the values the C compiler produces.
//
// Keep new fields at the end and bump [lazerAudioAbiVersion] only when the
// native side does, exactly like the header asks.
library;

import 'dart:ffi';

/// `LAZER_AUDIO_ABI_VERSION` — `lazer_audio_create` rejects anything else.
///
/// v24 appended the crossfeed fields to [LazerAudioDspConfig]; this mirror and the
/// vendored engine are updated together (see docs/audio-engine.md).
const int lazerAudioAbiVersion = 25;

/// `LAZER_AUDIO_MAX_EQ_BANDS`.
const int lazerAudioMaxEqBands = 32;

/// Reader callback results (positive counts are byte counts).
const int lazerAudioReaderEof = -1;
const int lazerAudioReaderIoError = -2;

/// `LazerAudioError`.
const int lazerAudioOk = 0;
const int lazerAudioErrorInvalidArgument = -1;
const int lazerAudioErrorUnsupported = -2;
const int lazerAudioErrorNoMemory = -3;
const int lazerAudioErrorSource = -4;
const int lazerAudioErrorDecode = -5;
const int lazerAudioErrorDevice = -6;
const int lazerAudioErrorCancelled = -7;
const int lazerAudioErrorState = -8;
const int lazerAudioErrorBufferTooSmall = -9;
const int lazerAudioErrorIndexOutOfRange = -10;

/// `LazerAudioQueueClearResult`: the queued successor already crossed the
/// boundary and is the active source now.
const int lazerAudioQueueCleared = lazerAudioOk;
const int lazerAudioQueueAlreadyActive = 1;

/// `LazerAudioState`.
const int lazerAudioStateIdle = 0;
const int lazerAudioStatePreparing = 1;
const int lazerAudioStateReady = 2;
const int lazerAudioStatePlaying = 3;
const int lazerAudioStatePaused = 4;
const int lazerAudioStateStopped = 5;
const int lazerAudioStateFailed = 6;

/// `LazerAudioEvent`. `-1` is the "nothing terminal yet" value the engine writes
/// into `LazerAudioSnapshot.terminalEvent`.
const int lazerAudioEventNone = -1;
const int lazerAudioEventReady = 0;
const int lazerAudioEventEnded = 1;
const int lazerAudioEventFailed = 2;
const int lazerAudioEventSeekCompleted = 3;
const int lazerAudioEventDeviceLost = 4;
const int lazerAudioEventBufferProgress = 5;
const int lazerAudioEventTrackChanged = 6;

/// `LazerAudioLogLevel`.
const int lazerAudioLogDebug = 0;
const int lazerAudioLogInfo = 1;
const int lazerAudioLogWarning = 2;
const int lazerAudioLogError = 3;

/// `LazerAudioResampleMode`.
const int lazerAudioResampleNative = 0;
const int lazerAudioResampleFixedRate = 1;

/// `LazerAudioDsdOutputMode`.
const int lazerAudioDsdOutputConvertToPcm = 0;
const int lazerAudioDsdOutputRequireDoP = 1;
const int lazerAudioDsdOutputRequireNative = 2;

/// `LazerAudioSourceFormatKind`.
const int lazerAudioSourceFormatPcm = 0;
const int lazerAudioSourceFormatDsd = 1;

/// `LazerAudioOutputFormatKind`.
const int lazerAudioOutputFormatPcm = 0;
const int lazerAudioOutputFormatDoP = 1;
const int lazerAudioOutputFormatNativeDsd = 2;

/// `LazerAudioFormatSelection`.
const int lazerAudioFormatSelectionUnknown = 0;
const int lazerAudioFormatSelectionSharedMix = 1;
const int lazerAudioFormatSelectionExclusiveSource = 2;
const int lazerAudioFormatSelectionExclusiveSameRateAlternate = 3;
const int lazerAudioFormatSelectionExclusiveMonoToStereo = 4;
const int lazerAudioFormatSelectionExclusiveMixFallback = 5;
const int lazerAudioFormatSelectionExclusiveCommonRateFallback = 6;
const int lazerAudioFormatSelectionDoPCarrier = 7;
const int lazerAudioFormatSelectionNativeDsdU8 = 8;
const int lazerAudioFormatSelectionNativeDsdU16Le = 9;
const int lazerAudioFormatSelectionNativeDsdU16Be = 10;
const int lazerAudioFormatSelectionNativeDsdU32Le = 11;
const int lazerAudioFormatSelectionNativeDsdU32Be = 12;

/// `LazerAudioEqBandKind`.
const int lazerAudioEqBandPeak = 0;
const int lazerAudioEqBandLowShelf = 1;
const int lazerAudioEqBandHighShelf = 2;
const int lazerAudioEqBandLowPass = 3;
const int lazerAudioEqBandHighPass = 4;
const int lazerAudioEqBandNotch = 5;
const int lazerAudioEqBandAllPass = 6;

/// `LazerAudioOutputDeviceFlags`.
const int lazerAudioOutputDeviceFlagActive = 1 << 0;
const int lazerAudioOutputDeviceFlagDefault = 1 << 1;
const int lazerAudioOutputDeviceFlagIdentityEphemeral = 1 << 2;

/// Read callback: `int32_t (*)(void *context, uint8_t *destination, int32_t length)`.
typedef LazerAudioReadNative =
    Int32 Function(Pointer<Void> context, Pointer<Uint8> destination, Int32 length);
typedef LazerAudioReadDart =
    int Function(Pointer<Void> context, Pointer<Uint8> destination, int length);

/// Seek callback: `int64_t (*)(void *context, int64_t position_bytes)`.
typedef LazerAudioSeekNative =
    Int64 Function(Pointer<Void> context, Int64 positionBytes);

/// Length callback: `int64_t (*)(void *context)`.
typedef LazerAudioLengthNative = Int64 Function(Pointer<Void> context);

/// Close/cancel callbacks: `void (*)(void *context)`.
typedef LazerAudioVoidNative = Void Function(Pointer<Void> context);

/// Event callback: `void (*)(void *context, int32_t event, int32_t detail,
/// int64_t position_millis)`. Raised on engine threads, never on the caller's.
typedef LazerAudioEventNative =
    Void Function(
      Pointer<Void> context,
      Int32 event,
      Int32 detail,
      Int64 positionMillis,
    );
typedef LazerAudioEventDart =
    void Function(
      Pointer<Void> context,
      int event,
      int detail,
      int positionMillis,
    );

/// Log callback: `void (*)(void *context, int32_t level, const char *message)`.
typedef LazerAudioLogNative =
    Void Function(Pointer<Void> context, Int32 level, Pointer<Uint8> message);
typedef LazerAudioLogDart =
    void Function(Pointer<Void> context, int level, Pointer<Uint8> message);

/// `LazerAudioDeviceConfig` — how the next output session is negotiated.
final class LazerAudioDeviceConfig extends Struct {
  /// `device_id` is a `wchar_t *` and only Windows reads it; hosts without a
  /// wide-character catalog resolve the device by [token] instead.
  external Pointer<Uint16> deviceId;

  @Int32()
  external int exclusive;

  @Int32()
  external int resampleMode;

  @Int32()
  external int targetSampleRate;

  @Int32()
  external int bufferMillis;

  /// Streams the decoded integer samples untouched; bypasses software volume and
  /// the EQ chain, so the caller owns the level.
  @Int32()
  external int bitPerfect;

  @Int32()
  external int dsdOutputMode;
}

/// Fills [config] with the engine's own defaults: system default endpoint, shared
/// mode, the decoded sample rate, a 120 ms buffer and DSD converted to PCM.
///
/// A `Struct` subclass cannot be instantiated from Dart, so every helper here
/// writes through a pointer the caller allocated (`calloc`) and owns.
void writeDefaultDeviceConfig(Pointer<LazerAudioDeviceConfig> config) {
  config.ref
    ..deviceId = nullptr
    ..exclusive = 0
    ..resampleMode = lazerAudioResampleNative
    ..targetSampleRate = 0
    ..bufferMillis = 120
    ..bitPerfect = 0
    ..dsdOutputMode = lazerAudioDsdOutputConvertToPcm;
}

/// `LazerAudioEventHandler`.
final class LazerAudioEventHandler extends Struct {
  external Pointer<NativeFunction<LazerAudioEventNative>> onEvent;
  external Pointer<Void> context;
}

/// `LazerAudioLogHandler`.
final class LazerAudioLogHandler extends Struct {
  external Pointer<NativeFunction<LazerAudioLogNative>> onLog;
  external Pointer<Void> context;
}

/// `LazerAudioEngineConfig` — the one struct that crosses at creation time.
final class LazerAudioEngineConfig extends Struct {
  @Uint32()
  external int abiVersion;

  @Uint32()
  external int structSize;

  external LazerAudioDeviceConfig device;
  external LazerAudioEventHandler events;
  external LazerAudioLogHandler log;
}

/// Caller-owned byte source. Returning 0 means "no bytes right now" — the engine
/// waits instead of treating it as end of stream — while [lazerAudioReaderEof]
/// is clean EOF and [lazerAudioReaderIoError] is terminal.
final class LazerAudioReader extends Struct {
  external Pointer<NativeFunction<LazerAudioReadNative>> read;
  external Pointer<NativeFunction<LazerAudioSeekNative>> seek;
  external Pointer<NativeFunction<LazerAudioLengthNative>> length;
  external Pointer<NativeFunction<LazerAudioVoidNative>> close;
  external Pointer<Void> context;

  /// Thread-safe interruption hook; may run concurrently with `read`/`seek`.
  external Pointer<NativeFunction<LazerAudioVoidNative>> cancel;
}

/// `LazerAudioOpenParams`. `struct_size` must be [sizeOf] the struct; the engine
/// also accepts the two older sizes for compatibility.
final class LazerAudioOpenParams extends Struct {
  @Uint32()
  external int structSize;

  @Int64()
  external int startMillis;

  @Int64()
  external int durationHintMillis;

  /// Optional CUE segment in 1/75 s frames; `(0, 0)` is the whole source.
  @Int64()
  external int cueStartFrame75;

  @Int64()
  external int cueEndFrame75;

  /// Per-source ReplayGain, valid range −60..24 dB. Non-zero is incompatible
  /// with bit-perfect and DoP, which the engine rejects rather than ignores.
  @Double()
  external double replayGainDb;
}

/// Fills [params] with `struct_size` already set to the value the native side
/// validates; a wrong size is rejected as `InvalidArgument`.
void writeOpenParams(
  Pointer<LazerAudioOpenParams> params, {
  Duration start = Duration.zero,
  Duration? durationHint,
  int cueStartFrame75 = 0,
  int cueEndFrame75 = 0,
  double replayGainDb = 0,
}) {
  params.ref
    ..structSize = sizeOf<LazerAudioOpenParams>()
    ..startMillis = start.inMilliseconds
    ..durationHintMillis = durationHint?.inMilliseconds ?? 0
    ..cueStartFrame75 = cueStartFrame75
    ..cueEndFrame75 = cueEndFrame75
    ..replayGainDb = replayGainDb;
}

/// `LazerAudioSnapshot` — the polled transport state.
final class LazerAudioSnapshot extends Struct {
  @Int32()
  external int state;

  @Int32()
  external int paused;

  @Int64()
  external int positionMillis;

  @Int64()
  external int durationMillis;

  @Int32()
  external int bufferedPercent;

  @Int32()
  external int error;

  /// True while the last submitted output contained source-starvation padding.
  @Int32()
  external int underrunActive;

  /// Cumulative padded frames; excludes the clean-EOF tail and queue waits.
  @Uint64()
  external int underrunFrames;

  /// Terminal event metadata, published before the callback runs. -1 = pending.
  @Int32()
  external int terminalEvent;

  @Int32()
  external int terminalDetail;

  @Int64()
  external int terminalPositionMillis;

  /// Whole frames waiting in the engine's lock-free output ring, and its size
  /// (ABI v25). Producer is the decode/DSP thread, consumer is the render thread.
  @Int32()
  external int ringFillFrames;

  @Int32()
  external int ringCapacityFrames;
}

/// `LazerAudioStreamInfo` — source metadata plus the format the initialized
/// output session accepted. Neither field certifies what the DAC receives.
final class LazerAudioStreamInfo extends Struct {
  @Array(64)
  external Array<Uint8> codec;

  @Int32()
  external int sourceSampleRate;

  @Int32()
  external int sourceChannels;

  @Int32()
  external int sourceBitsPerSample;

  @Int32()
  external int sourceBitrateKbps;

  @Int32()
  external int lossless;

  @Int32()
  external int outputSampleRate;

  @Int32()
  external int outputChannels;

  @Int32()
  external int outputBitsPerSample;

  @Int32()
  external int outputExclusive;

  @Int32()
  external int bitPerfectActive;

  @Int32()
  external int outputContainerBitsPerSample;

  @Int32()
  external int outputIsFloat;

  @Int32()
  external int outputFormatInitialized;

  @Int32()
  external int sourceFormatKind;

  @Int32()
  external int sourceDsdRateMultiplier;

  @Int32()
  external int outputFormatSelection;

  /// Maximum magnitude after DSP/volume, in milli-dBFS (clamped ±120 dBFS).
  @Int32()
  external int outputPeakMillidbfs;

  @Int32()
  external int limiterGainReductionMillidb;

  @Uint64()
  external int outputClippedSampleCount;

  @Int32()
  external int outputTelemetryValid;

  @Int32()
  external int outputFormatKind;

  @Int32()
  external int outputDsdRateMultiplier;

  @Int32()
  external int outputCoreAudioMixabilityKnown;

  @Int32()
  external int outputCoreAudioNonMixable;

  /// True only while the float DSP/volume chain is on the signal path (ABI v25).
  @Int32()
  external int outputDspActive;

  /// True only when the output session runs the source's own rate, channels and
  /// depth — no resampling, no requantization (ABI v25).
  @Int32()
  external int outputFormatMatchesSource;
}

/// `LazerAudioEqBand`.
final class LazerAudioEqBand extends Struct {
  @Int32()
  external int kind;

  @Double()
  external double frequencyHz;

  @Double()
  external double gainDb;

  @Double()
  external double q;

  @Int32()
  external int enabled;
}

/// `LazerAudioDspConfig`. `bands` points at [bandCount] contiguous bands that the
/// engine copies before returning, so the caller may free them right after.
final class LazerAudioDspConfig extends Struct {
  @Double()
  external double preampDb;

  @Uint32()
  external int bandCount;

  external Pointer<LazerAudioEqBand> bands;

  @Int32()
  external int limiterEnabled;

  @Double()
  external double limiterThresholdDb;

  /// Reserved; currently ignored by the engine.
  @Int32()
  external int balanceChannels;

  /// Append-only in ABI v24: cross-channel feed for headphone listening.
  @Int32()
  external int crossfeedEnabled;

  /// 0..1; below 0.0001 counts as off.
  @Double()
  external double crossfeedStrength;

  /// 0 custom, 1 Bauer, 2 Bs2b, 3 Meier.
  @Int32()
  external int crossfeedAlgorithm;

  /// Custom algorithm only; the named ones fix the delay.
  @Double()
  external double crossfeedDelayMs;

  /// Custom algorithm only; the named ones fix the cutoff.
  @Double()
  external double crossfeedCutoffHz;
}

/// `LazerAudioDspConfig.crossfeed_algorithm` values.
abstract final class LazerAudioCrossfeedAlgorithm {
  static const int custom = 0;
  static const int bauer = 1;
  static const int bs2b = 2;
  static const int meier = 3;
}

/// `LazerAudioOutputDeviceInfo`.
final class LazerAudioOutputDeviceInfo extends Struct {
  @Uint32()
  external int structSize;

  @Uint32()
  external int flags;
}

/// `LazerAudioDeviceInfo` — Windows render-endpoint identity and state.
final class LazerAudioDeviceInfo extends Struct {
  @Uint32()
  external int structSize;

  @Uint32()
  external int endpointState;

  @Uint32()
  external int defaultRoleMask;

  @Uint32()
  external int identityKind;

  @Int32()
  external int endpointVolumeQueryHresult;

  @Uint32()
  external int endpointVolumeHardwareSupportFlags;
}

/// `LazerAudioPcmFormatCandidate`.
final class LazerAudioPcmFormatCandidate extends Struct {
  @Uint32()
  external int sampleRate;

  @Uint16()
  external int channels;

  @Uint16()
  external int containerBits;

  @Uint16()
  external int validBits;

  @Uint16()
  external int reserved;
}

/// `LazerAudioPcmFormatProbeResult`.
final class LazerAudioPcmFormatProbeResult extends Struct {
  /// `LazerAudioPcmFormatProbeStatus`: 0 supported, 1 unsupported, 2 error.
  @Int32()
  external int status;

  /// The raw `IAudioClient::IsFormatSupported` HRESULT.
  @Int32()
  external int nativeStatus;
}

/// Reads the NUL-terminated `codec` array as text.
String lazerCodecName(LazerAudioStreamInfo info) {
  final List<int> bytes = <int>[];
  for (int i = 0; i < 64; i++) {
    final int byte = info.codec[i];
    if (byte == 0) break;
    bytes.add(byte);
  }
  return String.fromCharCodes(bytes);
}

/// Copies a NUL-terminated `const char *` into a Dart string.
///
/// Reads byte by byte through the pointer instead of materialising a typed
/// list: the engine's error strings are not sized buffers, so an over-read would
/// be a real out-of-bounds read. [maxBytes] bounds a missing terminator.
String lazerReadCString(Pointer<Uint8> pointer, {int maxBytes = 4096}) {
  if (pointer == nullptr) return '';
  final List<int> bytes = <int>[];
  for (int i = 0; i < maxBytes; i++) {
    final int byte = pointer[i];
    if (byte == 0) break;
    bytes.add(byte);
  }
  return String.fromCharCodes(bytes);
}
