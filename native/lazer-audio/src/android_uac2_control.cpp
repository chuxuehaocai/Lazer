#include "android_uac2_control.h"
#include "android_uac2_iso_transport.h"

#include <algorithm>
#include <vector>

namespace lazer::android_uac2 {
namespace {
using Bytes = std::vector<const unsigned char*>;
std::uint32_t Read(const unsigned char* p, int n) {
    std::uint32_t v = 0;
    for (int i = 0; i < n; ++i) v |= std::uint32_t(p[i]) << (8 * i);
    return v;
}
bool Descriptors(const unsigned char* p, int length, Bytes& result) {
    if (length < 0 || (length > 0 && p == nullptr)) return false;
    for (int at = 0; at < length;) {
        if (length - at < 3 || p[at] < 3 || p[at] > length - at) return false;
        if (p[at + 1] == 0x24) result.push_back(p + at);
        at += p[at];
    }
    return true;
}
int Fail(std::string* error, const char* text, int code = LIBUSB_ERROR_NOT_SUPPORTED) {
    if (error) *error = text;
    return code;
}
struct Candidate {
    NativeStreamConfig config;
    int control = -1;
    int clock = -1;
    int clock_controls = 0;
};
bool Endpoint(const libusb_endpoint_descriptor& ep, bool feedback, NativeStreamConfig& c) {
    if ((ep.bmAttributes & 3) != LIBUSB_TRANSFER_TYPE_ISOCHRONOUS) return false;
    const int usage = (ep.bmAttributes >> 4) & 3;
    const bool input = (ep.bEndpointAddress & 0x80) != 0;
    const auto packet = ep.wMaxPacketSize; // libusb already returns host-endian descriptor fields.
    if (feedback) {
        if (!input || usage != 1 || c.feedback_endpoint_address != 0) return false;
        c.feedback_endpoint_address = ep.bEndpointAddress;
        c.feedback_maximum_packet_size_bytes = packet & 0x7ff;
        c.feedback_transactions_per_interval = ((packet >> 11) & 3) + 1;
        c.feedback_interval = ep.bInterval;
    } else {
        if (input || usage != 0 || c.data_endpoint_address != 0) return false;
        c.data_endpoint_address = ep.bEndpointAddress;
        c.data_synchronization_type = (ep.bmAttributes >> 2) & 3;
        c.data_maximum_packet_size_bytes = packet & 0x7ff;
        c.data_transactions_per_interval = ((packet >> 11) & 3) + 1;
        c.data_interval = ep.bInterval;
    }
    return true;
}
int RateSupported(libusb_device_handle* h, int index, std::uint32_t rate) {
    unsigned char count[2]{};
    int rc = libusb_control_transfer(h, 0xa1, 2, 0x0100, index, count, 2, 1000);
    if (rc != 2) return rc < 0 ? rc : LIBUSB_ERROR_IO;
    const auto n = Read(count, 2);
    if (n == 0 || n > 64) return false;
    std::vector<unsigned char> ranges(2 + 12 * n);
    rc = libusb_control_transfer(h, 0xa1, 2, 0x0100, index, ranges.data(),
        static_cast<std::uint16_t>(ranges.size()), 1000);
    if (rc != static_cast<int>(ranges.size())) return rc < 0 ? rc : LIBUSB_ERROR_IO;
    if (Read(ranges.data(), 2) != n) return LIBUSB_ERROR_IO;
    for (std::uint32_t i = 0; i < n; ++i) {
        const auto* p = ranges.data() + 2 + 12 * i;
        const auto low = Read(p, 4), high = Read(p + 4, 4), step = Read(p + 8, 4);
        if (low > high) return false;
        if (rate >= low && rate <= high && (step == 0 || (rate - low) % step == 0)) return true;
    }
    return false;
}
} // namespace

void ReleasePcmDevice(libusb_device_handle* handle, ClaimedPcmInterfaces* claimed) noexcept {
    if (!handle || !claimed) return;
    if (claimed->streaming >= 0) {
        libusb_set_interface_alt_setting(handle, claimed->streaming, 0);
        libusb_release_interface(handle, claimed->streaming);
        claimed->streaming = -1;
    }
    if (claimed->control >= 0) {
        libusb_release_interface(handle, claimed->control);
        claimed->control = -1;
    }
}

int PreparePcmDevice(libusb_device_handle* handle, const std::uint32_t rate,
    const std::uint8_t channels, const std::uint8_t minimum_bits, NativeStreamConfig* config,
    ClaimedPcmInterfaces* claimed, std::string* error) {
    if (!handle || !config || !claimed || claimed->streaming >= 0 || claimed->control >= 0 ||
        rate < 8000 || rate > 768000 || channels < 1 || channels > 2 || minimum_bits > 32)
        return Fail(error, "Invalid USB PCM preparation request", LIBUSB_ERROR_INVALID_PARAM);
    libusb_config_descriptor* raw = nullptr;
    int rc = libusb_get_active_config_descriptor(libusb_get_device(handle), &raw);
    if (rc < 0 || !raw) return Fail(error, "Cannot read the active USB configuration", rc < 0 ? rc : LIBUSB_ERROR_NOT_FOUND);
    std::vector<Candidate> candidates;
    for (int i = 0; i < raw->bNumInterfaces; ++i) {
        const auto& iface = raw->interface[i];
        for (int a = 0; a < iface.num_altsetting; ++a) {
            const auto& alt = iface.altsetting[a];
            if (alt.bInterfaceClass != 1 || alt.bInterfaceSubClass != 2 ||
                alt.bInterfaceProtocol != 0x20 || alt.bAlternateSetting == 0) continue;
            Bytes descriptors;
            if (!Descriptors(alt.extra, alt.extra_length, descriptors)) continue;
            Candidate candidate;
            auto& c = candidate.config;
            c.configuration_value = raw->bConfigurationValue;
            c.interface_number = alt.bInterfaceNumber;
            c.alternate_setting = alt.bAlternateSetting;
            c.sample_rate_hz = rate;
            int terminal = -1, general_count = 0, format_count = 0;
            for (const auto* d : descriptors) {
                if (d[2] == 1 && d[0] >= 16 && d[5] == 1 && Read(d + 6, 4) == 1) {
                    ++general_count;
                    terminal = d[3];
                    c.channel_count = d[10];
                    c.channel_config = Read(d + 11, 4);
                }
                if (d[2] == 2 && d[0] >= 6 && d[3] == 1) {
                    ++format_count;
                    c.subslot_size_bytes = d[4];
                    c.valid_bit_resolution = d[5];
                }
            }
            // Restrict PCM to mono/stereo and integer formats supported by the engine's packer.
            if (general_count != 1 || format_count != 1 || c.channel_count != channels ||
                (c.channel_config != 0 && c.channel_config != (channels == 2 ? 3u : 1u)) ||
                c.valid_bit_resolution < minimum_bits ||
                !((c.valid_bit_resolution == 16 && c.subslot_size_bytes == 2) ||
                  (c.valid_bit_resolution == 24 && (c.subslot_size_bytes == 3 || c.subslot_size_bytes == 4)) ||
                  (c.valid_bit_resolution == 32 && c.subslot_size_bytes == 4))) continue;
            bool endpoints_valid = true;
            for (int e = 0; e < alt.bNumEndpoints; ++e) {
                const auto& ep = alt.endpoint[e];
                if (!Endpoint(ep, (ep.bEndpointAddress & 0x80) != 0, c)) endpoints_valid = false;
            }
            if (!endpoints_valid || c.data_endpoint_address == 0 ||
                (c.data_synchronization_type == 1) != (c.feedback_endpoint_address != 0)) continue;
            // A unique USB streaming input terminal must point directly to a clock source.
            int matches = 0;
            for (int j = 0; j < raw->bNumInterfaces; ++j) {
                const auto& control_iface = raw->interface[j];
                for (int k = 0; k < control_iface.num_altsetting; ++k) {
                    const auto& control = control_iface.altsetting[k];
                    if (control.bInterfaceClass != 1 || control.bInterfaceSubClass != 1 ||
                        control.bInterfaceProtocol != 0x20 || control.bAlternateSetting != 0) continue;
                    Bytes entities;
                    if (!Descriptors(control.extra, control.extra_length, entities)) continue;
                    for (const auto* t : entities) {
                        if (t[2] != 2 || t[0] < 17 || t[3] != terminal || Read(t + 4, 2) != 0x0101) continue;
                        for (const auto* clock : entities) {
                            if (clock[2] == 0x0a && clock[0] >= 8 && clock[3] == t[7]) {
                                candidate.control = control.bInterfaceNumber;
                                candidate.clock = clock[3];
                                candidate.clock_controls = clock[5];
                                ++matches;
                            }
                        }
                    }
                }
            }
            if (matches == 1 && (candidate.clock_controls & 3) != 0 &&
                (candidate.clock_controls & 3) != 2) candidates.push_back(candidate);
        }
    }
    libusb_free_config_descriptor(raw);
    if (candidates.empty()) return Fail(error, "No supported UAC2 PCM alternate with a direct readable clock source");
    std::stable_sort(candidates.begin(), candidates.end(), [](const Candidate& a, const Candidate& b) {
        return a.config.valid_bit_resolution < b.config.valid_bit_resolution;
    });
    rc = libusb_set_auto_detach_kernel_driver(handle, 1);
    if (rc < 0 && rc != LIBUSB_ERROR_NOT_SUPPORTED) return Fail(error, "Cannot enable USB kernel-driver detach", rc);
    for (const auto& candidate : candidates) {
        rc = libusb_claim_interface(handle, candidate.control);
        if (rc < 0) return Fail(error, "Cannot exclusively claim USB AudioControl interface", rc);
        claimed->control = candidate.control;
        rc = libusb_claim_interface(handle, candidate.config.interface_number);
        if (rc < 0) {
            ReleasePcmDevice(handle, claimed);
            return Fail(error, "Cannot exclusively claim USB AudioStreaming interface", rc);
        }
        claimed->streaming = candidate.config.interface_number;
        const auto reject = [&] { ReleasePcmDevice(handle, claimed); };
        rc = libusb_set_interface_alt_setting(handle, claimed->streaming, 0);
        if (rc < 0) { reject(); return Fail(error, "Cannot idle USB streaming interface", rc); }
        const int index = (candidate.clock << 8) | candidate.control;
        rc = RateSupported(handle, index, rate);
        if (rc < 0) { reject(); return Fail(error, "USB clock RANGE transfer failed", rc); }
        if (rc == 0) { reject(); continue; }
        unsigned char frequency[4]{};
        for (int b = 0; b < 4; ++b) frequency[b] = static_cast<unsigned char>(rate >> (8 * b));
        if ((candidate.clock_controls & 3) == 3) {
            rc = libusb_control_transfer(handle, 0x21, 1, 0x0100, index, frequency, 4, 1000);
            if (rc != 4) { reject(); return Fail(error, "USB clock SET_CUR failed", rc < 0 ? rc : LIBUSB_ERROR_IO); }
        }
        rc = libusb_control_transfer(handle, 0xa1, 1, 0x0100, index, frequency, 4, 1000);
        if (rc != 4) { reject(); return Fail(error, "USB clock GET_CUR failed", rc < 0 ? rc : LIBUSB_ERROR_IO); }
        if (Read(frequency, 4) != rate) { reject(); continue; }
        if ((candidate.clock_controls & 0x0c) != 0) {
            unsigned char valid = 0;
            rc = libusb_control_transfer(handle, 0xa1, 1, 0x0200, index, &valid, 1, 1000);
            if (rc != 1) { reject(); return Fail(error, "USB clock validity transfer failed", rc < 0 ? rc : LIBUSB_ERROR_IO); }
            if (valid != 1) { reject(); continue; }
        }
        rc = libusb_set_interface_alt_setting(handle, claimed->streaming, candidate.config.alternate_setting);
        if (rc < 0) { reject(); return Fail(error, "Cannot activate USB streaming alternate", rc); }
        *config = candidate.config;
        if (error) error->clear();
        return LIBUSB_SUCCESS;
    }
    return Fail(error, "DAC rejected the exact PCM rate, clock validity, or streaming alternate; system fallback is disabled");
}
} // namespace lazer::android_uac2
