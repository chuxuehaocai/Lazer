#include "android_uac2_output.h"
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <thread>
#include <vector>
#ifdef _WIN32
#include <io.h>
#include <fcntl.h>
#else
#include <unistd.h>
#include <fcntl.h>
#endif

namespace lazer::uac2_transport_probe {
void ResetFakeLibusbState();
void SetControlFault(int);
int ClaimedInterfaceCount();
int ClockSetCount();
int StreamingAlternate();
void SetFakeStreamingFormat(std::uint8_t, std::uint8_t);
std::vector<unsigned char> CapturedOutputBytes();
}
using namespace lazer::audio;
using namespace lazer::uac2_transport_probe;
namespace {
void Check(bool okay, const char* message) { if (!okay) throw std::runtime_error(message); }
struct DummyFd {
#ifdef _WIN32
    int fd = _open("NUL", _O_RDONLY);
    ~DummyFd() { _close(fd); }
#else
    int fd = ::open("/dev/null", O_RDONLY);
    ~DummyFd() { ::close(fd); }
#endif
};
class SystemSentinel : public AudioOutput {
public:
    explicit SystemSentinel(int& opens) : opens_(opens) {}
    int32_t open(const AudioOutputRequest&, const StreamDescription&, AudioOutputSession&,
        std::string&, LogProxy*) override { ++opens_; return LazerAudioErrorUnsupported; }
    void close() override {}
    int32_t start(std::string&) override { return 0; }
    int32_t stop(std::string&) override { return 0; }
    int32_t reset(std::string&) override { return 0; }
    OutputWaitResult waitForReady(int32_t, std::string&) override { return OutputWaitResult::Error; }
    int32_t writableFrames(std::string&) override { return 0; }
    int32_t queuedFrames(std::string&) override { return 0; }
    OutputDrainResult drain(std::string&) override { return OutputDrainResult::Error; }
    int32_t write(const uint8_t*, int32_t, std::string&) override { return -1; }
    bool isOpen() const noexcept override { return false; }
private: int& opens_;
};
void SuccessfulOutput(int rate, int bits, int bytes) {
    ResetFakeLibusbState();
    SetFakeStreamingFormat(static_cast<std::uint8_t>(bytes), static_cast<std::uint8_t>(bits));
    DummyFd fd;
    auto output = createAndroidUsbAudioOutput();
    AudioOutputRequest request;
    request.deviceId = "android-usb-fd:" + std::to_string(fd.fd);
    StreamDescription source;
    source.sampleRate = rate; source.channels = 2; source.bitsPerSample = bits;
    request.desired.sampleRate = rate;
    request.desired.channels = source.channels;
    AudioOutputSession facts;
    std::string error;
    Check(output->open(request, source, facts, error, nullptr) == LazerAudioOk, error.c_str());
    Check(facts.exclusive && facts.target.sampleRate == rate && facts.target.bitsPerSample == bits &&
        facts.target.containerBitsPerSample == bytes * 8, "negotiated PCM facts are inaccurate");
    Check(ClaimedInterfaceCount() == 2 && ClockSetCount() == 1 && StreamingAlternate() == 1,
        "output opened without claiming interfaces, setting clock, or setting alternate");
    std::vector<std::uint8_t> pcm(256 * 2 * bytes);
    for (std::size_t i = 0; i < pcm.size(); ++i) pcm[i] = static_cast<std::uint8_t>((i * 7) % 255 + 1);
    Check(output->write(pcm.data(), 256, error) == 256, "PCM write rejected");
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
    Check(output->queuedFrames(error) == 256, "paused output consumed PCM");
    Check(output->start(error) == 0, "USB start failed");
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (output->queuedFrames(error) > 0 && std::chrono::steady_clock::now() < deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    Check(output->drain(error) == OutputDrainResult::Drained, "USB output did not drain");
    const auto captured = CapturedOutputBytes();
    Check(std::search(captured.begin(), captured.end(), pcm.begin(), pcm.end()) != captured.end(),
        "USB data payload differs from submitted PCM bytes");
    Check(output->stop(error) == 0 && output->reset(error) == 0 && output->queuedFrames(error) == 0,
        "pause/flush ledger did not reset");
    output->close();
    Check(ClaimedInterfaceCount() == 0 && StreamingAlternate() == 0, "USB claims leaked after close");
}
void ConvertedDsd() {
    for (const int multiplier : {64, 128, 256}) {
        ResetFakeLibusbState();
        SetFakeStreamingFormat(3, 24);
        DummyFd fd;
        auto output = createAndroidUsbAudioOutput();
        AudioOutputRequest request;
        request.deviceId = "android-usb-fd:" + std::to_string(fd.fd);
        StreamDescription source;
        source.dsd = true; source.dsdRateMultiplier = multiplier;
        source.sampleRate = 44100 * multiplier / 8;
        source.channels = 2; source.bitsPerSample = 1;
        request.desired.sampleRate = source.sampleRate;
        AudioOutputSession facts;
        std::string error;
        // Fake clock tops out at 192 kHz: higher DSD conversion requests
        // must reopen at a lower supported PCM rate, never use the byte clock.
        Check(output->open(request, source, facts, error, nullptr) == 0, error.c_str());
        Check(facts.target.sampleRate == 176400 && facts.target.bitsPerSample == 24 &&
            !facts.doP && !facts.nativeDsd &&
            facts.formatSelection == LazerAudioFormatSelectionExclusiveCommonRateFallback,
            "DSD conversion did not report its negotiated PCM format");
        output->close();
        request.requireDoP = true;
        Check(output->open(request, source, facts, error, nullptr) == LazerAudioErrorUnsupported,
            "required DoP silently converted to PCM");
        request.requireDoP = false; request.requireNativeDsd = true;
        Check(output->open(request, source, facts, error, nullptr) == LazerAudioErrorUnsupported,
            "required native DSD silently converted to PCM");
        request.requireNativeDsd = false; request.bitPerfect = true;
        Check(output->open(request, source, facts, error, nullptr) == LazerAudioErrorUnsupported &&
            ClaimedInterfaceCount() == 0, "DSD conversion claimed bit-perfect playback");
    }
}
void Rejections() {
    DummyFd fd;
    StreamDescription source;
    source.sampleRate = 48000; source.channels = 2; source.bitsPerSample = 16;
    AudioOutputRequest request;
    request.deviceId = "android-usb-fd:" + std::to_string(fd.fd);
    request.desired.sampleRate = source.sampleRate;
    request.desired.channels = source.channels;
    for (int fault = 1; fault <= 6; ++fault) {
        ResetFakeLibusbState();
        SetControlFault(fault);
        int system_opens = 0;
        auto output = routeAndroidAudioOutput(std::make_unique<SystemSentinel>(system_opens));
        AudioOutputSession facts;
        std::string error;
        const auto result = output->open(request, source, facts, error, nullptr);
        Check(result != 0 && !error.empty(), "unverified device clock/topology unexpectedly opened");
        if (fault == 4 || fault == 5)
            Check(result == LazerAudioErrorDevice, "USB claim/control I/O failure was disguised as an unsupported format");
        Check(!facts.exclusive && system_opens == 0 && ClaimedInterfaceCount() == 0,
            "failed USB request leaked claims or fell back to system audio");
    }
    ResetFakeLibusbState();
    int system_opens = 0;
    auto output = routeAndroidAudioOutput(std::make_unique<SystemSentinel>(system_opens));
    AudioOutputSession facts;
    std::string error;
    for (int mismatch = 0; mismatch < 4; ++mismatch) {
        request.desired.sampleRate = mismatch == 0 ? 96000 : source.sampleRate;
        request.desired.channels = mismatch == 1 ? 1 : source.channels;
        request.desired.bitsPerSample = mismatch == 2 ? 24 : 0;
        request.desired.containerBitsPerSample = mismatch == 3 ? 32 : 0;
        Check(output->open(request, source, facts, error, nullptr) == LazerAudioErrorUnsupported &&
            system_opens == 0 && ClaimedInterfaceCount() == 0,
            "conflicting explicit PCM target was ignored or leaked USB ownership");
    }
    request.desired = {};
    request.desired.sampleRate = source.sampleRate;
    request.desired.bitsPerSample = 16;
    SetFakeStreamingFormat(3, 24);
    Check(output->open(request, source, facts, error, nullptr) == LazerAudioErrorUnsupported &&
        ClaimedInterfaceCount() == 0, "explicit precision silently widened to another endpoint format");
    SetFakeStreamingFormat(2, 16);
    request.desired.bitsPerSample = 0;
    for (const auto* id : {"android-usb:/dev/bus/001/002", "android-usb-fd:abc", "android-usb-fd:-1"}) {
        request.deviceId = id;
        Check(output->open(request, source, facts, error, nullptr) != 0 && system_opens == 0,
            "unresolved USB token silently routed to system audio");
    }
    request.deviceId.clear();
    output->open(request, source, facts, error, nullptr);
    Check(system_opens == 1, "default output no longer routes to AAudio");
}
}
int main() {
    try {
        SuccessfulOutput(44100, 16, 2);
        SuccessfulOutput(48000, 24, 3);
        SuccessfulOutput(96000, 24, 4);
        SuccessfulOutput(192000, 32, 4);
        ConvertedDsd();
        Rejections();
        std::cout << "USB output: exact PCM bytes, clock verification, ownership, pause/flush, rejection and routing passed\n";
        return 0;
    } catch (const std::exception& e) {
        std::cerr << e.what() << '\n';
        return 1;
    }
}
