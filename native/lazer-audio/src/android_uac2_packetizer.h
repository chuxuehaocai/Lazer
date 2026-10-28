#pragma once

#include <cstddef>
#include <cstdint>

namespace lazer::android_uac2 {

enum class UsbSpeed : std::uint8_t {
    Full = 1,
    High = 2,
};

enum class SynchronizationType : std::uint8_t {
    Asynchronous = 1,
    Adaptive = 2,
    Synchronous = 3,
};

/**
 * Computes integral PCM frames for USB 2.0 isochronous service intervals.
 *
 * Asynchronous sinks use their explicit feedback endpoint (10.14 samples/frame at full speed,
 * 16.16 samples/microframe at high speed). Adaptive/synchronous sinks use an exact rational
 * accumulator for the nominal source rate, so fractional rates such as 44.1 kHz have no
 * long-term rounding drift.
 * This class has no USB or JNI dependencies and is deterministic for host-side tests.
 */
class PcmPacketizer final {
public:
    bool Configure(
        std::uint32_t sample_rate_hz,
        std::uint32_t frame_bytes,
        std::uint32_t max_packet_bytes,
        UsbSpeed speed,
        SynchronizationType synchronization,
        std::uint8_t data_interval,
        bool has_explicit_feedback) noexcept;

    bool UpdateFeedback(const std::uint8_t* bytes, std::size_t length) noexcept;
    bool NextPacketFrameCount(std::uint32_t* frames) noexcept;
    void ResetPhase() noexcept;

    std::uint32_t service_interval_slots() const noexcept { return service_interval_slots_; }
    bool ready() const noexcept { return configured_ && (!requires_feedback_ || has_feedback_); }

private:
    bool SetRateIncrement(std::uint64_t samples_per_base_interval_q32) noexcept;

    bool configured_ = false;
    bool requires_feedback_ = false;
    bool has_feedback_ = false;
    std::uint8_t feedback_fraction_bits_ = 0;
    std::uint32_t base_slots_per_second_ = 0;
    std::uint64_t nominal_frames_per_interval_numerator_ = 0;
    std::uint64_t nominal_phase_ = 0;
    std::uint64_t feedback_increment_q32_ = 0;
    std::uint64_t phase_q32_ = 0;
    std::uint32_t max_frames_per_packet_ = 0;
    std::uint32_t service_interval_slots_ = 0;
};

} // namespace lazer::android_uac2
