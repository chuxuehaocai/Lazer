/* Public C ABI for the Lazer native audio engine. Exactly one function pointer table crosses the
 * JNA boundary, so the layout of every struct here is a wire contract: append new fields and new
 * functions at the end, never reorder, and bump LAZER_AUDIO_ABI_VERSION when semantics change. */
#ifndef LAZER_AUDIO_API_H
#define LAZER_AUDIO_API_H

#include <stdint.h>
#include <stddef.h>

#if defined(_WIN32)
#define LAZER_AUDIO_CALL __cdecl
#if defined(__cplusplus)
#if defined(LAZER_AUDIO_EXPORTS)
#define LAZER_AUDIO_API extern "C" __declspec(dllexport)
#else
#define LAZER_AUDIO_API extern "C" __declspec(dllimport)
#endif
#else
#if defined(LAZER_AUDIO_EXPORTS)
#define LAZER_AUDIO_API __declspec(dllexport)
#else
#define LAZER_AUDIO_API __declspec(dllimport)
#endif
#endif
#elif defined(__cplusplus)
#define LAZER_AUDIO_API extern "C"
#define LAZER_AUDIO_CALL
#else
#define LAZER_AUDIO_API
#define LAZER_AUDIO_CALL
#endif

#define LAZER_AUDIO_ABI_VERSION 27u

#define LAZER_AUDIO_MAX_EQ_BANDS 32u
/* Upper bound on the explicit DSP chain length; see LazerAudioDspStage. */
#define LAZER_AUDIO_MAX_DSP_STAGES 8u

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LazerAudioEngineT *LazerAudioEngine;

typedef enum LazerAudioState {
    LazerAudioStateIdle = 0,
    LazerAudioStatePreparing = 1,
    LazerAudioStateReady = 2,
    LazerAudioStatePlaying = 3,
    LazerAudioStatePaused = 4,
    LazerAudioStateStopped = 5,
    LazerAudioStateFailed = 6,
} LazerAudioState;

/* Non-zero LazerAudioError values are failures. Reader callback return values have their own
 * documented data/EOF/error meanings. */
typedef enum LazerAudioError {
    LazerAudioOk = 0,
    LazerAudioErrorInvalidArgument = -1,
    LazerAudioErrorUnsupported = -2,
    LazerAudioErrorNoMemory = -3,
    LazerAudioErrorSource = -4,
    LazerAudioErrorDecode = -5,
    LazerAudioErrorDevice = -6,
    LazerAudioErrorCancelled = -7,
    LazerAudioErrorState = -8,
    /* Additive catalog API results; existing error values retain their definitions. */
    LazerAudioErrorBufferTooSmall = -9,
    LazerAudioErrorIndexOutOfRange = -10,
} LazerAudioError;

/* clear_queued_reader() may report that the requested successor already crossed the audible
 * boundary. In that case it remains the active source and must not be closed as queued data. */
typedef enum LazerAudioQueueClearResult {
    LazerAudioQueueCleared = LazerAudioOk,
    LazerAudioQueueAlreadyActive = 1,
} LazerAudioQueueClearResult;

typedef enum LazerAudioLogLevel {
    LazerAudioLogDebug = 0,
    LazerAudioLogInfo = 1,
    LazerAudioLogWarning = 2,
    LazerAudioLogError = 3,
} LazerAudioLogLevel;

/* Events are raised on engine threads, never on the caller's thread, so the Kotlin listener must
 * not block. */
typedef enum LazerAudioEvent {
    LazerAudioEventReady = 0,
    LazerAudioEventEnded = 1,
    LazerAudioEventFailed = 2,
    LazerAudioEventSeekCompleted = 3,
    LazerAudioEventDeviceLost = 4,
    LazerAudioEventBufferProgress = 5,
    /* The next queued source has reached the output boundary in the current session. */
    LazerAudioEventTrackChanged = 6,
} LazerAudioEvent;

/* The caller owns the byte stream: it may be a growing HTTP cache file whose reads block until more
 * bytes land, which is why the engine never assumes EOF means "file finished" here. read returns a
 * positive byte count, 0 when no bytes are currently available, LAZER_AUDIO_READER_EOF at clean EOF,
 * or LAZER_AUDIO_READER_IO_ERROR for a terminal read failure. A known-length source with bytes
 * remaining must eventually produce data or EOF; opening probes its first four bytes to identify DFF
 * before selecting the decoder path. seek and length may be NULL for a stream that cannot be
 * repositioned, in which case the engine seeks by decoding forward. */
#define LAZER_AUDIO_READER_IO_ERROR (-2)
#define LAZER_AUDIO_READER_EOF (-1)
typedef struct LazerAudioReader {
    int32_t(LAZER_AUDIO_CALL *read)(void *context, uint8_t *destination, int32_t length);
    int64_t(LAZER_AUDIO_CALL *seek)(void *context, int64_t position_bytes);
    int64_t(LAZER_AUDIO_CALL *length)(void *context);
    void(LAZER_AUDIO_CALL *close)(void *context);
    void *context;
    /* Optional, thread-safe interruption hook. It may run concurrently with read/seek/length and
     * must wake blocking calls without freeing context; close runs once after those calls stop. */
    void(LAZER_AUDIO_CALL *cancel)(void *context);
} LazerAudioReader;

typedef struct LazerAudioEventHandler {
    void(LAZER_AUDIO_CALL *on_event)(
        void *context, int32_t event, int32_t detail, int64_t position_millis);
    void *context;
} LazerAudioEventHandler;

typedef struct LazerAudioLogHandler {
    void(LAZER_AUDIO_CALL *on_log)(void *context, int32_t level, const char *message);
    void *context;
} LazerAudioLogHandler;

/* Output format policy. LAZER_AUDIO_RESAMPLE_NATIVE keeps the decoded rate, which is what a
 * bit-perfect exclusive-mode listener wants. */
typedef enum LazerAudioResampleMode {
    LazerAudioResampleNative = 0,
    LazerAudioResampleFixedRate = 1,
    LazerAudioResampleAlwaysFloat32 = 2,
} LazerAudioResampleMode;

/* DSD output policy. Direct modes require an exact device format and never fall back to PCM. */
typedef enum LazerAudioDsdOutputMode {
    LazerAudioDsdOutputConvertToPcm = 0,
    LazerAudioDsdOutputRequireDoP = 1,
    /* Append-only in ABI v22: ALSA Native DSD_U8/U16/U32 from raw DSD sources. */
    LazerAudioDsdOutputRequireNative = 2,
} LazerAudioDsdOutputMode;

typedef struct LazerAudioDeviceConfig {
    /* NULL selects the system default endpoint. */
    const wchar_t *device_id;
    int32_t exclusive;
    int32_t resample_mode;
    int32_t target_sample_rate;
    int32_t buffer_millis;
    /* Bit-perfect stream out: the decoded integer samples reach the device untouched, which also
     * means the software volume and the EQ are bypassed, so the caller must own the volume. */
    int32_t bit_perfect;
    /* Append-only in ABI v17: desired handling for DSD sources. */
    int32_t dsd_output_mode;
} LazerAudioDeviceConfig;

typedef struct LazerAudioEngineConfig {
    uint32_t abi_version;
    uint32_t struct_size;
    LazerAudioDeviceConfig device;
    LazerAudioEventHandler events;
    LazerAudioLogHandler log;
} LazerAudioEngineConfig;

typedef enum LazerAudioSourceFormatKind {
    LazerAudioSourceFormatPcm = 0,
    LazerAudioSourceFormatDsd = 1,
} LazerAudioSourceFormatKind;

typedef enum LazerAudioOutputFormatKind {
    LazerAudioOutputFormatPcm = 0,
    LazerAudioOutputFormatDoP = 1,
    LazerAudioOutputFormatNativeDsd = 2,
} LazerAudioOutputFormatKind;

/* How the successfully initialized output session format was selected. This reports the player
 * branch that won negotiation; it does not mean a failed candidate was physically unsupported. */
typedef enum LazerAudioFormatSelection {
    LazerAudioFormatSelectionUnknown = 0,
    LazerAudioFormatSelectionSharedMix = 1,
    LazerAudioFormatSelectionExclusiveSource = 2,
    LazerAudioFormatSelectionExclusiveSameRateAlternate = 3,
    LazerAudioFormatSelectionExclusiveMonoToStereo = 4,
    LazerAudioFormatSelectionExclusiveMixFallback = 5,
    LazerAudioFormatSelectionExclusiveCommonRateFallback = 6,
    LazerAudioFormatSelectionDoPCarrier = 7,
    /* Append-only in ABI v22: exact ALSA Native DSD hardware formats. */
    LazerAudioFormatSelectionNativeDsdU8 = 8,
    LazerAudioFormatSelectionNativeDsdU16Le = 9,
    LazerAudioFormatSelectionNativeDsdU16Be = 10,
    LazerAudioFormatSelectionNativeDsdU32Le = 11,
    LazerAudioFormatSelectionNativeDsdU32Be = 12,
} LazerAudioFormatSelection;

/* Describes the source and initialized output-session format. PCM/DoP fields describe the format
 * accepted by the platform endpoint (WAVEFORMAT on WASAPI); Native DSD fields describe the ALSA
 * DSD word format. None certify the format emitted or recognized by the physical DAC. For DSD,
 * source_sample_rate and source_bits_per_sample are zero because DSD has no PCM sample-rate or
 * sample-depth fields; source_dsd_rate_multiplier carries the DSD rate (64, 128, 256, 512 or 1024). */
typedef struct LazerAudioStreamInfo {
    char codec[64];
    int32_t source_sample_rate;
    int32_t source_channels;
    int32_t source_bits_per_sample;
    int32_t source_bitrate_kbps;
    int32_t lossless;
    int32_t output_sample_rate;
    int32_t output_channels;
    int32_t output_bits_per_sample;
    int32_t output_exclusive;
    /* Set only when the exact lossless PCM format was accepted and DSP/digital volume are bypassed. */
    int32_t bit_perfect_active;
    /* Append-only in ABI v3: container width and encoding of the initialized output session. */
    int32_t output_container_bits_per_sample;
    int32_t output_is_float;
    /* True only after native endpoint initialization succeeded; this is not a DAC readback. */
    int32_t output_format_initialized;
    /* Append-only in ABI v6: source encoding and DSD rate, zero/default for PCM. */
    int32_t source_format_kind;
    int32_t source_dsd_rate_multiplier;
    /* Append-only in ABI v7: branch that selected the initialized output format. */
    int32_t output_format_selection;
    /* Append-only in ABI v8: valid only for the processed float DSP path, never bit-perfect.
     * Peak is the maximum sample magnitude observed since stream open after DSP/software volume and before output packing,
     * expressed in milli-dBFS and clamped to [-120, +120] dBFS. This is neither true-peak nor a
     * readback from the physical DAC. Limiter gain reduction is the greatest attenuation observed
     * since stream open (the most negative block value), in milli-dB. Integer clipped samples count inputs outside [-1, +1] that the integer PCM
     * quantizer saturated; the count is cumulative for this open stream. */
    int32_t output_peak_millidbfs;
    int32_t limiter_gain_reduction_millidb;
    uint64_t output_clipped_sample_count;
    int32_t output_telemetry_valid;
    /* Append-only in ABI v17: initialized output encoding and DSD rate multiplier (0 for PCM). */
    int32_t output_format_kind;
    int32_t output_dsd_rate_multiplier;
    /* Append-only in ABI v23: initialized CoreAudio virtual ASBD mixability metadata. A zero
     * `output_coreaudio_mixability_known` means unavailable/not applicable. */
    int32_t output_coreaudio_mixability_known;
    int32_t output_coreaudio_non_mixable;
    /* Append-only in ABI v25: the three facts `bit_perfect_active` is derived from, so a caller can
     * check the claim instead of trusting it. `output_dsp_active` is true only while the float
     * DSP/volume chain is actually in the signal path (it is false when the samples are routed
     * straight through, and false for the DoP and Native DSD paths, whose bit-perfect semantics are
     * defined separately). `output_format_matches_source` is true only when the initialized output
     * session runs the source's own sample rate, channel count and sample depth, with no resampling
     * or requantization. `bit_perfect_active` is true only when the session is exclusive, the DSP is
     * not in the path and the format matches the source. */
    int32_t output_dsp_active;
    int32_t output_format_matches_source;
} LazerAudioStreamInfo;

#if defined(__cplusplus) && defined(_WIN64)
static_assert(sizeof(LazerAudioStreamInfo) == 176, "update the JNA stream-info layout with the native ABI");
#endif

typedef struct LazerAudioSnapshot {
    int32_t state;
    int32_t paused;
    int64_t position_millis;
    int64_t duration_millis;
    int32_t buffered_percent;
    int32_t error;
    /* Append-only in ABI v18: true while the last submitted output included source-starvation
     * padding. Padding at clean EOF and waits at a queued track boundary are excluded. */
    int32_t underrun_active;
    /* Cumulative device-output padding frames caused by a source that had not reached EOF. */
    uint64_t underrun_frames;
    /* Append-only in ABI v20. Terminal event metadata is published before callbacks are invoked,
     * so pollers can classify delayed callbacks without a timing heuristic. -1 means pending. */
    int32_t terminal_event;
    int32_t terminal_detail;
    int64_t terminal_position_millis;
    /* Append-only in ABI v25: how full the engine's lock-free output ring is, in whole frames. The
     * producer is the decode/DSP thread and the consumer is the render thread, so this is the one
     * number that says whether the output is running ahead of the device or close to starving. */
    int32_t ring_fill_frames;
    int32_t ring_capacity_frames;
    /* Append-only in ABI v26: the hysteresis band the producer works in. It stops feeding at the
     * high mark and resumes at the low one, so the render thread always has a cushion without the
     * ring being pinned full. Zero while no stream is configured. */
    int32_t ring_low_watermark_frames;
    int32_t ring_high_watermark_frames;
} LazerAudioSnapshot;

#if defined(__cplusplus) && defined(_WIN64)
static_assert(sizeof(LazerAudioSnapshot) == 80, "update the JNA snapshot layout with the native ABI");
#endif

/* A constant-Q biquad pair per band; the engine keeps coefficient state warm across updates so a
 * slider drag never clicks. */
typedef enum LazerAudioEqBandKind {
    LazerAudioEqBandPeak = 0,
    LazerAudioEqBandLowShelf = 1,
    LazerAudioEqBandHighShelf = 2,
    LazerAudioEqBandLowPass = 3,
    LazerAudioEqBandHighPass = 4,
    LazerAudioEqBandNotch = 5,
    LazerAudioEqBandAllPass = 6,
} LazerAudioEqBandKind;

typedef struct LazerAudioEqBand {
    int32_t kind;
    double frequency_hz;
    double gain_db;
    double q;
    int32_t enabled;
} LazerAudioEqBand;

/* One processing stage of the float chain, in the order the caller asks for. Every stage reads and
 * writes the same interleaved float buffer, carries no state outside its own configuration, and can
 * be left out to bypass it. The engine's default order is Preamp, Eq, Crossfeed, Limiter, Volume. */
typedef enum LazerAudioDspStage {
    LazerAudioDspStagePreamp = 0,
    LazerAudioDspStageEq = 1,
    LazerAudioDspStageCrossfeed = 2,
    LazerAudioDspStageLimiter = 3,
    LazerAudioDspStageVolume = 4,
} LazerAudioDspStage;

typedef struct LazerAudioDspConfig {
    double preamp_db;
    uint32_t band_count;
    const LazerAudioEqBand *bands;
    int32_t limiter_enabled;
    double limiter_threshold_db;
    int32_t balance_channels; /* reserved, currently ignored */
    /* Append-only in ABI v24: cross-channel feed for headphone listening. The direct path is
     * attenuated as the cross path grows. Only stereo is processed; other layouts ignore it. */
    int32_t crossfeed_enabled;
    double crossfeed_strength;   /* 0..1; below 0.0001 counts as off. */
    int32_t crossfeed_algorithm; /* 0 custom, 1 Bauer, 2 Bs2b, 3 Meier. */
    double crossfeed_delay_ms;   /* Custom only; the named algorithms fix it. */
    double crossfeed_cutoff_hz;  /* Custom only; the named algorithms fix it. */
    /* Append-only in ABI v27: the explicit chain, front to back. `stage_order` holds
     * LazerAudioDspStage values; a stage that is not listed is bypassed for this request, and
     * `stage_count == 0` means the engine's default order unchanged. A stage listed twice is applied
     * twice, which is a legal — if unusual — request. Order is part of the audio result: the limiter
     * before the EQ protects the pre-EQ signal, after it protects what actually leaves the chain. */
    uint32_t stage_count;
    int32_t stage_order[LAZER_AUDIO_MAX_DSP_STAGES];
} LazerAudioDspConfig;

/* Immutable snapshot of the Windows render endpoints at catalog creation time. The catalog reports
 * endpoint identity and Windows state only; it does not assert sample-format or hardware features. */
typedef struct LazerAudioDeviceCatalogT *LazerAudioDeviceCatalog;

typedef enum LazerAudioDeviceIdentityKind {
    /* identity_key falls back to IMMDevice::GetId and may change after driver/OS updates. */
    LazerAudioDeviceIdentityEndpointId = 0,
    /* identity_key is PKEY_AudioEndpoint_StableId when Windows exposes it. */
    LazerAudioDeviceIdentityStableId = 1,
} LazerAudioDeviceIdentityKind;

typedef enum LazerAudioDeviceDefaultRole {
    LazerAudioDeviceDefaultRoleConsole = 1u << 0,
    LazerAudioDeviceDefaultRoleMultimedia = 1u << 1,
    LazerAudioDeviceDefaultRoleCommunications = 1u << 2,
} LazerAudioDeviceDefaultRole;

typedef enum LazerAudioEndpointState {
    LazerAudioEndpointStateActive = 0x00000001,
    LazerAudioEndpointStateDisabled = 0x00000002,
    LazerAudioEndpointStateNotPresent = 0x00000004,
    LazerAudioEndpointStateUnplugged = 0x00000008,
} LazerAudioEndpointState;

typedef struct LazerAudioDeviceInfo {
    /* Caller sets struct_size to sizeof(LazerAudioDeviceInfo); native code writes known fields. */
    uint32_t struct_size;
    /* DEVICE_STATE_* bitmask returned by IMMDevice::GetState. */
    uint32_t endpoint_state;
    /* Bitwise combination of LazerAudioDeviceDefaultRole values. */
    uint32_t default_role_mask;
    uint32_t identity_kind;
    /* HRESULT from IAudioEndpointVolume::QueryHardwareSupport, or the activation HRESULT.
     * For inactive/unqueried endpoints this is a non-success HRESULT (E_NOTIMPL). */
    int32_t endpoint_volume_query_hresult;
    /* ENDPOINT_HARDWARE_SUPPORT_* flags from IAudioEndpointVolume::QueryHardwareSupport.
     * Valid only when endpoint_volume_query_hresult succeeded. These describe Windows endpoint
     * support; they do not imply USB UAC Feature Unit access or prove DAC/analog behavior. */
    uint32_t endpoint_volume_hardware_support_flags;
} LazerAudioDeviceInfo;

/* One PCM layout to test against a Windows render endpoint. This describes the
 * WAVEFORMATEXTENSIBLE container width and valid sample bits separately. Only candidates with
 * 1-8 channels, 8/16/24/32-bit containers, a nonzero sample rate and 1..container_bits valid bits
 * are accepted. */
typedef struct LazerAudioPcmFormatCandidate {
    uint32_t sample_rate;
    uint16_t channels;
    uint16_t container_bits;
    uint16_t valid_bits;
    uint16_t reserved;
} LazerAudioPcmFormatCandidate;

typedef enum LazerAudioPcmFormatProbeStatus {
    LazerAudioPcmFormatProbeSupported = 0,
    LazerAudioPcmFormatProbeUnsupported = 1,
    LazerAudioPcmFormatProbeError = 2,
} LazerAudioPcmFormatProbeStatus;

typedef struct LazerAudioPcmFormatProbeResult {
    /* Per-candidate LazerAudioPcmFormatProbeStatus. */
    int32_t status;
    /* The raw HRESULT returned by IAudioClient::IsFormatSupported. */
    int32_t native_status;
} LazerAudioPcmFormatProbeResult;

LAZER_AUDIO_API int32_t LAZER_AUDIO_CALL lazer_audio_abi_version(void);

LAZER_AUDIO_API LazerAudioEngine LAZER_AUDIO_CALL lazer_audio_create(
    const LazerAudioEngineConfig *config);

LAZER_AUDIO_API void LAZER_AUDIO_CALL lazer_audio_destroy(LazerAudioEngine engine);

/* Where the engine starts reading and what the caller already believes about the track. Metadata
 * duration is a hint only: the engine prefers the container's own duration and falls back to it for
 * streams that report nothing. */
typedef struct LazerAudioOpenParams {
    uint32_t struct_size;
    int64_t start_millis;
    int64_t duration_hint_millis;
    /* Optional CUE segment in 1/75-second frames. (0, 0) means the whole source; an end of -1
     * selects physical EOF. Segment playback currently supports lossless PCM WAV and FLAC. */
    int64_t cue_start_frame75;
    int64_t cue_end_frame75;
    /* Per-source ReplayGain applied before the shared EQ/limiter chain. Valid range is -60..24 dB;
     * zero leaves the source unchanged. A non-zero value is incompatible with bit-perfect or DoP. */
    double replay_gain_db;
} LazerAudioOpenParams;

/* Exactly one of the two open paths may be active; opening again closes the previous stream. */
LAZER_AUDIO_API int32_t LAZER_AUDIO_CALL lazer_audio_open_file(
    LazerAudioEngine engine, const wchar_t *path, const LazerAudioOpenParams *params);
/* UTF-8 path entry point for non-Windows hosts and cross-platform callers. */
LAZER_AUDIO_API int32_t LAZER_AUDIO_CALL lazer_audio_open_file_utf8(
    LazerAudioEngine engine, const char *path_utf8, const LazerAudioOpenParams *params);

/* Open a caller-owned reader. Blocking read/seek/length callbacks must be interruptible through
 * `cancel`; reader context remains owned by the caller until stop/replacement and close callback. */
LAZER_AUDIO_API int32_t LAZER_AUDIO_CALL lazer_audio_open_reader(
    LazerAudioEngine engine, const LazerAudioReader *reader, const LazerAudioOpenParams *params);

LAZER_AUDIO_API int32_t LAZER_AUDIO_CALL lazer_audio_play(LazerAudioEngine engine);

LAZER_AUDIO_API int32_t LAZER_AUDIO_CALL lazer_audio_pause(LazerAudioEngine engine);

LAZER_AUDIO_API int32_t LAZER_AUDIO_CALL lazer_audio_stop(LazerAudioEngine engine);

LAZER_AUDIO_API int32_t LAZER_AUDIO_CALL lazer_audio_seek(
    LazerAudioEngine engine, int64_t position_millis);

LAZER_AUDIO_API int32_t LAZER_AUDIO_CALL lazer_audio_set_volume(
    LazerAudioEngine engine, double volume);

LAZER_AUDIO_API int32_t LAZER_AUDIO_CALL lazer_audio_set_dsp(
    LazerAudioEngine engine, const LazerAudioDspConfig *dsp);

LAZER_AUDIO_API int32_t LAZER_AUDIO_CALL lazer_audio_set_device(
    LazerAudioEngine engine, const LazerAudioDeviceConfig *device);

LAZER_AUDIO_API int32_t LAZER_AUDIO_CALL lazer_audio_snapshot(
    LazerAudioEngine engine, LazerAudioSnapshot *out);

LAZER_AUDIO_API int32_t LAZER_AUDIO_CALL lazer_audio_stream_info(
    LazerAudioEngine engine, LazerAudioStreamInfo *out);

/* Human-readable text for the last failure, safe to show after a Failed event. */
LAZER_AUDIO_API const char *LAZER_AUDIO_CALL lazer_audio_last_error(LazerAudioEngine engine);

/* Static FFmpeg build facts for the diagnostics panel; the pointer is owned by the engine. */
LAZER_AUDIO_API const char *LAZER_AUDIO_CALL lazer_audio_build_information(void);

/* Enumerate an immutable snapshot of render endpoints. The endpoint_id returned for an entry is
 * always the current IMMDevice::GetId value accepted by lazer_audio_set_device. Persist identity_key
 * if desired and resolve it against a fresh snapshot after restart. Required character counts
 * include the terminating NUL. Pass NULL/zero-capacity string buffers to query the required sizes;
 * get returns LazerAudioErrorBufferTooSmall until all three buffers are large enough. */
LAZER_AUDIO_API int32_t LAZER_AUDIO_CALL lazer_audio_device_catalog_create(
    LazerAudioDeviceCatalog *out_catalog);

LAZER_AUDIO_API int32_t LAZER_AUDIO_CALL lazer_audio_device_catalog_count(
    LazerAudioDeviceCatalog catalog, uint32_t *out_count);

LAZER_AUDIO_API int32_t LAZER_AUDIO_CALL lazer_audio_device_catalog_get(
    LazerAudioDeviceCatalog catalog,
    uint32_t index,
    LazerAudioDeviceInfo *out_info,
    wchar_t *endpoint_id,
    uint32_t endpoint_id_capacity,
    uint32_t *out_endpoint_id_chars,
    wchar_t *identity_key,
    uint32_t identity_key_capacity,
    uint32_t *out_identity_key_chars,
    wchar_t *friendly_name,
    uint32_t friendly_name_capacity,
    uint32_t *out_friendly_name_chars);

LAZER_AUDIO_API void LAZER_AUDIO_CALL lazer_audio_device_catalog_destroy(
    LazerAudioDeviceCatalog catalog);

/* Query candidate PCM layouts against the endpoint using AUDCLNT_SHAREMODE_EXCLUSIVE and an exact
 * WAVEFORMATEXTENSIBLE PCM format. The endpoint must be the current IMMDevice::GetId value. No
 * stream is initialized or started. S_OK means only that this endpoint's IAudioClient accepted
 * the exact format query; it does not prove a successful playback session or the physical DAC's
 * resulting format. AUDCLNT_E_UNSUPPORTED_FORMAT means unsupported. Other per-candidate HRESULTs
 * are returned as Error with the raw HRESULT in native_status. The function-level return reports
 * invalid arguments, COM/endpoint/activation failures, or allocation failure. */
LAZER_AUDIO_API int32_t LAZER_AUDIO_CALL lazer_audio_device_probe_pcm_formats(
    const wchar_t *endpoint_id,
    const LazerAudioPcmFormatCandidate *candidates,
    uint32_t candidate_count,
    LazerAudioPcmFormatProbeResult *out_results);

/* Get or set Windows' master volume for the exact render endpoint identified by its current
 * IMMDevice::GetId value. These calls use IAudioEndpointVolume only and never use engine software
 * gain or direct USB control transfers. They require ENDPOINT_HARDWARE_SUPPORT_VOLUME; otherwise
 * they return LazerAudioErrorUnsupported without falling back to software volume. The endpoint
 * master volume may affect other applications using that endpoint. A hardware support flag is not
 * proof of direct USB UAC Feature Unit/SET_CUR access or of the DAC's analog behavior.
 *
 * out_hardware_flags is from QueryHardwareSupport. out_hresult preserves the activation,
 * QueryHardwareSupport, or volume-operation HRESULT most relevant to the result. On a successful
 * support query with no hardware-volume flag, out_hresult is still a successful HRESULT while the
 * function returns LazerAudioErrorUnsupported. */
LAZER_AUDIO_API int32_t LAZER_AUDIO_CALL lazer_audio_endpoint_volume_get(
    const wchar_t *endpoint_id,
    float *out_scalar,
    uint32_t *out_hardware_flags,
    int32_t *out_hresult);

LAZER_AUDIO_API int32_t LAZER_AUDIO_CALL lazer_audio_endpoint_volume_set(
    const wchar_t *endpoint_id,
    float scalar,
    uint32_t *out_hardware_flags,
    int32_t *out_hresult);

/* UTF-8 local output device snapshot. Linux lists only ALSA hardware playback PCMs (hw:), never
 * ALSA plugin routes; macOS lists CoreAudio output devices by stable device UID. `active` means
 * the device was available when the snapshot was built, not that it can still be opened or that
 * Hog Mode is available. `default` marks the OS default output where the platform has one. Device
 * tokens are suitable for LazerAudioDeviceConfig.device_id after UTF-8 to wide conversion. */
typedef struct LazerAudioOutputDeviceCatalogT *LazerAudioOutputDeviceCatalog;

typedef enum LazerAudioOutputDeviceFlags {
    LazerAudioOutputDeviceFlagActive = 1u << 0,
    LazerAudioOutputDeviceFlagDefault = 1u << 1,
    /* The ALSA card ID was unavailable, so identity_key uses the volatile card index. */
    LazerAudioOutputDeviceFlagIdentityEphemeral = 1u << 2,
} LazerAudioOutputDeviceFlags;

typedef struct LazerAudioOutputDeviceInfo {
    /* Caller sets struct_size to sizeof(LazerAudioOutputDeviceInfo). */
    uint32_t struct_size;
    uint32_t flags;
} LazerAudioOutputDeviceInfo;

LAZER_AUDIO_API int32_t LAZER_AUDIO_CALL lazer_audio_output_device_catalog_create(
    LazerAudioOutputDeviceCatalog *out_catalog);

LAZER_AUDIO_API int32_t LAZER_AUDIO_CALL lazer_audio_output_device_catalog_count(
    LazerAudioOutputDeviceCatalog catalog, uint32_t *out_count);

/* Required byte counts include the terminating NUL. Pass NULL/zero-capacity buffers to query
 * lengths; get reports all required byte counts and returns BufferTooSmall unless every string
 * buffer fits. Strings are UTF-8. Linux ALSA tokens use hw:CARD=<id>,DEV=<n> and stable identity
 * keys based on card ID and PCM number; macOS tokens are CoreAudio device UIDs and identity keys
 * have the form coreaudio:uid:<UID>. */
LAZER_AUDIO_API int32_t LAZER_AUDIO_CALL lazer_audio_output_device_catalog_get(
    LazerAudioOutputDeviceCatalog catalog,
    uint32_t index,
    LazerAudioOutputDeviceInfo *out_info,
    char *device_token_utf8,
    uint32_t device_token_capacity,
    uint32_t *out_device_token_bytes,
    char *identity_key_utf8,
    uint32_t identity_key_capacity,
    uint32_t *out_identity_key_bytes,
    char *display_name_utf8,
    uint32_t display_name_capacity,
    uint32_t *out_display_name_bytes);

LAZER_AUDIO_API void LAZER_AUDIO_CALL lazer_audio_output_device_catalog_destroy(
    LazerAudioOutputDeviceCatalog catalog);

/* Prepare one successor reader for the current output session. queue_generation must increase
 * monotonically for each queue/cancel request and rejects late in-flight requests. The engine decodes it using the
 * already-negotiated output format and appends its PCM to the current session when the active source
 * ends. Its sample rate must match the active source; a different-rate track must reopen and
 * renegotiate output. Only one successor may be queued at a time. In bit-perfect mode it must exactly
 * match the active session's PCM format. Once opened, the engine decodes it on a background worker
 * into a bounded PCM prebuffer. A blocking reader must supply `cancel`; it may run concurrently with
 * `read`, `seek` or `length` and must wake them without freeing `context`. The `close` callback runs
 * after their calls have ended. The reader and callback context must stay alive until a
 * TrackChanged/Ended event or until the session is stopped/replaced. A false return (error code)
 * means the caller should use the normal stop/open path. This call can read the source while opening;
 * callers must invoke it away from the render/UI thread. */
LAZER_AUDIO_API int32_t LAZER_AUDIO_CALL lazer_audio_queue_reader(
    LazerAudioEngine engine,
    uint64_t queue_generation,
    const LazerAudioReader *reader,
    const LazerAudioOpenParams *params);

/* Cancel a prepared successor using a newer queue_generation. Returns QueueAlreadyActive if it has
 * already crossed the output boundary, State if no successor is installed, or Ok after clearing an
 * installed successor. In-flight preparation is invalidated too; its cancel callback wakes a
 * blocked probe or decoder read. The caller must retain the reader context until queue_reader returns. */
LAZER_AUDIO_API int32_t LAZER_AUDIO_CALL lazer_audio_clear_queued_reader(
    LazerAudioEngine engine, uint64_t queue_generation);

/* Optional additive ABI extension. Polls an owned copy of one warning/error.
 * Unlike on_log, the text remains valid after this call until the caller changes
 * its own buffer. Returns bytes including NUL, zero if empty, or a negative
 * error. BufferTooSmall leaves the entry queued. A 2048-byte buffer always fits.
 * Bounded to the last 128 entries. Older libraries may omit this export. */
LAZER_AUDIO_API int32_t LAZER_AUDIO_CALL lazer_audio_read_log(
    LazerAudioEngine engine, int32_t *out_level, char *message, uint32_t capacity);

#ifdef __cplusplus
}
#endif

#endif /* LAZER_AUDIO_API_H */
