/* Single-producer/single-consumer PCM frame queue shared by the Engine render thread and the
 * CoreAudio IOProc. The callback never acquires a mutex or allocates memory. */
#ifndef LAZER_AUDIO_COREAUDIO_PCM_QUEUE_H
#define LAZER_AUDIO_COREAUDIO_PCM_QUEUE_H

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <vector>

namespace lazer::audio {

class CoreAudioPcmQueue {
public:
    bool configure(size_t capacityFrames, size_t frameBytes) {
        if (capacityFrames == 0 || frameBytes == 0 ||
            capacityFrames > std::numeric_limits<size_t>::max() / frameBytes) {
            return false;
        }
        try {
            bytes_.assign(capacityFrames * frameBytes, 0);
        } catch (...) {
            bytes_.clear();
            capacityFrames_ = 0;
            frameBytes_ = 0;
            return false;
        }
        capacityFrames_ = capacityFrames;
        frameBytes_ = frameBytes;
        writeFrame_.store(0, std::memory_order_relaxed);
        readFrame_.store(0, std::memory_order_relaxed);
        return true;
    }

    void reset() noexcept {
        /* The caller must stop the CoreAudio IOProc and serialize Engine writes first. */
        readFrame_.store(0, std::memory_order_relaxed);
        writeFrame_.store(0, std::memory_order_relaxed);
    }

    [[nodiscard]] size_t capacityFrames() const noexcept { return capacityFrames_; }
    [[nodiscard]] size_t frameBytes() const noexcept { return frameBytes_; }

    [[nodiscard]] size_t queuedFrames() const noexcept {
        const uint64_t written = writeFrame_.load(std::memory_order_acquire);
        const uint64_t read = readFrame_.load(std::memory_order_acquire);
        const uint64_t queued = written >= read ? written - read : 0;
        return static_cast<size_t>(std::min<uint64_t>(queued, capacityFrames_));
    }

    [[nodiscard]] size_t writableFrames() const noexcept {
        return capacityFrames_ - queuedFrames();
    }

    int32_t write(const uint8_t *source, int32_t frames) noexcept {
        if (source == nullptr || frames <= 0 || frameBytes_ == 0 || capacityFrames_ == 0) {
            return frames == 0 ? 0 : -1;
        }
        const uint64_t written = writeFrame_.load(std::memory_order_relaxed);
        const uint64_t read = readFrame_.load(std::memory_order_acquire);
        const uint64_t queued = written >= read ? written - read : 0;
        const size_t count = std::min(static_cast<size_t>(frames),
            capacityFrames_ - static_cast<size_t>(std::min<uint64_t>(queued, capacityFrames_)));
        copyIn(static_cast<size_t>(written % capacityFrames_), source, count);
        writeFrame_.store(written + count, std::memory_order_release);
        return static_cast<int32_t>(count);
    }

    /* Copies complete interleaved frames byte-for-byte. This is used for DoP, whose three-byte
     * words cannot pass through the PCM sample endian/layout conversion path. */
    int32_t readInterleavedBytes(uint8_t *destination, size_t byteCapacity,
        size_t maximumFrames) noexcept {
        if (destination == nullptr || frameBytes_ == 0 || capacityFrames_ == 0) return -1;
        const uint64_t read = readFrame_.load(std::memory_order_relaxed);
        const uint64_t written = writeFrame_.load(std::memory_order_acquire);
        const size_t available = written >= read
            ? static_cast<size_t>(std::min<uint64_t>(written - read, capacityFrames_)) : 0;
        const size_t count = std::min({maximumFrames, byteCapacity / frameBytes_, available,
            static_cast<size_t>(std::numeric_limits<int32_t>::max())});
        if (count == 0) return 0;
        copyOut(static_cast<size_t>(read % capacityFrames_), destination, count);
        readFrame_.store(read + count, std::memory_order_release);
        return static_cast<int32_t>(count);
    }

    /* Copies engine-interleaved frames into one interleaved buffer or one buffer per channel.
     * Byte order is converted only at this boundary. Buffer capacities are measured in bytes. */
    int32_t readToBuffers(uint8_t *const *destinations, const size_t *capacities,
        size_t destinationCount, bool interleaved, int32_t channels, int32_t bytesPerSample,
        bool destinationLittleEndian, int32_t maximumFrames) noexcept {
        if (destinations == nullptr || capacities == nullptr || channels <= 0 ||
            bytesPerSample <= 0 || maximumFrames <= 0 || frameBytes_ == 0 ||
            destinationCount != (interleaved ? 1U : static_cast<size_t>(channels)) ||
            static_cast<size_t>(channels) * static_cast<size_t>(bytesPerSample) != frameBytes_) {
            return -1;
        }

        size_t capacity = static_cast<size_t>(maximumFrames);
        for (size_t index = 0; index < destinationCount; ++index) {
            if (destinations[index] == nullptr) return -1;
            const size_t bytesPerFrame = interleaved ? frameBytes_
                : static_cast<size_t>(bytesPerSample);
            capacity = std::min(capacity, capacities[index] / bytesPerFrame);
        }
        const uint64_t read = readFrame_.load(std::memory_order_relaxed);
        const uint64_t written = writeFrame_.load(std::memory_order_acquire);
        const size_t available = written >= read
            ? static_cast<size_t>(std::min<uint64_t>(written - read, capacityFrames_)) : 0;
        const size_t frames = std::min(capacity, available);
        if (frames == 0) return 0;

        const bool reverseBytes = destinationLittleEndian != hostIsLittleEndian();
        for (size_t frame = 0; frame < frames; ++frame) {
            const size_t sourceFrame = static_cast<size_t>((read + frame) % capacityFrames_);
            const uint8_t *source = bytes_.data() + sourceFrame * frameBytes_;
            for (int32_t channel = 0; channel < channels; ++channel) {
                const uint8_t *sample = source + static_cast<size_t>(channel) * bytesPerSample;
                uint8_t *destination = interleaved
                    ? destinations[0] + frame * frameBytes_ +
                        static_cast<size_t>(channel) * bytesPerSample
                    : destinations[channel] + frame * bytesPerSample;
                if (!reverseBytes || bytesPerSample == 1) {
                    std::memcpy(destination, sample, static_cast<size_t>(bytesPerSample));
                } else {
                    for (int32_t byte = 0; byte < bytesPerSample; ++byte) {
                        destination[byte] = sample[bytesPerSample - byte - 1];
                    }
                }
            }
        }
        readFrame_.store(read + frames, std::memory_order_release);
        return static_cast<int32_t>(frames);
    }

private:
    static bool hostIsLittleEndian() noexcept {
        const uint16_t value = 1;
        return *reinterpret_cast<const uint8_t *>(&value) == 1;
    }

    void copyIn(size_t frameOffset, const uint8_t *source, size_t frames) noexcept {
        const size_t firstFrames = std::min(frames, capacityFrames_ - frameOffset);
        const size_t firstBytes = firstFrames * frameBytes_;
        std::memcpy(bytes_.data() + frameOffset * frameBytes_, source, firstBytes);
        const size_t remainingFrames = frames - firstFrames;
        if (remainingFrames > 0) {
            std::memcpy(bytes_.data(), source + firstBytes, remainingFrames * frameBytes_);
        }
    }

    void copyOut(size_t frameOffset, uint8_t *destination, size_t frames) const noexcept {
        const size_t firstFrames = std::min(frames, capacityFrames_ - frameOffset);
        const size_t firstBytes = firstFrames * frameBytes_;
        std::memcpy(destination, bytes_.data() + frameOffset * frameBytes_, firstBytes);
        const size_t remainingFrames = frames - firstFrames;
        if (remainingFrames > 0) {
            std::memcpy(destination + firstBytes, bytes_.data(), remainingFrames * frameBytes_);
        }
    }

    std::vector<uint8_t> bytes_;
    size_t capacityFrames_ = 0;
    size_t frameBytes_ = 0;
    std::atomic<uint64_t> writeFrame_{0};
    std::atomic<uint64_t> readFrame_{0};
};

}  // namespace lazer::audio

#endif  // LAZER_AUDIO_COREAUDIO_PCM_QUEUE_H
