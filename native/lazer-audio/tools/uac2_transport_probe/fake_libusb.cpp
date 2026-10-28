#include <libusb.h>

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <mutex>
#include <new>
#include <unordered_map>
#include <unordered_set>
#include <vector>

struct libusb_context final {};

struct libusb_device final {
    int speed = LIBUSB_SPEED_HIGH;
};

struct libusb_device_handle final {
    intptr_t wrapped_fd = -1;
    libusb_device* device = nullptr;
};

namespace {

std::mutex g_mutex;
std::condition_variable g_changed;
std::deque<libusb_transfer*> g_pending;
std::unordered_map<libusb_transfer*, bool> g_cancelled;
std::unordered_set<libusb_transfer*> g_dispatching;
bool g_interrupted = false;
int g_close_count = 0;
int g_exit_count = 0;
int g_closed_fd_count = 0;
int g_freed_transfer_count = 0;
int g_live_transfer_count = 0;
int g_callback_count = 0;
int g_event_error_count = 0;
int g_cancel_error_count = 0;
int g_cancel_failures_remaining = 0;
int g_event_failures_remaining = 0;
int g_fault_error_code = LIBUSB_ERROR_IO;
int g_wrapped_fd = -1;
int g_data_transfer_completion_budget = -1;
std::uint8_t g_streaming_subslot_size = 2;
std::uint8_t g_streaming_bit_resolution = 16;
std::uint32_t g_feedback_sample_rate_hz = 48000;
std::vector<unsigned char> g_captured_output;
libusb_device g_device;

unsigned char kStreamingExtra[] = {
    16, 0x24, 0x01, 1, 0, 1, 1, 0, 0, 0, 2, 3, 0, 0, 0, 0,
    6, 0x24, 0x02, 1, 2, 16,
};
libusb_endpoint_descriptor g_endpoints[2]{};
libusb_interface_descriptor g_alternate{};
libusb_interface g_interface{};
libusb_interface g_interfaces[1]{};
libusb_config_descriptor g_configuration{};

void InitializeDescriptors() {
    kStreamingExtra[sizeof(kStreamingExtra) - 2] = g_streaming_subslot_size;
    kStreamingExtra[sizeof(kStreamingExtra) - 1] = g_streaming_bit_resolution;
    g_endpoints[0].bLength = LIBUSB_DT_ENDPOINT_SIZE;
    g_endpoints[0].bDescriptorType = LIBUSB_DT_ENDPOINT;
    g_endpoints[0].bEndpointAddress = 0x01;
    g_endpoints[0].bmAttributes = static_cast<unsigned char>(
        LIBUSB_TRANSFER_TYPE_ISOCHRONOUS | (1u << 2u));
    g_endpoints[0].wMaxPacketSize = 1024;
    g_endpoints[0].bInterval = 1;
    g_endpoints[1].bLength = LIBUSB_DT_ENDPOINT_SIZE;
    g_endpoints[1].bDescriptorType = LIBUSB_DT_ENDPOINT;
    g_endpoints[1].bEndpointAddress = 0x81;
    g_endpoints[1].bmAttributes = static_cast<unsigned char>(
        LIBUSB_TRANSFER_TYPE_ISOCHRONOUS | (1u << 4u));
    g_endpoints[1].wMaxPacketSize = 4;
    g_endpoints[1].bInterval = 1;

    g_alternate.bLength = LIBUSB_DT_INTERFACE_SIZE;
    g_alternate.bDescriptorType = LIBUSB_DT_INTERFACE;
    g_alternate.bInterfaceNumber = 1;
    g_alternate.bAlternateSetting = 1;
    g_alternate.bNumEndpoints = 2;
    g_alternate.bInterfaceClass = 0x01;
    g_alternate.bInterfaceSubClass = 0x02;
    g_alternate.bInterfaceProtocol = 0x20;
    g_alternate.extra = kStreamingExtra;
    g_alternate.extra_length = static_cast<int>(sizeof(kStreamingExtra));
    g_alternate.endpoint = g_endpoints;

    g_interface.altsetting = &g_alternate;
    g_interface.num_altsetting = 1;
    g_interfaces[0] = g_interface;
    g_configuration.bLength = LIBUSB_DT_CONFIG_SIZE;
    g_configuration.bDescriptorType = LIBUSB_DT_CONFIG;
    g_configuration.bConfigurationValue = 1;
    g_configuration.bNumInterfaces = 1;
    g_configuration.interface = g_interfaces;
}

void CompleteTransfer(libusb_transfer* transfer, const bool cancelled) {
    if (cancelled) {
        transfer->status = LIBUSB_TRANSFER_CANCELLED;
        transfer->actual_length = 0;
    } else {
        transfer->status = LIBUSB_TRANSFER_COMPLETED;
        transfer->actual_length = 0;
        if (transfer->endpoint == 0x81) {
            for (int packet_index = 0; packet_index < transfer->num_iso_packets; ++packet_index) {
                auto& packet = transfer->iso_packet_desc[packet_index];
                auto* bytes = libusb_get_iso_packet_buffer_simple(transfer, packet_index);
                // High-speed feedback is a 16.16 samples-per-microframe value.
                if (packet.length >= 4) {
                    const std::uint32_t feedback = static_cast<std::uint32_t>(
                        (static_cast<std::uint64_t>(g_feedback_sample_rate_hz) * 65536u + 4000u) / 8000u);
                    bytes[0] = static_cast<unsigned char>(feedback & 0xffu);
                    bytes[1] = static_cast<unsigned char>((feedback >> 8u) & 0xffu);
                    bytes[2] = static_cast<unsigned char>((feedback >> 16u) & 0xffu);
                    bytes[3] = static_cast<unsigned char>((feedback >> 24u) & 0xffu);
                    packet.actual_length = 4;
                }
                packet.status = LIBUSB_TRANSFER_COMPLETED;
                transfer->actual_length += packet.actual_length;
            }
        } else {
            for (int packet_index = 0; packet_index < transfer->num_iso_packets; ++packet_index) {
                auto& packet = transfer->iso_packet_desc[packet_index];
                packet.actual_length = static_cast<int>(packet.length);
                packet.status = LIBUSB_TRANSFER_COMPLETED;
                transfer->actual_length += packet.actual_length;
            }
            {
                std::lock_guard<std::mutex> lock(g_mutex);
                if (transfer->buffer != nullptr && transfer->length > 0) {
                    g_captured_output.insert(g_captured_output.end(), transfer->buffer,
                        transfer->buffer + transfer->length);
                }
            }
        }
    }
    if (transfer->callback != nullptr) transfer->callback(transfer);
}

} // namespace

extern "C" {

int LIBUSB_CALL libusb_init_context(
    libusb_context** context,
    const libusb_init_option*,
    int) {
    if (context == nullptr) return LIBUSB_ERROR_INVALID_PARAM;
    *context = new (std::nothrow) libusb_context();
    return *context == nullptr ? LIBUSB_ERROR_NO_MEM : LIBUSB_SUCCESS;
}

void LIBUSB_CALL libusb_exit(libusb_context* context) {
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        ++g_exit_count;
    }
    delete context;
}

int LIBUSB_CALL libusb_wrap_sys_device(
    libusb_context*,
    intptr_t sys_dev,
    libusb_device_handle** device_handle) {
    if (device_handle == nullptr || sys_dev < 0) return LIBUSB_ERROR_INVALID_PARAM;
    auto* handle = new (std::nothrow) libusb_device_handle();
    if (handle == nullptr) return LIBUSB_ERROR_NO_MEM;
    handle->wrapped_fd = sys_dev;
    handle->device = &g_device;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_wrapped_fd = static_cast<int>(sys_dev);
    }
    *device_handle = handle;
    return LIBUSB_SUCCESS;
}

libusb_device* LIBUSB_CALL libusb_get_device(libusb_device_handle* device_handle) {
    return device_handle == nullptr ? nullptr : device_handle->device;
}

int LIBUSB_CALL libusb_get_device_speed(libusb_device* device) {
    return device == nullptr ? LIBUSB_SPEED_UNKNOWN : device->speed;
}

int LIBUSB_CALL libusb_get_active_config_descriptor(
    libusb_device*,
    libusb_config_descriptor** config) {
    if (config == nullptr) return LIBUSB_ERROR_INVALID_PARAM;
    InitializeDescriptors();
    *config = &g_configuration;
    return LIBUSB_SUCCESS;
}

void LIBUSB_CALL libusb_free_config_descriptor(libusb_config_descriptor*) {}

libusb_transfer* LIBUSB_CALL libusb_alloc_transfer(const int iso_packets) {
    if (iso_packets < 0) return nullptr;
    const auto bytes = sizeof(libusb_transfer) +
        static_cast<std::size_t>(iso_packets) * sizeof(libusb_iso_packet_descriptor);
    auto* transfer = static_cast<libusb_transfer*>(std::calloc(1, bytes));
    if (transfer != nullptr) {
        transfer->num_iso_packets = iso_packets;
        std::lock_guard<std::mutex> lock(g_mutex);
        ++g_live_transfer_count;
    }
    return transfer;
}

void LIBUSB_CALL libusb_free_transfer(libusb_transfer* transfer) {
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        ++g_freed_transfer_count;
        --g_live_transfer_count;
    }
    std::free(transfer);
}

int LIBUSB_CALL libusb_submit_transfer(libusb_transfer* transfer) {
    if (transfer == nullptr) return LIBUSB_ERROR_INVALID_PARAM;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_cancelled[transfer] = false;
        transfer->status = LIBUSB_TRANSFER_COMPLETED;
        g_pending.push_back(transfer);
    }
    g_changed.notify_all();
    return LIBUSB_SUCCESS;
}

int LIBUSB_CALL libusb_cancel_transfer(libusb_transfer* transfer) {
    if (transfer == nullptr) return LIBUSB_ERROR_INVALID_PARAM;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (g_cancel_failures_remaining < 0 || g_cancel_failures_remaining > 0) {
            if (g_cancel_failures_remaining > 0) --g_cancel_failures_remaining;
            ++g_cancel_error_count;
            return g_fault_error_code;
        }
        g_cancelled[transfer] = true;
        if (std::find(g_pending.begin(), g_pending.end(), transfer) == g_pending.end() &&
            g_dispatching.find(transfer) == g_dispatching.end()) {
            g_pending.push_back(transfer);
        }
    }
    g_changed.notify_all();
    return LIBUSB_SUCCESS;
}

int LIBUSB_CALL libusb_handle_events_timeout_completed(
    libusb_context*,
    timeval* timeout,
    int*) {
    libusb_transfer* transfer = nullptr;
    {
        std::unique_lock<std::mutex> lock(g_mutex);
        if (g_event_failures_remaining < 0 || g_event_failures_remaining > 0) {
            if (g_event_failures_remaining > 0) --g_event_failures_remaining;
            ++g_event_error_count;
            return g_fault_error_code;
        }
        const auto dispatchable = [] {
            return g_interrupted || std::any_of(g_pending.begin(), g_pending.end(), [](const auto* pending) {
                return pending->endpoint != 0x01 || g_data_transfer_completion_budget != 0;
            });
        };
        if (!dispatchable()) {
            const auto wait_duration = timeout == nullptr
                ? std::chrono::milliseconds(1)
                : std::min(
                    std::chrono::milliseconds(1),
                    std::chrono::milliseconds(timeout->tv_sec * 1000 + timeout->tv_usec / 1000));
            g_changed.wait_for(lock, wait_duration, dispatchable);
        }
        if (g_interrupted && g_pending.empty()) {
            g_interrupted = false;
            return LIBUSB_ERROR_INTERRUPTED;
        }
        const auto selected = std::find_if(g_pending.begin(), g_pending.end(), [](const auto* pending) {
            return pending->endpoint != 0x01 || g_data_transfer_completion_budget != 0;
        });
        if (selected == g_pending.end()) {
            if (g_interrupted) {
                g_interrupted = false;
                return LIBUSB_ERROR_INTERRUPTED;
            }
            return LIBUSB_SUCCESS;
        }
        transfer = *selected;
        g_pending.erase(selected);
        if (transfer->endpoint == 0x01 && g_data_transfer_completion_budget > 0) {
            --g_data_transfer_completion_budget;
        }
        g_dispatching.insert(transfer);
    }

    bool cancelled = false;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        const auto found = g_cancelled.find(transfer);
        if (found != g_cancelled.end()) {
            cancelled = found->second;
            g_cancelled.erase(found);
        }
    }
    CompleteTransfer(transfer, cancelled);
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_dispatching.erase(transfer);
        ++g_callback_count;
    }
    return LIBUSB_SUCCESS;
}

void LIBUSB_CALL libusb_interrupt_event_handler(libusb_context*) {
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_interrupted = true;
    }
    g_changed.notify_all();
}

const char* LIBUSB_CALL libusb_error_name(const int error_code) {
    switch (error_code) {
        case LIBUSB_SUCCESS: return "LIBUSB_SUCCESS";
        case LIBUSB_ERROR_INVALID_PARAM: return "LIBUSB_ERROR_INVALID_PARAM";
        case LIBUSB_ERROR_NO_MEM: return "LIBUSB_ERROR_NO_MEM";
        case LIBUSB_ERROR_NOT_SUPPORTED: return "LIBUSB_ERROR_NOT_SUPPORTED";
        case LIBUSB_ERROR_NO_DEVICE: return "LIBUSB_ERROR_NO_DEVICE";
        case LIBUSB_ERROR_IO: return "LIBUSB_ERROR_IO";
        default: return "LIBUSB_ERROR_OTHER";
    }
}

void LIBUSB_CALL libusb_close(libusb_device_handle* device_handle) {
    if (device_handle == nullptr) return;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        ++g_close_count;
        // libusb_close() does not own the wrapped descriptor; Java closes it after native close.
    }
    delete device_handle;
}

} // extern "C"

namespace lazer::uac2_transport_probe {

void ResetFakeLibusbState() {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_pending.clear();
    g_cancelled.clear();
    g_dispatching.clear();
    g_interrupted = false;
    g_close_count = 0;
    g_exit_count = 0;
    g_closed_fd_count = 0;
    g_freed_transfer_count = 0;
    g_live_transfer_count = 0;
    g_callback_count = 0;
    g_event_error_count = 0;
    g_cancel_error_count = 0;
    g_cancel_failures_remaining = 0;
    g_event_failures_remaining = 0;
    g_fault_error_code = LIBUSB_ERROR_IO;
    g_wrapped_fd = -1;
    g_data_transfer_completion_budget = -1;
    g_streaming_subslot_size = 2;
    g_streaming_bit_resolution = 16;
    g_feedback_sample_rate_hz = 48000;
    g_captured_output.clear();
}

void SetFakeStreamingFormat(const std::uint8_t subslot_size, const std::uint8_t bit_resolution) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_streaming_subslot_size = subslot_size;
    g_streaming_bit_resolution = bit_resolution;
}

void SetFakeFeedbackSampleRate(const std::uint32_t sample_rate_hz) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_feedback_sample_rate_hz = sample_rate_hz;
}

void SetFakeDataTransferCompletionBudget(const int completions) {
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_data_transfer_completion_budget = completions;
    }
    g_changed.notify_all();
}

int PendingDataTransferCount() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return static_cast<int>(std::count_if(g_pending.begin(), g_pending.end(), [](const auto* pending) {
        return pending->endpoint == 0x01;
    }));
}

std::vector<unsigned char> CapturedOutputBytes() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_captured_output;
}

int CloseCount() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_close_count;
}

int ExitCount() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_exit_count;
}

int ClosedFdCount() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_closed_fd_count;
}

void SetCancelFailures(const int count) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_cancel_failures_remaining = count;
}

void SetEventFailures(const int count) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_event_failures_remaining = count;
}

int FreedTransferCount() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_freed_transfer_count;
}

int LiveTransferCount() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_live_transfer_count;
}

int CallbackCount() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_callback_count;
}

int EventErrorCount() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_event_error_count;
}

int CancelErrorCount() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_cancel_error_count;
}

int PendingTransferCount() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return static_cast<int>(g_pending.size() + g_dispatching.size());
}

int WrappedFd() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_wrapped_fd;
}

} // namespace lazer::uac2_transport_probe
