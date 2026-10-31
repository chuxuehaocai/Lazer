/* The float32 processing chain between the resampler and the output ring: preamp, biquad EQ,
 * protection limiter and the smoothed volume ramp. Everything runs interleaved at the device rate,
 * so no stage has to care about sample depth. */
#ifndef LAZER_AUDIO_DSP_CHAIN_H
#define LAZER_AUDIO_DSP_CHAIN_H

#include <array>
#include <atomic>
#include <cmath>
#include <mutex>
#include <vector>
#include "internal.h"

namespace lazer::audio {

/* One second-order section using the RBJ cookbook coefficients. State is per channel; b is in
 * double because a 20 Hz shelf on a 44.1 kHz clock diverges visibly in float. */
struct Biquad {
    double b0 = 1.0;
    double b1 = 0.0;
    double b2 = 0.0;
    double a1 = 0.0;
    double a2 = 0.0;
    std::array<double, 8 * 4> history{};  /* [x1,x2,y1,y2] per channel, up to 8 channels. */

    void reset() { history.fill(0.0); }

    float process(float input, size_t channel) noexcept {
        if (channel >= 8) return input;
        const size_t base = channel * 4;
        const double x2 = history[base];
        const double x1 = history[base + 1];
        const double y2 = history[base + 2];
        const double y1 = history[base + 3];
        const double x = input;
        const double y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
        history[base] = x1;
        history[base + 1] = x;
        history[base + 2] = y1;
        history[base + 3] = y;
        return static_cast<float>(y);
    }
};

/* Design filters for a clock; re-derived whenever the output rate changes. */
class EqSection {
public:
    enum class Kind { Peak, LowShelf, HighShelf, LowPass, HighPass, Notch, AllPass };

    struct Specification {
        Kind kind = Kind::Peak;
        double frequencyHz = 1000.0;
        double gainDb = 0.0;
        double q = 1.0;
        bool enabled = true;
    };

    void configure(const Specification &specification, int32_t sampleRate);
    void reset() noexcept { biquad_.reset(); }
    float process(float input, size_t channel) noexcept { return biquad_.process(input, channel); }
    [[nodiscard]] bool active() const noexcept { return active_; }

private:
    Biquad biquad_;
    bool active_ = false;
};

class Limiter {
public:
    void configure(int32_t sampleRate, double thresholdDb, bool enabled);
    void reset() noexcept;
    /* Returns the largest gain reduction applied inside the block, for the UI's GR meter. */
    double process(float *interleaved, size_t frameCount, size_t channels) noexcept;

    [[nodiscard]] bool enabled() const noexcept { return enabled_; }
    [[nodiscard]] double gainReductionDb() const noexcept {
        return 20.0 * std::log10(envelope_ <= 0.0 ? 1.0 : envelope_);
    }

private:
    bool enabled_ = false;
    double thresholdLinear_ = 1.0;
    double releaseCoefficient_ = 0.0;
    double envelope_ = 1.0;
    int32_t sampleRate_ = 44100;
};

/* A per-frame interpolating gain so a slider drag or a pause fade never steps the waveform. */
class VolumeRamp {
public:
    void configure(int32_t sampleRate, int32_t durationMillis);
    void setTarget(double target);
    void reset(double gain) noexcept;
    double process(float *interleaved, size_t frameCount, size_t channels) noexcept;
    [[nodiscard]] double current() const noexcept { return current_; }

private:
    double current_ = 1.0;
    double start_ = 1.0;
    double target_ = 1.0;
    double remainingFrames_ = 0.0;
    double totalFrames_ = 1.0;
};


/* Cross-channel feed for headphone listening: mixes a delayed, low-passed copy of
 * each channel into the other, which moves the image out of the head. The delay and
 * cutoff come from the chosen algorithm (Bauer/Bs2b 0.22 ms at 700 Hz, Meier 0.35 ms
 * at 650 Hz) and the direct/cross gains scale with the strength.
 *
 * Ported from the Twilight Echo audio engine (`audio-engine/dsp/CrossfeedProcessor.cpp`,
 * Apache-2.0), reduced to the sample maths this chain needs: it runs interleaved at the
 * device rate like every other stage here. */
class Crossfeed {
public:
    enum class Algorithm { Custom = 0, Bauer = 1, Bs2b = 2, Meier = 3 };

    struct Specification {
        bool enabled = false;
        double strength = 0.0;      /* 0..1, below 0.0001 is treated as off. */
        int32_t algorithm = 0;      /* Algorithm */
        double delayMs = 0.22;      /* Custom only. */
        double cutoffHz = 700.0;    /* Custom only. */
    };

    void configure(const Specification &specification, int32_t sampleRate, int32_t channels);
    void reset() noexcept;
    [[nodiscard]] bool active() const noexcept { return active_; }
    void process(float *interleaved, size_t frameCount, size_t channels) noexcept;

private:
    std::vector<float> delayLeft_;
    std::vector<float> delayRight_;
    size_t index_ = 0;
    double lowpassLeft_ = 0.0;
    double lowpassRight_ = 0.0;
    double alpha_ = 0.0;
    double directGain_ = 1.0;
    double crossGain_ = 0.0;
    bool active_ = false;
};

/* Owns the EQ sections and applies the whole chain. The engine installs a new EQ request from the
 * caller's thread; the audio thread picks it up at the next block boundary, which at ~5 ms blocks is
 * far below audibility.
 *
 * The chain itself is explicit: `LazerAudioDspConfig::stage_order` names the stages front to back and
 * leaves the rest bypassed. Every stage reads and writes the same interleaved float buffer and owns
 * its own state, so the order is the whole of the contract between them — which is also what makes
 * "the EQ is in the signal path" a fact a caller can point at rather than an assumption. */
class DspChain {
public:
    /* One processing stage. */
    enum class Stage : int32_t {
        Preamp = LazerAudioDspStagePreamp,
        Eq = LazerAudioDspStageEq,
        Crossfeed = LazerAudioDspStageCrossfeed,
        Limiter = LazerAudioDspStageLimiter,
        Volume = LazerAudioDspStageVolume,
    };

    /* The order used when a request does not name one. */
    static constexpr std::array<Stage, 5> kDefaultOrder{
        Stage::Preamp, Stage::Eq, Stage::Crossfeed, Stage::Limiter, Stage::Volume};

    void configureFormat(PcmFormat format);
    /* Safe from the caller's thread: the request is copied and the audio thread installs it at the
     * next block boundary. */
    void requestConfig(const LazerAudioDspConfig &config);
    void setVolume(double volume, int32_t rampMillis);
    void reset() noexcept;

    /* Returns the limiter's gain reduction in dB for the block, or 0 when the limiter is off. */
    double process(float *interleaved, size_t frameCount);
    [[nodiscard]] bool eqActive() const noexcept;
    [[nodiscard]] bool crossfeedActive() const noexcept { return crossfeed_.active(); }
    [[nodiscard]] double gainReductionDb() const noexcept { return lastReductionDb_; }
    /* The order the audio thread currently applies, for probes and diagnostics. */
    [[nodiscard]] std::vector<Stage> activeOrder() const;

private:
    void applyPendingConfig();
    void applyOrder(const std::vector<Stage> &order);

    std::mutex pendingMutex_;
    std::vector<LazerAudioEqBand> pendingBands_;
    double pendingPreampDb_ = 0.0;
    bool pendingLimiterEnabled_ = false;
    double pendingLimiterThresholdDb_ = -1.0;
    Crossfeed::Specification pendingCrossfeed_;
    /* Empty means "the engine's default order". */
    std::vector<Stage> pendingOrder_;
    bool pendingDirty_ = false;

    PcmFormat format_{};
    std::vector<EqSection> sections_;
    Crossfeed crossfeed_;
    double preampLinear_ = 1.0;
    Limiter limiter_;
    VolumeRamp volume_;
    int32_t rampMillis_ = 200;
    double lastReductionDb_ = 0.0;
    /* Applied order, owned by the audio thread once installed. */
    std::vector<Stage> order_;
};

}  // namespace lazer::audio

#endif  // LAZER_AUDIO_DSP_CHAIN_H
