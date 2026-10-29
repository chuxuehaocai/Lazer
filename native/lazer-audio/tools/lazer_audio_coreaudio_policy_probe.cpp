#include <cstdlib>
#include <iostream>
#include <string>
#include <utility>
#include <vector>

#include "coreaudio_format_policy.h"

namespace {

using namespace lazer::audio;

int failures = 0;

void check(bool condition, const std::string &message) {
    if (condition) return;
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
}

CoreAudioSampleRateRange rateRange(double minimumHz, double maximumHz) {
    return CoreAudioSampleRateRange{minimumHz, maximumHz};
}

CoreAudioPcmStreamTuple pcmTuple(int32_t minimumRateHz, int32_t maximumRateHz,
    int32_t channels, int32_t bits, int32_t containerBits, bool interleaved = true,
    bool littleEndian = true, bool alignedHigh = true, bool nonMixable = false) {
    return CoreAudioPcmStreamTuple{
        rateRange(minimumRateHz, maximumRateHz),
        channels,
        CoreAudioPcmEncoding::SignedInteger,
        bits,
        containerBits,
        interleaved,
        littleEndian,
        bits == containerBits,
        alignedHigh,
        nonMixable,
    };
}

CoreAudioPcmStreamTuple floatTuple(int32_t minimumRateHz, int32_t maximumRateHz,
    int32_t channels, bool interleaved = true, bool littleEndian = true) {
    return CoreAudioPcmStreamTuple{
        rateRange(minimumRateHz, maximumRateHz),
        channels,
        CoreAudioPcmEncoding::Float32,
        32,
        32,
        interleaved,
        littleEndian,
        true,
        true,
        false,
    };
}

CoreAudioPcmStreamTuple withPacked(CoreAudioPcmStreamTuple tuple, bool packed) {
    tuple.packed = packed;
    return tuple;
}

CoreAudioHalPcmCapabilities knownCapabilities(
    std::vector<CoreAudioSampleRateRange> nominalRanges,
    std::vector<CoreAudioPcmStreamTuple> tuples,
    CoreAudioHogOwnership hog = CoreAudioHogOwnership::OwnedByCurrentProcess) {
    CoreAudioHalPcmCapabilities result{};
    result.nominalSampleRateRangesKnown = true;
    result.nominalSampleRateRanges = std::move(nominalRanges);
    result.streamTuplesKnown = true;
    result.streamTuples = std::move(tuples);
    result.hogOwnership = hog;
    return result;
}

TargetFormat targetFormat(int32_t sampleRateHz, int32_t channels,
    int32_t bitsPerSample, int32_t containerBitsPerSample = 0) {
    TargetFormat target{};
    target.sampleRate = sampleRateHz;
    target.channels = channels;
    target.bitsPerSample = bitsPerSample;
    target.containerBitsPerSample = containerBitsPerSample;
    return target;
}

void testExactPcmTupleMatrix() {
    struct Case {
        const char *name;
        TargetFormat target;
        CoreAudioPcmStreamTuple tuple;
    };
    const std::vector<Case> cases{
        {"PCM16 stereo 44.1 kHz", targetFormat(44100, 2, 16), pcmTuple(44100, 44100, 2, 16, 16)},
        {"packed PCM24 stereo 48 kHz", targetFormat(48000, 2, 24), pcmTuple(48000, 48000, 2, 24, 24)},
        {"24-valid-in-32 mono 192 kHz", targetFormat(192000, 1, 24, 32), pcmTuple(192000, 192000, 1, 24, 32)},
        {"PCM32 stereo 768 kHz", targetFormat(768000, 2, 32), pcmTuple(768000, 768000, 2, 32, 32)},
        {"float32 mono 44.1 kHz", targetFormat(44100, 1, 0), floatTuple(44100, 44100, 1)},
        {"float32 stereo 48 kHz", targetFormat(48000, 2, 0), floatTuple(48000, 48000, 2)},
    };

    for (const auto &test : cases) {
        const auto capabilities = knownCapabilities(
            {rateRange(test.target.sampleRate, test.target.sampleRate)}, {test.tuple});
        const auto decision = negotiateCoreAudioPcmFormat(test.target, capabilities, true, true);
        check(decision.kind == CoreAudioPcmDecisionKind::ExactPcmTuple,
            std::string(test.name) + " should choose an exact tuple");
        check(decision.endpoint.sampleRateHz == test.target.sampleRate &&
                decision.endpoint.channels == test.target.channels,
            std::string(test.name) + " should preserve rate and channels");
        if (test.target.bitsPerSample == 0) {
            check(decision.endpoint.bitsPerSample == 0,
                std::string(test.name) + " should preserve the float32 target sentinel");
        }
        if (test.target.bitsPerSample == 24 && test.target.containerBitsPerSample == 32) {
            check(!decision.endpoint.packed && decision.endpoint.alignedHigh,
                std::string(test.name) + " should preserve unpacked high-aligned 24-in-32 layout");
        }
        check(decision.conversionReasons == CoreAudioPcmConversionNone,
            std::string(test.name) + " should not request conversion");
    }
}

void testAsbdEncodingFlagsAndNonMixableMetadata() {
    check(coreAudioPcmEncodingFromFlags(false, true) == CoreAudioPcmEncoding::SignedInteger,
        "signed-integer ASBD flags should map to integer PCM");
    check(coreAudioPcmEncodingFromFlags(true, false) == CoreAudioPcmEncoding::Float32,
        "float ASBD flags should map to float PCM");
    check(coreAudioPcmEncodingFromFlags(false, false) == CoreAudioPcmEncoding::Unsupported,
        "ASBD without an encoding flag should be rejected");
    check(coreAudioPcmEncodingFromFlags(true, true) == CoreAudioPcmEncoding::Unsupported,
        "ASBD with conflicting float and signed-integer flags should be rejected");

    auto tuple = pcmTuple(48000, 48000, 2, 24, 24, true, true, true, true);
    const auto decision = negotiateCoreAudioPcmFormat(targetFormat(48000, 2, 24),
        knownCapabilities({rateRange(48000, 48000)}, {tuple}), true, true);
    check(decision.kind == CoreAudioPcmDecisionKind::ExactPcmTuple,
        "a non-mixable integer format should retain its exact PCM classification");
    check(decision.endpoint.nonMixable,
        "the selected tuple should report the HAL non-mixable flag");
    check(decision.conversionReasons == CoreAudioPcmConversionNone,
        "non-mixable metadata must not imply PCM sample conversion");
}

void testRateAndChannelConversionCandidates() {
    const auto supported = knownCapabilities(
        {rateRange(44100, 44100), rateRange(48000, 48000), rateRange(192000, 192000),
            rateRange(768000, 768000)},
        {pcmTuple(44100, 44100, 2, 16, 16), pcmTuple(48000, 48000, 2, 24, 24),
            pcmTuple(192000, 192000, 1, 24, 32), pcmTuple(768000, 768000, 2, 32, 32)});

    auto unsupportedRate = negotiateCoreAudioPcmFormat(
        targetFormat(46050, 2, 24), supported, false, false);
    check(unsupportedRate.kind == CoreAudioPcmDecisionKind::ConversionCandidate,
        "a non-bit-perfect unsupported rate should get an explicit conversion candidate");
    check((unsupportedRate.conversionReasons & CoreAudioPcmConversionSampleRate) != 0,
        "a changed endpoint rate should report sample-rate conversion");
    check(unsupportedRate.endpoint.sampleRateHz == 48000,
        "when rate distance ties, the deterministic candidate should prefer the matching 24-bit tuple");

    const auto monoOnly = knownCapabilities({rateRange(48000, 48000)},
        {pcmTuple(48000, 48000, 1, 24, 24)});
    const auto channelCandidate = negotiateCoreAudioPcmFormat(
        targetFormat(48000, 2, 24), monoOnly, false, false);
    check(channelCandidate.kind == CoreAudioPcmDecisionKind::ConversionCandidate,
        "mono/stereo mismatch should be explicit conversion, not exact");
    check((channelCandidate.conversionReasons & CoreAudioPcmConversionChannelCount) != 0,
        "channel conversion reason should be reported");

    const auto nonInterleaved = knownCapabilities({rateRange(44100, 44100)},
        {pcmTuple(44100, 44100, 2, 16, 16, false)});
    const auto layoutCandidate = negotiateCoreAudioPcmFormat(
        targetFormat(44100, 2, 16), nonInterleaved, false, false);
    check(layoutCandidate.kind == CoreAudioPcmDecisionKind::ConversionCandidate,
        "non-interleaved HAL tuple should require an explicit layout conversion candidate");
    check((layoutCandidate.conversionReasons & CoreAudioPcmConversionInterleaving) != 0,
        "non-interleaved HAL tuple should report its layout conversion");

    const auto bigEndian = knownCapabilities({rateRange(44100, 44100)},
        {pcmTuple(44100, 44100, 2, 16, 16, true, false)});
    const auto bigEndianCandidate = negotiateCoreAudioPcmFormat(
        targetFormat(44100, 2, 16), bigEndian, false, false);
    check(bigEndianCandidate.kind == CoreAudioPcmDecisionKind::ConversionCandidate &&
            (bigEndianCandidate.conversionReasons & CoreAudioPcmConversionEndianness) != 0,
        "big-endian HAL samples must never be considered byte-exact");

    const auto unpacked = knownCapabilities({rateRange(44100, 44100)},
        {withPacked(pcmTuple(44100, 44100, 2, 16, 16), false)});
    const auto unpackedCandidate = negotiateCoreAudioPcmFormat(
        targetFormat(44100, 2, 16), unpacked, false, false);
    check(unpackedCandidate.kind == CoreAudioPcmDecisionKind::ConversionCandidate &&
            (unpackedCandidate.conversionReasons & CoreAudioPcmConversionPacking) != 0,
        "unpacked HAL frames must require a packing candidate when the target is packed");

    const auto lowAligned = knownCapabilities({rateRange(192000, 192000)},
        {pcmTuple(192000, 192000, 2, 24, 32, true, true, false)});
    const auto alignmentCandidate = negotiateCoreAudioPcmFormat(
        targetFormat(192000, 2, 24, 32), lowAligned, false, false);
    check(alignmentCandidate.kind == CoreAudioPcmDecisionKind::ConversionCandidate &&
            (alignmentCandidate.conversionReasons & CoreAudioPcmConversionSampleAlignment) != 0,
        "low-aligned 24-in-32 HAL samples must require a sample-alignment conversion");

    const auto packed24In32 = knownCapabilities({rateRange(192000, 192000)},
        {withPacked(pcmTuple(192000, 192000, 2, 24, 32), true)});
    const auto packed24In32Candidate = negotiateCoreAudioPcmFormat(
        targetFormat(192000, 2, 24, 32), packed24In32, false, false);
    check(packed24In32Candidate.kind == CoreAudioPcmDecisionKind::ConversionCandidate &&
            (packed24In32Candidate.conversionReasons & CoreAudioPcmConversionPacking) != 0,
        "packed ASBD with 24 valid bits in a 32-bit container must not be exact");
}

void testUnknownAndEmptyCapabilities() {
    auto unknown = knownCapabilities({}, {});
    unknown.nominalSampleRateRangesKnown = false;
    const auto unknownDecision = negotiateCoreAudioPcmFormat(
        targetFormat(44100, 2, 16), unknown, false, false);
    check(unknownDecision.kind == CoreAudioPcmDecisionKind::Rejected &&
            unknownDecision.reason == CoreAudioPcmDecisionReason::UnknownHalCapabilities,
        "unknown HAL properties must not be guessed into an output candidate");

    auto noFormats = knownCapabilities({rateRange(44100, 192000)}, {});
    const auto emptyDecision = negotiateCoreAudioPcmFormat(
        targetFormat(44100, 2, 16), noFormats, false, false);
    check(emptyDecision.kind == CoreAudioPcmDecisionKind::Rejected &&
            emptyDecision.reason == CoreAudioPcmDecisionReason::NoUsablePcmTuple,
        "known empty stream tuple lists should reject explicitly");

    auto disjoint = knownCapabilities({rateRange(44100, 44100)},
        {pcmTuple(48000, 48000, 2, 16, 16)});
    const auto disjointDecision = negotiateCoreAudioPcmFormat(
        targetFormat(44100, 2, 16), disjoint, false, false);
    check(disjointDecision.kind == CoreAudioPcmDecisionKind::Rejected &&
            disjointDecision.reason == CoreAudioPcmDecisionReason::NoSampleRateIntersection,
        "device and stream rate ranges with no intersection must reject");
}

void testBitPerfectNeverFallsBack() {
    const auto exactTuple = pcmTuple(44100, 44100, 2, 16, 16);
    const auto tuples = std::vector<CoreAudioPcmStreamTuple>{exactTuple,
        pcmTuple(48000, 48000, 2, 24, 24)};
    const auto rates = std::vector<CoreAudioSampleRateRange>{rateRange(44100, 44100),
        rateRange(48000, 48000)};

    const auto rateFallbackCaps = knownCapabilities(rates, tuples);
    const auto rateFallback = negotiateCoreAudioPcmFormat(
        targetFormat(96000, 2, 24), rateFallbackCaps, true, true);
    check(rateFallback.kind == CoreAudioPcmDecisionKind::Rejected &&
            rateFallback.reason == CoreAudioPcmDecisionReason::NoExactTuple,
        "bit-perfect rate/format mismatch must reject instead of returning fallback");
    check(rateFallback.conversionReasons == CoreAudioPcmConversionNone,
        "rejected bit-perfect decision must not expose an acceptable fallback tuple");

    const auto lowAlignedCaps = knownCapabilities({rateRange(192000, 192000)},
        {pcmTuple(192000, 192000, 2, 24, 32, true, true, false)});
    const auto lowAlignedBitPerfect = negotiateCoreAudioPcmFormat(
        targetFormat(192000, 2, 24, 32), lowAlignedCaps, true, true);
    check(lowAlignedBitPerfect.kind == CoreAudioPcmDecisionKind::Rejected &&
            lowAlignedBitPerfect.reason == CoreAudioPcmDecisionReason::NoExactTuple,
        "bit-perfect 24-in-32 output must reject a HAL tuple with the wrong sample alignment");

    const auto packed24In32Caps = knownCapabilities({rateRange(192000, 192000)},
        {withPacked(pcmTuple(192000, 192000, 2, 24, 32), true)});
    const auto packed24In32BitPerfect = negotiateCoreAudioPcmFormat(
        targetFormat(192000, 2, 24, 32), packed24In32Caps, true, true);
    check(packed24In32BitPerfect.kind == CoreAudioPcmDecisionKind::Rejected &&
            packed24In32BitPerfect.reason == CoreAudioPcmDecisionReason::NoExactTuple,
        "bit-perfect 24-in-32 output must reject a packed HAL layout");

    const std::vector<std::pair<CoreAudioHogOwnership, CoreAudioPcmDecisionReason>> hogCases{
        {CoreAudioHogOwnership::OwnedByAnotherProcess,
            CoreAudioPcmDecisionReason::HogOwnedByAnotherProcess},
        {CoreAudioHogOwnership::Unsupported,
            CoreAudioPcmDecisionReason::HogModeUnavailable},
        {CoreAudioHogOwnership::Unknown,
            CoreAudioPcmDecisionReason::HogOwnershipUnknown},
    };
    for (const auto &[ownership, expectedReason] : hogCases) {
        const auto busyCapabilities = knownCapabilities(rates, tuples, ownership);
        const auto busy = negotiateCoreAudioPcmFormat(
            targetFormat(44100, 2, 16), busyCapabilities, true, true);
        check(busy.kind == CoreAudioPcmDecisionKind::Rejected,
            "bit-perfect request must reject when Hog Mode cannot be owned by this process");
        check(busy.reason == expectedReason,
            "Hog Mode failure must carry its specific unavailable/occupied/unknown reason");
    }

    const auto noHogRequest = negotiateCoreAudioPcmFormat(
        targetFormat(44100, 2, 16), rateFallbackCaps, false, true);
    check(noHogRequest.kind == CoreAudioPcmDecisionKind::Rejected &&
            noHogRequest.reason == CoreAudioPcmDecisionReason::BitPerfectRequiresHogMode,
        "bit-perfect request without exclusive/Hog request must reject");

    const auto sharedFallbackCaps = knownCapabilities(rates, tuples,
        CoreAudioHogOwnership::OwnedByAnotherProcess);
    const auto sharedFallback = negotiateCoreAudioPcmFormat(
        targetFormat(44100, 2, 16), sharedFallbackCaps, true, false);
    check(sharedFallback.kind == CoreAudioPcmDecisionKind::ConversionCandidate,
        "non-bit-perfect exclusive request may return an explicit shared-mode candidate");
    check((sharedFallback.conversionReasons & CoreAudioPcmConversionSharedModeFallback) != 0,
        "shared-mode fallback must be visible in candidate reasons");
}

void testInvalidAndDoPTargets() {
    const auto caps = knownCapabilities({rateRange(44100, 768000)},
        {pcmTuple(44100, 768000, 2, 32, 32)});
    auto invalid = targetFormat(44100, 6, 16);
    auto invalidDecision = negotiateCoreAudioPcmFormat(invalid, caps, false, false);
    check(invalidDecision.kind == CoreAudioPcmDecisionKind::Rejected &&
            invalidDecision.reason == CoreAudioPcmDecisionReason::InvalidTarget,
        "this PCM policy should reject target layouts other than mono/stereo");

    auto dop = targetFormat(176400, 2, 24, 24);
    dop.doP = true;
    const auto dopDecision = negotiateCoreAudioPcmFormat(dop, caps, false, false);
    check(dopDecision.kind == CoreAudioPcmDecisionKind::Rejected &&
            dopDecision.reason == CoreAudioPcmDecisionReason::DoPIsNotPcm,
        "DoP payloads must be rejected by the PCM negotiation policy");
}

void testExactDoPCarrierPolicy() {
    auto dop = targetFormat(176400, 2, 24, 24);
    dop.doP = true;
    const auto exact = knownCapabilities({rateRange(176400, 176400)},
        {pcmTuple(176400, 176400, 2, 24, 24)});
    const auto accepted = negotiateCoreAudioDoPFormat(dop, exact, true);
    check(accepted.accepted && accepted.reason == CoreAudioDoPDecisionReason::None,
        "DoP should accept only the exact Hog Mode carrier tuple");
    check(accepted.endpoint.sampleRateHz == 176400 && accepted.endpoint.channels == 2 &&
            accepted.endpoint.bitsPerSample == 24 &&
            accepted.endpoint.containerBitsPerSample == 24 &&
            accepted.endpoint.interleaved && accepted.endpoint.littleEndian &&
            accepted.endpoint.packed,
        "accepted DoP tuple must preserve the exact packed carrier layout");

    const auto monoCaps = knownCapabilities({rateRange(88200, 88200)},
        {pcmTuple(88200, 88200, 1, 24, 24)});
    dop.sampleRate = 88200;
    dop.channels = 1;
    check(negotiateCoreAudioDoPFormat(dop, monoCaps, true).accepted,
        "mono DoP is accepted when the exact carrier tuple is available");

    dop.sampleRate = 176400;
    dop.channels = 2;
    check(negotiateCoreAudioDoPFormat(dop, exact, false).reason ==
            CoreAudioDoPDecisionReason::ExclusiveModeRequired,
        "DoP without an exclusive/Hog request must be rejected");
    check(negotiateCoreAudioDoPFormat(dop, knownCapabilities(
            {rateRange(176400, 176400)}, {pcmTuple(176400, 176400, 2, 24, 24)},
            CoreAudioHogOwnership::OwnedByAnotherProcess), true).reason ==
            CoreAudioDoPDecisionReason::HogOwnedByAnotherProcess,
        "DoP must reject when another process owns Hog Mode");

    auto noRate = knownCapabilities({rateRange(44100, 96000)},
        {pcmTuple(44100, 96000, 2, 24, 24)});
    check(negotiateCoreAudioDoPFormat(dop, noRate, true).reason ==
            CoreAudioDoPDecisionReason::NoExactCarrierTuple,
        "DoP must reject rather than convert an unsupported carrier rate");
    const std::vector<CoreAudioPcmStreamTuple> rejectedLayouts{
        pcmTuple(176400, 176400, 1, 24, 24),
        pcmTuple(176400, 176400, 2, 24, 32),
        pcmTuple(176400, 176400, 2, 24, 24, false),
        pcmTuple(176400, 176400, 2, 24, 24, true, false),
        withPacked(pcmTuple(176400, 176400, 2, 24, 24), false),
    };
    for (const auto &tuple : rejectedLayouts) {
        const auto capabilities = knownCapabilities({rateRange(176400, 176400)}, {tuple});
        check(!negotiateCoreAudioDoPFormat(dop, capabilities, true).accepted,
            "DoP must reject channel, 24-in-32, planar, endian-swapped and unpacked layouts");
    }
    auto invalid = dop;
    invalid.doP = false;
    check(negotiateCoreAudioDoPFormat(invalid, exact, true).reason ==
            CoreAudioDoPDecisionReason::InvalidTarget,
        "the DoP policy must reject non-DoP targets");
}

void testStreamFormatRestoreGuard() {
    CoreAudioStreamFormatSnapshot selected{};
    selected.sampleRateHz = 96000.0;
    selected.formatId = 0x6c70636d;
    selected.formatFlags = 0x0c;
    selected.bytesPerPacket = 6;
    selected.framesPerPacket = 1;
    selected.bytesPerFrame = 6;
    selected.channelsPerFrame = 2;
    selected.bitsPerChannel = 24;
    selected.reserved = 0;

    auto current = selected;
    current.sampleRateHz = 44100.0;
    check(coreAudioStreamFormatMayRestore(current, selected, true, 44100.0),
        "restore guard should tolerate only the virtual sample rate following nominal-rate restore");
    check(!coreAudioStreamFormatMayRestore(current, selected, false, 44100.0),
        "restore guard must not tolerate sample-rate drift unless nominal-rate restore succeeded");
    check(!coreAudioStreamFormatMayRestore(current, selected, true, 48000.0),
        "restore guard must reject a rate that is neither selected nor the restored nominal rate");
    current = selected;
    current.sampleRateHz = 44100.0;
    current.bitsPerChannel = 32;
    check(!coreAudioStreamFormatMayRestore(current, selected, true, 44100.0),
        "restore guard must preserve externally changed precision");
}

}  // namespace

int main() {
    testExactPcmTupleMatrix();
    testAsbdEncodingFlagsAndNonMixableMetadata();
    testRateAndChannelConversionCandidates();
    testUnknownAndEmptyCapabilities();
    testBitPerfectNeverFallsBack();
    testInvalidAndDoPTargets();
    testExactDoPCarrierPolicy();
    testStreamFormatRestoreGuard();
    if (failures != 0) {
        std::cerr << failures << " CoreAudio policy probe assertion(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "CoreAudio PCM/DoP negotiation policy: all checks passed\n";
    return EXIT_SUCCESS;
}
