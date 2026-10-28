/* Platform-independent candidate ordering for exclusive WASAPI PCM negotiation. */
#ifndef LAZER_AUDIO_WASAPI_PCM_FORMAT_POLICY_H
#define LAZER_AUDIO_WASAPI_PCM_FORMAT_POLICY_H

#include <cstdint>
#include <optional>
#include <vector>

namespace lazer::audio::wasapi {

enum class PcmCandidateTier {
    ExactSource,
    SameRateAlternate,
    MonoToStereo,
    MixFormat,
    CommonRate,
};

enum class PcmDescriptor {
    ExtensibleInteger,
    LegacyInteger,
    DeviceMix,
};

struct PcmSourceFormat {
    uint32_t sampleRate = 0;
    uint16_t channels = 0;
    uint16_t bitsPerSample = 0;
    bool lossless = false;
    bool integerPcm = false;
};

struct PcmMixFormat {
    uint32_t sampleRate = 0;
};

struct PcmCandidate {
    PcmCandidateTier tier = PcmCandidateTier::ExactSource;
    PcmDescriptor descriptor = PcmDescriptor::ExtensibleInteger;
    uint32_t sampleRate = 0;
    uint16_t channels = 0;
    uint16_t validBits = 0;
    uint16_t containerBits = 0;
};

enum class PcmCandidateResult {
    Accepted,
    FormatRejected,
    BufferSizeNotAligned,
    FatalFailure,
};

struct PcmCandidateSelection {
    std::optional<PcmCandidate> candidate;
    bool fatalFailure = false;
};

struct PcmCandidateInitializeOutcome {
    PcmCandidateResult result = PcmCandidateResult::FatalFailure;
    int64_t successfulBufferDurationHundredNanos = 0;
};

[[nodiscard]] std::vector<PcmCandidate> exclusivePcmCandidates(
    const PcmSourceFormat &source, const PcmMixFormat &mix, bool bitPerfect);

/* The injected predicates are normally IAudioClient::IsFormatSupported and Initialize. A candidate
 * is selected only after both accept it; explicit format rejection may continue, while any other
 * failure stops negotiation. */
template <typename IsFormatSupported, typename InitializeCandidate, typename PrepareNextClient>
[[nodiscard]] PcmCandidateSelection negotiateExclusivePcmCandidate(
    const PcmSourceFormat &source, const PcmMixFormat &mix, bool bitPerfect,
    IsFormatSupported &&isFormatSupported, InitializeCandidate &&initializeCandidate,
    PrepareNextClient &&prepareNextClient) {
    for (const PcmCandidate &candidate : exclusivePcmCandidates(source, mix, bitPerfect)) {
        const PcmCandidateResult supported = isFormatSupported(candidate);
        if (supported == PcmCandidateResult::FormatRejected) continue;
        if (supported != PcmCandidateResult::Accepted) return {std::nullopt, true};

        const PcmCandidateResult initialized = initializeCandidate(candidate);
        if (initialized == PcmCandidateResult::Accepted) return {candidate, false};
        if (initialized != PcmCandidateResult::FormatRejected || !prepareNextClient()) {
            return {std::nullopt, true};
        }
    }
    return {std::nullopt, false};
}

/* An unaligned exclusive initialization retries the same candidate on a fresh client, using the
 * frame-aligned duration. The callbacks are injected so this rule is testable without Windows. */
template <typename InitializeCandidate, typename GetAlignedBufferDuration,
    typename RecreateClient>
[[nodiscard]] PcmCandidateInitializeOutcome initializePcmCandidateWithAlignedRetry(
    const PcmCandidate &candidate, int64_t initialBufferDurationHundredNanos,
    InitializeCandidate &&initializeCandidate,
    GetAlignedBufferDuration &&getAlignedBufferDuration,
    RecreateClient &&recreateClient) {
    PcmCandidateResult result = initializeCandidate(candidate,
        initialBufferDurationHundredNanos);
    if (result != PcmCandidateResult::BufferSizeNotAligned) {
        return {result, result == PcmCandidateResult::Accepted
            ? initialBufferDurationHundredNanos : 0};
    }

    const std::optional<int64_t> alignedDuration = getAlignedBufferDuration(candidate);
    if (!alignedDuration || *alignedDuration <= 0 || !recreateClient()) {
        return {PcmCandidateResult::FatalFailure, 0};
    }

    result = initializeCandidate(candidate, *alignedDuration);
    if (result == PcmCandidateResult::BufferSizeNotAligned) {
        return {PcmCandidateResult::FatalFailure, 0};
    }
    return {result, result == PcmCandidateResult::Accepted ? *alignedDuration : 0};
}

}  // namespace lazer::audio::wasapi

#endif  // LAZER_AUDIO_WASAPI_PCM_FORMAT_POLICY_H
