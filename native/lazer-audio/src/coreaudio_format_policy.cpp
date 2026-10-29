#include "coreaudio_format_policy.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <tuple>

namespace lazer::audio {
namespace {

struct NormalizedTarget {
    int32_t sampleRateHz = 0;
    int32_t channels = 0;
    CoreAudioPcmEncoding encoding = CoreAudioPcmEncoding::Unsupported;
    int32_t bitsPerSample = 0;
    int32_t containerBitsPerSample = 0;
};

struct Candidate {
    CoreAudioPcmEndpointTuple endpoint{};
    uint32_t conversionReasons = CoreAudioPcmConversionNone;
    bool exactTuple = false;
    uint64_t score = std::numeric_limits<uint64_t>::max();
};

bool isValidRange(const CoreAudioSampleRateRange &range) noexcept {
    return std::isfinite(range.minimumHz) && std::isfinite(range.maximumHz) &&
        range.minimumHz > 0.0 && range.maximumHz >= range.minimumHz &&
        range.maximumHz <= static_cast<double>(std::numeric_limits<int32_t>::max());
}

bool contains(const CoreAudioSampleRateRange &range, int32_t rateHz) noexcept {
    return isValidRange(range) && static_cast<double>(rateHz) >= range.minimumHz &&
        static_cast<double>(rateHz) <= range.maximumHz;
}

bool intersect(const CoreAudioSampleRateRange &left, const CoreAudioSampleRateRange &right,
    CoreAudioSampleRateRange &result) noexcept {
    if (!isValidRange(left) || !isValidRange(right)) return false;
    result.minimumHz = std::max(left.minimumHz, right.minimumHz);
    result.maximumHz = std::min(left.maximumHz, right.maximumHz);
    return result.maximumHz >= result.minimumHz &&
        std::ceil(result.minimumHz) <= std::floor(result.maximumHz);
}

bool normalizeTarget(const TargetFormat &target, NormalizedTarget &normalized,
    CoreAudioPcmDecisionReason &reason) noexcept {
    if (target.doP) {
        reason = CoreAudioPcmDecisionReason::DoPIsNotPcm;
        return false;
    }
    if (target.sampleRate <= 0 || (target.channels != 1 && target.channels != 2)) {
        reason = CoreAudioPcmDecisionReason::InvalidTarget;
        return false;
    }

    normalized.sampleRateHz = target.sampleRate;
    normalized.channels = target.channels;
    if (target.bitsPerSample == 0) {
        const int32_t containerBits = target.containerBitsPerSample == 0
            ? 32 : target.containerBitsPerSample;
        if (containerBits != 32) {
            reason = CoreAudioPcmDecisionReason::UnsupportedTargetPcm;
            return false;
        }
        normalized.encoding = CoreAudioPcmEncoding::Float32;
        normalized.bitsPerSample = 0;
        normalized.containerBitsPerSample = 32;
        return true;
    }

    if (target.bitsPerSample != 16 && target.bitsPerSample != 24 &&
        target.bitsPerSample != 32) {
        reason = CoreAudioPcmDecisionReason::UnsupportedTargetPcm;
        return false;
    }
    const int32_t containerBits = target.containerBitsPerSample == 0
        ? target.bitsPerSample : target.containerBitsPerSample;
    if ((containerBits != 16 && containerBits != 24 && containerBits != 32) ||
        containerBits < target.bitsPerSample) {
        reason = CoreAudioPcmDecisionReason::UnsupportedTargetPcm;
        return false;
    }
    normalized.encoding = CoreAudioPcmEncoding::SignedInteger;
    normalized.bitsPerSample = target.bitsPerSample;
    normalized.containerBitsPerSample = containerBits;
    return true;
}

bool normalizeTuple(const CoreAudioPcmStreamTuple &tuple, int32_t &validBits,
    int32_t &containerBits) noexcept {
    if ((tuple.channels != 1 && tuple.channels != 2) ||
        !isValidRange(tuple.sampleRateRange)) return false;
    if (tuple.encoding == CoreAudioPcmEncoding::Float32) {
        if (tuple.bitsPerChannel != 32 || tuple.containerBitsPerSample != 32) return false;
        validBits = 32;
        containerBits = 32;
        return true;
    }
    if (tuple.encoding != CoreAudioPcmEncoding::SignedInteger ||
        (tuple.bitsPerChannel != 16 && tuple.bitsPerChannel != 24 &&
            tuple.bitsPerChannel != 32) ||
        (tuple.containerBitsPerSample != 16 && tuple.containerBitsPerSample != 24 &&
            tuple.containerBitsPerSample != 32) ||
        tuple.containerBitsPerSample < tuple.bitsPerChannel) return false;
    validBits = tuple.bitsPerChannel;
    containerBits = tuple.containerBitsPerSample;
    return true;
}

bool targetUsesPackedSamples(const NormalizedTarget &target) noexcept {
    /* convertIntegerPcm emits tightly packed frames only when there are no per-sample padding
     * bits. For integer precision below the container width it left-aligns samples and fills the
     * low padding bits with zero, which is an unpacked, aligned-high ASBD representation. */
    return target.encoding == CoreAudioPcmEncoding::Float32 ||
        target.bitsPerSample == target.containerBitsPerSample;
}

bool containsAny(const std::vector<CoreAudioSampleRateRange> &ranges, int32_t rateHz) noexcept {
    return std::any_of(ranges.begin(), ranges.end(), [rateHz](const auto &range) {
        return contains(range, rateHz);
    });
}

bool selectRate(const std::vector<CoreAudioSampleRateRange> &nominalRanges,
    const CoreAudioSampleRateRange &streamRange, int32_t requestedRate, int32_t &selectedRate,
    bool &requestedRateSupported) noexcept {
    bool found = false;
    uint64_t bestDistance = std::numeric_limits<uint64_t>::max();
    requestedRateSupported = false;
    for (const auto &nominalRange : nominalRanges) {
        CoreAudioSampleRateRange common{};
        if (!intersect(nominalRange, streamRange, common)) continue;
        if (contains(common, requestedRate)) {
            selectedRate = requestedRate;
            requestedRateSupported = true;
            return true;
        }

        const double nearestBoundary = std::clamp(static_cast<double>(requestedRate),
            common.minimumHz, common.maximumHz);
        const int64_t rounded = static_cast<int64_t>(std::llround(nearestBoundary));
        const int64_t first = static_cast<int64_t>(std::ceil(common.minimumHz));
        const int64_t last = static_cast<int64_t>(std::floor(common.maximumHz));
        if (first > last) continue;
        const int32_t candidateRate = static_cast<int32_t>(
            std::clamp(rounded, first, last));
        const uint64_t distance = candidateRate >= requestedRate
            ? static_cast<uint64_t>(candidateRate - requestedRate)
            : static_cast<uint64_t>(requestedRate - candidateRate);
        if (!found || distance < bestDistance ||
            (distance == bestDistance && candidateRate < selectedRate)) {
            found = true;
            bestDistance = distance;
            selectedRate = candidateRate;
        }
    }
    return found;
}

uint32_t conversionReasonsFor(const NormalizedTarget &target,
    const CoreAudioPcmEndpointTuple &endpoint) noexcept {
    uint32_t reasons = CoreAudioPcmConversionNone;
    if (endpoint.sampleRateHz != target.sampleRateHz) {
        reasons |= CoreAudioPcmConversionSampleRate;
    }
    if (endpoint.channels != target.channels) {
        reasons |= CoreAudioPcmConversionChannelCount;
    }
    if (endpoint.bitsPerSample == 0 && target.encoding != CoreAudioPcmEncoding::Float32) {
        reasons |= CoreAudioPcmConversionSampleEncoding;
    } else if (endpoint.bitsPerSample != 0 &&
        target.encoding != CoreAudioPcmEncoding::SignedInteger) {
        reasons |= CoreAudioPcmConversionSampleEncoding;
    }
    if (endpoint.bitsPerSample != target.bitsPerSample) {
        reasons |= CoreAudioPcmConversionValidBits;
    }
    if (endpoint.containerBitsPerSample != target.containerBitsPerSample) {
        reasons |= CoreAudioPcmConversionContainerWidth;
    }
    if (!endpoint.interleaved) reasons |= CoreAudioPcmConversionInterleaving;
    if (!endpoint.littleEndian) reasons |= CoreAudioPcmConversionEndianness;
    if (endpoint.packed != targetUsesPackedSamples(target)) {
        reasons |= CoreAudioPcmConversionPacking;
    }
    if (target.encoding == CoreAudioPcmEncoding::SignedInteger &&
        target.bitsPerSample < target.containerBitsPerSample && !endpoint.alignedHigh) {
        reasons |= CoreAudioPcmConversionSampleAlignment;
    }
    return reasons;
}

uint64_t candidateScore(const NormalizedTarget &target,
    const CoreAudioPcmEndpointTuple &endpoint) noexcept {
    /* Prefer keeping the sample clock, then channel count, encoding/precision/storage and layout.
     * This order is deterministic and favors avoiding SRC when a supported tuple permits it. */
    const uint64_t rateDistance = endpoint.sampleRateHz >= target.sampleRateHz
        ? static_cast<uint64_t>(endpoint.sampleRateHz - target.sampleRateHz)
        : static_cast<uint64_t>(target.sampleRateHz - endpoint.sampleRateHz);
    uint64_t score = rateDistance * 1'000'000'000ULL;
    if (endpoint.channels != target.channels) score += 100'000'000ULL;
    const bool endpointFloat = endpoint.bitsPerSample == 0;
    const bool targetFloat = target.encoding == CoreAudioPcmEncoding::Float32;
    if (endpointFloat != targetFloat) score += 10'000'000ULL;
    score += static_cast<uint64_t>(std::abs(endpoint.bitsPerSample - target.bitsPerSample)) * 100'000ULL;
    score += static_cast<uint64_t>(std::abs(
        endpoint.containerBitsPerSample - target.containerBitsPerSample)) * 1'000ULL;
    if (!endpoint.interleaved) score += 100ULL;
    if (!endpoint.littleEndian) score += 50ULL;
    if (endpoint.packed != targetUsesPackedSamples(target)) score += 25ULL;
    if (target.encoding == CoreAudioPcmEncoding::SignedInteger &&
        target.bitsPerSample < target.containerBitsPerSample && !endpoint.alignedHigh) {
        score += 10ULL;
    }
    return score;
}

CoreAudioPcmDecision rejected(CoreAudioPcmDecisionReason reason) noexcept {
    CoreAudioPcmDecision decision{};
    decision.kind = CoreAudioPcmDecisionKind::Rejected;
    decision.reason = reason;
    return decision;
}

CoreAudioPcmDecisionReason hogFailureReason(CoreAudioHogOwnership ownership) noexcept {
    switch (ownership) {
        case CoreAudioHogOwnership::OwnedByAnotherProcess:
            return CoreAudioPcmDecisionReason::HogOwnedByAnotherProcess;
        case CoreAudioHogOwnership::Unsupported:
            return CoreAudioPcmDecisionReason::HogModeUnavailable;
        case CoreAudioHogOwnership::Unknown:
            return CoreAudioPcmDecisionReason::HogOwnershipUnknown;
        case CoreAudioHogOwnership::OwnedByCurrentProcess:
            break;
    }
    return CoreAudioPcmDecisionReason::None;
}

}  // namespace

CoreAudioPcmEncoding coreAudioPcmEncodingFromFlags(bool isFloat,
    bool isSignedInteger) noexcept {
    if (isFloat == isSignedInteger) return CoreAudioPcmEncoding::Unsupported;
    return isFloat ? CoreAudioPcmEncoding::Float32 : CoreAudioPcmEncoding::SignedInteger;
}

bool coreAudioStreamFormatMayRestore(const CoreAudioStreamFormatSnapshot &current,
    const CoreAudioStreamFormatSnapshot &selected, bool nominalRateWasRestored,
    double restoredNominalRateHz) noexcept {
    if (current.formatId != selected.formatId || current.formatFlags != selected.formatFlags ||
        current.bytesPerPacket != selected.bytesPerPacket ||
        current.framesPerPacket != selected.framesPerPacket ||
        current.bytesPerFrame != selected.bytesPerFrame ||
        current.channelsPerFrame != selected.channelsPerFrame ||
        current.bitsPerChannel != selected.bitsPerChannel ||
        current.reserved != selected.reserved || !std::isfinite(current.sampleRateHz) ||
        !std::isfinite(selected.sampleRateHz)) {
        return false;
    }
    if (std::abs(current.sampleRateHz - selected.sampleRateHz) < 0.5) return true;
    return nominalRateWasRestored && std::isfinite(restoredNominalRateHz) &&
        std::abs(current.sampleRateHz - restoredNominalRateHz) < 0.5;
}

CoreAudioPcmDecision negotiateCoreAudioPcmFormat(const TargetFormat &target,
    const CoreAudioHalPcmCapabilities &capabilities, bool exclusiveRequested,
    bool bitPerfectRequested) noexcept {
    NormalizedTarget normalized{};
    CoreAudioPcmDecisionReason targetError = CoreAudioPcmDecisionReason::None;
    if (!normalizeTarget(target, normalized, targetError)) return rejected(targetError);

    if (bitPerfectRequested) {
        if (!exclusiveRequested) {
            return rejected(CoreAudioPcmDecisionReason::BitPerfectRequiresHogMode);
        }
        const CoreAudioPcmDecisionReason hogReason =
            hogFailureReason(capabilities.hogOwnership);
        if (hogReason != CoreAudioPcmDecisionReason::None) return rejected(hogReason);
    }

    if (!capabilities.nominalSampleRateRangesKnown || !capabilities.streamTuplesKnown) {
        return rejected(CoreAudioPcmDecisionReason::UnknownHalCapabilities);
    }
    if (capabilities.nominalSampleRateRanges.empty() || capabilities.streamTuples.empty()) {
        return rejected(CoreAudioPcmDecisionReason::NoUsablePcmTuple);
    }

    Candidate best{};
    bool sawValidTuple = false;
    bool sawRateIntersection = false;
    for (const auto &tuple : capabilities.streamTuples) {
        int32_t tupleBits = 0;
        int32_t tupleContainerBits = 0;
        if (!normalizeTuple(tuple, tupleBits, tupleContainerBits)) continue;
        sawValidTuple = true;

        int32_t selectedRate = 0;
        bool requestedRateSupported = false;
        if (!selectRate(capabilities.nominalSampleRateRanges, tuple.sampleRateRange,
                normalized.sampleRateHz, selectedRate, requestedRateSupported)) continue;
        sawRateIntersection = true;

        CoreAudioPcmEndpointTuple endpoint{};
        endpoint.sampleRateHz = selectedRate;
        endpoint.channels = tuple.channels;
        endpoint.bitsPerSample = tuple.encoding == CoreAudioPcmEncoding::Float32
            ? 0 : tupleBits;
        endpoint.containerBitsPerSample = tupleContainerBits;
        endpoint.interleaved = tuple.interleaved;
        endpoint.littleEndian = tuple.littleEndian;
        endpoint.packed = tuple.packed;
        endpoint.alignedHigh = tuple.alignedHigh;
        endpoint.nonMixable = tuple.nonMixable;

        uint32_t conversionReasons = conversionReasonsFor(normalized, endpoint);
        const bool exactEncoding = tuple.encoding == normalized.encoding;
        const bool exactTuple = requestedRateSupported && tuple.channels == normalized.channels &&
            exactEncoding && endpoint.bitsPerSample == normalized.bitsPerSample &&
            tupleContainerBits == normalized.containerBitsPerSample && tuple.interleaved &&
            tuple.littleEndian && tuple.packed == targetUsesPackedSamples(normalized) &&
            (normalized.encoding != CoreAudioPcmEncoding::SignedInteger ||
                normalized.bitsPerSample == normalized.containerBitsPerSample || tuple.alignedHigh);

        if (exactTuple && (!exclusiveRequested || capabilities.hogOwnership ==
                CoreAudioHogOwnership::OwnedByCurrentProcess)) {
            CoreAudioPcmDecision decision{};
            decision.kind = CoreAudioPcmDecisionKind::ExactPcmTuple;
            decision.reason = CoreAudioPcmDecisionReason::None;
            decision.endpoint = endpoint;
            return decision;
        }

        const uint64_t score = candidateScore(normalized, endpoint);
        if (score < best.score) {
            best.endpoint = endpoint;
            best.conversionReasons = conversionReasons;
            best.exactTuple = false;
            best.score = score;
        }
    }

    if (bitPerfectRequested) return rejected(CoreAudioPcmDecisionReason::NoExactTuple);
    if (!sawValidTuple) return rejected(CoreAudioPcmDecisionReason::NoUsablePcmTuple);
    if (!sawRateIntersection) return rejected(CoreAudioPcmDecisionReason::NoSampleRateIntersection);
    if (best.score == std::numeric_limits<uint64_t>::max()) {
        return rejected(CoreAudioPcmDecisionReason::NoUsablePcmTuple);
    }

    if (exclusiveRequested && capabilities.hogOwnership !=
            CoreAudioHogOwnership::OwnedByCurrentProcess) {
        best.conversionReasons |= CoreAudioPcmConversionSharedModeFallback;
    }
    CoreAudioPcmDecision decision{};
    decision.kind = CoreAudioPcmDecisionKind::ConversionCandidate;
    decision.reason = CoreAudioPcmDecisionReason::NoExactTuple;
    if (exclusiveRequested && capabilities.hogOwnership !=
            CoreAudioHogOwnership::OwnedByCurrentProcess) {
        decision.reason = hogFailureReason(capabilities.hogOwnership);
    }
    decision.conversionReasons = best.conversionReasons;
    decision.endpoint = best.endpoint;
    return decision;
}

CoreAudioDoPDecision negotiateCoreAudioDoPFormat(const TargetFormat &target,
    const CoreAudioHalPcmCapabilities &capabilities, bool exclusiveRequested) noexcept {
    const auto reject = [](CoreAudioDoPDecisionReason reason) {
        CoreAudioDoPDecision decision{};
        decision.reason = reason;
        return decision;
    };
    if (!target.doP || target.sampleRate <= 0 || (target.channels != 1 && target.channels != 2) ||
        target.bitsPerSample != 24 || target.containerBitsPerSample != 24) {
        return reject(CoreAudioDoPDecisionReason::InvalidTarget);
    }
    if (!exclusiveRequested) return reject(CoreAudioDoPDecisionReason::ExclusiveModeRequired);
    switch (capabilities.hogOwnership) {
        case CoreAudioHogOwnership::OwnedByCurrentProcess:
            break;
        case CoreAudioHogOwnership::OwnedByAnotherProcess:
            return reject(CoreAudioDoPDecisionReason::HogOwnedByAnotherProcess);
        case CoreAudioHogOwnership::Unsupported:
            return reject(CoreAudioDoPDecisionReason::HogModeUnavailable);
        case CoreAudioHogOwnership::Unknown:
            return reject(CoreAudioDoPDecisionReason::HogOwnershipUnknown);
    }
    if (!capabilities.nominalSampleRateRangesKnown || !capabilities.streamTuplesKnown) {
        return reject(CoreAudioDoPDecisionReason::UnknownHalCapabilities);
    }
    if (capabilities.nominalSampleRateRanges.empty() || capabilities.streamTuples.empty()) {
        return reject(CoreAudioDoPDecisionReason::NoUsableCarrierTuple);
    }

    const bool nominalRateSupported = containsAny(capabilities.nominalSampleRateRanges,
        target.sampleRate);
    if (!nominalRateSupported) return reject(CoreAudioDoPDecisionReason::NoExactCarrierTuple);

    bool sawUsableTuple = false;
    for (const auto &tuple : capabilities.streamTuples) {
        int32_t validBits = 0;
        int32_t containerBits = 0;
        if (!normalizeTuple(tuple, validBits, containerBits)) continue;
        sawUsableTuple = true;
        if (tuple.encoding != CoreAudioPcmEncoding::SignedInteger ||
            tuple.channels != target.channels || validBits != 24 || containerBits != 24 ||
            !tuple.interleaved || !tuple.littleEndian || !tuple.packed ||
            !contains(tuple.sampleRateRange, target.sampleRate)) {
            continue;
        }

        CoreAudioDoPDecision decision{};
        decision.accepted = true;
        decision.reason = CoreAudioDoPDecisionReason::None;
        decision.endpoint.sampleRateHz = target.sampleRate;
        decision.endpoint.channels = target.channels;
        decision.endpoint.bitsPerSample = 24;
        decision.endpoint.containerBitsPerSample = 24;
        decision.endpoint.interleaved = true;
        decision.endpoint.littleEndian = true;
        decision.endpoint.packed = true;
        decision.endpoint.alignedHigh = tuple.alignedHigh;
        return decision;
    }
    return reject(sawUsableTuple
        ? CoreAudioDoPDecisionReason::NoExactCarrierTuple
        : CoreAudioDoPDecisionReason::NoUsableCarrierTuple);
}

}  // namespace lazer::audio
