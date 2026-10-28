/* Hardware-free regression checks for the native float DSP chain. */
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <vector>

#include "dsp_chain.h"
#include "pcm_output.h"

namespace {

constexpr double kThresholdDb = -1.0;
constexpr double kTolerance = 1e-6;

bool expect(bool condition, const char *message) {
    if (condition) return true;
    std::fprintf(stderr, "FAIL: %s\n", message);
    return false;
}

bool testSamplePeakCeiling(int32_t sampleRate) {
    const double threshold = std::pow(10.0, kThresholdDb / 20.0);
    bool passed = true;

    lazer::audio::Limiter limiter;
    limiter.configure(sampleRate, kThresholdDb, true);

    const std::vector<float> monoInput{1.5f, -1.8f, 0.25f, -2.2f, 0.9f};
    std::vector<float> mono = monoInput;
    const double reduction = limiter.process(mono.data(), mono.size(), 1);
    const bool monoUnderCeiling = std::all_of(mono.begin(), mono.end(), [threshold](float sample) {
        return std::abs(static_cast<double>(sample)) <= threshold + kTolerance;
    });
    passed &= expect(monoUnderCeiling,
        "enabled limiter must keep every mono sample under the configured ceiling");
    passed &= expect(reduction < 0.0,
        "limiter must report gain reduction for over-ceiling peaks");

    limiter.reset();
    const std::vector<float> stereoInput{1.8f, -0.9f, -1.5f, 0.75f, 0.2f, -2.1f};
    std::vector<float> stereo = stereoInput;
    limiter.process(stereo.data(), stereo.size() / 2, 2);
    bool stereoLinked = true;
    bool stereoUnderCeiling = true;
    for (size_t frame = 0; frame < stereo.size() / 2; ++frame) {
        const float left = stereoInput[frame * 2];
        const float right = stereoInput[frame * 2 + 1];
        const double leftGain = static_cast<double>(stereo[frame * 2]) / left;
        const double rightGain = static_cast<double>(stereo[frame * 2 + 1]) / right;
        stereoLinked = stereoLinked && std::abs(leftGain - rightGain) <= kTolerance;
        stereoUnderCeiling = stereoUnderCeiling &&
            std::max(std::abs(static_cast<double>(stereo[frame * 2])),
                std::abs(static_cast<double>(stereo[frame * 2 + 1]))) <= threshold + kTolerance;
    }
    passed &= expect(stereoLinked,
        "limiter must apply one linked gain to every channel in a frame");
    passed &= expect(stereoUnderCeiling,
        "stereo-linked output must remain under the configured ceiling");

    limiter.reset();
    float impulse = 1.5f;
    limiter.process(&impulse, 1, 1);
    const size_t releaseFrames = static_cast<size_t>(sampleRate / 5);
    std::vector<float> release(releaseFrames, 0.1f);
    limiter.process(release.data(), release.size(), 1);
    passed &= expect(release.front() < release.back() && release.back() < 0.1f,
        "release should recover gradually toward unity after the transient");
    bool monotonicRelease = true;
    bool smoothRelease = true;
    for (size_t index = 1; index < release.size(); ++index) {
        monotonicRelease = monotonicRelease && release[index] + 1e-8f >= release[index - 1];
        smoothRelease = smoothRelease && release[index] - release[index - 1] <= 2e-5f;
    }
    passed &= expect(monotonicRelease, "release gain must recover monotonically");
    passed &= expect(smoothRelease, "release must not introduce a per-sample gain step");

    limiter.configure(sampleRate, kThresholdDb, false);
    std::vector<float> bypass{1.5f, -2.25f, 0.2f};
    const std::vector<float> bypassExpected = bypass;
    const double bypassReduction = limiter.process(bypass.data(), bypass.size(), 1);
    passed &= expect(bypass == bypassExpected && bypassReduction == 0.0,
        "disabled limiter must leave samples transparent");

    LazerAudioEqBand unusedBand{};
    LazerAudioDspConfig config{};
    config.bands = &unusedBand;
    config.limiter_enabled = 1;
    config.limiter_threshold_db = kThresholdDb;
    lazer::audio::DspChain chain;
    chain.configureFormat({sampleRate, 1});
    chain.requestConfig(config);
    float chainImpulse = 1.5f;
    const double chainReduction = chain.process(&chainImpulse, 1);
    passed &= expect(chain.gainReductionDb() == chainReduction && chainReduction < 0.0,
        "DSP chain must publish the block's limiter gain reduction");

    if (passed) {
        std::printf("%d Hz sample-peak limiter: ceiling, linked stereo, smooth release, bypass, meter OK\n",
            sampleRate);
    }
    return passed;
}

bool testTpdfQuantizer() {
    constexpr int32_t kBits = 16;
    constexpr size_t kSampleCount = 200'000;
    uint64_t state = 0x9e3779b97f4a7c15ULL;
    int64_t sum = 0;
    uint64_t squareSum = 0;
    int64_t minimum = 0;
    int64_t maximum = 0;
    for (size_t index = 0; index < kSampleCount; ++index) {
        const int64_t sample = lazer::audio::quantizeWithTpdf(0.0f, kBits, state);
        sum += sample;
        squareSum += static_cast<uint64_t>(sample * sample);
        minimum = std::min(minimum, sample);
        maximum = std::max(maximum, sample);
    }
    const double mean = static_cast<double>(sum) / static_cast<double>(kSampleCount);
    const double variance = static_cast<double>(squareSum) / static_cast<double>(kSampleCount);
    const bool passed = expect(minimum == -1 && maximum == 1,
            "TPDF at digital silence should dither across adjacent quantization steps") &&
        expect(std::abs(mean) < 0.01,
            "TPDF silence noise should have near-zero mean") &&
        expect(variance >= 0.22 && variance <= 0.28,
            "TPDF silence noise should have the expected triangular quantization variance");
    if (passed) std::printf("16-bit TPDF silence vector: mean=%g LSB, variance=%g LSB^2 OK\n",
        mean, variance);
    return passed;
}

bool testIntegerPcmPacking() {
    constexpr uint64_t kInitialDitherState = 0x9e3779b97f4a7c15ULL;
    const float endpoints[2]{-2.0f, 2.0f};
    bool passed = true;

    uint8_t pcm16[4]{};
    uint64_t state16 = kInitialDitherState;
    const uint64_t clipped16 = lazer::audio::convertIntegerPcm(endpoints, 2, 16, 16, pcm16, state16);
    passed &= expect(pcm16[0] == 0x00 && pcm16[1] == 0x80 &&
        pcm16[2] == 0xff && pcm16[3] == 0x7f,
        "16-bit PCM must clamp to signed endpoints and pack little-endian");
    passed &= expect(clipped16 == 2,
        "integer clipping telemetry must count samples outside normalized full scale");

    uint8_t pcm24Packed[6]{};
    uint64_t state24Packed = kInitialDitherState;
    const uint64_t clipped24Packed = lazer::audio::convertIntegerPcm(
        endpoints, 2, 24, 24, pcm24Packed, state24Packed);
    passed &= expect(pcm24Packed[0] == 0x00 && pcm24Packed[1] == 0x00 && pcm24Packed[2] == 0x80 &&
        pcm24Packed[3] == 0xff && pcm24Packed[4] == 0xff && pcm24Packed[5] == 0x7f,
        "packed 24-bit PCM must clamp to signed endpoints and emit three little-endian bytes");
    passed &= expect(clipped24Packed == 2,
        "packed 24-bit clipping telemetry must count samples outside normalized full scale");

    uint8_t pcm24In32[8]{};
    uint64_t state24 = kInitialDitherState;
    lazer::audio::convertIntegerPcm(endpoints, 2, 24, 32, pcm24In32, state24);
    passed &= expect(pcm24In32[0] == 0x00 && pcm24In32[1] == 0x00 &&
        pcm24In32[2] == 0x00 && pcm24In32[3] == 0x80 &&
        pcm24In32[4] == 0x00 && pcm24In32[5] == 0xff &&
        pcm24In32[6] == 0xff && pcm24In32[7] == 0x7f,
        "24-valid-in-32 PCM must clamp and left-align the valid bits");

    uint8_t pcm32[8]{};
    uint64_t state32 = kInitialDitherState;
    const uint64_t clipped32 = lazer::audio::convertIntegerPcm(
        endpoints, 2, 32, 32, pcm32, state32);
    passed &= expect(pcm32[0] == 0x00 && pcm32[1] == 0x00 && pcm32[2] == 0x00 && pcm32[3] == 0x80 &&
        pcm32[4] == 0xff && pcm32[5] == 0xff && pcm32[6] == 0xff && pcm32[7] == 0x7f,
        "32-bit PCM must clamp to signed Q31 endpoints and emit four little-endian bytes");
    passed &= expect(clipped32 == 2,
        "32-bit clipping telemetry must count samples outside normalized full scale");

    uint8_t pcm8[2]{};
    uint64_t state8 = kInitialDitherState;
    lazer::audio::convertIntegerPcm(endpoints, 2, 8, 8, pcm8, state8);
    passed &= expect(pcm8[0] == 0x00 && pcm8[1] == 0xff,
        "8-bit PCM must clamp to unsigned endpoint codes");

    const float samplePeakInput[]{0.5f, -1.2f, 1.01f, 0.0f};
    passed &= expect(lazer::audio::samplePeakMilliDbfs(samplePeakInput, 4) == 1'584,
        "sample-peak telemetry must report the peak in milli-dBFS");
    const float silence[]{0.0f, 0.0f};
    passed &= expect(lazer::audio::samplePeakMilliDbfs(silence, 2) == -120'000,
        "sample-peak telemetry must use the documented floor for digital silence");

    if (passed) std::printf("integer PCM endpoints and valid/container packing OK\n");
    return passed;
}

}  // namespace

int main() {
    const bool at44100 = testSamplePeakCeiling(44'100);
    const bool at96000 = testSamplePeakCeiling(96'000);
    const bool dither = testTpdfQuantizer();
    const bool packing = testIntegerPcmPacking();
    return at44100 && at96000 && dither && packing ? 0 : 1;
}
