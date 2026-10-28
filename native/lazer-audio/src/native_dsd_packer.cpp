#include "native_dsd_packer.h"

#include <limits>

namespace lazer::audio {

NativeDsdPacker::NativeDsdPacker(size_t channels, size_t wordBytes,
    bool bigEndian) noexcept : channels_(channels), wordBytes_(wordBytes),
    bigEndian_(bigEndian) {
    reset();
}

void NativeDsdPacker::reset() noexcept {
    pendingFrames_ = 0;
    pending_.fill(0x69);
}

void NativeDsdPacker::writePending(uint8_t *destination) const noexcept {
    for (size_t channel = 0; channel < channels_; ++channel) {
        for (size_t byte = 0; byte < wordBytes_; ++byte) {
            const size_t sourceByte = bigEndian_ ? byte : wordBytes_ - byte - 1;
            destination[channel * wordBytes_ + byte] =
                pending_[sourceByte * channels_ + channel];
        }
    }
}

NativeDsdPackResult NativeDsdPacker::pack(const uint8_t *interleavedDsd,
    size_t inputFrameCount, uint8_t *nativeDsd,
    size_t outputCapacityFrames) noexcept {
    if (channels_ != 1 && channels_ != 2) {
        return {NativeDsdPackStatus::InvalidChannelCount, 0, 0};
    }
    if (wordBytes_ != 1 && wordBytes_ != 2 && wordBytes_ != 4) {
        return {NativeDsdPackStatus::InvalidWordBytes, 0, 0};
    }
    if ((inputFrameCount > 0 && interleavedDsd == nullptr) ||
        (outputCapacityFrames > 0 && nativeDsd == nullptr)) {
        return {NativeDsdPackStatus::InvalidArgument, 0, 0};
    }

    constexpr size_t kMax = std::numeric_limits<size_t>::max();
    const size_t outputBytesPerFrame = channels_ * wordBytes_;
    if (inputFrameCount > kMax / channels_ ||
        outputCapacityFrames > kMax / outputBytesPerFrame) {
        return {NativeDsdPackStatus::SizeOverflow, 0, 0};
    }

    size_t consumed = 0;
    size_t produced = 0;
    while (consumed < inputFrameCount) {
        if (pendingFrames_ + 1 == wordBytes_ && produced == outputCapacityFrames) {
            return {NativeDsdPackStatus::OutputFull, consumed, produced};
        }
        for (size_t channel = 0; channel < channels_; ++channel) {
            pending_[pendingFrames_ * channels_ + channel] =
                interleavedDsd[consumed * channels_ + channel];
        }
        ++consumed;
        ++pendingFrames_;
        if (pendingFrames_ == wordBytes_) {
            writePending(nativeDsd + produced * outputBytesPerFrame);
            ++produced;
            pendingFrames_ = 0;
        }
    }

    return {pendingFrames_ == 0 ? NativeDsdPackStatus::Ok : NativeDsdPackStatus::NeedMoreInput,
        consumed, produced};
}

NativeDsdPackResult NativeDsdPacker::flush(uint8_t *nativeDsd,
    size_t outputCapacityFrames) noexcept {
    if (channels_ != 1 && channels_ != 2) {
        return {NativeDsdPackStatus::InvalidChannelCount, 0, 0};
    }
    if (wordBytes_ != 1 && wordBytes_ != 2 && wordBytes_ != 4) {
        return {NativeDsdPackStatus::InvalidWordBytes, 0, 0};
    }
    if (pendingFrames_ == 0) return {NativeDsdPackStatus::Ok, 0, 0};
    if (outputCapacityFrames == 0) return {NativeDsdPackStatus::OutputFull, 0, 0};
    if (nativeDsd == nullptr) return {NativeDsdPackStatus::InvalidArgument, 0, 0};

    for (size_t frame = pendingFrames_; frame < wordBytes_; ++frame) {
        for (size_t channel = 0; channel < channels_; ++channel) {
            pending_[frame * channels_ + channel] = 0x69;
        }
    }
    writePending(nativeDsd);
    pendingFrames_ = 0;
    return {NativeDsdPackStatus::Ok, 0, 1};
}

}  // namespace lazer::audio
