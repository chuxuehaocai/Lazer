/* Finite impulse response convolution as a chain stage (ABI v29).
 *
 * Nothing in the app enables this stage — no setting, no default IR, no UI — so the only thing that
 * can be said about it is what these cases prove. They are about the contract rather than about a
 * fancy algorithm: the stage sits in the ordered chain, it consumes caller-supplied taps copied by
 * the engine, it is bypassed when left out of the order, it refuses an unusable IR, and it leaves
 * the signal untouched whenever it is not in the path.
 */
#include "dsp_chain.h"

#include <cmath>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <vector>

namespace {

using namespace lazer::audio;

constexpr int32_t kSampleRate = 48'000;
constexpr int32_t kChannels = 2;
constexpr size_t kFrames = 512;

std::vector<float> makeSignal() {
    std::vector<float> samples(kFrames * kChannels);
    for (size_t frame = 0; frame < kFrames; ++frame) {
        const float value = static_cast<float>(std::sin(0.01 * static_cast<double>(frame)));
        samples[frame * kChannels] = value;
        samples[frame * kChannels + 1] = -value;
    }
    return samples;
}

std::vector<float> stereoEcho() {
    std::vector<float> taps(static_cast<size_t>(kChannels) * 2, 0.0f);
    for (int32_t channel = 0; channel < kChannels; ++channel) {
        taps[static_cast<size_t>(channel) * 2] = 0.5f;
        taps[static_cast<size_t>(channel) * 2 + 1] = 0.5f;
    }
    return taps;
}

/* Runs the chain once with the given order and IR; the taps are channel-major. */
std::vector<float> run(const std::vector<int32_t> &order, const std::vector<float> &taps,
    size_t tapFrames, int32_t tapChannels) {
    DspChain chain;
    chain.configureFormat(PcmFormat{kSampleRate, kChannels});
    LazerAudioDspConfig config{};
    config.stage_count = static_cast<uint32_t>(order.size());
    for (size_t index = 0; index < order.size(); ++index) {
        config.stage_order[index] = order[index];
    }
    if (!taps.empty()) {
        config.impulse_response = taps.data();
        config.impulse_response_frames = static_cast<uint32_t>(tapFrames);
        config.impulse_response_channels = static_cast<uint32_t>(tapChannels);
    }
    chain.requestConfig(config);
    std::vector<float> samples = makeSignal();
    chain.process(samples.data(), kFrames);
    return samples;
}

bool nearlyEqual(const std::vector<float> &a, const std::vector<float> &b, float epsilon = 1e-6f) {
    if (a.size() != b.size()) return false;
    for (size_t index = 0; index < a.size(); ++index) {
        if (std::fabs(a[index] - b[index]) > epsilon) return false;
    }
    return true;
}

}  // namespace

int main() {
    bool ok = true;
    const std::vector<float> signal = makeSignal();

    /* 1. A unit impulse is the identity. */
    {
        const std::vector<float> taps(kChannels, 1.0f);
        if (!nearlyEqual(run({LazerAudioDspStageConvolver}, taps, 1, kChannels), signal)) {
            std::cerr << "FAIL: a unit impulse changed the signal\n";
            ok = false;
        } else {
            std::cout << "PASS: a unit impulse is the identity through the convolver\n";
        }
    }

    /* 2. A two-tap response matches a direct convolution, sample for sample. */
    {
        const std::vector<float> output =
            run({LazerAudioDspStageConvolver}, stereoEcho(), 2, kChannels);
        std::vector<float> expected(signal.size(), 0.0f);
        for (size_t frame = 0; frame < kFrames; ++frame) {
            for (int32_t channel = 0; channel < kChannels; ++channel) {
                const size_t index = frame * kChannels + static_cast<size_t>(channel);
                const float previous = frame == 0
                    ? 0.0f
                    : signal[(frame - 1) * kChannels + static_cast<size_t>(channel)];
                expected[index] = 0.5f * signal[index] + 0.5f * previous;
            }
        }
        if (!nearlyEqual(output, expected)) {
            std::cerr << "FAIL: the two-tap response does not match a direct convolution\n";
            ok = false;
        } else {
            std::cout << "PASS: a two-tap response matches a direct convolution sample for sample\n";
        }
    }

    /* 3. Left out of the order, the stage is bypassed even though an IR was supplied. */
    {
        if (!nearlyEqual(run({LazerAudioDspStageVolume}, stereoEcho(), 2, kChannels), signal)) {
            std::cerr << "FAIL: an IR altered a chain that does not list the convolver\n";
            ok = false;
        } else {
            std::cout << "PASS: an IR left out of the order does not touch the signal\n";
        }
    }

    /* 4. An IR whose channel count does not match the session is refused, not mixed. */
    {
        const std::vector<float> mono(4, 0.5f);
        if (!nearlyEqual(run({LazerAudioDspStageConvolver}, mono, 4, 1), signal)) {
            std::cerr << "FAIL: a mono IR was applied to a stereo session\n";
            ok = false;
        } else {
            std::cout << "PASS: an IR that does not match the session channels is refused\n";
        }
    }

    /* 5. An IR longer than the cap is refused, and the stage stays inert. */
    {
        const std::vector<float> huge(
            static_cast<size_t>(Convolver::kMaxTaps + 1) * kChannels, 0.0f);
        DspChain chain;
        chain.configureFormat(PcmFormat{kSampleRate, kChannels});
        LazerAudioDspConfig config{};
        config.stage_count = 1;
        config.stage_order[0] = LazerAudioDspStageConvolver;
        config.impulse_response = huge.data();
        config.impulse_response_frames = static_cast<uint32_t>(Convolver::kMaxTaps + 1);
        config.impulse_response_channels = kChannels;
        chain.requestConfig(config);
        std::vector<float> samples = makeSignal();
        chain.process(samples.data(), kFrames);
        if (!nearlyEqual(samples, signal) || chain.convolverActive()) {
            std::cerr << "FAIL: an oversized IR was accepted\n";
            ok = false;
        } else {
            std::cout << "PASS: an IR longer than " << Convolver::kMaxTaps
                << " taps is refused and the stage stays inert\n";
        }
    }

    /* 6. Bypassing the stage clears its history. With a two-tap IR, the first frame after
     * re-enabling must be 0.5 * x[0] + 0.5 * (nothing): stale history would add the previous run's
     * last sample instead. */
    {
        DspChain chain;
        chain.configureFormat(PcmFormat{kSampleRate, kChannels});
        LazerAudioDspConfig withConvolver{};
        withConvolver.stage_count = 1;
        withConvolver.stage_order[0] = LazerAudioDspStageConvolver;
        const std::vector<float> echo = stereoEcho();
        withConvolver.impulse_response = echo.data();
        withConvolver.impulse_response_frames = 2;
        withConvolver.impulse_response_channels = kChannels;
        chain.requestConfig(withConvolver);
        std::vector<float> first = makeSignal();
        chain.process(first.data(), 64);
        LazerAudioDspConfig bypassed = withConvolver;
        bypassed.stage_order[0] = LazerAudioDspStageVolume;
        chain.requestConfig(bypassed);
        std::vector<float> muted = makeSignal();
        chain.process(muted.data(), 64);
        chain.requestConfig(withConvolver);
        std::vector<float> resumed = makeSignal();
        chain.process(resumed.data(), 64);
        const std::vector<float> input = makeSignal();
        bool clean = true;
        for (int32_t channel = 0; channel < kChannels; ++channel) {
            const float expected = 0.5f * input[static_cast<size_t>(channel)];
            if (std::fabs(resumed[static_cast<size_t>(channel)] - expected) > 1e-6f) clean = false;
        }
        if (!clean) {
            std::cerr << "FAIL: re-enabling kept state from before the bypass\n";
            ok = false;
        } else {
            std::cout << "PASS: bypassing the stage clears its history\n";
        }
    }

    return ok ? 0 : 1;
}
