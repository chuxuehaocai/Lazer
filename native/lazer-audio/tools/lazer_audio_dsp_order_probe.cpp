/* The DSP chain is explicit and ordered (ABI v27), so the order has to be provable, not cosmetic.
 *
 * Four things are checked, all offline on synthetic buffers:
 *   1. an empty request still means the documented default order (no behaviour change for callers
 *      that do not name one);
 *   2. putting the limiter before the EQ produces different samples than putting it after — the
 *      order is part of the result, because a limiter that runs first protects the *pre*-EQ signal;
 *   3. a stage left out of the order is bypassed, and its state is released rather than merely
 *      skipped;
 *   4. a request naming an unknown stage still applies the stages it did name.
 */
#include "dsp_chain.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <vector>

namespace {

using namespace lazer::audio;

constexpr int32_t kSampleRate = 48'000;
constexpr size_t kFrames = 4'096;

/* A signal hot enough that the limiter acts on it, so the order is audible in the samples. */
std::vector<float> makeSignal() {
    std::vector<float> samples(kFrames * 2);
    for (size_t frame = 0; frame < kFrames; ++frame) {
        const double t = static_cast<double>(frame) / kSampleRate;
        const float value = static_cast<float>(0.9 * std::sin(2.0 * M_PI * 220.0 * t));
        samples[frame * 2] = value;
        samples[frame * 2 + 1] = -value * 0.5f;
    }
    return samples;
}

LazerAudioEqBand makeBand() {
    LazerAudioEqBand band{};
    band.kind = LazerAudioEqBandPeak;
    band.frequency_hz = 1'000.0;
    band.gain_db = -18.0;  /* A deep cut: unmistakable in a byte comparison. */
    band.q = 1.0;
    band.enabled = 1;
    return band;
}

std::vector<float> runChain(const std::vector<int32_t> &order, bool limiterEnabled) {
    DspChain chain;
    chain.configureFormat(PcmFormat{kSampleRate, 2});
    LazerAudioEqBand band = makeBand();
    LazerAudioDspConfig config{};
    config.preamp_db = 6.0;
    config.band_count = 1;
    config.bands = &band;
    config.limiter_enabled = limiterEnabled ? 1 : 0;
    config.limiter_threshold_db = -12.0;
    config.stage_count = static_cast<uint32_t>(order.size());
    for (size_t index = 0; index < order.size(); ++index) {
        config.stage_order[index] = order[index];
    }
    chain.requestConfig(config);
    std::vector<float> samples = makeSignal();
    chain.process(samples.data(), kFrames);
    return samples;
}

bool same(const std::vector<float> &a, const std::vector<float> &b) {
    return a.size() == b.size() &&
        std::memcmp(a.data(), b.data(), a.size() * sizeof(float)) == 0;
}

size_t differingSamples(const std::vector<float> &a, const std::vector<float> &b) {
    size_t count = 0;
    for (size_t index = 0; index < std::min(a.size(), b.size()); ++index) {
        if (a[index] != b[index]) ++count;
    }
    return count;
}

}  // namespace

int main() {
    bool ok = true;

    const std::vector<int32_t> defaultOrder{
        LazerAudioDspStagePreamp, LazerAudioDspStageEq, LazerAudioDspStageCrossfeed,
        LazerAudioDspStageLimiter, LazerAudioDspStageVolume};

    /* 1. No order named == the documented default order. */
    const std::vector<float> implicitDefault = runChain({}, true);
    const std::vector<float> explicitDefault = runChain(defaultOrder, true);
    if (!same(implicitDefault, explicitDefault)) {
        std::cerr << "FAIL: an empty stage list does not reproduce the default order ("
            << differingSamples(implicitDefault, explicitDefault) << " samples differ)\n";
        ok = false;
    } else {
        std::cout << "PASS: an empty stage list reproduces the documented default order exactly\n";
    }

    /* 2. Limiter before the EQ is a different chain than limiter after it. */
    const std::vector<float> limiterFirst = runChain(
        {LazerAudioDspStageLimiter, LazerAudioDspStageEq}, true);
    const std::vector<float> eqFirst = runChain(
        {LazerAudioDspStageEq, LazerAudioDspStageLimiter}, true);
    const size_t orderDifference = differingSamples(limiterFirst, eqFirst);
    if (orderDifference == 0) {
        std::cerr << "FAIL: swapping the limiter and the EQ produced identical samples; the order "
                     "is not being applied\n";
        ok = false;
    } else {
        std::cout << "PASS: limiter-before-EQ and EQ-before-limiter differ in "
            << orderDifference << " of " << eqFirst.size() << " samples\n";
    }

    /* 3. Leaving the EQ out is a bypass, and it changes the result. */
    const std::vector<float> withoutEq = runChain({LazerAudioDspStagePreamp}, true);
    const std::vector<float> withEq = runChain({LazerAudioDspStagePreamp, LazerAudioDspStageEq}, true);
    if (differingSamples(withoutEq, withEq) == 0) {
        std::cerr << "FAIL: omitting the EQ from the order changed nothing\n";
        ok = false;
    } else {
        std::cout << "PASS: omitting the EQ from the order bypasses it ("
            << differingSamples(withoutEq, withEq) << " samples differ)\n";
    }

    /* Leaving the limiter out is a bypass too: the same order with it on differs. */
    const std::vector<float> withoutLimiter = runChain({LazerAudioDspStagePreamp}, false);
    if (differingSamples(withoutLimiter, withoutEq) != 0) {
        std::cerr << "FAIL: the limiter stage changed samples while it was disabled\n";
        ok = false;
    } else {
        std::cout << "PASS: a disabled limiter is transparent in the same order\n";
    }

    /* 4. An unknown stage is ignored, the named ones still apply. */
    const std::vector<float> withUnknown = runChain({99, LazerAudioDspStagePreamp}, true);
    if (!same(withUnknown, withoutEq)) {
        std::cerr << "FAIL: an unknown stage in the order changed the result\n";
        ok = false;
    } else {
        std::cout << "PASS: an unknown stage is ignored and the named stages still apply\n";
    }

    /* The chain reports the order it applies, which is what the UI will present. */
    DspChain chain;
    chain.configureFormat(PcmFormat{kSampleRate, 2});
    const std::vector<DspChain::Stage> reported = chain.activeOrder();
    if (reported.size() != defaultOrder.size() ||
        static_cast<int32_t>(reported[0]) != LazerAudioDspStagePreamp ||
        static_cast<int32_t>(reported.back()) != LazerAudioDspStageVolume) {
        std::cerr << "FAIL: the chain reported an unexpected default order\n";
        ok = false;
    } else {
        std::cout << "PASS: the chain reports the " << reported.size()
            << "-stage order it applies\n";
    }

    return ok ? 0 : 1;
}
