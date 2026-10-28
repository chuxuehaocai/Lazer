#include "pcm_output.h"

#include <algorithm>
#include <cmath>

namespace lazer::audio {

namespace {

double nextDitherValue(uint64_t &state) {
    state ^= state >> 12;
    state ^= state << 25;
    state ^= state >> 27;
    const uint64_t random = state * 0x2545F4914F6CDD1DULL;
    return static_cast<double>(random >> 11) * (1.0 / 9007199254740992.0);
}

}  // namespace

int64_t quantizeWithTpdf(float value, int32_t bits, uint64_t &state) {
    const int64_t scale = int64_t{1} << (bits - 1);
    const double dither = nextDitherValue(state) - nextDitherValue(state);
    const double scaled = static_cast<double>(value) * static_cast<double>(scale) + dither;
    const int64_t rounded = static_cast<int64_t>(std::llround(scaled));
    return std::clamp(rounded, -scale, scale - 1);
}

uint64_t convertIntegerPcm(const float *source, size_t sampleCount, int32_t validBits,
    int32_t containerBits, uint8_t *destination, uint64_t &ditherState) {
    if (source == nullptr || destination == nullptr || sampleCount == 0 || validBits <= 0) return 0;
    if (containerBits <= 0) containerBits = validBits;
    const int32_t containerBytes = (containerBits + 7) / 8;
    const int32_t paddingBits = std::max(containerBits - validBits, 0);
    uint64_t clippedSamples = 0;

    for (size_t index = 0; index < sampleCount; ++index) {
        if (source[index] > 1.0f || source[index] < -1.0f) ++clippedSamples;
        const int64_t signedSample = quantizeWithTpdf(source[index], validBits, ditherState);
        const uint64_t packedSample = validBits == 8
            ? static_cast<uint64_t>(signedSample + 128) << paddingBits
            : static_cast<uint64_t>(signedSample) << paddingBits;
        for (int32_t byte = 0; byte < containerBytes; ++byte) {
            destination[index * static_cast<size_t>(containerBytes) + static_cast<size_t>(byte)] =
                static_cast<uint8_t>((packedSample >> (byte * 8)) & 0xff);
        }
    }
    return clippedSamples;
}

int32_t samplePeakMilliDbfs(const float *source, size_t sampleCount) noexcept {
    if (source == nullptr || sampleCount == 0) return -120'000;
    double peak = 0.0;
    for (size_t index = 0; index < sampleCount; ++index) {
        const double sample = static_cast<double>(source[index]);
        if (std::isfinite(sample)) peak = std::max(peak, std::abs(sample));
    }
    const double dbfs = peak > 0.0 ? 20.0 * std::log10(peak) : -120.0;
    return static_cast<int32_t>(std::llround(std::clamp(dbfs, -120.0, 120.0) * 1000.0));
}

}  // namespace lazer::audio
