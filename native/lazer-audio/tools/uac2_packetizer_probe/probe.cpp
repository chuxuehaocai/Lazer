#include "android_uac2_packetizer.h"

#include <cstdint>
#include <iostream>

using lazer::android_uac2::PcmPacketizer;
using lazer::android_uac2::SynchronizationType;
using lazer::android_uac2::UsbSpeed;

namespace {

bool CountFrames(PcmPacketizer& packetizer, const std::uint32_t count, std::uint64_t* total) {
    *total = 0;
    for (std::uint32_t index = 0; index < count; ++index) {
        std::uint32_t frames = 0;
        if (!packetizer.NextPacketFrameCount(&frames)) return false;
        *total += frames;
    }
    return true;
}

bool Check(const bool condition, const char* message) {
    if (condition) return true;
    std::cerr << message << '\n';
    return false;
}

} // namespace

int main() {
    std::uint64_t total = 0;
    PcmPacketizer full_speed_adaptive;
    if (!Check(full_speed_adaptive.Configure(
                   44100, 6, 1023, UsbSpeed::Full, SynchronizationType::Adaptive, 1, false),
               "44.1 kHz full-speed adaptive configuration should fit the endpoint")) return 1;
    if (!Check(CountFrames(full_speed_adaptive, 1000, &total) && total == 44100,
               "Full-speed packetization must preserve exactly 44,100 frames per second")) return 1;

    PcmPacketizer high_speed_adaptive;
    if (!Check(high_speed_adaptive.Configure(
                   44100, 8, 1024, UsbSpeed::High, SynchronizationType::Adaptive, 1, false),
               "44.1 kHz high-speed adaptive configuration should fit the endpoint")) return 1;
    if (!Check(CountFrames(high_speed_adaptive, 8000, &total) && total == 44100,
               "High-speed packetization must preserve exactly 44,100 frames per second")) return 1;

    PcmPacketizer high_speed_interval_two;
    if (!Check(high_speed_interval_two.Configure(
                   44100, 8, 1024, UsbSpeed::High, SynchronizationType::Synchronous, 2, false),
               "High-speed bInterval=2 packetization should be supported")) return 1;
    if (!Check(CountFrames(high_speed_interval_two, 4000, &total) && total == 44100,
               "High-speed bInterval=2 must preserve the nominal frame rate")) return 1;

    PcmPacketizer high_speed_async;
    if (!Check(!high_speed_async.Configure(
                   44100, 4, 1024, UsbSpeed::High, SynchronizationType::Asynchronous, 1, false),
               "An asynchronous sink without explicit feedback must fail closed")) return 1;
    if (!Check(high_speed_async.Configure(
                   44100, 4, 1024, UsbSpeed::High, SynchronizationType::Asynchronous, 1, true),
               "High-speed asynchronous configuration with feedback should be supported")) return 1;
    const std::uint8_t high_speed_feedback[4] = {0x33u, 0x83u, 0x05u, 0x00u};
    if (!Check(high_speed_async.UpdateFeedback(high_speed_feedback, sizeof(high_speed_feedback)),
               "16.16 high-speed feedback should be accepted")) return 1;
    if (!Check(CountFrames(high_speed_async, 8000, &total) && total >= 44099 && total <= 44100,
               "High-speed 16.16 feedback should pace near 44,100 frames per second")) return 1;
    const std::uint8_t invalid_feedback[4] = {0, 0, 0, 0};
    if (!Check(!high_speed_async.UpdateFeedback(invalid_feedback, sizeof(invalid_feedback)),
               "Zero feedback must be rejected")) return 1;

    PcmPacketizer full_speed_async;
    if (!Check(full_speed_async.Configure(
                   44100, 4, 1024, UsbSpeed::Full, SynchronizationType::Asynchronous, 1, true),
               "Full-speed asynchronous configuration with feedback should be supported")) return 1;
    const std::uint8_t full_speed_feedback[3] = {0x66u, 0x06u, 0x0bu};
    if (!Check(full_speed_async.UpdateFeedback(full_speed_feedback, sizeof(full_speed_feedback)),
               "10.14 full-speed feedback should be accepted")) return 1;
    if (!Check(CountFrames(full_speed_async, 1000, &total) && total >= 44099 && total <= 44100,
               "Full-speed 10.14 feedback should pace near 44,100 frames per second")) return 1;

    PcmPacketizer unsupported_speed;
    if (!Check(!unsupported_speed.Configure(
                   44100, 4, 1024, static_cast<UsbSpeed>(3), SynchronizationType::Adaptive, 1, false),
               "Non-USB-2 link speeds must fail closed")) return 1;

    std::cout << "UAC2 packetizer pacing and feedback checks passed\n";
    return 0;
}
