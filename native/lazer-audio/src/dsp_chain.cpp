#include "dsp_chain.h"

#include <algorithm>
#include <cmath>

namespace lazer::audio {

namespace {

constexpr double kPi = 3.14159265358979323846;

double clampFrequency(double frequency, int32_t sampleRate) {
    const double nyquist = static_cast<double>(sampleRate) * 0.5;
    return std::clamp(frequency, 10.0, nyquist - 10.0);
}

}  // namespace

void EqSection::configure(const Specification &specification, int32_t sampleRate) {
    active_ = false;
    if (!specification.enabled || sampleRate <= 0) {
        biquad_.reset();
        return;
    }

    const double sampleRateDouble = static_cast<double>(sampleRate);
    const double frequency = clampFrequency(specification.frequencyHz, sampleRate);
    const double q = std::max(specification.q, 0.1);
    const double w0 = 2.0 * kPi * frequency / sampleRateDouble;
    const double cosine = std::cos(w0);
    const double sine = std::sin(w0);
    /* Q of 0.7071 is Butterworth; the shelf slope uses the cookbook's midpoint convention so a
     * 100 Hz shelf measured on the mixer lands where the listener expects it. */
    const double alpha = sine / (2.0 * q);
    const double gainLinear = std::pow(10.0, specification.gainDb / 40.0);

    double b0 = 1.0;
    double b1 = 0.0;
    double b2 = 0.0;
    double a0 = 1.0;
    double a1 = 0.0;
    double a2 = 0.0;

    switch (specification.kind) {
        case Kind::Peak: {
            const double amplitude = std::pow(10.0, specification.gainDb / 20.0);
            const double peakAlpha = sine / 2.0 * std::sqrt((amplitude + 1.0 / amplitude) *
                (1.0 / q - 1.0) + 2.0);
            b0 = 1.0 + peakAlpha * amplitude;
            b1 = -2.0 * cosine;
            b2 = 1.0 - peakAlpha * amplitude;
            a0 = 1.0 + peakAlpha / amplitude;
            a1 = -2.0 * cosine;
            a2 = 1.0 - peakAlpha / amplitude;
            break;
        }
        case Kind::LowShelf: {
            const double shape = 2.0 * std::sqrt(gainLinear) * alpha;
            b0 = gainLinear * ((gainLinear + 1.0) - (gainLinear - 1.0) * cosine + shape);
            b1 = 2.0 * gainLinear * ((gainLinear - 1.0) - (gainLinear + 1.0) * cosine);
            b2 = gainLinear * ((gainLinear + 1.0) - (gainLinear - 1.0) * cosine - shape);
            a0 = (gainLinear + 1.0) + (gainLinear - 1.0) * cosine + shape;
            a1 = -2.0 * ((gainLinear - 1.0) + (gainLinear + 1.0) * cosine);
            a2 = (gainLinear + 1.0) + (gainLinear - 1.0) * cosine - shape;
            break;
        }
        case Kind::HighShelf: {
            const double shape = 2.0 * std::sqrt(gainLinear) * alpha;
            b0 = gainLinear * ((gainLinear + 1.0) + (gainLinear - 1.0) * cosine + shape);
            b1 = -2.0 * gainLinear * ((gainLinear - 1.0) + (gainLinear + 1.0) * cosine);
            b2 = gainLinear * ((gainLinear + 1.0) + (gainLinear - 1.0) * cosine - shape);
            a0 = (gainLinear + 1.0) - (gainLinear - 1.0) * cosine + shape;
            a1 = 2.0 * ((gainLinear - 1.0) - (gainLinear + 1.0) * cosine);
            a2 = (gainLinear + 1.0) - (gainLinear - 1.0) * cosine - shape;
            break;
        }
        case Kind::LowPass:
            b0 = (1.0 - cosine) / 2.0;
            b1 = 1.0 - cosine;
            b2 = (1.0 - cosine) / 2.0;
            a0 = 1.0 + alpha;
            a1 = -2.0 * cosine;
            a2 = 1.0 - alpha;
            break;
        case Kind::HighPass:
            b0 = (1.0 + cosine) / 2.0;
            b1 = -(1.0 + cosine);
            b2 = (1.0 + cosine) / 2.0;
            a0 = 1.0 + alpha;
            a1 = -2.0 * cosine;
            a2 = 1.0 - alpha;
            break;
        case Kind::Notch:
            b0 = 1.0;
            b1 = -2.0 * cosine;
            b2 = 1.0;
            a0 = 1.0 + alpha;
            a1 = -2.0 * cosine;
            a2 = 1.0 - alpha;
            break;
        case Kind::AllPass:
            b0 = 1.0 - alpha;
            b1 = -2.0 * cosine;
            b2 = 1.0 + alpha;
            a0 = 1.0 + alpha;
            a1 = -2.0 * cosine;
            a2 = 1.0 - alpha;
            break;
    }

    biquad_.b0 = b0 / a0;
    biquad_.b1 = b1 / a0;
    biquad_.b2 = b2 / a0;
    biquad_.a1 = a1 / a0;
    biquad_.a2 = a2 / a0;
    biquad_.reset();
    active_ = true;
}

void Limiter::configure(int32_t sampleRate, double thresholdDb, bool enabled) {
    sampleRate_ = sampleRate > 0 ? sampleRate : 44100;
    /* A threshold at or below the floor means the listener turned protection off; anything above it
     * is a real ceiling, because -0 dBFS on a float chain would clamp at every transient. */
    enabled_ = enabled && thresholdDb > -90.0;
    thresholdLinear_ = std::pow(10.0, thresholdDb / 20.0);
    /* Attack is immediate so the limiter enforces a real sample-peak ceiling. A one-millisecond
     * smoothed attack would let the transient through and leave the integer packer to hard-clip. */
    const double releaseSeconds = 0.12;
    releaseCoefficient_ = std::exp(-1.0 / (releaseSeconds * sampleRate_));
}

void Limiter::reset() noexcept {
    envelope_ = 1.0;
}

double Limiter::process(float *interleaved, size_t frameCount, size_t channels) noexcept {
    if (!enabled_ || interleaved == nullptr || frameCount == 0 || channels == 0) return 0.0;
    const double floorThreshold = std::max(thresholdLinear_, 1e-6);
    double blockReduction = 1.0;
    for (size_t frame = 0; frame < frameCount; ++frame) {
        float *samples = interleaved + frame * channels;
        double peak = 0.0;
        for (size_t channel = 0; channel < channels; ++channel) {
            peak = std::max(peak, std::abs(static_cast<double>(samples[channel])));
        }
        const double desired = peak > floorThreshold ? floorThreshold / peak : 1.0;
        if (desired < envelope_) {
            envelope_ = desired;
        } else {
            envelope_ = releaseCoefficient_ * envelope_ +
                (1.0 - releaseCoefficient_) * desired;
        }
        /* Keep the output under the ceiling even at floating-point rounding boundaries. */
        const double applied = std::min({envelope_, desired, 1.0});
        blockReduction = std::min(blockReduction, applied);
        for (size_t channel = 0; channel < channels; ++channel) {
            samples[channel] = static_cast<float>(samples[channel] * applied);
        }
    }
    return 20.0 * std::log10(std::max(blockReduction, 1e-9));
}

void VolumeRamp::configure(int32_t sampleRate, int32_t durationMillis) {
    const int32_t rate = sampleRate > 0 ? sampleRate : 44100;
    totalFrames_ = std::max(rate * static_cast<double>(durationMillis) / 1000.0, 1.0);
}

void VolumeRamp::setTarget(double target) {
    const double clamped = std::clamp(target, 0.0, 1.0);
    if (clamped == target_) return;
    start_ = current_;
    target_ = clamped;
    remainingFrames_ = totalFrames_;
}

void VolumeRamp::reset(double gain) noexcept {
    current_ = std::clamp(gain, 0.0, 1.0);
    start_ = current_;
    target_ = current_;
    remainingFrames_ = 0.0;
}

double VolumeRamp::process(float *interleaved, size_t frameCount, size_t channels) noexcept {
    if (interleaved == nullptr || frameCount == 0 || channels == 0) return current_;
    const size_t total = frameCount * channels;
    if (remainingFrames_ <= 0.0) {
        if (current_ != 1.0) {
            for (size_t index = 0; index < total; ++index) {
                interleaved[index] = static_cast<float>(interleaved[index] * current_);
            }
        }
        return current_;
    }
    /* One increment per frame rather than a division per sample keeps a 32-band chain well inside a
     * block's budget on a slow laptop core. */
    const double step = (target_ - start_) / totalFrames_;
    for (size_t frame = 0; frame < frameCount; ++frame) {
        current_ = remainingFrames_ > 1.0
            ? start_ + (totalFrames_ - remainingFrames_) * step
            : target_;
        float *samples = interleaved + frame * channels;
        for (size_t channel = 0; channel < channels; ++channel) {
            samples[channel] = static_cast<float>(samples[channel] * current_);
        }
        remainingFrames_ -= 1.0;
        if (remainingFrames_ <= 0.0) {
            current_ = target_;
        }
    }
    return current_;
}


/* ---- Crossfeed -------------------------------------------------------------------------------
 * Ported from the Twilight Echo audio engine (`audio-engine/dsp/CrossfeedProcessor.cpp`,
 * Apache-2.0). The algorithm choice fixes delay and cutoff; the direct path is attenuated as the
 * cross path grows so the total power stays roughly constant instead of getting louder. */
void Crossfeed::configure(const Specification &specification, int32_t sampleRate, int32_t channels) {
    const bool wasActive = active_;
    /* Only stereo has a cross channel to feed. */
    active_ = specification.enabled && specification.strength > 0.0001 && channels == 2 &&
              sampleRate > 0;
    if (!active_) {
        reset();
        return;
    }

    const double strength = std::clamp(specification.strength, 0.0, 1.0);
    const Algorithm algorithm = static_cast<Algorithm>(specification.algorithm);
    double delayMs = specification.delayMs;
    double cutoffHz = specification.cutoffHz;
    switch (algorithm) {
        case Algorithm::Bauer:
        case Algorithm::Bs2b:
            directGain_ = 1.0 - 0.12 * strength;
            crossGain_ = 0.24 * strength;
            delayMs = 0.22;
            cutoffHz = 700.0;
            break;
        case Algorithm::Meier:
            directGain_ = 1.0 - 0.05 * strength;
            crossGain_ = 0.18 * strength;
            delayMs = 0.35;
            cutoffHz = 650.0;
            break;
        case Algorithm::Custom:
        default:
            directGain_ = 1.0 - 0.08 * strength;
            crossGain_ = 0.38 * strength;
            break;
    }

    delayMs = std::clamp(delayMs, 0.05, 2.0);
    cutoffHz = std::clamp(cutoffHz, 80.0, 4000.0);
    const size_t delaySamples = static_cast<size_t>(
        std::max(1.0, std::round(static_cast<double>(sampleRate) * delayMs / 1000.0)));
    delayLeft_.assign(delaySamples, 0.0f);
    delayRight_.assign(delaySamples, 0.0f);
    index_ = 0;

    const double dt = 1.0 / static_cast<double>(sampleRate);
    const double rc = 1.0 / (2.0 * 3.14159265358979323846 * cutoffHz);
    alpha_ = dt / (rc + dt);
    lowpassLeft_ = 0.0;
    lowpassRight_ = 0.0;
    if (!wasActive) reset();
}

void Crossfeed::reset() noexcept {
    std::fill(delayLeft_.begin(), delayLeft_.end(), 0.0f);
    std::fill(delayRight_.begin(), delayRight_.end(), 0.0f);
    index_ = 0;
    lowpassLeft_ = 0.0;
    lowpassRight_ = 0.0;
}

void Crossfeed::process(float *interleaved, size_t frameCount, size_t channels) noexcept {
    if (!active_ || interleaved == nullptr || frameCount == 0 || channels != 2 ||
        delayLeft_.empty() || delayRight_.empty()) {
        return;
    }
    const size_t size = delayLeft_.size();
    for (size_t frame = 0; frame < frameCount; ++frame) {
        const size_t offset = frame * 2;
        const double left = interleaved[offset];
        const double right = interleaved[offset + 1];

        const double delayedLeft = delayLeft_[index_];
        const double delayedRight = delayRight_[index_];
        delayLeft_[index_] = static_cast<float>(left);
        delayRight_[index_] = static_cast<float>(right);
        index_ += 1;
        if (index_ >= size) index_ = 0;

        lowpassLeft_ += alpha_ * (delayedLeft - lowpassLeft_);
        lowpassRight_ += alpha_ * (delayedRight - lowpassRight_);

        interleaved[offset] =
            static_cast<float>(std::clamp(left * directGain_ + lowpassRight_ * crossGain_, -4.0, 4.0));
        interleaved[offset + 1] =
            static_cast<float>(std::clamp(right * directGain_ + lowpassLeft_ * crossGain_, -4.0, 4.0));
    }
}

bool Convolver::configure(const float *taps, int32_t channels, size_t frames) {
    if (taps == nullptr || channels <= 0 || frames == 0 || frames > kMaxTaps) return false;
    taps_.assign(taps, taps + static_cast<size_t>(channels) * frames);
    tapFrames_ = frames;
    channels_ = channels;
    history_.assign(static_cast<size_t>(channels) * frames * 2, 0.0f);
    cursor_ = 0;
    return true;
}

void Convolver::reset() noexcept {
    std::fill(history_.begin(), history_.end(), 0.0f);
    cursor_ = 0;
}

void Convolver::process(float *interleaved, size_t frameCount) noexcept {
    if (!active() || interleaved == nullptr || frameCount == 0) return;
    const size_t channels = static_cast<size_t>(channels_);
    const size_t taps = tapFrames_;
    for (size_t frame = 0; frame < frameCount; ++frame) {
        float *samples = interleaved + frame * channels;
        /* Mirror the new sample so the tap window stays contiguous; the newest sample ends up at
         * `cursor + taps`, and y[n] = sum over k of taps[k] * x[n-k] walks backwards from there. */
        for (size_t channel = 0; channel < channels; ++channel) {
            const float value = samples[channel];
            const size_t base = channel * taps * 2;
            history_[base + cursor_] = value;
            history_[base + cursor_ + taps] = value;
        }
        for (size_t channel = 0; channel < channels; ++channel) {
            const float *channelTaps = taps_.data() + channel * taps;
            const float *channelHistory = history_.data() + channel * taps * 2 + cursor_ + taps;
            float accumulator = 0.0f;
            for (size_t tap = 0; tap < taps; ++tap) {
                accumulator += channelTaps[tap] * channelHistory[-static_cast<ptrdiff_t>(tap)];
            }
            samples[channel] = accumulator;
        }
        cursor_ = (cursor_ + 1) % taps;
    }
}

void DspChain::configureFormat(PcmFormat format) {
    format_ = format;
    sections_.clear();
    applyPendingConfig();
    volume_.configure(format_.sampleRate, rampMillis_);
    volume_.reset(1.0);
    reset();
}

void DspChain::requestConfig(const LazerAudioDspConfig &config) {
    std::lock_guard guard(pendingMutex_);
    /* The bands pointer belongs to the caller's stack, so the specifications are copied here rather
     * than read on the audio thread. The order is a fixed array in the struct, so it is copied the
     * same way and validated on the audio thread. */
    pendingBands_.assign(config.bands, config.bands + std::min<uint32_t>(
        config.band_count, LAZER_AUDIO_MAX_EQ_BANDS));
    pendingPreampDb_ = config.preamp_db;
    pendingLimiterEnabled_ = config.limiter_enabled != 0;
    pendingLimiterThresholdDb_ = config.limiter_threshold_db;
    pendingCrossfeed_.enabled = config.crossfeed_enabled != 0;
    pendingCrossfeed_.strength = config.crossfeed_strength;
    pendingCrossfeed_.algorithm = config.crossfeed_algorithm;
    pendingCrossfeed_.delayMs = config.crossfeed_delay_ms;
    pendingCrossfeed_.cutoffHz = config.crossfeed_cutoff_hz;
    pendingTapFrames_ = static_cast<size_t>(config.impulse_response_frames);
    pendingTapChannels_ = static_cast<int32_t>(config.impulse_response_channels);
    if (config.impulse_response == nullptr || pendingTapFrames_ == 0 ||
        pendingTapChannels_ <= 0 || pendingTapFrames_ > Convolver::kMaxTaps) {
        pendingTapFrames_ = 0;
        pendingTapChannels_ = 0;
        pendingTaps_.clear();
    } else {
        /* The caller's buffer is not ours after this returns. */
        pendingTaps_.assign(config.impulse_response,
            config.impulse_response + pendingTapFrames_ * static_cast<size_t>(pendingTapChannels_));
    }
    pendingOrder_.clear();
    const uint32_t stageCount = std::min<uint32_t>(config.stage_count, LAZER_AUDIO_MAX_DSP_STAGES);
    for (uint32_t index = 0; index < stageCount; ++index) {
        const int32_t value = config.stage_order[index];
        if (value < LazerAudioDspStagePreamp || value > LazerAudioDspStageConvolver) {
            /* An unknown stage is ignored rather than failing the whole request: the chain still
             * has to keep the stages the caller did name. */
            continue;
        }
        pendingOrder_.push_back(static_cast<Stage>(value));
    }
    pendingDirty_ = true;
}

void DspChain::setVolume(double volume, int32_t rampMillis) {
    rampMillis_ = std::max(rampMillis, 1);
    volume_.configure(format_.sampleRate > 0 ? format_.sampleRate : 44100, rampMillis_);
    volume_.setTarget(std::clamp(volume, 0.0, 1.0));
}

void DspChain::reset() noexcept {
    for (auto &section : sections_) section.reset();
    crossfeed_.reset();
    limiter_.reset();
    convolver_.reset();
}

bool DspChain::eqActive() const noexcept {
    return std::any_of(sections_.begin(), sections_.end(),
        [](const EqSection &section) { return section.active(); });
}

std::vector<DspChain::Stage> DspChain::activeOrder() const {
    return order_.empty()
        ? std::vector<Stage>(kDefaultOrder.begin(), kDefaultOrder.end())
        : order_;
}

void DspChain::applyOrder(const std::vector<Stage> &order) {
    order_ = order;
    if (order_.empty()) return;
    /* A stage the caller left out is bypassed, which for the EQ means its sections are cleared and
     * for the limiter that it stops processing — not merely skipped at the call site, so the state
     * it would otherwise carry into the next request is gone. */
    const auto listed = [this](Stage stage) {
        return std::find(order_.begin(), order_.end(), stage) != order_.end();
    };
    if (!listed(Stage::Eq)) sections_.clear();
    if (!listed(Stage::Crossfeed)) crossfeed_.reset();
    if (!listed(Stage::Limiter)) limiter_.configure(format_.sampleRate, -1.0, false);
    if (!listed(Stage::Convolver)) convolver_.reset();
}

void DspChain::applyPendingConfig() {
    std::vector<LazerAudioEqBand> bands;
    double preampDb = 0.0;
    bool limiterEnabled = false;
    double limiterThresholdDb = -1.0;
    Crossfeed::Specification crossfeed;
    std::vector<float> taps;
    size_t tapFrames = 0;
    int32_t tapChannels = 0;
    {
        std::lock_guard guard(pendingMutex_);
        if (!pendingDirty_) return;
        bands = pendingBands_;
        preampDb = pendingPreampDb_;
        limiterEnabled = pendingLimiterEnabled_;
        limiterThresholdDb = pendingLimiterThresholdDb_;
        crossfeed = pendingCrossfeed_;
        taps = pendingTaps_;
        tapFrames = pendingTapFrames_;
        tapChannels = pendingTapChannels_;
        pendingDirty_ = false;
    }

    preampLinear_ = std::pow(10.0, preampDb / 20.0);
    sections_.resize(bands.size());
    for (size_t index = 0; index < bands.size(); ++index) {
        EqSection::Specification specification;
        switch (bands[index].kind) {
            case LazerAudioEqBandLowShelf:
                specification.kind = EqSection::Kind::LowShelf;
                break;
            case LazerAudioEqBandHighShelf:
                specification.kind = EqSection::Kind::HighShelf;
                break;
            case LazerAudioEqBandLowPass:
                specification.kind = EqSection::Kind::LowPass;
                break;
            case LazerAudioEqBandHighPass:
                specification.kind = EqSection::Kind::HighPass;
                break;
            case LazerAudioEqBandNotch:
                specification.kind = EqSection::Kind::Notch;
                break;
            case LazerAudioEqBandAllPass:
                specification.kind = EqSection::Kind::AllPass;
                break;
            default:
                specification.kind = EqSection::Kind::Peak;
                break;
        }
        specification.frequencyHz = bands[index].frequency_hz;
        specification.gainDb = bands[index].gain_db;
        specification.q = bands[index].q <= 0.0 ? 1.0 : bands[index].q;
        specification.enabled = bands[index].enabled != 0;
        sections_[index].configure(specification, format_.sampleRate);
    }
    /* Crossfeed runs between the EQ and the limiter by default: the limiter therefore protects the
     * summed signal, which is what actually leaves the chain. A caller that asks for another order
     * gets exactly that order — see `process()`. */
    crossfeed_.configure(crossfeed, format_.sampleRate, format_.channels);
    limiter_.configure(format_.sampleRate, limiterThresholdDb, limiterEnabled);
    limiter_.reset();
    if (tapFrames > 0 && static_cast<int32_t>(tapChannels) == format_.channels) {
        convolver_.configure(taps.data(), tapChannels, tapFrames);
    } else if (!taps.empty()) {
        /* An IR whose channel count does not match the session would silently mix channels; drop it
         * and leave the stage inert instead. */
        convolver_.reset();
        convolver_.configure(nullptr, 0, 0);
    }
    applyOrder(pendingOrder_);
}

double DspChain::process(float *interleaved, size_t frameCount) {
    if (interleaved == nullptr || frameCount == 0 || !format_.isValid()) return 0.0;
    applyPendingConfig();
    const size_t channels = static_cast<size_t>(format_.channels);
    const std::vector<Stage> order = activeOrder();

    double reduction = 0.0;
    for (const Stage stage : order) {
        switch (stage) {
            case Stage::Preamp:
                if (preampLinear_ == 1.0) break;
                for (size_t frame = 0; frame < frameCount; ++frame) {
                    float *samples = interleaved + frame * channels;
                    for (size_t channel = 0; channel < channels; ++channel) {
                        samples[channel] = static_cast<float>(samples[channel] * preampLinear_);
                    }
                }
                break;
            case Stage::Eq:
                if (sections_.empty()) break;
                for (size_t frame = 0; frame < frameCount; ++frame) {
                    float *samples = interleaved + frame * channels;
                    for (size_t channel = 0; channel < channels; ++channel) {
                        double value = samples[channel];
                        for (auto &section : sections_) {
                            if (section.active()) {
                                value = section.process(static_cast<float>(value), channel);
                            }
                        }
                        samples[channel] = static_cast<float>(value);
                    }
                }
                break;
            case Stage::Crossfeed:
                crossfeed_.process(interleaved, frameCount, channels);
                break;
            case Stage::Limiter:
                if (!limiter_.enabled()) break;
                /* The last limiter in the chain reports its gain reduction; the telemetry row is
                 * about the protection the listener actually gets. */
                reduction = limiter_.process(interleaved, frameCount, channels);
                break;
            case Stage::Volume:
                volume_.process(interleaved, frameCount, channels);
                break;
            case Stage::Convolver:
                if (!convolverActive()) break;
                convolver_.process(interleaved, frameCount);
                break;
        }
    }
    lastReductionDb_ = reduction;
    return reduction;
}

}  // namespace lazer::audio
