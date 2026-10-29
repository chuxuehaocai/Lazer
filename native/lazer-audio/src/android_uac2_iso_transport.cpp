#include "android_uac2_iso_transport.h"

#include "dop_packer.h"

#include <algorithm>
#include <array>
#include <cerrno>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <sstream>
#include <utility>

#if defined(_WIN32)
#include <io.h>
#else
#include <fcntl.h>
#include <unistd.h>
#endif

namespace lazer::android_uac2 {
namespace {

constexpr std::size_t kDataTransferCount = 4;
constexpr std::uint8_t kHighSpeedPacketsPerTransfer = 8;
constexpr std::uint8_t kFullSpeedPacketsPerTransfer = 4;
constexpr std::size_t kMinimumQueueBytes = 256u * 1024u;
constexpr std::size_t kMaximumQueueBytes = 16u * 1024u * 1024u;
constexpr std::uint8_t kMaxConsecutiveInvalidFeedback = 4;
constexpr std::uint8_t kHighSpeedFeedbackPacketsPerTransfer = 8;
constexpr std::uint8_t kFullSpeedFeedbackPacketsPerTransfer = 4;
constexpr std::size_t kMaximumOutstandingSessions = 4;
constexpr std::chrono::milliseconds kDefaultStopTimeout{500};
constexpr std::chrono::milliseconds kStopRetryInterval{50};
constexpr std::chrono::milliseconds kEventErrorInitialBackoff{10};
constexpr std::chrono::milliseconds kEventErrorMaximumBackoff{250};

struct SessionRegistry final {
    std::mutex mutex;
    std::array<IsoTransportSession*, kMaximumOutstandingSessions> quarantined{};
    std::size_t reserved_sessions = 0;
};

SessionRegistry* Registry() {
    // A process-lifetime registry deliberately retains quarantined sessions until process exit.
    static SessionRegistry* const registry = new SessionRegistry();
    return registry;
}

bool ReserveSessionSlot() {
    auto* registry = Registry();
    std::lock_guard<std::mutex> lock(registry->mutex);
    if (registry->reserved_sessions >= kMaximumOutstandingSessions) return false;
    ++registry->reserved_sessions;
    return true;
}

void ReleaseSessionSlot() noexcept {
    auto* registry = Registry();
    std::lock_guard<std::mutex> lock(registry->mutex);
    if (registry->reserved_sessions > 0) --registry->reserved_sessions;
}

bool RetainQuarantinedSession(IsoTransportSession* session) noexcept {
    if (session == nullptr) return false;
    auto* registry = Registry();
    std::lock_guard<std::mutex> lock(registry->mutex);
    for (auto& quarantined : registry->quarantined) {
        if (quarantined == nullptr) {
            quarantined = session;
            return true;
        }
    }
    return false;
}

int DuplicateFd(const int fd) noexcept {
#if defined(_WIN32)
    return _dup(fd);
#else
    return fcntl(fd, F_DUPFD_CLOEXEC, 0);
#endif
}

void CloseFd(const int fd) noexcept {
    if (fd < 0) return;
#if defined(_WIN32)
    _close(fd);
#else
    close(fd);
#endif
}

std::string UsbErrorText(const char* operation, const int code) {
    std::ostringstream text;
    text << operation << " failed (" << code << "): " << libusb_error_name(code);
    return text.str();
}

std::uint32_t ReadLittleEndian(const unsigned char* bytes, const std::size_t count) noexcept {
    std::uint32_t value = 0;
    for (std::size_t i = 0; i < count; ++i) value |= static_cast<std::uint32_t>(bytes[i]) << (i * 8u);
    return value;
}

} // namespace

IsoTransportSession::IsoTransportSession(
    const int borrowed_usb_fd,
    const int owned_usb_fd) noexcept
    : borrowed_usb_fd_(borrowed_usb_fd), owned_usb_fd_(owned_usb_fd) {}

IsoTransportSession::Pointer IsoTransportSession::Open(
    const int borrowed_usb_fd,
    std::string* error) {
    Pointer session;
    if (borrowed_usb_fd < 0) {
        if (error != nullptr) *error = "UsbDeviceConnection returned an invalid file descriptor";
        return session;
    }

    try {
        if (!ReserveSessionSlot()) {
            if (error != nullptr) {
                *error = "Too many native UAC2 sessions are active or quarantined; refusing another USB open";
            }
            return session;
        }
    } catch (const std::exception& exception) {
        if (error != nullptr) *error = std::string("Could not reserve native UAC2 session state: ") + exception.what();
        return session;
    } catch (...) {
        if (error != nullptr) *error = "Could not reserve native UAC2 session state";
        return session;
    }

    const int owned_usb_fd = DuplicateFd(borrowed_usb_fd);
    if (owned_usb_fd < 0) {
        const int error_code = errno;
        ReleaseSessionSlot();
        if (error != nullptr) {
            *error = std::string("Could not duplicate UsbDeviceConnection FD: ") + std::strerror(error_code);
        }
        return session;
    }

    try {
        session.reset(new IsoTransportSession(borrowed_usb_fd, owned_usb_fd));
    } catch (...) {
        CloseFd(owned_usb_fd);
        ReleaseSessionSlot();
        if (error != nullptr) *error = "Could not allocate native UAC2 transport session";
        return session;
    }

    const libusb_init_option option{
        .option = LIBUSB_OPTION_NO_DEVICE_DISCOVERY,
        .value = {.ival = 0},
    };
    int result = libusb_init_context(&session->context_, &option, 1);
    if (result < 0) {
        if (error != nullptr) *error = UsbErrorText("libusb_init_context", result);
        session->Close(0);
        return nullptr;
    }

    result = libusb_wrap_sys_device(
        session->context_,
        static_cast<intptr_t>(owned_usb_fd),
        &session->device_handle_);
    if (result < 0 || session->device_handle_ == nullptr) {
        if (error != nullptr) *error = UsbErrorText("libusb_wrap_sys_device", result);
        session->Close(0);
        return nullptr;
    }
    return session;
}

IsoTransportSession::~IsoTransportSession() {
    // Active sessions are owned by Pointer. Its deleter quarantines this object if Close cannot
    // prove callback quiescence; reaching the destructor with outstanding work would be a bug.
    const bool closed = Close(0);
    if (!closed) std::terminate();
}

void IsoTransportSession::Deleter::operator()(IsoTransportSession* session) const noexcept {
    if (session == nullptr) return;
    if (session->quarantine_required_.load(std::memory_order_acquire)) {
        if (RetainQuarantinedSession(session)) return;
        // The open-time reservation makes this unreachable. Leaking is safer than freeing memory
        // that an in-flight libusb callback may still reference.
        return;
    }
    if (!session->Close(0)) {
        session->quarantine_required_.store(true, std::memory_order_release);
        if (RetainQuarantinedSession(session)) return;
        return;
    }
    delete session;
}

std::size_t IsoTransportSession::QuarantinedSessionCount() noexcept {
    auto* registry = Registry();
    std::lock_guard<std::mutex> lock(registry->mutex);
    std::size_t count = 0;
    for (const auto* session : registry->quarantined) if (session != nullptr) ++count;
    return count;
}

std::size_t IsoTransportSession::MaximumSessionCount() noexcept {
    return kMaximumOutstandingSessions;
}

int IsoTransportSession::Start(const NativeStreamConfig& config, std::string* error) {
    std::unique_lock<std::mutex> lock(mutex_);
    if (closed_ || device_handle_ == nullptr || context_ == nullptr) {
        if (error != nullptr) *error = "USB session is closed";
        return LIBUSB_ERROR_NO_DEVICE;
    }
    if (stream_started_ || event_thread_.joinable()) {
        if (error != nullptr) *error = "USB stream is already started";
        return LIBUSB_ERROR_BUSY;
    }
    fatal_error_ = LIBUSB_SUCCESS;
    cancellation_error_ = LIBUSB_SUCCESS;
    last_error_.clear();
    invalid_feedback_count_ = 0;
    underrun_packets_ = 0;
    queue_read_offset_ = 0;
    queue_size_ = 0;
    stopping_ = false;
    draining_ = false;
    flushing_ = false;
    playing_ = false;
    event_loop_exit_ = false;
    played_frames_since_flush_ = 0;
    dop_next_marker_ = 0x05;
    last_playback_progress_ = std::chrono::steady_clock::now();

    auto* device = libusb_get_device(device_handle_);
    if (device == nullptr) {
        if (error != nullptr) *error = "libusb did not expose the wrapped USB device";
        return LIBUSB_ERROR_NO_DEVICE;
    }
    const int speed = libusb_get_device_speed(device);
    if (speed == LIBUSB_SPEED_FULL) {
        usb_speed_ = UsbSpeed::Full;
    } else if (speed == LIBUSB_SPEED_HIGH) {
        usb_speed_ = UsbSpeed::High;
    } else {
        if (error != nullptr) {
            *error = speed == LIBUSB_SPEED_SUPER || speed == LIBUSB_SPEED_SUPER_PLUS ||
                    speed == LIBUSB_SPEED_SUPER_PLUS_X2
                ? "SuperSpeed USB is not supported by this USB 2.0 transfer implementation"
                : "USB link speed is unknown; refusing to guess isochronous timing";
        }
        return LIBUSB_ERROR_NOT_SUPPORTED;
    }

    const int validation = ValidatePreparedStreamLocked(config, usb_speed_, error);
    if (validation < 0) {
        ReleaseStreamResourcesLocked();
        return validation;
    }

    const auto max_packet_size = static_cast<std::size_t>(config.data_maximum_packet_size_bytes);
    maximum_data_packet_bytes_ = max_packet_size * config.data_transactions_per_interval;
    data_packets_per_transfer_ = usb_speed_ == UsbSpeed::High
        ? kHighSpeedPacketsPerTransfer
        : kFullSpeedPacketsPerTransfer;
    const std::uint8_t synchronization = config.data_synchronization_type;
    if (!packetizer_.Configure(
            config.sample_rate_hz,
            static_cast<std::uint32_t>(frame_bytes_),
            static_cast<std::uint32_t>(maximum_data_packet_bytes_),
            usb_speed_,
            static_cast<SynchronizationType>(synchronization),
            config.data_interval,
            config.feedback_endpoint_address != 0)) {
        if (error != nullptr) *error = "PCM endpoint cannot be paced within its advertised USB packet size";
        ReleaseStreamResourcesLocked();
        return LIBUSB_ERROR_NOT_SUPPORTED;
    }

    const std::uint64_t half_second_queue =
        static_cast<std::uint64_t>(config.sample_rate_hz) * frame_bytes_ / 2u;
    const std::size_t queue_capacity = static_cast<std::size_t>(std::clamp<std::uint64_t>(
        half_second_queue,
        kMinimumQueueBytes,
        kMaximumQueueBytes));
    pcm_queue_.assign(queue_capacity, 0);
    stream_config_ = config;

    if (config.feedback_endpoint_address != 0) {
        feedback_transfer_ = std::make_unique<TransferSlot>();
        feedback_transfer_->owner = this;
        feedback_transfer_->kind = TransferKind::Feedback;
        const std::size_t feedback_packet_bytes = usb_speed_ == UsbSpeed::Full ? 3u : 4u;
        const std::uint8_t feedback_packets_per_transfer = usb_speed_ == UsbSpeed::High
            ? kHighSpeedFeedbackPacketsPerTransfer
            : kFullSpeedFeedbackPacketsPerTransfer;
        feedback_transfer_->buffer.assign(
            feedback_packet_bytes * feedback_packets_per_transfer, 0);
        feedback_transfer_->transfer = libusb_alloc_transfer(feedback_packets_per_transfer);
        if (feedback_transfer_->transfer == nullptr) {
            if (error != nullptr) *error = "libusb_alloc_transfer failed for feedback endpoint";
            ReleaseStreamResourcesLocked();
            return LIBUSB_ERROR_NO_MEM;
        }
        auto* transfer = feedback_transfer_->transfer;
        transfer->dev_handle = device_handle_;
        transfer->flags = 0;
        transfer->endpoint = config.feedback_endpoint_address;
        transfer->type = LIBUSB_TRANSFER_TYPE_ISOCHRONOUS;
        transfer->timeout = 0;
        transfer->status = LIBUSB_TRANSFER_COMPLETED;
        transfer->length = static_cast<int>(feedback_transfer_->buffer.size());
        transfer->actual_length = 0;
        transfer->callback = &IsoTransportSession::OnTransferComplete;
        transfer->user_data = feedback_transfer_.get();
        transfer->buffer = feedback_transfer_->buffer.data();
        transfer->num_iso_packets = feedback_packets_per_transfer;
        for (std::uint8_t packet = 0; packet < feedback_packets_per_transfer; ++packet) {
            transfer->iso_packet_desc[packet].length = static_cast<unsigned int>(feedback_packet_bytes);
            transfer->iso_packet_desc[packet].actual_length = 0;
            transfer->iso_packet_desc[packet].status = LIBUSB_TRANSFER_COMPLETED;
        }
    }

    data_transfers_.reserve(kDataTransferCount);
    const std::size_t data_buffer_bytes = maximum_data_packet_bytes_ * data_packets_per_transfer_;
    for (std::size_t index = 0; index < kDataTransferCount; ++index) {
        auto slot = std::make_unique<TransferSlot>();
        slot->owner = this;
        slot->kind = TransferKind::Data;
        slot->buffer.assign(data_buffer_bytes, 0);
        slot->transfer = libusb_alloc_transfer(data_packets_per_transfer_);
        if (slot->transfer == nullptr) {
            if (error != nullptr) *error = "libusb_alloc_transfer failed for PCM endpoint";
            ReleaseStreamResourcesLocked();
            return LIBUSB_ERROR_NO_MEM;
        }
        auto* transfer = slot->transfer;
        transfer->dev_handle = device_handle_;
        transfer->flags = 0;
        transfer->endpoint = config.data_endpoint_address;
        transfer->type = LIBUSB_TRANSFER_TYPE_ISOCHRONOUS;
        transfer->timeout = 0;
        transfer->status = LIBUSB_TRANSFER_COMPLETED;
        transfer->length = 0;
        transfer->actual_length = 0;
        transfer->callback = &IsoTransportSession::OnTransferComplete;
        transfer->user_data = slot.get();
        transfer->buffer = slot->buffer.data();
        transfer->num_iso_packets = data_packets_per_transfer_;
        for (std::uint8_t packet = 0; packet < data_packets_per_transfer_; ++packet) {
            transfer->iso_packet_desc[packet].length = 0;
            transfer->iso_packet_desc[packet].actual_length = 0;
            transfer->iso_packet_desc[packet].status = LIBUSB_TRANSFER_COMPLETED;
        }
        data_transfers_.push_back(std::move(slot));
    }

    stream_started_ = true;
    accepting_writes_ = true;
    try {
        event_thread_ = std::thread(&IsoTransportSession::EventLoop, this);
    } catch (const std::system_error& exception) {
        stream_started_ = false;
        accepting_writes_ = false;
        if (error != nullptr) *error = std::string("Could not start libusb event thread: ") + exception.what();
        ReleaseStreamResourcesLocked();
        return LIBUSB_ERROR_NO_MEM;
    }

    int result = LIBUSB_SUCCESS;
    if (feedback_transfer_ != nullptr) result = SubmitSlotLocked(feedback_transfer_.get());
    if (result == LIBUSB_SUCCESS && !packetizer_.ready()) {
        // An asynchronous sink does not receive OUT packets until a valid explicit feedback sample
        // has arrived. This prevents guessed-rate data from reaching a DAC during startup.
    } else if (result == LIBUSB_SUCCESS) {
        for (const auto& slot : data_transfers_) {
            result = PrepareAndSubmitDataLocked(slot.get());
            if (result < 0) break;
        }
    }
    if (result < 0) {
        if (error != nullptr) *error = last_error_.empty() ? UsbErrorText("Starting USB transfers", result) : last_error_;
        lock.unlock();
        Stop(false, 0);
        return result;
    }
    return LIBUSB_SUCCESS;
}

int IsoTransportSession::ValidatePreparedStreamLocked(
    const NativeStreamConfig& config,
    const UsbSpeed speed,
    std::string* error) {
    const bool is_async = config.data_synchronization_type ==
        static_cast<std::uint8_t>(SynchronizationType::Asynchronous);
    const bool valid_sync = config.data_synchronization_type >=
            static_cast<std::uint8_t>(SynchronizationType::Asynchronous) &&
        config.data_synchronization_type <=
            static_cast<std::uint8_t>(SynchronizationType::Synchronous);
    const bool has_feedback = config.feedback_endpoint_address != 0;
    if (config.configuration_value == 0 || config.alternate_setting == 0 ||
        config.sample_rate_hz < 8000 || config.sample_rate_hz > 768000 ||
        config.channel_count == 0 || config.channel_count > 32 ||
        config.subslot_size_bytes == 0 || config.subslot_size_bytes > 4 ||
        config.valid_bit_resolution == 0 ||
        config.valid_bit_resolution > config.subslot_size_bytes * 8u ||
        !valid_sync ||
        (config.data_endpoint_address & 0x80u) != 0 ||
        (config.data_endpoint_address & 0x0fu) == 0 ||
        config.data_maximum_packet_size_bytes == 0 ||
        config.data_transactions_per_interval == 0 ||
        config.data_transactions_per_interval > (speed == UsbSpeed::High ? 3u : 1u) ||
        config.data_interval == 0 || config.data_interval > 16 ||
        (speed == UsbSpeed::Full && config.data_interval != 1) ||
        (is_async != has_feedback)) {
        if (error != nullptr) *error = config.doP
            ? "UAC2 DoP stream plan contains unsupported or inconsistent endpoint fields"
            : "UAC2 PCM stream plan contains unsupported or inconsistent endpoint fields";
        return LIBUSB_ERROR_INVALID_PARAM;
    }
    if (config.doP && (config.channel_count != 2 || config.subslot_size_bytes != 3 ||
        config.valid_bit_resolution != 24)) {
        if (error != nullptr) *error = "DoP transport requires stereo packed 24-bit carrier samples";
        return LIBUSB_ERROR_NOT_SUPPORTED;
    }
    if (has_feedback &&
        ((config.feedback_endpoint_address & 0x80u) == 0 ||
         (config.feedback_endpoint_address & 0x0fu) == 0 ||
         config.feedback_transactions_per_interval != 1 ||
         config.feedback_interval == 0 || config.feedback_interval > 16 ||
         (speed == UsbSpeed::Full &&
          (config.feedback_interval != 1 || config.feedback_maximum_packet_size_bytes != 3)) ||
         (speed == UsbSpeed::High && config.feedback_maximum_packet_size_bytes != 4))) {
        if (error != nullptr) *error = "Explicit feedback endpoint is not a supported USB 2.0 feedback format";
        return LIBUSB_ERROR_NOT_SUPPORTED;
    }

    frame_bytes_ = static_cast<std::size_t>(config.channel_count) * config.subslot_size_bytes;
    if (frame_bytes_ == 0 || frame_bytes_ > std::numeric_limits<std::uint32_t>::max()) {
        if (error != nullptr) *error = "Invalid PCM frame size";
        return LIBUSB_ERROR_INVALID_PARAM;
    }
    const std::size_t maximum_packet_bytes =
        static_cast<std::size_t>(config.data_maximum_packet_size_bytes) * config.data_transactions_per_interval;
    if (maximum_packet_bytes > 3072 || maximum_packet_bytes < frame_bytes_ ||
        (speed == UsbSpeed::Full && config.data_maximum_packet_size_bytes > 1023u) ||
        (speed == UsbSpeed::High && config.data_maximum_packet_size_bytes > 1024u)) {
        if (error != nullptr) *error = "USB 2.0 PCM packet exceeds the supported service payload";
        return LIBUSB_ERROR_NOT_SUPPORTED;
    }
    auto* device = libusb_get_device(device_handle_);
    if (device == nullptr) {
        if (error != nullptr) *error = "libusb did not expose the wrapped USB device";
        return LIBUSB_ERROR_NO_DEVICE;
    }
    libusb_config_descriptor* active_configuration = nullptr;
    int result = libusb_get_active_config_descriptor(device, &active_configuration);
    if (result < 0 || active_configuration == nullptr) {
        if (error != nullptr) *error = result < 0
            ? UsbErrorText("libusb_get_active_config_descriptor", result)
            : "The configured USB device has no active configuration descriptor";
        return result < 0 ? result : LIBUSB_ERROR_NOT_FOUND;
    }

    const auto release_descriptor = [&active_configuration] {
        if (active_configuration != nullptr) {
            libusb_free_config_descriptor(active_configuration);
            active_configuration = nullptr;
        }
    };
    if (active_configuration->bConfigurationValue != config.configuration_value) {
        release_descriptor();
        if (error != nullptr) *error = "USB session configuration differs from the selected stream plan";
        return LIBUSB_ERROR_NOT_SUPPORTED;
    }

    const libusb_interface_descriptor* stream_interface = nullptr;
    for (std::uint8_t interface_index = 0;
         interface_index < active_configuration->bNumInterfaces;
         ++interface_index) {
        const auto& interface = active_configuration->interface[interface_index];
        for (int alternate_index = 0; alternate_index < interface.num_altsetting; ++alternate_index) {
            const auto& alternate = interface.altsetting[alternate_index];
            if (alternate.bInterfaceNumber == config.interface_number &&
                alternate.bAlternateSetting == config.alternate_setting) {
                if (stream_interface != nullptr) {
                    release_descriptor();
                    if (error != nullptr) *error = "Selected USB interface alternate is ambiguous";
                    return LIBUSB_ERROR_NOT_SUPPORTED;
                }
                stream_interface = &alternate;
            }
        }
    }
    if (stream_interface == nullptr || stream_interface->bInterfaceClass != 0x01u ||
        stream_interface->bInterfaceSubClass != 0x02u ||
        stream_interface->bInterfaceProtocol != 0x20u) {
        release_descriptor();
        if (error != nullptr) *error = "Selected alternate is not a UAC2 AudioStreaming interface";
        return LIBUSB_ERROR_NOT_SUPPORTED;
    }

    bool has_type_i_pcm_format = false;
    bool has_channel_layout = false;
    bool has_subslot_layout = false;
    bool malformed_stream_descriptors = false;
    for (int offset = 0; offset < stream_interface->extra_length;) {
        const auto* descriptor = reinterpret_cast<const unsigned char*>(stream_interface->extra + offset);
        const int remaining = stream_interface->extra_length - offset;
        const auto descriptor_length = static_cast<int>(descriptor[0]);
        if (descriptor_length < 3 || descriptor_length > remaining) {
            malformed_stream_descriptors = true;
            break;
        }
        if (descriptor[1] == 0x24u && descriptor[2] == 0x01u) {
            const bool pcm_format = descriptor_length >= 16 &&
                descriptor[5] == 0x01u && // FORMAT_TYPE_I
                (ReadLittleEndian(descriptor + 6, 4) & 0x01u) != 0; // PCM bit in bmFormats
            const bool channel_layout = descriptor_length >= 16 &&
                descriptor[10] == config.channel_count &&
                ReadLittleEndian(descriptor + 11, 4) == config.channel_config;
            has_type_i_pcm_format = has_type_i_pcm_format || pcm_format;
            has_channel_layout = has_channel_layout || channel_layout;
        } else if (descriptor[1] == 0x24u && descriptor[2] == 0x02u &&
                   descriptor_length >= 6 && descriptor[3] == 0x01u) {
            has_subslot_layout = has_subslot_layout ||
                (descriptor[4] == config.subslot_size_bytes &&
                 descriptor[5] == config.valid_bit_resolution);
        }
        offset += descriptor_length;
    }
    if (malformed_stream_descriptors || !has_type_i_pcm_format ||
        !has_channel_layout || !has_subslot_layout) {
        release_descriptor();
        if (error != nullptr) *error = "Active interface descriptors do not advertise the selected Type-I PCM layout";
        return LIBUSB_ERROR_NOT_SUPPORTED;
    }

    const libusb_endpoint_descriptor* data_endpoint = nullptr;
    const libusb_endpoint_descriptor* feedback_endpoint = nullptr;
    for (std::uint8_t endpoint_index = 0;
         endpoint_index < stream_interface->bNumEndpoints;
         ++endpoint_index) {
        const auto& endpoint = stream_interface->endpoint[endpoint_index];
        if (endpoint.bEndpointAddress == config.data_endpoint_address) data_endpoint = &endpoint;
        if (endpoint.bEndpointAddress == config.feedback_endpoint_address) feedback_endpoint = &endpoint;
    }
    const auto endpoint_matches = [speed](
        const libusb_endpoint_descriptor* endpoint,
        const std::uint8_t address,
        const std::uint8_t synchronization,
        const std::uint8_t usage,
        const std::uint16_t packet_size,
        const std::uint8_t transactions,
        const std::uint8_t interval) {
        if (endpoint == nullptr || endpoint->bEndpointAddress != address ||
            (endpoint->bmAttributes & 0x03u) != LIBUSB_TRANSFER_TYPE_ISOCHRONOUS ||
            ((endpoint->bmAttributes >> 2u) & 0x03u) != synchronization ||
            ((endpoint->bmAttributes >> 4u) & 0x03u) != usage ||
            endpoint->bInterval != interval) return false;
        const std::uint16_t encoded_packet = libusb_le16_to_cpu(endpoint->wMaxPacketSize);
        const auto max_packet = static_cast<std::uint16_t>(encoded_packet & 0x07ffu);
        const auto multiplier_bits = static_cast<std::uint8_t>((encoded_packet >> 11u) & 0x03u);
        const auto actual_transactions = speed == UsbSpeed::High
            ? static_cast<std::uint8_t>(multiplier_bits + 1u)
            : static_cast<std::uint8_t>(1u);
        return multiplier_bits != 3u && max_packet == packet_size &&
            (speed == UsbSpeed::High || multiplier_bits == 0u) &&
            actual_transactions == transactions;
    };
    const bool data_matches = endpoint_matches(
        data_endpoint,
        config.data_endpoint_address,
        config.data_synchronization_type,
        0u,
        config.data_maximum_packet_size_bytes,
        config.data_transactions_per_interval,
        config.data_interval);
    const bool feedback_matches = !has_feedback || endpoint_matches(
        feedback_endpoint,
        config.feedback_endpoint_address,
        0u,
        1u,
        config.feedback_maximum_packet_size_bytes,
        config.feedback_transactions_per_interval,
        config.feedback_interval);
    release_descriptor();
    if (!data_matches || !feedback_matches) {
        if (error != nullptr) *error = "Selected PCM/feedback endpoint parameters do not match the active USB descriptors";
        return LIBUSB_ERROR_NOT_SUPPORTED;
    }
    return LIBUSB_SUCCESS;
}

int IsoTransportSession::Write(
    const std::uint8_t* bytes,
    const std::size_t length,
    const std::uint32_t timeout_ms) {
    if (length == 0) return 0;
    if (bytes == nullptr) return LIBUSB_ERROR_INVALID_PARAM;

    std::unique_lock<std::mutex> lock(mutex_);
    if (!stream_started_ || !accepting_writes_ || stopping_) return LIBUSB_ERROR_BUSY;
    if (length % frame_bytes_ != 0) return LIBUSB_ERROR_INVALID_PARAM;
    if (length > static_cast<std::size_t>(std::numeric_limits<int>::max())) return LIBUSB_ERROR_OVERFLOW;
    const std::size_t maximum_accepted = std::min(
        length,
        (pcm_queue_.size() / frame_bytes_) * frame_bytes_);
    const auto has_space = [this] {
        return FreeBytesLocked() >= frame_bytes_ || fatal_error_ < 0 || stopping_ || closed_;
    };
    if (FreeBytesLocked() < frame_bytes_) {
        if (timeout_ms == 0) return 0;
        if (!changed_.wait_for(lock, std::chrono::milliseconds(timeout_ms), has_space)) return 0;
    }
    if (fatal_error_ < 0) return fatal_error_;
    if (stopping_ || closed_) return LIBUSB_ERROR_BUSY;

    const std::size_t accepted = std::min(
        maximum_accepted,
        (FreeBytesLocked() / frame_bytes_) * frame_bytes_);
    if (accepted == 0) return 0;

    if (queue_size_ == 0) last_playback_progress_ = std::chrono::steady_clock::now();
    CopyToQueueLocked(bytes, accepted);
    draining_ = false;
    for (const auto& slot : data_transfers_) {
        if (!slot->in_flight && packetizer_.ready()) {
            const int result = PrepareAndSubmitDataLocked(slot.get());
            if (result < 0) return result;
        }
    }
    changed_.notify_all();
    return static_cast<int>(accepted);
}

void IsoTransportSession::SetPlaying(const bool playing) noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!stream_started_ || stopping_ || fatal_error_ < 0) return;
    playing_ = playing;
    if (playing_) last_playback_progress_ = std::chrono::steady_clock::now();
    changed_.notify_all();
}

bool IsoTransportSession::Flush(const std::uint32_t timeout_ms) {
    std::unique_lock<std::mutex> lock(mutex_);
    if (!stream_started_) {
        queue_read_offset_ = 0;
        queue_size_ = 0;
        played_frames_since_flush_ = 0;
        packetizer_.ResetPhase();
        playing_ = false;
        return true;
    }
    if (fatal_error_ < 0 || stopping_) return false;
    const bool previous_accepting = accepting_writes_;
    const bool previous_playing = playing_;
    accepting_writes_ = false;
    flushing_ = true;
    draining_ = false;
    changed_.notify_all();
    const auto completed = [this] {
        return in_flight_data_count_ == 0 || fatal_error_ < 0 || stopping_;
    };
    bool finished = false;
    if (timeout_ms == 0) {
        finished = completed();
    } else {
        finished = changed_.wait_for(lock, std::chrono::milliseconds(timeout_ms), completed);
    }
    const bool success = finished && in_flight_data_count_ == 0 && fatal_error_ >= 0 && !stopping_;
    flushing_ = false;
    accepting_writes_ = previous_accepting && fatal_error_ >= 0 && !stopping_;
    if (success) {
        queue_read_offset_ = 0;
        queue_size_ = 0;
        played_frames_since_flush_ = 0;
        packetizer_.ResetPhase();
        playing_ = false;
        draining_ = false;
        last_playback_progress_ = std::chrono::steady_clock::now();
        for (const auto& slot : data_transfers_) {
            if (!slot->in_flight && packetizer_.ready()) {
                const int result = PrepareAndSubmitDataLocked(slot.get());
                if (result < 0) {
                    MarkFailedLocked(result, "Restarting PCM endpoint after flush");
                    changed_.notify_all();
                    return false;
                }
            }
        }
    } else if (!stopping_ && fatal_error_ >= 0) {
        playing_ = previous_playing;
        draining_ = false;
        for (const auto& slot : data_transfers_) {
            if (!slot->in_flight && packetizer_.ready()) {
                const int result = PrepareAndSubmitDataLocked(slot.get());
                if (result < 0) {
                    MarkFailedLocked(result, "Resuming PCM endpoint after incomplete flush");
                    break;
                }
            }
        }
    }
    changed_.notify_all();
    return success;
}

bool IsoTransportSession::Stop(const bool drain, const std::uint32_t timeout_ms) {
    const auto started_at = std::chrono::steady_clock::now();
    const auto deadline = started_at + (timeout_ms == 0
        ? kDefaultStopTimeout
        : std::chrono::milliseconds(timeout_ms));
    std::unique_lock<std::mutex> lock(mutex_);
    bool drained = true;
    if (drain && stream_started_ && fatal_error_ >= 0) {
        accepting_writes_ = false;
        playing_ = true;
        draining_ = true;
        for (const auto& slot : data_transfers_) {
            if (!slot->in_flight && packetizer_.ready()) {
                const int result = PrepareAndSubmitDataLocked(slot.get());
                if (result < 0) {
                    MarkFailedLocked(result, "Starting final PCM drain");
                    break;
                }
            }
        }
        const auto drained_predicate = [this] {
            return (queue_size_ == 0 && in_flight_data_count_ == 0) || fatal_error_ < 0;
        };
        bool finished = drained_predicate();
        if (!finished && timeout_ms != 0) {
            finished = changed_.wait_until(lock, deadline, drained_predicate);
        }
        drained = finished && queue_size_ == 0 && in_flight_data_count_ == 0 && fatal_error_ >= 0;
    } else if (drain && fatal_error_ < 0) {
        drained = false;
    }
    if (!stream_started_ && !event_thread_.joinable()) {
        ReleaseStreamResourcesLocked();
        return drained;
    }
    accepting_writes_ = false;
    draining_ = true;
    stopping_ = true;
    flushing_ = false;
    CancelAllLocked();
    // Cancellation can fail or callbacks may never arrive after an event-loop error. Retry
    // transient cancellation failures, but never free callback-owned storage without proof that
    // every submitted transfer has returned.
    while (in_flight_count_ != 0) {
        const auto now = std::chrono::steady_clock::now();
        if (now >= deadline) break;
        const auto retry_deadline = std::min(deadline, now + kStopRetryInterval);
        changed_.wait_until(lock, retry_deadline, [this] { return in_flight_count_ == 0; });
        if (in_flight_count_ != 0 && std::chrono::steady_clock::now() < deadline) {
            CancelAllLocked();
        }
    }
    if (in_flight_count_ != 0) {
        if (fatal_error_ >= 0) fatal_error_ = LIBUSB_ERROR_TIMEOUT;
        if (last_error_.empty()) {
            last_error_ = "Timed out waiting for libusb transfer callbacks; native session was quarantined";
        } else {
            last_error_ += "; callbacks did not quiesce before the shutdown deadline";
        }
        accepting_writes_ = false;
        quarantine_required_.store(true, std::memory_order_release);
        changed_.notify_all();
        return false;
    }

    event_loop_exit_ = true;
    lock.unlock();
    if (context_ != nullptr) libusb_interrupt_event_handler(context_);
    if (event_thread_.joinable()) event_thread_.join();
    lock.lock();

    ReleaseStreamResourcesLocked();
    stream_started_ = false;
    accepting_writes_ = false;
    playing_ = false;
    stopping_ = false;
    draining_ = false;
    flushing_ = false;
    event_loop_exit_ = false;
    queue_read_offset_ = 0;
    queue_size_ = 0;
    changed_.notify_all();
    return drained && fatal_error_ >= 0 && cancellation_error_ >= 0;
}

bool IsoTransportSession::Close(const std::uint32_t timeout_ms) noexcept {
    if (quarantine_required_.load(std::memory_order_acquire)) return false;
    Stop(false, timeout_ms);
    std::lock_guard<std::mutex> lock(mutex_);
    if (closed_) return true;
    if (in_flight_count_ != 0 || stream_started_ || event_thread_.joinable()) {
        quarantine_required_.store(true, std::memory_order_release);
        return false;
    }
    closed_ = true;
    if (device_handle_ != nullptr) {
        // libusb_close() does not close the sys_dev descriptor. Close our duplicate only after all
        // callbacks have returned; the Android UsbDeviceConnection still owns borrowed_usb_fd_.
        libusb_close(device_handle_);
        device_handle_ = nullptr;
    }
    if (context_ != nullptr) {
        libusb_exit(context_);
        context_ = nullptr;
    }
    CloseFd(owned_usb_fd_);
    if (session_slot_reserved_) {
        session_slot_reserved_ = false;
        ReleaseSessionSlot();
    }
    return true;
}

int IsoTransportSession::underrun_packets() const noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    return underrun_packets_;
}

int IsoTransportSession::error_code() const noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    return fatal_error_;
}

std::uint64_t IsoTransportSession::played_frames_since_flush() const noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    return played_frames_since_flush_;
}

std::uint64_t IsoTransportSession::buffer_size_frames() const noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    return frame_bytes_ == 0 ? 0 : pcm_queue_.size() / frame_bytes_;
}

bool IsoTransportSession::is_stalled() const noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    if (fatal_error_ < 0) return true;
    return playing_ && queue_size_ > 0 &&
        std::chrono::steady_clock::now() - last_playback_progress_ > std::chrono::milliseconds(500);
}

std::string IsoTransportSession::LastError() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return last_error_;
}

void LIBUSB_CALL IsoTransportSession::OnTransferComplete(libusb_transfer* transfer) noexcept {
    if (transfer == nullptr || transfer->user_data == nullptr) return;
    auto* slot = static_cast<TransferSlot*>(transfer->user_data);
    if (slot->owner != nullptr) slot->owner->HandleTransferComplete(slot, transfer);
}

void IsoTransportSession::HandleTransferComplete(
    TransferSlot* slot,
    libusb_transfer* transfer) noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    if (slot == nullptr || transfer == nullptr || !slot->in_flight) return;
    slot->in_flight = false;
    if (in_flight_count_ > 0) --in_flight_count_;
    if (slot->kind == TransferKind::Data && in_flight_data_count_ > 0) --in_flight_data_count_;

    if (transfer->status != LIBUSB_TRANSFER_COMPLETED &&
        !(stopping_ && transfer->status == LIBUSB_TRANSFER_CANCELLED)) {
        MarkFailedLocked(
            transfer->status == LIBUSB_TRANSFER_NO_DEVICE ? LIBUSB_ERROR_NO_DEVICE : LIBUSB_ERROR_IO,
            slot->kind == TransferKind::Data ? "PCM isochronous OUT transfer" : "feedback isochronous IN transfer");
        changed_.notify_all();
        return;
    }

    if (transfer->status == LIBUSB_TRANSFER_COMPLETED && slot->kind == TransferKind::Feedback) {
        const auto expected = usb_speed_ == UsbSpeed::Full ? 3u : 4u;
        bool received_valid_feedback = false;
        for (int index = 0; index < transfer->num_iso_packets; ++index) {
            const auto& packet = transfer->iso_packet_desc[index];
            auto* feedback_bytes = libusb_get_iso_packet_buffer_simple(transfer, index);
            const bool valid_packet = packet.status == LIBUSB_TRANSFER_COMPLETED &&
                packet.actual_length == expected &&
                packet.actual_length <= stream_config_.feedback_maximum_packet_size_bytes;
            const bool updated = valid_packet && feedback_bytes != nullptr &&
                packetizer_.UpdateFeedback(feedback_bytes, static_cast<std::size_t>(packet.actual_length));
            if (!updated) {
                ++invalid_feedback_count_;
                if (invalid_feedback_count_ >= kMaxConsecutiveInvalidFeedback) {
                    MarkFailedLocked(LIBUSB_ERROR_IO, "USB 2.0 feedback endpoint returned invalid pacing samples");
                    changed_.notify_all();
                    return;
                }
            } else {
                invalid_feedback_count_ = 0;
                received_valid_feedback = true;
            }
        }
        if (received_valid_feedback && !stopping_ && !flushing_ &&
            (!draining_ || queue_size_ > 0)) {
            for (const auto& data_slot : data_transfers_) {
                if (!data_slot->in_flight) {
                    const int result = PrepareAndSubmitDataLocked(data_slot.get());
                    if (result < 0) break;
                }
            }
        }
    } else if (transfer->status == LIBUSB_TRANSFER_COMPLETED && slot->kind == TransferKind::Data) {
        for (int index = 0; index < transfer->num_iso_packets; ++index) {
            if (transfer->iso_packet_desc[index].status != LIBUSB_TRANSFER_COMPLETED ||
                transfer->iso_packet_desc[index].actual_length !=
                    static_cast<int>(transfer->iso_packet_desc[index].length)) {
                MarkFailedLocked(LIBUSB_ERROR_IO, "PCM isochronous packet did not complete");
                changed_.notify_all();
                return;
            }
        }
        if (played_frames_since_flush_ <=
            std::numeric_limits<std::uint64_t>::max() - slot->payload_frames) {
            played_frames_since_flush_ += slot->payload_frames;
        } else {
            played_frames_since_flush_ = std::numeric_limits<std::uint64_t>::max();
        }
        if (slot->payload_frames > 0) last_playback_progress_ = std::chrono::steady_clock::now();
    }

    if (!stopping_ && slot->kind == TransferKind::Feedback) {
        const int result = SubmitSlotLocked(slot);
        if (result < 0) MarkFailedLocked(result, "Resubmitting feedback endpoint transfer");
    } else if (!stopping_ && !flushing_ && slot->kind == TransferKind::Data &&
               (!draining_ || queue_size_ > 0) && packetizer_.ready()) {
        const int result = PrepareAndSubmitDataLocked(slot);
        if (result < 0) MarkFailedLocked(result, "Resubmitting PCM endpoint transfer");
    }
    changed_.notify_all();
}

void IsoTransportSession::EventLoop() noexcept {
    auto error_backoff = kEventErrorInitialBackoff;
    while (true) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (quarantine_required_.load(std::memory_order_acquire) && in_flight_count_ == 0) {
                // The quarantined state must outlive this thread object, but no callback remains.
                // Exit the event pump to avoid a permanent polling thread; the retained session,
                // transfer storage, libusb handle/context, and duplicated FD remain untouched.
                event_loop_exit_ = true;
            }
            if (event_loop_exit_ && in_flight_count_ == 0) break;
        }
        timeval timeout{0, 50'000};
        const int result = libusb_handle_events_timeout_completed(context_, &timeout, nullptr);
        if (result < 0 && result != LIBUSB_ERROR_INTERRUPTED) {
            {
                std::lock_guard<std::mutex> lock(mutex_);
                MarkFailedLocked(result, "libusb event handling");
                changed_.notify_all();
            }
            std::this_thread::sleep_for(error_backoff);
            error_backoff = std::min(error_backoff * 2, kEventErrorMaximumBackoff);
        } else {
            error_backoff = kEventErrorInitialBackoff;
        }
    }
}

int IsoTransportSession::SubmitSlotLocked(TransferSlot* slot) noexcept {
    if (slot == nullptr || slot->transfer == nullptr || slot->in_flight || stopping_) {
        return LIBUSB_ERROR_INVALID_PARAM;
    }
    slot->in_flight = true;
    ++in_flight_count_;
    if (slot->kind == TransferKind::Data) ++in_flight_data_count_;
    const int result = libusb_submit_transfer(slot->transfer);
    if (result < 0) {
        slot->in_flight = false;
        --in_flight_count_;
        if (slot->kind == TransferKind::Data) --in_flight_data_count_;
        changed_.notify_all();
    }
    return result;
}

int IsoTransportSession::PrepareAndSubmitDataLocked(TransferSlot* slot) noexcept {
    if (slot == nullptr || slot->transfer == nullptr || slot->in_flight ||
        stopping_ || !stream_started_ || !packetizer_.ready()) {
        return LIBUSB_ERROR_INVALID_PARAM;
    }
    auto* transfer = slot->transfer;
    std::fill(slot->buffer.begin(), slot->buffer.end(), 0);
    slot->payload_frames = 0;
    std::size_t byte_offset = 0;
    for (int packet_index = 0; packet_index < transfer->num_iso_packets; ++packet_index) {
        std::uint32_t frames = 0;
        if (!packetizer_.NextPacketFrameCount(&frames)) return LIBUSB_ERROR_NOT_SUPPORTED;
        const std::size_t packet_bytes = static_cast<std::size_t>(frames) * frame_bytes_;
        if (packet_bytes > maximum_data_packet_bytes_ || byte_offset + packet_bytes > slot->buffer.size()) {
            return LIBUSB_ERROR_OVERFLOW;
        }
        transfer->iso_packet_desc[packet_index].length = static_cast<unsigned int>(packet_bytes);
        transfer->iso_packet_desc[packet_index].actual_length = 0;
        transfer->iso_packet_desc[packet_index].status = LIBUSB_TRANSFER_COMPLETED;
        std::size_t audio_frames = 0;
        if (packet_bytes > 0 && playing_) {
            const std::size_t queued_before = queue_size_;
            audio_frames = std::min(queued_before, packet_bytes) / frame_bytes_;
            slot->payload_frames += audio_frames;
            CopyFromQueueLocked(slot->buffer.data() + byte_offset, packet_bytes);
            if (queued_before < packet_bytes) ++underrun_packets_;
        }
        if (stream_config_.doP) {
            const int32_t prepared_frames = lazer::audio::prepareDopCarrierFrames(
                slot->buffer.data() + byte_offset,
                static_cast<int32_t>(frames),
                static_cast<int32_t>(audio_frames),
                stream_config_.channel_count,
                true,
                dop_next_marker_);
            if (prepared_frames != static_cast<int32_t>(frames)) return LIBUSB_ERROR_NOT_SUPPORTED;
        }
        byte_offset += packet_bytes;
    }
    transfer->length = static_cast<int>(byte_offset);
    transfer->actual_length = 0;
    transfer->status = LIBUSB_TRANSFER_COMPLETED;
    const int result = SubmitSlotLocked(slot);
    if (result < 0) MarkFailedLocked(result, "Submitting PCM isochronous OUT transfer");
    return result;
}

int IsoTransportSession::CancelAllLocked() noexcept {
    int first_error = LIBUSB_SUCCESS;
    const auto cancel_slot = [this, &first_error](TransferSlot* slot) {
        if (slot == nullptr || !slot->in_flight || slot->transfer == nullptr) return;
        const int result = libusb_cancel_transfer(slot->transfer);
        // NOT_FOUND means libusb no longer has a cancellable request; its completion callback may
        // already be queued, so retain storage until that callback updates in_flight_count_.
        if (result < 0 && result != LIBUSB_ERROR_NOT_FOUND) {
            if (first_error == LIBUSB_SUCCESS) first_error = result;
            RecordCancellationFailureLocked(result);
        }
    };
    for (const auto& slot : data_transfers_) {
        cancel_slot(slot.get());
    }
    cancel_slot(feedback_transfer_.get());
    return first_error;
}

void IsoTransportSession::RecordCancellationFailureLocked(const int error) noexcept {
    if (cancellation_error_ >= 0) cancellation_error_ = error;
    if (fatal_error_ >= 0) fatal_error_ = error;
    if (last_error_.empty()) {
        last_error_ = UsbErrorText("Cancelling libusb transfer", error);
    }
}

void IsoTransportSession::MarkFailedLocked(const int error, const char* operation) noexcept {
    if (fatal_error_ >= 0) {
        fatal_error_ = error < 0 ? error : LIBUSB_ERROR_IO;
        last_error_ = UsbErrorText(operation, fatal_error_);
    }
    accepting_writes_ = false;
    draining_ = true;
    stopping_ = true;
    CancelAllLocked();
}

void IsoTransportSession::ReleaseStreamResourcesLocked() noexcept {
    for (auto& slot : data_transfers_) {
        if (slot->transfer != nullptr) {
            libusb_free_transfer(slot->transfer);
            slot->transfer = nullptr;
        }
    }
    data_transfers_.clear();
    if (feedback_transfer_ != nullptr && feedback_transfer_->transfer != nullptr) {
        libusb_free_transfer(feedback_transfer_->transfer);
        feedback_transfer_->transfer = nullptr;
    }
    feedback_transfer_.reset();
    pcm_queue_.clear();
    maximum_data_packet_bytes_ = 0;
    data_packets_per_transfer_ = 0;
    frame_bytes_ = 0;
    in_flight_count_ = 0;
    in_flight_data_count_ = 0;
}

std::size_t IsoTransportSession::QueuedBytesLocked() const noexcept {
    return queue_size_;
}

std::size_t IsoTransportSession::FreeBytesLocked() const noexcept {
    return pcm_queue_.size() - queue_size_;
}

void IsoTransportSession::CopyToQueueLocked(const std::uint8_t* bytes, const std::size_t length) noexcept {
    const std::size_t tail = (queue_read_offset_ + queue_size_) % pcm_queue_.size();
    const std::size_t first = std::min(length, pcm_queue_.size() - tail);
    std::memcpy(pcm_queue_.data() + tail, bytes, first);
    if (length > first) std::memcpy(pcm_queue_.data(), bytes + first, length - first);
    queue_size_ += length;
}

void IsoTransportSession::CopyFromQueueLocked(unsigned char* destination, const std::size_t length) noexcept {
    const std::size_t available = std::min(length, queue_size_);
    if (available == 0) {
        std::memset(destination, 0, length);
        return;
    }
    const std::size_t first = std::min(available, pcm_queue_.size() - queue_read_offset_);
    std::memcpy(destination, pcm_queue_.data() + queue_read_offset_, first);
    if (available > first) std::memcpy(destination + first, pcm_queue_.data(), available - first);
    if (available < length) std::memset(destination + available, 0, length - available);
    queue_read_offset_ = (queue_read_offset_ + available) % pcm_queue_.size();
    queue_size_ -= available;
    if (queue_size_ == 0) queue_read_offset_ = 0;
    changed_.notify_all();
}

} // namespace lazer::android_uac2
