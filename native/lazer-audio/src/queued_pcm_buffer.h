/* Bounded decoded-PCM staging between a queued source's decoder worker and the engine pump. */
#ifndef LAZER_AUDIO_QUEUED_PCM_BUFFER_H
#define LAZER_AUDIO_QUEUED_PCM_BUFFER_H

#include <algorithm>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include "source.h"

namespace lazer::audio {

class QueuedPcmBuffer final : public SourceConsumer {
public:
    QueuedPcmBuffer(size_t capacityFrames, size_t readyWatermarkFrames, size_t frameBytes)
        : capacityFrames_(std::max<size_t>(capacityFrames, 1)),
          readyWatermarkFrames_(std::clamp<size_t>(readyWatermarkFrames, 1, capacityFrames_)),
          frameBytes_(std::max<size_t>(frameBytes, 1)),
          storage_(capacityFrames_ * frameBytes_) {}

    int32_t accept(const uint8_t *bytes, int32_t frameCount) override {
        if (bytes == nullptr || frameCount <= 0) return 0;
        std::lock_guard guard(mutex_);
        if (cancelled_ || finished_) return 0;
        const size_t accepted = std::min<size_t>(
            static_cast<size_t>(frameCount), capacityFrames_ - queuedFrames_);
        if (accepted == 0) return 0;
        copyIn(bytes, accepted);
        queuedFrames_ += accepted;
        changed_.notify_all();
        return static_cast<int32_t>(accepted);
    }

    bool shouldPump() const override {
        std::lock_guard guard(mutex_);
        return !cancelled_ && !finished_ && queuedFrames_ < capacityFrames_;
    }

    bool isCancelled() const override {
        std::lock_guard guard(mutex_);
        return cancelled_;
    }

    bool waitUntilReady() {
        std::unique_lock guard(mutex_);
        changed_.wait(guard, [this] {
            return cancelled_ || queuedFrames_ >= readyWatermarkFrames_ || finished_;
        });
        return !cancelled_ && (queuedFrames_ >= readyWatermarkFrames_ || queuedFrames_ > 0);
    }

    void waitForDataOrFinish() {
        std::unique_lock guard(mutex_);
        changed_.wait(guard, [this] { return cancelled_ || queuedFrames_ > 0 || finished_; });
    }

    int32_t peekFrames(uint8_t *destination, int32_t maxFrames) const {
        if (destination == nullptr || maxFrames <= 0) return 0;
        std::lock_guard guard(mutex_);
        const size_t count = std::min<size_t>(queuedFrames_, static_cast<size_t>(maxFrames));
        copyOut(destination, count);
        return static_cast<int32_t>(count);
    }

    void consumeFrames(int32_t frameCount) {
        if (frameCount <= 0) return;
        std::lock_guard guard(mutex_);
        const size_t consumed = std::min<size_t>(queuedFrames_, static_cast<size_t>(frameCount));
        readFrame_ = (readFrame_ + consumed) % capacityFrames_;
        queuedFrames_ -= consumed;
        if (consumed > 0) changed_.notify_all();
    }

    void finish(int32_t result, std::string error, bool reachedEof) {
        std::lock_guard guard(mutex_);
        if (finished_) return;
        result_ = result;
        error_ = std::move(error);
        reachedEof_ = reachedEof;
        finished_ = true;
        changed_.notify_all();
    }

    void cancel() {
        std::lock_guard guard(mutex_);
        cancelled_ = true;
        changed_.notify_all();
    }

    void discardAll() {
        std::lock_guard guard(mutex_);
        readFrame_ = writeFrame_;
        queuedFrames_ = 0;
        changed_.notify_all();
    }

    bool resetForRestart() {
        std::lock_guard guard(mutex_);
        if (!finished_ || cancelled_) return false;
        readFrame_ = 0;
        writeFrame_ = 0;
        queuedFrames_ = 0;
        finished_ = false;
        reachedEof_ = false;
        result_ = LazerAudioOk;
        error_.clear();
        changed_.notify_all();
        return true;
    }

    [[nodiscard]] size_t queuedFrames() const {
        std::lock_guard guard(mutex_);
        return queuedFrames_;
    }

    [[nodiscard]] bool finished() const {
        std::lock_guard guard(mutex_);
        return finished_;
    }

    [[nodiscard]] bool cancelled() const {
        std::lock_guard guard(mutex_);
        return cancelled_;
    }

    [[nodiscard]] bool reachedEof() const {
        std::lock_guard guard(mutex_);
        return reachedEof_;
    }

    [[nodiscard]] int32_t result() const {
        std::lock_guard guard(mutex_);
        return result_;
    }

    [[nodiscard]] std::string error() const {
        std::lock_guard guard(mutex_);
        return error_;
    }

    [[nodiscard]] size_t readyWatermarkFrames() const noexcept {
        return readyWatermarkFrames_;
    }

private:
    void copyIn(const uint8_t *source, size_t frames) {
        const size_t firstFrames = std::min(frames, capacityFrames_ - writeFrame_);
        const size_t firstBytes = firstFrames * frameBytes_;
        std::memcpy(storage_.data() + writeFrame_ * frameBytes_, source, firstBytes);
        if (firstFrames < frames) {
            std::memcpy(storage_.data(), source + firstBytes, (frames - firstFrames) * frameBytes_);
        }
        writeFrame_ = (writeFrame_ + frames) % capacityFrames_;
    }

    void copyOut(uint8_t *destination, size_t frames) const {
        const size_t firstFrames = std::min(frames, capacityFrames_ - readFrame_);
        const size_t firstBytes = firstFrames * frameBytes_;
        std::memcpy(destination, storage_.data() + readFrame_ * frameBytes_, firstBytes);
        if (firstFrames < frames) {
            std::memcpy(destination + firstBytes, storage_.data(), (frames - firstFrames) * frameBytes_);
        }
    }

    const size_t capacityFrames_;
    const size_t readyWatermarkFrames_;
    const size_t frameBytes_;
    std::vector<uint8_t> storage_;
    mutable std::mutex mutex_;
    std::condition_variable changed_;
    size_t readFrame_ = 0;
    size_t writeFrame_ = 0;
    size_t queuedFrames_ = 0;
    bool cancelled_ = false;
    bool finished_ = false;
    bool reachedEof_ = false;
    int32_t result_ = LazerAudioOk;
    std::string error_;
};

}  // namespace lazer::audio

#endif  // LAZER_AUDIO_QUEUED_PCM_BUFFER_H
