#pragma once

#include <libusb.h>
#include <cstdint>
#include <string>

namespace lazer::android_uac2 {
struct NativeStreamConfig;

// Only direct terminal -> clock-source topologies are accepted. Selector/multiplier
// clocks require their own verified controls and must never be guessed.
struct ClaimedPcmInterfaces {
    int control = -1;
    int streaming = -1;
};
int PreparePcmDevice(libusb_device_handle* handle, std::uint32_t rate,
    std::uint8_t channels, std::uint8_t minimum_bits, NativeStreamConfig* config,
    ClaimedPcmInterfaces* claimed, std::string* error);
void ReleasePcmDevice(libusb_device_handle* handle, ClaimedPcmInterfaces* claimed) noexcept;
} // namespace lazer::android_uac2
