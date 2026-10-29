#include "wasapi_pcm_format_policy.h"

#include <algorithm>
#include <array>
#include <cstdlib>
#include <vector>

namespace lazer::audio::wasapi {

namespace {

constexpr std::array<uint32_t, 10> kCommonRates{
    44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000, 705600, 768000
};

bool standardDepth(uint16_t depth) {
    return depth == 16 || depth == 24 || depth == 32;
}

std::array<uint16_t, 3> orderedDepths(uint16_t sourceBits) {
    if (standardDepth(sourceBits)) {
        return {sourceBits, static_cast<uint16_t>(sourceBits == 32 ? 24 : 32),
            static_cast<uint16_t>(sourceBits == 16 ? 24 : 16)};
    }
    return {32, 24, 16};
}

void appendExtensible(std::vector<PcmCandidate> &candidates, PcmCandidateTier tier,
    uint32_t rate, uint16_t channels, uint16_t validBits, uint16_t containerBits) {
    candidates.push_back(PcmCandidate{
        tier, PcmDescriptor::ExtensibleInteger, rate, channels, validBits, containerBits});
}

void appendLegacy16(std::vector<PcmCandidate> &candidates, PcmCandidateTier tier,
    uint32_t rate, uint16_t channels) {
    candidates.push_back(PcmCandidate{
        tier, PcmDescriptor::LegacyInteger, rate, channels, 16, 16});
}

void appendDepth(std::vector<PcmCandidate> &candidates, PcmCandidateTier tier,
    uint32_t rate, uint16_t channels, uint16_t depth) {
    appendExtensible(candidates, tier, rate, channels, depth, depth);
    if (depth == 24) appendExtensible(candidates, tier, rate, channels, depth, 32);
    if (depth == 16) appendLegacy16(candidates, tier, rate, channels);
}

std::vector<uint32_t> orderedFallbackRates(const PcmSourceFormat &source,
    const PcmMixFormat &mix) {
    std::vector<uint32_t> rates;
    const auto appendUnique = [&rates](uint32_t rate) {
        if (rate == 0 || std::find(rates.begin(), rates.end(), rate) != rates.end()) return;
        rates.push_back(rate);
    };

    appendUnique(mix.sampleRate);
    std::vector<uint32_t> common;
    for (const uint32_t rate : kCommonRates) {
        if (rate == source.sampleRate || rate == mix.sampleRate) continue;
        common.push_back(rate);
    }

    const bool sourceUses441Family = source.sampleRate % 44100 == 0;
    std::stable_sort(common.begin(), common.end(), [&](uint32_t left, uint32_t right) {
        const bool leftSameFamily = (left % 44100 == 0) == sourceUses441Family;
        const bool rightSameFamily = (right % 44100 == 0) == sourceUses441Family;
        if (leftSameFamily != rightSameFamily) return leftSameFamily;
        const uint64_t leftDistance = left > source.sampleRate
            ? static_cast<uint64_t>(left) - source.sampleRate
            : static_cast<uint64_t>(source.sampleRate) - left;
        const uint64_t rightDistance = right > source.sampleRate
            ? static_cast<uint64_t>(right) - source.sampleRate
            : static_cast<uint64_t>(source.sampleRate) - right;
        return leftDistance < rightDistance;
    });
    for (const uint32_t rate : common) appendUnique(rate);
    return rates;
}

}  // namespace

std::vector<PcmCandidate> exclusivePcmCandidates(const PcmSourceFormat &source,
    const PcmMixFormat &mix, bool bitPerfect) {
    std::vector<PcmCandidate> candidates;
    const bool monoOrStereo = source.channels == 1 || source.channels == 2;
    const bool validSourceFormat = source.sampleRate > 0 && monoOrStereo &&
        standardDepth(source.bitsPerSample);
    const bool exactSourceEligible = validSourceFormat && source.lossless && source.integerPcm;

    if (exactSourceEligible) {
        const auto sourceBits = source.bitsPerSample;
        appendExtensible(candidates, PcmCandidateTier::ExactSource, source.sampleRate,
            source.channels, sourceBits, sourceBits);
        if (sourceBits == 24) {
            /* Many DAC drivers expose 24 valid bits in a 32-bit physical container. */
            appendExtensible(candidates, PcmCandidateTier::ExactSource, source.sampleRate,
                source.channels, 24, 32);
        }
        if (sourceBits == 16) {
            /* Microsoft recommends trying both extensible and legacy PCM descriptors. */
            appendLegacy16(candidates, PcmCandidateTier::ExactSource,
                source.sampleRate, source.channels);
        }
    }

    if (bitPerfect) return candidates;

    if (source.sampleRate > 0 && monoOrStereo) {
        for (const uint16_t depth : orderedDepths(source.bitsPerSample)) {
            /* Exact source descriptors have already been tested; skip them in this fallback tier. */
            if (exactSourceEligible && depth == source.bitsPerSample) continue;
            appendDepth(candidates, PcmCandidateTier::SameRateAlternate, source.sampleRate,
                source.channels, depth);
        }
    }

    if (source.sampleRate > 0 && source.channels == 1) {
        for (const uint16_t depth : {uint16_t{32}, uint16_t{24}, uint16_t{16}}) {
            appendDepth(candidates, PcmCandidateTier::MonoToStereo, source.sampleRate, 2, depth);
        }
    }

    if (mix.sampleRate > 0) {
        candidates.push_back(PcmCandidate{
            PcmCandidateTier::MixFormat, PcmDescriptor::DeviceMix, mix.sampleRate, 0, 0, 0});
    }

    const auto depths = orderedDepths(source.bitsPerSample);
    for (const uint32_t rate : orderedFallbackRates(source, mix)) {
        for (const uint16_t depth : depths) {
            appendDepth(candidates, PcmCandidateTier::CommonRate, rate, 2, depth);
        }
    }
    return candidates;
}

}  // namespace lazer::audio::wasapi
