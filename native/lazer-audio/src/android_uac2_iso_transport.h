#pragma once

#include "android_uac2_packetizer.h"

#include <libusb.h>

#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace lazer::android_uac2 {

struct NativeStreamConfig final {
    std::uint8_t configuration_value = 0;
    std::uint8_t interface_number = 0;
    std::uint8_t alternate_setting = 0;
    std::uint32_t sample_rate_hz = 0;
    std::uint8_t channel_count = 0;
    std::uint32_t channel_config = 0;
    std::uint8_t subslot_size_bytes = 0;
    std::uint8_t valid_bit_resolution = 0;
    std::uint8_t data_endpoint_address = 0;
    std::uint8_t data_synchronization_type = 0;
    std::uint16_t data_maximum_packet_size_bytes = 0;
    std::uint8_t data_transactions_per_interval = 0;
    std::uint8_t data_interval = 0;
    std::uint8_t feedback_endpoint_address = 0;
    std::uint16_t feedback_maximum_packet_size_bytes = 0;
    std::uint8_t feedback_transactions_per_interval = 0;
    std::uint8_t feedback_interval = 0;
    bool doP = false;
};

/**
 * Owns a libusb context and wrapped device handle. The supplied USB file descriptor is borrowed:
 * Android's UsbDeviceConnection owns it and must remain open until this object is closed.
 */
class IsoTransportSession final {
public:
    struct Deleter final {
        void operator()(IsoTransportSession* session) const noexcept;
    };
    using Pointer = std::unique_ptr<IsoTransportSession, Deleter>;

    static Pointer Open(int borrowed_usb_fd, std::string* error);
    static std::size_t QuarantinedSessionCount() noexcept;
    static std::size_t MaximumSessionCount() noexcept;

    IsoTransportSession(const IsoTransportSession&) = delete;
    IsoTransportSession& operator=(const IsoTransportSession&) = delete;
    ~IsoTransportSession();

    int Start(const NativeStreamConfig& config, std::string* error);
    int Write(const std::uint8_t* bytes, std::size_t length, std::uint32_t timeout_ms);
    void SetPlaying(bool playing) noexcept;
    bool Flush(std::uint32_t timeout_ms);
    bool Stop(bool drain, std::uint32_t timeout_ms);
    // Returns true only when callback quiescence was proven and libusb plus the native duplicate
    // of Android's descriptor were closed. On timeout it retains all transfer/session state; the
    // Pointer deleter quarantines the object instead of freeing anything callbacks may reference.
    bool Close(std::uint32_t timeout_ms = 500) noexcept;

    int underrun_packets() const noexcept;
    int error_code() const noexcept;
    std::uint64_t played_frames_since_flush() const noexcept;
    std::uint64_t buffer_size_frames() const noexcept;
    bool is_stalled() const noexcept;
    std::string LastError() const;

private:
    enum class TransferKind : std::uint8_t { Data, Feedback };

    struct TransferSlot final {
        IsoTransportSession* owner = nullptr;
        TransferKind kind = TransferKind::Data;
        libusb_transfer* transfer = nullptr;
        std::vector<unsigned char> buffer;
        std::uint64_t payload_frames = 0;
        bool in_flight = false;
    };

    IsoTransportSession(int borrowed_usb_fd, int owned_usb_fd) noexcept;

    static void LIBUSB_CALL OnTransferComplete(libusb_transfer* transfer) noexcept;
    void HandleTransferComplete(TransferSlot* slot, libusb_transfer* transfer) noexcept;
    void EventLoop() noexcept;
    int SubmitSlotLocked(TransferSlot* slot) noexcept;
    int PrepareAndSubmitDataLocked(TransferSlot* slot) noexcept;
    int ValidatePreparedStreamLocked(
        const NativeStreamConfig& config,
        UsbSpeed speed,
        std::string* error);
    int CancelAllLocked() noexcept;
    void RecordCancellationFailureLocked(int error) noexcept;
    void MarkFailedLocked(int error, const char* operation) noexcept;
    void ReleaseStreamResourcesLocked() noexcept;
    std::size_t QueuedBytesLocked() const noexcept;
    std::size_t FreeBytesLocked() const noexcept;
    void CopyToQueueLocked(const std::uint8_t* bytes, std::size_t length) noexcept;
    void CopyFromQueueLocked(unsigned char* destination, std::size_t length) noexcept;

    const int borrowed_usb_fd_;
    const int owned_usb_fd_;
    libusb_context* context_ = nullptr;
    libusb_device_handle* device_handle_ = nullptr;
    std::thread event_thread_;
    mutable std::mutex mutex_;
    std::condition_variable changed_;
    std::vector<std::uint8_t> pcm_queue_;
    std::size_t queue_read_offset_ = 0;
    std::size_t queue_size_ = 0;
    std::vector<std::unique_ptr<TransferSlot>> data_transfers_;
    std::unique_ptr<TransferSlot> feedback_transfer_;
    PcmPacketizer packetizer_;
    NativeStreamConfig stream_config_{};
    UsbSpeed usb_speed_ = UsbSpeed::Full;
    std::size_t frame_bytes_ = 0;
    std::size_t maximum_data_packet_bytes_ = 0;
    std::uint8_t data_packets_per_transfer_ = 0;
    std::uint8_t dop_next_marker_ = 0x05;
    std::size_t in_flight_count_ = 0;
    std::size_t in_flight_data_count_ = 0;
    std::uint64_t played_frames_since_flush_ = 0;
    std::uint8_t invalid_feedback_count_ = 0;
    std::chrono::steady_clock::time_point last_playback_progress_{};
    int underrun_packets_ = 0;
    int fatal_error_ = LIBUSB_SUCCESS;
    int cancellation_error_ = LIBUSB_SUCCESS;
    std::string last_error_;
    bool stream_started_ = false;
    bool accepting_writes_ = false;
    bool playing_ = false;
    bool draining_ = false;
    bool flushing_ = false;
    bool stopping_ = false;
    bool event_loop_exit_ = false;
    bool closed_ = false;
    std::atomic<bool> quarantine_required_{false};
    bool session_slot_reserved_ = true;
};

} // namespace lazer::android_uac2
