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
    capacity_ = static_cast<int32_t>(frames);
    frameBytes_ = std::max(frameBytes, 1);
    /* One spare frame absorbs the wrap copy, and the head is nudged to a 64-byte boundary so the
     * memcpy loops keep their aligned loads across block copies. */
    storage_.assign((frames + 1) * static_cast<size_t>(frameBytes_) + kAlignmentBytes, 0);
    const uintptr_t address = reinterpret_cast<uintptr_t>(storage_.data());
    const size_t padding = (kAlignmentBytes - (address % kAlignmentBytes)) % kAlignmentBytes;
    data_ = storage_.data() + padding;
    writeCursor_.store(0, std::memory_order_relaxed);
    readCursor_.store(0, std::memory_order_relaxed);
    flushSequence_.store(0, std::memory_order_relaxed);
}

int32_t RingBuffer::readableFrames() const noexcept {
    return static_cast<int32_t>(writeCursor_.load(std::memory_order_acquire) -
        readCursor_.load(std::memory_order_acquire));
}

int32_t RingBuffer::write(const uint8_t *source, int32_t frameCount) {
    if (data_ == nullptr || frameCount <= 0) return 0;
    const int32_t count = std::min(frameCount, writableFrames());
    if (count <= 0) return 0;
    const size_t mask = static_cast<size_t>(capacity_) - 1U;
    const size_t start = writeCursor_.load(std::memory_order_relaxed) & mask;
    const size_t first = std::min(static_cast<size_t>(count), capacity_ - start) *
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
    const int32_t count = std::min(frameCount, readableFrames());
    if (count <= 0) return 0;
    const size_t mask = static_cast<size_t>(capacity_) - 1U;
    const size_t start = readCursor_.load(std::memory_order_relaxed) & mask;
    const size_t first = std::min(static_cast<size_t>(count), capacity_ - start) *
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
    /* The consumer compares this sequence before every read, so a reset here can never hand it
     * frames from before the seek. */
    flushSequence_.fetch_add(1, std::memory_order_acq_rel);
    readCursor_.store(writeCursor_.load(std::memory_order_relaxed), std::memory_order_release);
}

}  // namespace lazer::audio
