/* Platform-neutral format negotiation policy for the future CoreAudio HAL output.
 * This file intentionally does not include Apple SDK headers: reported HAL capabilities are
 * normalized into plain PCM tuples so selection and fallback rules can be tested on every host. */
#ifndef LAZER_AUDIO_COREAUDIO_FORMAT_POLICY_H
#define LAZER_AUDIO_COREAUDIO_FORMAT_POLICY_H

#include <cstdint>
#include <vector>

#include "source.h"

namespace lazer::audio {

struct CoreAudioSampleRateRange {
    double minimumHz = 0.0;
    double maximumHz = 0.0;
};

enum class CoreAudioPcmEncoding : int32_t {
    SignedInteger = 0,
    Float32 = 1,
    Unsupported = 2,
};

/* ASBD PCM flags must describe exactly one supported sample encoding. */
CoreAudioPcmEncoding coreAudioPcmEncodingFromFlags(bool isFloat, bool isSignedInteger) noexcept;

/* Normalized from an AudioStreamRangedDescription. containerBitsPerSample is the storage width
 * inferred by the HAL adapter from bytes-per-frame; bitsPerChannel is the valid precision reported
 * by the stream. A non-interleaved stream reports the per-channel sample storage width. The last
 * layout flags preserve ASBD details needed to decide whether the engine's little-endian, packed,
 * high-aligned PCM bytes can be submitted unchanged. nonMixable is retained as HAL metadata; it is
 * not a PCM sample-layout or bit-perfect guarantee. */
struct CoreAudioPcmStreamTuple {
    CoreAudioSampleRateRange sampleRateRange{};
    int32_t channels = 0;
    CoreAudioPcmEncoding encoding = CoreAudioPcmEncoding::Unsupported;
    int32_t bitsPerChannel = 0;
    int32_t containerBitsPerSample = 0;
    bool interleaved = false;
    bool littleEndian = true;
    bool packed = true;
    bool alignedHigh = true;
    bool nonMixable = false;
};

enum class CoreAudioHogOwnership : int32_t {
    OwnedByCurrentProcess = 0,
    OwnedByAnotherProcess = 1,
    Unsupported = 2,
    Unknown = 3,
};

struct CoreAudioHalPcmCapabilities {
    /* `known` distinguishes an empty, authoritative HAL result from a property query failure.
     * Exclusive callers provide device nominal-rate ranges. Shared callers provide only the
     * current virtual-format rates, because they must not retime the shared device or stream. */
    bool nominalSampleRateRangesKnown = false;
    std::vector<CoreAudioSampleRateRange> nominalSampleRateRanges;
    bool streamTuplesKnown = false;
    std::vector<CoreAudioPcmStreamTuple> streamTuples;
    CoreAudioHogOwnership hogOwnership = CoreAudioHogOwnership::Unknown;
};

enum class CoreAudioPcmDecisionKind : int32_t {
    ExactPcmTuple = 0,
    ConversionCandidate = 1,
    Rejected = 2,
};

enum class CoreAudioPcmDecisionReason : int32_t {
    None = 0,
    InvalidTarget = 1,
    DoPIsNotPcm = 2,
    UnsupportedTargetPcm = 3,
    UnknownHalCapabilities = 4,
    NoUsablePcmTuple = 5,
    NoSampleRateIntersection = 6,
    BitPerfectRequiresHogMode = 7,
    HogOwnedByAnotherProcess = 8,
    HogModeUnavailable = 9,
    HogOwnershipUnknown = 10,
    NoExactTuple = 11,
};

enum CoreAudioPcmConversion : uint32_t {
    CoreAudioPcmConversionNone = 0,
    CoreAudioPcmConversionSampleRate = 1u << 0,
    CoreAudioPcmConversionChannelCount = 1u << 1,
    CoreAudioPcmConversionSampleEncoding = 1u << 2,
    CoreAudioPcmConversionValidBits = 1u << 3,
    CoreAudioPcmConversionContainerWidth = 1u << 4,
    CoreAudioPcmConversionInterleaving = 1u << 5,
    CoreAudioPcmConversionSharedModeFallback = 1u << 6,
    CoreAudioPcmConversionEndianness = 1u << 7,
    CoreAudioPcmConversionPacking = 1u << 8,
    CoreAudioPcmConversionSampleAlignment = 1u << 9,
};

/* The selected endpoint tuple, with an integer sample rate chosen from the intersection of the
 * device's nominal-rate ranges and this stream format's range. `bitsPerSample == 0` denotes float32,
 * matching TargetFormat. These are negotiation facts, not DAC readback or bit-perfect verification. */
struct CoreAudioPcmEndpointTuple {
    int32_t sampleRateHz = 0;
    int32_t channels = 0;
    int32_t bitsPerSample = 0;
    int32_t containerBitsPerSample = 0;
    bool interleaved = false;
    bool littleEndian = true;
    bool packed = true;
    bool alignedHigh = true;
    bool nonMixable = false;
};

/* The subset of AudioStreamBasicDescription that must remain unchanged before restoring a
 * stream's original virtual format. Some HALs update only mSampleRate when the device nominal
 * rate is restored, so the caller may explicitly allow that field to match the restored rate. */
struct CoreAudioStreamFormatSnapshot {
    double sampleRateHz = 0.0;
    uint32_t formatId = 0;
    uint32_t formatFlags = 0;
    uint32_t bytesPerPacket = 0;
    uint32_t framesPerPacket = 0;
    uint32_t bytesPerFrame = 0;
    uint32_t channelsPerFrame = 0;
    uint32_t bitsPerChannel = 0;
    uint32_t reserved = 0;
};

bool coreAudioStreamFormatMayRestore(const CoreAudioStreamFormatSnapshot &current,
    const CoreAudioStreamFormatSnapshot &selected, bool nominalRateWasRestored,
    double restoredNominalRateHz) noexcept;

struct CoreAudioPcmDecision {
    CoreAudioPcmDecisionKind kind = CoreAudioPcmDecisionKind::Rejected;
    CoreAudioPcmDecisionReason reason = CoreAudioPcmDecisionReason::NoUsablePcmTuple;
    uint32_t conversionReasons = CoreAudioPcmConversionNone;
    CoreAudioPcmEndpointTuple endpoint{};

    [[nodiscard]] bool accepted() const noexcept {
        return kind != CoreAudioPcmDecisionKind::Rejected;
    }
};

enum class CoreAudioDoPDecisionReason : int32_t {
    None = 0,
    InvalidTarget = 1,
    ExclusiveModeRequired = 2,
    HogOwnedByAnotherProcess = 3,
    HogModeUnavailable = 4,
    HogOwnershipUnknown = 5,
    UnknownHalCapabilities = 6,
    NoUsableCarrierTuple = 7,
    NoExactCarrierTuple = 8,
};

/* DoP is an encoded payload carried in PCM24 words. It can only select an exact, packed,
 * little-endian interleaved tuple under confirmed Hog Mode ownership; it never has a conversion
 * candidate or shared-mode fallback. */
struct CoreAudioDoPDecision {
    bool accepted = false;
    CoreAudioDoPDecisionReason reason = CoreAudioDoPDecisionReason::NoUsableCarrierTuple;
    CoreAudioPcmEndpointTuple endpoint{};
};

/* `exclusiveRequested` means the caller wants CoreAudio Hog Mode. A bit-perfect request always
 * requires Hog Mode ownership and an exact tuple; neither a shared-mode fallback nor conversion is
 * ever returned as acceptable for bit-perfect playback. */
CoreAudioPcmDecision negotiateCoreAudioPcmFormat(const TargetFormat &target,
    const CoreAudioHalPcmCapabilities &capabilities, bool exclusiveRequested,
    bool bitPerfectRequested) noexcept;

CoreAudioDoPDecision negotiateCoreAudioDoPFormat(const TargetFormat &target,
    const CoreAudioHalPcmCapabilities &capabilities, bool exclusiveRequested) noexcept;

}  // namespace lazer::audio

#endif  // LAZER_AUDIO_COREAUDIO_FORMAT_POLICY_H
