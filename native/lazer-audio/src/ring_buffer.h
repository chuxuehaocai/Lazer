/* A single-producer / single-consumer ring of whole PCM frames. The decode thread only writes, the
 * render thread only reads, and both publish progress through atomics so neither ever waits on the
 * other: a stalled audio endpoint must not stop the decoder from draining FFmpeg.
 *
 * Frames carry whatever the output asked for - float32 when the DSP chain is in play, or the device's
 * own integer layout when the listener wants a bit-perfect exclusive stream - so the ring is byte
 * oriented and only ever moves complete frames. */
#ifndef LAZER_AUDIO_RING_BUFFER_H
#define LAZER_AUDIO_RING_BUFFER_H

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <vector>

#include "internal.h"

namespace lazer::audio {

class RingBuffer {
public:
    RingBuffer() = default;

    /* The producer must not read while resetting: the engine only calls this while the pipeline is
     * parked, never from the render thread. */
    void reset(int32_t capacityFrames, int32_t frameBytes);

    [[nodiscard]] int32_t capacityFrames() const noexcept { return capacity_; }
    [[nodiscard]] int32_t frameBytes() const noexcept { return frameBytes_; }
    [[nodiscard]] int32_t readableFrames() const noexcept;
    [[nodiscard]] int32_t writableFrames() const noexcept {
        return capacity_ - static_cast<int32_t>(occupied());
    }

    int32_t write(const uint8_t *source, int32_t frameCount);
    int32_t read(uint8_t *destination, int32_t frameCount);

    /* Drops everything the consumer has not rendered yet, used by seek and stop. Only the producer
     * may call it; the consumer's read index is reset under the same rule. */
    void clearForProducer();

    /* The consumer snapshots this before a read and re-reads it after; a change means the frames it
     * just copied were invalidated by a seek, so it must discard them instead of rendering. */
    [[nodiscard]] uint64_t flushSequence() const noexcept {
        return flushSequence_.load(std::memory_order_acquire);
    }

private:
    [[nodiscard]] size_t occupied() const noexcept {
        return writeCursor_.load(std::memory_order_acquire) -
            readCursor_.load(std::memory_order_acquire);
    }

    /* The mask arithmetic needs a power-of-two frame count, so capacity is rounded up and the
     * storage carries one extra frame plus slack for the alignment offset. */
    std::vector<uint8_t> storage_;
    uint8_t *data_ = nullptr;
    int32_t capacity_ = 0;
    int32_t frameBytes_ = 0;
    std::atomic<size_t> writeCursor_{0};
    std::atomic<size_t> readCursor_{0};
    std::atomic<uint64_t> flushSequence_{0};
};

}  // namespace lazer::audio

#endif  // LAZER_AUDIO_RING_BUFFER_H
