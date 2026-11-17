#include "alsa_output_policy.h"
#include <iostream>
#include <stdexcept>

using namespace lazer::audio;
void check(bool value, const char* text) { if (!value) throw std::runtime_error(text); }
int main() {
    try {
        check(selectAlsaOutputDevice("", false, false, false, false) == "default",
            "ordinary playback bypassed the system mixer");
        for (int required = 0; required < 4; ++required) {
            check(selectAlsaOutputDevice("", required == 0, required == 1,
                required == 2, required == 3) == "hw:0,0", "direct output used a shared default");
            check(!allowsAlsaSharedOutput(required == 0, required == 1, required == 2,
                required == 3), "shared output accepted an exact/direct requirement");
        }
        for (const auto* shared : {"default", "pulse", "pipewire"}) {
            check(isAlsaSharedDevice(shared), "supported shared route was rejected");
            check(!isAlsaHardwareDevice(shared), "shared route claimed hardware ownership");
            check(selectAlsaOutputDevice(shared, false, false, false, false) == shared,
                "explicit shared route was replaced");
            check(acceptsAlsaRateReadback(shared, 192000, 48000), "shared actual rate was rejected");
            check(!acceptsAlsaRateReadback(shared, 192000, 0), "invalid shared clock was accepted");
        }
        check(allowsAlsaSharedOutput(false, false, false, false), "normal shared output was disabled");
        check(selectAlsaOutputDevice("hw:CARD=DAC,DEV=1", false, false, false, false) ==
            "hw:CARD=DAC,DEV=1", "explicit hardware route silently fell back");
        check(isAlsaHardwareDevice("hw:1,0") && !isAlsaHardwareDevice("hw:"), "hardware ID parsing failed");
        check(!isAlsaHardwareDevice(std::string("hw:1\0bad", 8)), "NUL device suffix was accepted");
        check(!isAlsaHardwareDevice("hw:1\n") && !isAlsaSharedDevice("plughw:1,0"),
            "unverified device wrapper was accepted");
        check(acceptsAlsaRateReadback("hw:1,0", 192000, 192000) &&
            !acceptsAlsaRateReadback("hw:1,0", 192000, 48000), "direct clock mismatch was accepted");
        std::cout << "ALSA routes: default shared, explicit device preserved, exact/direct gates and actual clock passed\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
