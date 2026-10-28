/* Deterministic tests for WASAPI PCM negotiation order; no Windows endpoint is required. */
#include <cstdio>
#include <vector>

#include "wasapi_pcm_format_policy.h"

using lazer::audio::wasapi::PcmCandidate;
using lazer::audio::wasapi::PcmCandidateInitializeOutcome;
using lazer::audio::wasapi::PcmCandidateResult;
using lazer::audio::wasapi::PcmCandidateTier;
using lazer::audio::wasapi::PcmDescriptor;
using lazer::audio::wasapi::PcmMixFormat;
using lazer::audio::wasapi::PcmSourceFormat;
using lazer::audio::wasapi::exclusivePcmCandidates;
using lazer::audio::wasapi::initializePcmCandidateWithAlignedRetry;
using lazer::audio::wasapi::negotiateExclusivePcmCandidate;

namespace {

bool fail(const char *message) {
    std::fprintf(stderr, "FAIL: %s\n", message);
    return false;
}

bool testStrictOnlyTriesExactSourceCandidates() {
    const PcmSourceFormat source{96000, 2, 24, true, true};
    const PcmMixFormat mix{48000};
    std::vector<PcmCandidate> supportTried;
    std::vector<PcmCandidate> initializeTried;
    const auto selection = negotiateExclusivePcmCandidate(source, mix, true,
        [&](const PcmCandidate &candidate) {
            supportTried.push_back(candidate);
            return PcmCandidateResult::Accepted;
        }, [&](const PcmCandidate &candidate) {
            initializeTried.push_back(candidate);
            return PcmCandidateResult::FormatRejected;
        }, [] { return true; });
    if (selection.candidate || selection.fatalFailure) {
        return fail("strict mode unexpectedly selected a rejected format or stopped fatally");
    }
    if (supportTried.size() != 2 || initializeTried.size() != 2) {
        return fail("strict mode did not initialize both exact 24-bit descriptors");
    }
    for (const auto &candidate : supportTried) {
        if (candidate.tier != PcmCandidateTier::ExactSource ||
            candidate.sampleRate != source.sampleRate || candidate.channels != source.channels ||
            candidate.validBits != 24) {
            return fail("strict mode tried a non-exact source format");
        }
    }
    return true;
}

bool testExactCandidatesPrecedeAlternateDepth() {
    const PcmSourceFormat source{44100, 2, 16, true, true};
    const PcmMixFormat mix{48000};
    std::vector<PcmCandidate> initialized;
    size_t freshClients = 0;
    const auto selection = negotiateExclusivePcmCandidate(source, mix, false,
        [](const PcmCandidate &) { return PcmCandidateResult::Accepted; },
        [&](const PcmCandidate &candidate) {
            initialized.push_back(candidate);
            return candidate.tier == PcmCandidateTier::SameRateAlternate
                ? PcmCandidateResult::Accepted : PcmCandidateResult::FormatRejected;
        }, [&] {
            ++freshClients;
            return true;
        });
    if (!selection.candidate || selection.fatalFailure ||
        selection.candidate->validBits != 32 ||
        selection.candidate->sampleRate != source.sampleRate) {
        return fail("same-rate alternate depth was not selected after exact candidates");
    }
    if (initialized.size() != 3 || initialized[0].tier != PcmCandidateTier::ExactSource ||
        initialized[1].descriptor != PcmDescriptor::LegacyInteger ||
        initialized[2].tier != PcmCandidateTier::SameRateAlternate || freshClients != 2) {
        return fail("initialize rejection did not advance through exact to alternate candidates");
    }
    return true;
}

bool testMonoToStereoPrecedesMixFormat() {
    const PcmSourceFormat source{44100, 1, 16, true, true};
    const PcmMixFormat mix{48000};
    std::vector<PcmCandidate> initialized;
    const auto selection = negotiateExclusivePcmCandidate(source, mix, false,
        [](const PcmCandidate &) { return PcmCandidateResult::Accepted; },
        [&](const PcmCandidate &candidate) {
            initialized.push_back(candidate);
            return candidate.tier == PcmCandidateTier::MonoToStereo
                ? PcmCandidateResult::Accepted : PcmCandidateResult::FormatRejected;
        }, [] { return true; });
    if (!selection.candidate || selection.candidate->channels != 2 ||
        selection.candidate->sampleRate != source.sampleRate) {
        return fail("mono-to-stereo candidate was not selected");
    }
    const auto candidates = exclusivePcmCandidates(source, mix, false);
    size_t firstMono = candidates.size();
    size_t firstMix = candidates.size();
    for (size_t index = 0; index < candidates.size(); ++index) {
        if (firstMono == candidates.size() && candidates[index].tier == PcmCandidateTier::MonoToStereo) {
            firstMono = index;
        }
        if (firstMix == candidates.size() && candidates[index].tier == PcmCandidateTier::MixFormat) {
            firstMix = index;
        }
    }
    if (firstMono == candidates.size() || firstMix <= firstMono ||
        candidates[firstMono].channels != 2) {
        return fail("mix-format fallback was tried before mono-to-stereo candidates");
    }
    return true;
}

bool testMixFormatPrecedesCommonRates() {
    const PcmSourceFormat source{96000, 2, 24, true, true};
    const PcmMixFormat mix{48000};
    std::vector<PcmCandidate> initialized;
    const auto selection = negotiateExclusivePcmCandidate(source, mix, false,
        [](const PcmCandidate &) { return PcmCandidateResult::Accepted; },
        [&](const PcmCandidate &candidate) {
            initialized.push_back(candidate);
            return candidate.tier == PcmCandidateTier::MixFormat
                ? PcmCandidateResult::Accepted : PcmCandidateResult::FormatRejected;
        }, [] { return true; });
    if (!selection.candidate || selection.candidate->descriptor != PcmDescriptor::DeviceMix) {
        return fail("mix-format fallback was not selected after source candidates");
    }
    const auto candidates = exclusivePcmCandidates(source, mix, false);
    if (initialized.size() >= candidates.size() || candidates[initialized.size()].tier != PcmCandidateTier::CommonRate) {
        return fail("common-rate fallback did not follow the mix format");
    }
    return true;
}

bool testCommonRatesPreferSourceFamilyAndDistance() {
    const PcmSourceFormat source{96000, 2, 24, true, true};
    const PcmMixFormat mix{48000};
    std::vector<uint32_t> firstRateCandidates;
    const auto selection = negotiateExclusivePcmCandidate(source, mix, false,
        [&](const PcmCandidate &candidate) {
            if (candidate.tier == PcmCandidateTier::CommonRate &&
                (firstRateCandidates.empty() || firstRateCandidates.back() != candidate.sampleRate)) {
                firstRateCandidates.push_back(candidate.sampleRate);
            }
            return PcmCandidateResult::Accepted;
        }, [](const PcmCandidate &) { return PcmCandidateResult::FormatRejected; }, [] { return true; });
    if (selection.candidate || selection.fatalFailure || firstRateCandidates.size() < 5 || firstRateCandidates[0] != 48000 ||
        firstRateCandidates[1] != 192000 || firstRateCandidates[2] != 384000 ||
        firstRateCandidates[3] != 768000 || firstRateCandidates[4] != 88200) {
        std::fprintf(stderr, "  observed common-rate order:");
        for (const uint32_t rate : firstRateCandidates) std::fprintf(stderr, " %u", rate);
        std::fputc('\n', stderr);
        return fail("common rates no longer prioritize source clock family, then proximity");
    }
    return true;
}

bool testAllInitializeRejectionsDoNotSelectASessionFormat() {
    const PcmSourceFormat source{96000, 2, 24, true, true};
    const PcmMixFormat mix{48000};
    std::vector<PcmCandidate> initialized;
    std::optional<PcmCandidate> sessionFormat;
    const auto selection = negotiateExclusivePcmCandidate(source, mix, false,
        [](const PcmCandidate &) { return PcmCandidateResult::Accepted; },
        [&](const PcmCandidate &candidate) {
            initialized.push_back(candidate);
            return PcmCandidateResult::FormatRejected;
        }, [] { return true; });
    if (selection.candidate || selection.fatalFailure) {
        return fail("all explicit format rejections should exhaust candidates without a fatal error");
    }
    if (selection.candidate) sessionFormat = selection.candidate;
    if (sessionFormat || initialized.empty() || initialized.back().tier != PcmCandidateTier::CommonRate) {
        return fail("failed initialization published a session format or skipped fallback candidates");
    }
    return true;
}

bool testFatalFailureDoesNotTryFallback() {
    const PcmSourceFormat source{96000, 2, 24, true, true};
    const PcmMixFormat mix{48000};
    size_t checked = 0;
    size_t initialized = 0;
    const auto selection = negotiateExclusivePcmCandidate(source, mix, false,
        [&](const PcmCandidate &) {
            ++checked;
            return PcmCandidateResult::Accepted;
        }, [&](const PcmCandidate &) {
            ++initialized;
            return PcmCandidateResult::FatalFailure;
        }, [] { return true; });
    if (selection.candidate || !selection.fatalFailure || checked != 1 || initialized != 1) {
        return fail("a non-format initialization failure incorrectly advanced to fallback");
    }
    return true;
}

bool testFatalFormatQueryDoesNotTryFallback() {
    const PcmSourceFormat source{96000, 2, 24, true, true};
    const PcmMixFormat mix{48000};
    size_t checked = 0;
    size_t initialized = 0;
    const auto selection = negotiateExclusivePcmCandidate(source, mix, false,
        [&](const PcmCandidate &) {
            ++checked;
            return PcmCandidateResult::FatalFailure;
        }, [&](const PcmCandidate &) {
            ++initialized;
            return PcmCandidateResult::Accepted;
        }, [] { return true; });
    if (selection.candidate || !selection.fatalFailure || checked != 1 || initialized != 0) {
        return fail("a fatal format query incorrectly advanced to another candidate");
    }
    return true;
}

bool testUnalignedRetryUsesSameCandidateAndFreshClient() {
    const PcmCandidate candidate{
        PcmCandidateTier::ExactSource, PcmDescriptor::ExtensibleInteger,
        96000, 2, 24, 32};
    std::vector<PcmCandidate> initializedCandidates;
    std::vector<int64_t> durations;
    int initializeCalls = 0;
    int alignedDurationQueries = 0;
    int clientRecreations = 0;
    const PcmCandidateInitializeOutcome outcome = initializePcmCandidateWithAlignedRetry(
        candidate, 100000,
        [&](const PcmCandidate &attempted, int64_t duration) {
            initializedCandidates.push_back(attempted);
            durations.push_back(duration);
            return ++initializeCalls == 1
                ? PcmCandidateResult::BufferSizeNotAligned
                : PcmCandidateResult::Accepted;
        }, [&](const PcmCandidate &attempted) -> std::optional<int64_t> {
            ++alignedDurationQueries;
            if (!(attempted.tier == candidate.tier && attempted.sampleRate == candidate.sampleRate &&
                attempted.validBits == candidate.validBits &&
                attempted.containerBits == candidate.containerBits)) return std::nullopt;
            return 250000;
        }, [&] {
            ++clientRecreations;
            return true;
        });
    if (outcome.result != PcmCandidateResult::Accepted ||
        outcome.successfulBufferDurationHundredNanos != 250000 ||
        initializeCalls != 2 || alignedDurationQueries != 1 || clientRecreations != 1 ||
        initializedCandidates.size() != 2 || initializedCandidates[0].tier != candidate.tier ||
        initializedCandidates[0].descriptor != candidate.descriptor ||
        initializedCandidates[0].sampleRate != candidate.sampleRate ||
        initializedCandidates[0].channels != candidate.channels ||
        initializedCandidates[0].validBits != candidate.validBits ||
        initializedCandidates[0].containerBits != candidate.containerBits ||
        initializedCandidates[1].tier != candidate.tier ||
        initializedCandidates[1].descriptor != candidate.descriptor ||
        initializedCandidates[1].sampleRate != candidate.sampleRate ||
        initializedCandidates[1].channels != candidate.channels ||
        initializedCandidates[1].validBits != candidate.validBits ||
        initializedCandidates[1].containerBits != candidate.containerBits ||
        durations[0] != 100000 || durations[1] != 250000) {
        return fail("buffer alignment retry did not preserve the exact candidate on a fresh client");
    }
    return true;
}

}  // namespace

int main() {
    const bool strict = testStrictOnlyTriesExactSourceCandidates();
    const bool exactOrder = testExactCandidatesPrecedeAlternateDepth();
    const bool monoOrder = testMonoToStereoPrecedesMixFormat();
    const bool mixOrder = testMixFormatPrecedesCommonRates();
    const bool commonOrder = testCommonRatesPreferSourceFamilyAndDistance();
    const bool noSessionOnFailure = testAllInitializeRejectionsDoNotSelectASessionFormat();
    const bool fatal = testFatalFailureDoesNotTryFallback();
    const bool fatalFormatQuery = testFatalFormatQueryDoesNotTryFallback();
    const bool alignment = testUnalignedRetryUsesSameCandidateAndFreshClient();
    if (strict && exactOrder && monoOrder && mixOrder && commonOrder && noSessionOnFailure &&
        fatal && fatalFormatQuery && alignment) {
        std::puts("PASS: WASAPI candidate initialization fallback, strict mode and aligned retry policies");
        return 0;
    }
    return 1;
}
