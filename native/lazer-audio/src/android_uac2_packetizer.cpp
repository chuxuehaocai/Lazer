#include "android_uac2_packetizer.h"

#include <limits>

namespace lazer::android_uac2 {

bool PcmPacketizer::Configure(
    const std::uint32_t sample_rate_hz,
    const std::uint32_t frame_bytes,
    const std::uint32_t max_packet_bytes,
    const UsbSpeed speed,
    const SynchronizationType synchronization,
    const std::uint8_t data_interval,
    const bool has_explicit_feedback) noexcept {
    configured_ = false;
    requires_feedback_ = false;
    has_feedback_ = false;
    feedback_fraction_bits_ = 0;
    base_slots_per_second_ = 0;
    nominal_frames_per_interval_numerator_ = 0;
    nominal_phase_ = 0;
    feedback_increment_q32_ = 0;
    phase_q32_ = 0;
    max_frames_per_packet_ = 0;
    service_interval_slots_ = 0;

    if (sample_rate_hz == 0 || frame_bytes == 0 || max_packet_bytes < frame_bytes ||
        data_interval == 0 || data_interval > 16) {
        return false;
    }
    if (speed != UsbSpeed::Full && speed != UsbSpeed::High) return false;
    if (speed == UsbSpeed::Full && data_interval != 1) return false;
    if (synchronization != SynchronizationType::Asynchronous &&
        synchronization != SynchronizationType::Adaptive &&
        synchronization != SynchronizationType::Synchronous) {
        return false;
    }

    const std::uint32_t base_slots_per_second = speed == UsbSpeed::Full ? 1000u : 8000u;
    service_interval_slots_ = speed == UsbSpeed::Full
        ? 1u
        : (1u << (data_interval - 1u));
    max_frames_per_packet_ = max_packet_bytes / frame_bytes;
    if (max_frames_per_packet_ == 0) return false;

    const std::uint64_t nominal_frames_numerator =
        static_cast<std::uint64_t>(sample_rate_hz) * service_interval_slots_;
    if (nominal_frames_numerator >
        static_cast<std::uint64_t>(max_frames_per_packet_) * base_slots_per_second) return false;
    base_slots_per_second_ = base_slots_per_second;
    nominal_frames_per_interval_numerator_ = nominal_frames_numerator;

    const std::uint64_t whole_frames = nominal_frames_numerator / base_slots_per_second;
    const std::uint64_t fractional_frames = nominal_frames_numerator % base_slots_per_second;
    const std::uint64_t nominal_q32 =
        (whole_frames << 32u) + ((fractional_frames << 32u) / base_slots_per_second);
    if (!SetRateIncrement(nominal_q32)) return false;

    requires_feedback_ = synchronization == SynchronizationType::Asynchronous;
    if (requires_feedback_ && !has_explicit_feedback) return false;
    feedback_fraction_bits_ = speed == UsbSpeed::Full ? 14u : 16u;
    configured_ = true;
    return true;
}

bool PcmPacketizer::SetRateIncrement(const std::uint64_t samples_per_interval_q32) noexcept {
    const auto maximum = static_cast<std::uint64_t>(max_frames_per_packet_) << 32u;
    if (samples_per_interval_q32 == 0 || samples_per_interval_q32 > maximum) return false;
    feedback_increment_q32_ = samples_per_interval_q32;
    return true;
}

bool PcmPacketizer::UpdateFeedback(const std::uint8_t* bytes, const std::size_t length) noexcept {
    if (!configured_ || !requires_feedback_ || bytes == nullptr) return false;
    const std::size_t expected_length = feedback_fraction_bits_ == 14u ? 3u : 4u;
    if (length != expected_length) return false;

    std::uint64_t raw = 0;
    for (std::size_t i = 0; i < length; ++i) {
        raw |= static_cast<std::uint64_t>(bytes[i]) << (i * 8u);
    }
    if (raw == 0) return false;

    const unsigned shift = 32u - feedback_fraction_bits_;
    if (raw > std::numeric_limits<std::uint64_t>::max() / service_interval_slots_) return false;
    const std::uint64_t interval_samples = raw * service_interval_slots_;
    if (interval_samples > (std::numeric_limits<std::uint64_t>::max() >> shift)) return false;
    if (!SetRateIncrement(interval_samples << shift)) return false;
    has_feedback_ = true;
    return true;
}

bool PcmPacketizer::NextPacketFrameCount(std::uint32_t* frames) noexcept {
    if (frames == nullptr || !ready()) return false;
    std::uint64_t whole_frames = 0;
    if (requires_feedback_) {
        const std::uint64_t accumulated = phase_q32_ + feedback_increment_q32_;
        whole_frames = accumulated >> 32u;
        phase_q32_ = accumulated & 0xffffffffu;
    } else {
        const std::uint64_t accumulated =
            nominal_phase_ + nominal_frames_per_interval_numerator_;
        whole_frames = accumulated / base_slots_per_second_;
        nominal_phase_ = accumulated % base_slots_per_second_;
    }
    if (whole_frames > std::numeric_limits<std::uint32_t>::max()) return false;
    const auto packet_frames = static_cast<std::uint32_t>(whole_frames);
    if (packet_frames > max_frames_per_packet_) return false;
    *frames = packet_frames;
    return true;
}

void PcmPacketizer::ResetPhase() noexcept {
    nominal_phase_ = 0;
    phase_q32_ = 0;
}

} // namespace lazer::android_uac2
