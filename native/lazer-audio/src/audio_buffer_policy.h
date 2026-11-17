#ifndef LAZER_AUDIO_BUFFER_POLICY_H
#define LAZER_AUDIO_BUFFER_POLICY_H

#include <algorithm>
#include <cstddef>
#include <cstdint>

namespace lazer::audio {

constexpr size_t kMaxOutputRingBytes = 32U * 1024U * 1024U;
constexpr size_t kMaxQueuedPcmBytes = 32U * 1024U * 1024U;
constexpr size_t kMaxMixEffectBytes = 32U * 1024U * 1024U;
constexpr int32_t kMaxDeviceBufferMillis = 2'000;

constexpr int32_t normalizedBufferMillis(int32_t value) noexcept {
    return value <= 0 ? 120 : std::min(value, kMaxDeviceBufferMillis);
}

/* The ring rounds up to a power of two. Budget that rounded allocation, and use 64-bit arithmetic
 * before narrowing; a malformed duration must not overflow into a tiny, starvation-prone ring. */
inline int32_t outputRingFrames(int32_t rate, int32_t period, int32_t frameBytes,
    int32_t bufferMillis) noexcept {
    if (rate <= 0 || period <= 0 || frameBytes <= 0) return 0;
    size_t budgetFrames = kMaxOutputRingBytes / static_cast<size_t>(frameBytes);
    if (budgetFrames == 0) return 0;
    size_t maximumPowerOfTwo = 1;
    while (maximumPowerOfTwo <= budgetFrames / 2) maximumPowerOfTwo *= 2;
    const int64_t minimum = static_cast<int64_t>(period) * 3;
    if (minimum > static_cast<int64_t>(maximumPowerOfTwo)) return 0;
    const int64_t desired = std::max(minimum, static_cast<int64_t>(rate) *
        std::max(normalizedBufferMillis(bufferMillis), 60) / 1000);
    return static_cast<int32_t>(std::min<int64_t>(desired, maximumPowerOfTwo));
}

inline size_t queuedPcmCapacityFrames(int32_t rate, int32_t period, int32_t frameBytes,
    int32_t overlapFrames) noexcept {
    if (rate <= 0 || period <= 0 || frameBytes <= 0) return 0;
    const size_t budget = kMaxQueuedPcmBytes / static_cast<size_t>(frameBytes);
    const size_t cushion = std::max<size_t>(static_cast<size_t>(rate) / 4,
        static_cast<size_t>(period) * 2);
    const size_t desired = std::max({static_cast<size_t>(rate),
        static_cast<size_t>(period) * 4, static_cast<size_t>(std::max(overlapFrames, 0)) + cushion});
    return std::min(desired, budget);
}

}  // namespace lazer::audio

#endif
