#ifndef LAZER_AUDIO_BEAT_GRID_CAPTURE_H
#define LAZER_AUDIO_BEAT_GRID_CAPTURE_H

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

#include "beat_grid.h"

namespace lazer_audio {

/* Analysis-only mono window, at no more than 48 kHz. The playback samples never pass through this
 * reducer. Its memory and autocorrelation work are independent of source rate and channel count. */
class BeatGridCapture {
public:
    static constexpr int32_t kMaxAnalysisRate = 48'000;
    static constexpr int32_t kSeconds = 6;

    void append(const float *samples, int32_t frames, int32_t rate, size_t channels) {
        if (samples == nullptr || frames <= 0 || rate <= 0 || channels == 0) return;
        if (rate_ == 0) {
            rate_ = rate;
            stride_ = std::max<int32_t>(1, (static_cast<int64_t>(rate) + kMaxAnalysisRate - 1) /
                kMaxAnalysisRate);
            maximumInputFrames_ = static_cast<int64_t>(rate) * kSeconds;
            mono_.reserve(static_cast<size_t>(maximumInputFrames_ / stride_));
        }
        if (rate != rate_) return;
        const int32_t take = static_cast<int32_t>(std::min<int64_t>(frames,
            maximumInputFrames_ - inputFrames_));
        for (int32_t frame = 0; frame < take; ++frame) {
            double mono = 0.0;
            for (size_t channel = 0; channel < channels; ++channel) {
                mono += samples[static_cast<size_t>(frame) * channels + channel];
            }
            pendingSum_ += mono / static_cast<double>(channels);
            if (++pendingFrames_ == stride_) {
                mono_.push_back(static_cast<float>(pendingSum_ / stride_));
                pendingSum_ = 0.0;
                pendingFrames_ = 0;
            }
        }
        inputFrames_ += take;
    }

    [[nodiscard]] bool full() const noexcept {
        return rate_ > 0 && inputFrames_ >= maximumInputFrames_;
    }
    [[nodiscard]] bool empty() const noexcept { return inputFrames_ == 0; }
    [[nodiscard]] size_t storageBytes() const noexcept { return mono_.capacity() * sizeof(float); }

    [[nodiscard]] BeatGrid estimate() const {
        const int32_t analysisRate = rate_ > 0 ? std::max(1, rate_ / stride_) : 0;
        BeatGrid grid = estimateBeatGrid(mono_.data(), static_cast<int64_t>(mono_.size()),
            analysisRate, 1);
        if (grid.valid) {
            grid.firstBeatFrame *= stride_;
            grid.bpm *= static_cast<double>(rate_) / (static_cast<double>(analysisRate) * stride_);
        }
        grid.sampleRate = rate_;
        return grid;
    }

private:
    int32_t rate_ = 0;
    int32_t stride_ = 1;
    int32_t pendingFrames_ = 0;
    int64_t maximumInputFrames_ = 0;
    int64_t inputFrames_ = 0;
    double pendingSum_ = 0.0;
    std::vector<float> mono_;
};

}  // namespace lazer_audio

#endif
