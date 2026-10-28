/* Hardware-free regression checks for the crossfeed stage.
 *
 * Crossfeed mixes each channel into the other, so the interesting properties are
 * measurable on a synthetic signal: a right-only impulse must appear on the left
 * channel after the configured delay, the strength must scale that leakage, an
 * inactive/off crossfeed must be bit-transparent, and the stage must ignore layouts
 * it cannot cross (mono, and more than stereo).
 *
 * The stage is driven through the real `DspChain`, so it also proves the request
 * plumbing (requestConfig → applyPendingConfig → process) and that the limiter still
 * sees the summed signal.
 */
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <vector>

#include "dsp_chain.h"

namespace {

bool expect(bool condition, const char *message) {
    if (condition) return true;
    std::fprintf(stderr, "FAIL: %s\n", message);
    return false;
}

lazer::audio::PcmFormat stereoFormat(int32_t sampleRate) {
    lazer::audio::PcmFormat format{};
    format.sampleRate = sampleRate;
    format.channels = 2;
    return format;
}

LazerAudioDspConfig crossfeedConfig(
    bool enabled, double strength, int32_t algorithm, double delayMs, double cutoffHz) {
    LazerAudioDspConfig config{};
    config.preamp_db = 0.0;
    config.band_count = 0;
    config.bands = nullptr;
    config.limiter_enabled = 0;
    config.limiter_threshold_db = -1.0;
    config.crossfeed_enabled = enabled ? 1 : 0;
    config.crossfeed_strength = strength;
    config.crossfeed_algorithm = algorithm;
    config.crossfeed_delay_ms = delayMs;
    config.crossfeed_cutoff_hz = cutoffHz;
    return config;
}

/* An impulse in the right channel only: the left channel's first non-zero sample is the
 * crossfeed leakage, and the position of that impulse through the right channel's direct
 * path stays at frame zero. */
bool testCrossChannelLeakage(int32_t sampleRate) {
    bool passed = true;

    lazer::audio::DspChain chain;
    chain.configureFormat(stereoFormat(sampleRate));
    chain.requestConfig(crossfeedConfig(true, 1.0, /*algorithm=*/0, 0.22, 700.0));
    chain.setVolume(1.0, 1);

    constexpr size_t kFrames = 512;
    std::vector<float> buffer(kFrames * 2, 0.0f);
    buffer[2 * 100 + 1] = 0.5f; /* right channel impulse at frame 100 */
    chain.process(buffer.data(), kFrames);

    double leftPeak = 0.0;
    size_t leftPeakFrame = 0;
    for (size_t frame = 0; frame < kFrames; ++frame) {
        const double magnitude = std::abs(static_cast<double>(buffer[frame * 2]));
        if (magnitude > leftPeak) {
            leftPeak = magnitude;
            leftPeakFrame = frame;
        }
    }
    double rightChannelPeak = 0.0;
    for (size_t frame = 0; frame < kFrames; ++frame) {
        rightChannelPeak = std::max(rightChannelPeak,
            std::abs(static_cast<double>(buffer[frame * 2 + 1])));
    }

    /* The leakage amplitude depends on the one-pole coefficient, so it shrinks as the
     * sample rate rises (alpha = dt/(rc+dt)). Assert the ratio to the source impulse
     * instead of an absolute level so the check holds at every rate. */
    const double leakageRatio = leftPeak / 0.5;
    passed &= expect(leakageRatio > 0.005 && leakageRatio < 0.2,
        "a right-channel impulse must leak into the left channel with a plausible ratio");
    passed &= expect(leftPeakFrame > 100,
        "the leaked signal must arrive after the source impulse (delayed path)");
    passed &= expect(rightChannelPeak > leftPeak,
        "the direct channel must stay louder than the crossfed copy at full strength");

    /* Raising the strength must raise the leakage. */
    lazer::audio::DspChain quiet;
    quiet.configureFormat(stereoFormat(sampleRate));
    quiet.requestConfig(crossfeedConfig(true, 0.25, 0, 0.22, 700.0));
    quiet.setVolume(1.0, 1);
    std::vector<float> quietBuffer(kFrames * 2, 0.0f);
    quietBuffer[2 * 100 + 1] = 0.5f;
    quiet.process(quietBuffer.data(), kFrames);
    double quietLeftPeak = 0.0;
    for (size_t frame = 0; frame < kFrames; ++frame) {
        quietLeftPeak = std::max(quietLeftPeak,
            std::abs(static_cast<double>(quietBuffer[frame * 2])));
    }
    passed &= expect(quietLeftPeak < leftPeak,
        "a lower strength must leak less into the opposite channel");
    return passed;
}

/* Off must be bit-transparent: the chain may not touch the samples at all. */
bool testDisabledIsTransparent(int32_t sampleRate) {
    bool passed = true;
    lazer::audio::DspChain chain;
    chain.configureFormat(stereoFormat(sampleRate));
    chain.requestConfig(crossfeedConfig(false, 1.0, 0, 0.22, 700.0));
    chain.setVolume(1.0, 1);

    std::vector<float> buffer(64 * 2);
    for (size_t frame = 0; frame < 64; ++frame) {
        buffer[frame * 2] = static_cast<float>(0.1 * static_cast<double>(frame));
        buffer[frame * 2 + 1] = static_cast<float>(-0.1 * static_cast<double>(frame));
    }
    const std::vector<float> original = buffer;
    chain.process(buffer.data(), 64);
    passed &= expect(buffer == original,
        "a disabled crossfeed stage must leave the samples untouched");
    return passed;
}

/* Only stereo has a cross channel; other layouts must not be touched. */
bool testNonStereoIsIgnored(int32_t sampleRate) {
    bool passed = true;
    lazer::audio::PcmFormat mono = stereoFormat(sampleRate);
    mono.channels = 1;

    lazer::audio::DspChain chain;
    chain.configureFormat(mono);
    chain.requestConfig(crossfeedConfig(true, 1.0, 0, 0.22, 700.0));
    chain.setVolume(1.0, 1);
    std::vector<float> buffer(32);
    for (size_t index = 0; index < buffer.size(); ++index) {
        buffer[index] = (index % 2 == 0) ? 0.5f : -0.5f;
    }
    const std::vector<float> original = buffer;
    chain.process(buffer.data(), 32);
    passed &= expect(buffer == original,
        "crossfeed must be bypassed for mono sources");
    return passed;
}

/* The named algorithms use their own delay/cutoff, so their leakage differs from the
 * custom default at the same strength. */
bool testAlgorithmsDiffer(int32_t sampleRate) {
    bool passed = true;
    auto leakage = [sampleRate](int32_t algorithm) {
        lazer::audio::DspChain chain;
        chain.configureFormat(stereoFormat(sampleRate));
        chain.requestConfig(crossfeedConfig(true, 1.0, algorithm, 0.22, 700.0));
        chain.setVolume(1.0, 1);
        constexpr size_t kFrames = 256;
        std::vector<float> buffer(kFrames * 2, 0.0f);
        buffer[2 * 20 + 1] = 1.0f;
        chain.process(buffer.data(), kFrames);
        double peak = 0.0;
        for (size_t frame = 0; frame < kFrames; ++frame) {
            peak = std::max(peak, std::abs(static_cast<double>(buffer[frame * 2])));
        }
        return peak;
    };

    const double custom = leakage(0);
    const double bauer = leakage(1);
    const double meier = leakage(3);
    passed &= expect(custom > 0.0 && bauer > 0.0 && meier > 0.0,
        "every crossfeed algorithm must produce leakage");
    passed &= expect(bauer != custom && meier != custom,
        "named algorithms must not behave like the custom default");
    passed &= expect(meier < bauer,
        "Meier's weaker cross gain must leak less than Bauer's");
    return passed;
}

/* The limiter runs after crossfeed, so it must still catch a summed peak. */
bool testLimiterSeesSummedSignal(int32_t sampleRate) {
    bool passed = true;
    lazer::audio::DspChain chain;
    chain.configureFormat(stereoFormat(sampleRate));
    LazerAudioDspConfig config =
        crossfeedConfig(true, 1.0, 0, 0.22, 700.0);
    config.limiter_enabled = 1;
    config.limiter_threshold_db = -1.0;
    chain.requestConfig(config);
    chain.setVolume(1.0, 1);

    constexpr size_t kFrames = 256;
    std::vector<float> buffer(kFrames * 2, 0.0f);
    for (size_t frame = 0; frame < 32; ++frame) {
        buffer[frame * 2] = 0.95f;
        buffer[frame * 2 + 1] = 0.95f;
    }
    chain.process(buffer.data(), kFrames);
    const double ceiling = std::pow(10.0, -1.0 / 20.0);
    bool underCeiling = true;
    for (float sample : buffer) {
        if (std::abs(static_cast<double>(sample)) > ceiling + 1e-4) {
            underCeiling = false;
            break;
        }
    }
    passed &= expect(underCeiling,
        "the limiter must keep the crossfed signal under its ceiling");
    return passed;
}

}  // namespace

int main() {
    bool passed = true;
    passed &= testCrossChannelLeakage(44'100);
    passed &= testCrossChannelLeakage(96'000);
    passed &= testDisabledIsTransparent(48'000);
    passed &= testNonStereoIsIgnored(48'000);
    passed &= testAlgorithmsDiffer(48'000);
    passed &= testLimiterSeesSummedSignal(48'000);
    if (!passed) std::fprintf(stderr, "crossfeed probe failed\n");
    return passed ? 0 : 1;
}
