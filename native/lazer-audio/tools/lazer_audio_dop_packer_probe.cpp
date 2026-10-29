/* Hardware-independent checks for the standalone DSD-to-DoP frame packer. */
#include "dop_packer.h"

#include <cstdint>
#include <iostream>
#include <limits>
#include <string>
#include <vector>

namespace {

using lazer::audio::DopPackStatus;
using lazer::audio::DopPacker;

bool expect(bool condition, const char *message) {
    if (condition) return true;
    std::cerr << "FAIL: " << message << '\n';
    return false;
}

bool testStereoPayloadAndSynchronizedMarkers() {
    DopPacker packer(2);
    const std::vector<uint8_t> input{
        0x10, 0x90, 0x11, 0x91,
        0x12, 0x92, 0x13, 0x93,
        0x14, 0x94, 0x15, 0x95,
    };
    std::vector<uint8_t> output(3 * 2 * 3);
    const auto result = packer.pack(input.data(), 6, output.data(), 3);
    const std::vector<uint8_t> expected{
        0x10, 0x11, 0x05, 0x90, 0x91, 0x05,
        0x12, 0x13, 0xFA, 0x92, 0x93, 0xFA,
        0x14, 0x15, 0x05, 0x94, 0x95, 0x05,
    };
    return expect(result.status == DopPackStatus::Ok &&
            result.consumedInputFrames == 6 && result.producedOutputFrames == 3,
            "stereo pack counts/status are incorrect") &&
        expect(output == expected, "stereo payload order, channel separation, or marker sequence is incorrect") &&
        expect(!packer.hasPendingInputFrame() && packer.nextMarker() == 0xFA,
            "packer state did not advance once per carrier frame");
}

bool packChunks(const std::vector<uint8_t> &input, size_t channels,
    const std::vector<size_t> &chunkSizes, std::vector<uint8_t> &output) {
    DopPacker packer(channels);
    size_t inputOffsetFrames = 0;
    size_t outputOffsetFrames = 0;
    for (const size_t chunkFrames : chunkSizes) {
        if (inputOffsetFrames + chunkFrames > input.size() / channels) return false;
        const size_t remainingOutputFrames = output.size() / (channels * 3) - outputOffsetFrames;
        auto *out = remainingOutputFrames == 0 ? nullptr
            : output.data() + outputOffsetFrames * channels * 3;
        const auto result = packer.pack(
            chunkFrames == 0 ? nullptr : input.data() + inputOffsetFrames * channels,
            chunkFrames, out, remainingOutputFrames);
        if (result.consumedInputFrames != chunkFrames ||
            result.status == DopPackStatus::OutputFull ||
            result.status == DopPackStatus::InvalidArgument ||
            result.status == DopPackStatus::InvalidChannelCount ||
            result.status == DopPackStatus::SizeOverflow) {
            return false;
        }
        inputOffsetFrames += result.consumedInputFrames;
        outputOffsetFrames += result.producedOutputFrames;
    }
    return inputOffsetFrames == input.size() / channels &&
        outputOffsetFrames == output.size() / (channels * 3);
}

bool testChunkSplitInvariance() {
    constexpr size_t kChannels = 2;
    const std::vector<uint8_t> input{
        0x01, 0x81, 0x02, 0x82, 0x03, 0x83, 0x04, 0x84,
        0x05, 0x85, 0x06, 0x86, 0x07, 0x87,
    };
    DopPacker baselinePacker(kChannels);
    std::vector<uint8_t> baseline(3 * kChannels * 3);
    const auto baselineResult = baselinePacker.pack(input.data(), 7, baseline.data(), 3);
    if (!expect(baselineResult.status == DopPackStatus::NeedMoreInput &&
            baselineResult.consumedInputFrames == 7 && baselineResult.producedOutputFrames == 3,
            "odd total input did not retain its final DSD frame")) return false;

    /* Exercise every partition of the seven input frames. This includes every possible odd
     * boundary and consecutive one-frame chunks, while keeping enough output capacity in reserve. */
    for (unsigned int cuts = 0; cuts < (1u << 6); ++cuts) {
        std::vector<size_t> chunks;
        size_t chunkStart = 0;
        for (size_t boundary = 1; boundary < 7; ++boundary) {
            if ((cuts & (1u << (boundary - 1))) != 0) {
                chunks.push_back(boundary - chunkStart);
                chunkStart = boundary;
            }
        }
        chunks.push_back(7 - chunkStart);
        std::vector<uint8_t> chunked(baseline.size());
        if (!expect(packChunks(input, kChannels, chunks, chunked),
                "a chunk partition failed to consume input or produce the expected frame count")) {
            return false;
        }
        if (!expect(chunked == baseline,
                "chunk split changed DoP payload bytes or carrier marker sequence")) return false;
    }
    return true;
}

bool testMonoOddBoundaryAndReset() {
    DopPacker packer(1);
    const uint8_t firstChunk[]{0xA1, 0xA2, 0xA3};
    uint8_t output[6]{};
    const auto first = packer.pack(firstChunk, 3, output, 2);
    if (!expect(first.status == DopPackStatus::NeedMoreInput &&
            first.consumedInputFrames == 3 && first.producedOutputFrames == 1 &&
            packer.hasPendingInputFrame(), "mono odd chunk did not retain exactly one input frame")) {
        return false;
    }
    const uint8_t next[]{0xA4};
    const auto second = packer.pack(next, 1, output + 3, 1);
    if (!expect(second.status == DopPackStatus::Ok && second.producedOutputFrames == 1 &&
            output[0] == 0xA1 && output[1] == 0xA2 && output[2] == 0x05 &&
            output[3] == 0xA3 && output[4] == 0xA4 && output[5] == 0xFA,
            "mono payload or marker continuity across an odd boundary is incorrect")) return false;

    const uint8_t pendingOnly[]{0xB1};
    const auto pending = packer.pack(pendingOnly, 1, nullptr, 0);
    if (!expect(pending.status == DopPackStatus::NeedMoreInput &&
            pending.consumedInputFrames == 1 && packer.hasPendingInputFrame(),
            "zero output capacity failed to retain an unpaired input frame")) return false;
    packer.reset();
    const uint8_t afterReset[]{0xC1, 0xC2};
    const auto resetResult = packer.pack(afterReset, 2, output, 1);
    return expect(resetResult.status == DopPackStatus::Ok && resetResult.producedOutputFrames == 1 &&
            output[0] == 0xC1 && output[1] == 0xC2 && output[2] == 0x05 &&
            !packer.hasPendingInputFrame() && packer.nextMarker() == 0xFA,
            "reset did not discard pending data and restore the initial marker");
}

bool testFinalOddByteFlush() {
    DopPacker packer(2);
    const uint8_t oddInput[]{0x21, 0xA1, 0x22, 0xA2, 0x23, 0xA3};
    uint8_t packed[6]{};
    const auto result = packer.pack(oddInput, 3, packed, 2);
    if (!expect(result.status == DopPackStatus::NeedMoreInput &&
            result.producedOutputFrames == 1 && packer.hasPendingInputFrame(),
            "odd DSD byte count did not leave one frame for EOF flush")) return false;
    uint8_t finalCarrier[6]{};
    const auto noCapacity = packer.flush(nullptr, 0);
    if (!expect(noCapacity.status == DopPackStatus::OutputFull && packer.hasPendingInputFrame(),
            "zero-capacity flush discarded the final DSD bytes")) return false;
    const auto flushed = packer.flush(finalCarrier, 1);
    return expect(flushed.status == DopPackStatus::Ok && flushed.producedOutputFrames == 1 &&
            finalCarrier[0] == 0x23 && finalCarrier[1] == 0x69 && finalCarrier[2] == 0xFA &&
            finalCarrier[3] == 0xA3 && finalCarrier[4] == 0x69 && finalCarrier[5] == 0xFA &&
            !packer.hasPendingInputFrame(),
        "EOF flush did not preserve the last DSD byte and pad a synchronized idle byte");
}

bool testVariablePeriodMarkerContinuity() {
    uint8_t nextMarker = 0x05;
    std::vector<uint8_t> firstPeriod(5 * 2 * 3, 0xCC);
    const int32_t firstFrames = lazer::audio::prepareDopCarrierFrames(
        firstPeriod.data(), 5, 3, 2, false, nextMarker);
    if (!expect(firstFrames == 3 && nextMarker == 0xFA &&
            firstPeriod[2] == 0x05 && firstPeriod[8] == 0xFA && firstPeriod[14] == 0x05 &&
            firstPeriod[20] == 0xCC,
            "variable output formatted unused writable space or advanced its marker clock")) {
        return false;
    }
    uint8_t secondPeriod[2 * 2 * 3]{};
    const int32_t secondFrames = lazer::audio::prepareDopCarrierFrames(
        secondPeriod, 2, 2, 2, false, nextMarker);
    if (!expect(secondFrames == 2 && secondPeriod[2] == 0xFA &&
            secondPeriod[8] == 0x05 && nextMarker == 0xFA,
            "the next variable write did not alternate from the last submitted carrier")) {
        return false;
    }
    uint8_t fixedPeriod[2 * 2 * 3]{};
    const int32_t fixedFrames = lazer::audio::prepareDopCarrierFrames(
        fixedPeriod, 2, 1, 2, true, nextMarker);
    return expect(fixedFrames == 2 && fixedPeriod[2] == 0xFA &&
            fixedPeriod[8] == 0x05 && fixedPeriod[6] == 0x69 && fixedPeriod[7] == 0x69 &&
            nextMarker == 0xFA,
        "fixed-period padding did not keep silence payload and marker clocks running");
}

bool testOutputCapacityAndArgumentErrors() {
    DopPacker packer(2);
    const uint8_t input[]{0x10, 0x90, 0x11, 0x91, 0x12, 0x92, 0x13, 0x93};
    uint8_t output[6]{};
    const auto first = packer.pack(input, 4, output, 1);
    if (!expect(first.status == DopPackStatus::OutputFull &&
            first.consumedInputFrames == 3 && first.producedOutputFrames == 1 &&
            packer.hasPendingInputFrame() && output[0] == 0x10 &&
            output[1] == 0x11 && output[2] == 0x05,
            "capacity exhaustion did not report a retryable input prefix")) return false;
    uint8_t remainingOutput[6]{};
    const auto rest = packer.pack(input + first.consumedInputFrames * 2, 1, remainingOutput, 1);
    if (!expect(rest.status == DopPackStatus::Ok && rest.consumedInputFrames == 1 &&
            remainingOutput[0] == 0x12 && remainingOutput[1] == 0x13 &&
            remainingOutput[2] == 0xFA && remainingOutput[3] == 0x92 &&
            remainingOutput[4] == 0x93 && remainingOutput[5] == 0xFA,
            "retry after capacity exhaustion lost input or desynchronized markers")) return false;

    DopPacker zeroCapacityPacker(1);
    const uint8_t pair[]{0x31, 0x32};
    const auto noRoom = zeroCapacityPacker.pack(pair, 2, nullptr, 0);
    uint8_t oneCarrier[3]{};
    const auto retry = zeroCapacityPacker.pack(pair + noRoom.consumedInputFrames, 1,
        oneCarrier, 1);
    if (!expect(noRoom.status == DopPackStatus::OutputFull && noRoom.consumedInputFrames == 1 &&
            retry.status == DopPackStatus::Ok && retry.consumedInputFrames == 1 &&
            oneCarrier[0] == 0x31 && oneCarrier[1] == 0x32 && oneCarrier[2] == 0x05,
            "capacity retry dropped a cached first DSD byte")) return false;

    DopPacker invalidChannels(3);
    const auto badChannels = invalidChannels.pack(nullptr, 0, nullptr, 0);
    if (!expect(badChannels.status == DopPackStatus::InvalidChannelCount,
            "unsupported channel count did not return its explicit status")) return false;
    const auto badInput = packer.pack(nullptr, 1, nullptr, 0);
    if (!expect(badInput.status == DopPackStatus::InvalidArgument &&
            badInput.consumedInputFrames == 0 && badInput.producedOutputFrames == 0,
            "null nonempty input did not return an explicit argument error")) return false;
    const auto overflow = packer.pack(reinterpret_cast<const uint8_t *>(1),
        std::numeric_limits<size_t>::max(), nullptr, 0);
    return expect(overflow.status == DopPackStatus::SizeOverflow,
        "input byte count overflow did not return an explicit size error");
}

}  // namespace

int main() {
    bool passed = true;
    passed &= testStereoPayloadAndSynchronizedMarkers();
    passed &= testChunkSplitInvariance();
    passed &= testMonoOddBoundaryAndReset();
    passed &= testFinalOddByteFlush();
    passed &= testVariablePeriodMarkerContinuity();
    passed &= testOutputCapacityAndArgumentErrors();
    if (!passed) return 1;
    std::cout << "PASS: hardware-independent DSD-to-DoP packer probe\n";
    return 0;
}
