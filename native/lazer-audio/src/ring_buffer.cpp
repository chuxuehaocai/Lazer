#include "ring_buffer.h"

#include <algorithm>
#include <cstring>

namespace lazer::audio {

namespace {

constexpr size_t kAlignmentBytes = 64;

size_t roundUpToPowerOfTwo(size_t value) {
    size_t result = 1;
    while (result < value) result <<= 1U;
    return result;
}

}  // namespace

void RingBuffer::reset(int32_t capacityFrames, int32_t frameBytes) {
    const size_t frames = roundUpToPowerOfTwo(std::max<int32_t>(capacityFrames, 1));
    frameBytes_ = std::max(frameBytes, 1);
    /* One spare frame absorbs the wrap copy, and the head is nudged to a 64-byte boundary so the
     * memcpy loops keep their aligned loads across block copies. */
    const size_t bytes = (frames + 1) * static_cast<size_t>(frameBytes_) + kAlignmentBytes;
    if (bytes < storage_.capacity() / 2) std::vector<uint8_t>(bytes, 0).swap(storage_);
    else storage_.assign(bytes, 0);
    const uintptr_t address = reinterpret_cast<uintptr_t>(storage_.data());
    const size_t padding = (kAlignmentBytes - (address % kAlignmentBytes)) % kAlignmentBytes;
    data_ = storage_.data() + padding;
    writeCursor_.store(0, std::memory_order_relaxed);
    readCursor_.store(0, std::memory_order_relaxed);
    flushThroughCursor_.store(0, std::memory_order_relaxed);
    flushSequence_.store(0, std::memory_order_relaxed);
    consumerFlushSequence_ = 0;
    capacity_.store(static_cast<int32_t>(frames), std::memory_order_release);
}

void RingBuffer::releaseStorage() {
    std::vector<uint8_t>().swap(storage_);
    data_ = nullptr;
    frameBytes_ = 0;
    writeCursor_.store(0, std::memory_order_relaxed);
    readCursor_.store(0, std::memory_order_relaxed);
    flushThroughCursor_.store(0, std::memory_order_relaxed);
    flushSequence_.store(0, std::memory_order_relaxed);
    consumerFlushSequence_ = 0;
    capacity_.store(0, std::memory_order_release);
}

int32_t RingBuffer::readableFrames() const noexcept {
    return static_cast<int32_t>(occupied());
}

int32_t RingBuffer::write(const uint8_t *source, int32_t frameCount) {
    if (data_ == nullptr || frameCount <= 0) return 0;
    const int32_t count = std::min(frameCount, writableFrames());
    if (count <= 0) return 0;
    const size_t capacity = static_cast<size_t>(capacity_.load(std::memory_order_relaxed));
    const size_t mask = capacity - 1U;
    const size_t start = writeCursor_.load(std::memory_order_relaxed) & mask;
    const size_t first = std::min(static_cast<size_t>(count), capacity - start) *
        static_cast<size_t>(frameBytes_);
    std::memcpy(data_ + start * frameBytes_, source, first);
    const size_t total = static_cast<size_t>(count) * frameBytes_;
    if (first < total) {
        std::memcpy(data_, source + first, total - first);
    }
    writeCursor_.store(
        writeCursor_.load(std::memory_order_relaxed) + static_cast<size_t>(count),
        std::memory_order_release);
    return count;
}

int32_t RingBuffer::read(uint8_t *destination, int32_t frameCount) {
    if (data_ == nullptr || frameCount <= 0) return 0;
    if (!acknowledgeFlushForConsumer()) return 0;
    const int32_t count = std::min(frameCount, readableFrames());
    if (count <= 0) return 0;
    const size_t capacity = static_cast<size_t>(capacity_.load(std::memory_order_relaxed));
    const size_t mask = capacity - 1U;
    const size_t start = readCursor_.load(std::memory_order_relaxed) & mask;
    const size_t first = std::min(static_cast<size_t>(count), capacity - start) *
        static_cast<size_t>(frameBytes_);
    std::memcpy(destination, data_ + start * frameBytes_, first);
    const size_t total = static_cast<size_t>(count) * frameBytes_;
    if (first < total) {
        std::memcpy(destination + first, data_, total - first);
    }
    readCursor_.store(
        readCursor_.load(std::memory_order_relaxed) + static_cast<size_t>(count),
        std::memory_order_release);
    return count;
}

void RingBuffer::clearForProducer() {
    if (data_ == nullptr) return;
    /* Never write the consumer cursor here. Doing so could free storage while its read is still
     * copying, and the read's eventual cursor store could resurrect discarded pre-seek frames.
     * Odd/even publication lets the consumer take one bounded coherent snapshot without spinning. */
    flushSequence_.fetch_add(1, std::memory_order_acq_rel);
    flushThroughCursor_.store(writeCursor_.load(std::memory_order_relaxed), std::memory_order_release);
    flushSequence_.fetch_add(1, std::memory_order_release);
}

bool RingBuffer::acknowledgeFlushForConsumer() noexcept {
    const uint64_t sequence = flushSequence_.load(std::memory_order_acquire);
    if ((sequence & 1U) != 0) return false;
    if (sequence == consumerFlushSequence_) return true;
    const size_t through = flushThroughCursor_.load(std::memory_order_acquire);
    if (flushSequence_.load(std::memory_order_acquire) != sequence) return false;
    readCursor_.store(through, std::memory_order_release);
    consumerFlushSequence_ = sequence;
    return true;
}

}  // namespace lazer::audio
