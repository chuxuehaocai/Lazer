#pragma once

#include <string>
#include <string_view>

namespace lazer::audio {

inline bool isAlsaHardwareDevice(std::string_view name) noexcept {
    return name.size() > 3 && name.substr(0, 3) == "hw:" &&
        name.find_first_of(std::string_view("\r\n\0", 3)) == std::string_view::npos;
}

inline bool isAlsaSharedDevice(std::string_view name) noexcept {
    return name == "default" || name == "pulse" || name == "pipewire";
}

inline std::string selectAlsaOutputDevice(std::string_view explicitDevice, bool exclusive,
    bool bitPerfect, bool requireDoP, bool requireNativeDsd) {
    if (!explicitDevice.empty()) return std::string(explicitDevice);
    return exclusive || bitPerfect || requireDoP || requireNativeDsd ? "hw:0,0" : "default";
}

inline bool allowsAlsaSharedOutput(bool exclusive, bool bitPerfect,
    bool requireDoP, bool requireNativeDsd) noexcept {
    return !exclusive && !bitPerfect && !requireDoP && !requireNativeDsd;
}

inline bool acceptsAlsaRateReadback(std::string_view device, unsigned int requested,
    unsigned int actual) noexcept {
    return actual > 0 && (isAlsaSharedDevice(device) || actual == requested);
}

} // namespace lazer::audio
