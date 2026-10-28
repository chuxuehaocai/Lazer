#include "dop_packer.h"

#include <limits>

namespace lazer::audio {

DopPacker::DopPacker(size_t channels) noexcept : channels_(channels) {
    reset();
}

void DopPacker::reset() noexcept {
    pendingFrame_.fill(0);
    hasPendingFrame_ = false;
    nextMarker_ = 0x05;
}

DopPackResult DopPacker::pack(const uint8_t *interleavedDsd,
    size_t inputFrameCount, uint8_t *interleavedDop,
    size_t outputCapacityFrames) noexcept {
    if (channels_ != 1 && channels_ != 2) {
        return {DopPackStatus::InvalidChannelCount, 0, 0};
    }
    if ((inputFrameCount > 0 && interleavedDsd == nullptr) ||
        (outputCapacityFrames > 0 && interleavedDop == nullptr)) {
        return {DopPackStatus::InvalidArgument, 0, 0};
    }

    constexpr size_t kMax = std::numeric_limits<size_t>::max();
    const size_t outputBytesPerFrame = channels_ * 3;
    if (inputFrameCount > kMax / channels_ ||
        outputCapacityFrames > kMax / outputBytesPerFrame) {
        return {DopPackStatus::SizeOverflow, 0, 0};
    }

    size_t consumed = 0;
    size_t produced = 0;
    while (consumed < inputFrameCount) {
        if (!hasPendingFrame_) {
            const size_t inputOffset = consumed * channels_;
            for (size_t channel = 0; channel < channels_; ++channel) {
                pendingFrame_[channel] = interleavedDsd[inputOffset + channel];
            }
            hasPendingFrame_ = true;
            ++consumed;
            if (consumed == inputFrameCount) {
                return {DopPackStatus::NeedMoreInput, consumed, produced};
            }
        }

        if (produced == outputCapacityFrames) {
            return {DopPackStatus::OutputFull, consumed, produced};
        }

        const size_t inputOffset = consumed * channels_;
        const size_t outputOffset = produced * outputBytesPerFrame;
        for (size_t channel = 0; channel < channels_; ++channel) {
            const size_t channelOffset = channel * 3;
            interleavedDop[outputOffset + channelOffset] = pendingFrame_[channel];
            interleavedDop[outputOffset + channelOffset + 1] =
                interleavedDsd[inputOffset + channel];
            interleavedDop[outputOffset + channelOffset + 2] = nextMarker_;
        }
        ++consumed;
        ++produced;
        hasPendingFrame_ = false;
        nextMarker_ = nextMarker_ == 0x05 ? 0xFA : 0x05;
    }

    return {hasPendingFrame_ ? DopPackStatus::NeedMoreInput : DopPackStatus::Ok,
        consumed, produced};
}

DopPackResult DopPacker::flush(uint8_t *interleavedDop,
    size_t outputCapacityFrames) noexcept {
    if (channels_ != 1 && channels_ != 2) {
        return {DopPackStatus::InvalidChannelCount, 0, 0};
    }
    if (!hasPendingFrame_) return {DopPackStatus::Ok, 0, 0};
    if (outputCapacityFrames == 0) return {DopPackStatus::OutputFull, 0, 0};
    if (interleavedDop == nullptr) return {DopPackStatus::InvalidArgument, 0, 0};

    for (size_t channel = 0; channel < channels_; ++channel) {
        const size_t offset = channel * 3;
        interleavedDop[offset] = pendingFrame_[channel];
        interleavedDop[offset + 1] = 0x69;
        interleavedDop[offset + 2] = nextMarker_;
    }
    hasPendingFrame_ = false;
    pendingFrame_.fill(0);
    nextMarker_ = nextMarker_ == 0x05 ? 0xFA : 0x05;
    return {DopPackStatus::Ok, 0, 1};
}

int32_t prepareDopCarrierFrames(uint8_t *bytes, int32_t writableFrames,
    int32_t audioFrames, int32_t channels, bool fixedPeriod,
    uint8_t &nextMarker) noexcept {
    if (writableFrames < 0 || audioFrames < 0 || (channels != 1 && channels != 2) ||
        (writableFrames > 0 && bytes == nullptr)) {
        return -1;
    }
    if (writableFrames == 0) return 0;

    const int32_t audioCount = audioFrames < writableFrames ? audioFrames : writableFrames;
    const int32_t framesToWrite = fixedPeriod || audioCount == 0
        ? writableFrames : audioCount;
    for (int32_t frame = 0; frame < framesToWrite; ++frame) {
        uint8_t *carrierFrame = bytes + static_cast<size_t>(frame) *
            static_cast<size_t>(channels) * 3;
        if (frame >= audioCount) {
            /* DoP idle uses the alternating 0x69 DSD payload pattern. */
            for (int32_t channel = 0; channel < channels; ++channel) {
                uint8_t *word = carrierFrame + static_cast<size_t>(channel) * 3;
                word[0] = 0x69;
                word[1] = 0x69;
            }
        }
        for (int32_t channel = 0; channel < channels; ++channel) {
            carrierFrame[static_cast<size_t>(channel) * 3 + 2] = nextMarker;
        }
        nextMarker = nextMarker == 0x05 ? 0xFA : 0x05;
    }
    return framesToWrite;
}

}  // namespace lazer::audio
