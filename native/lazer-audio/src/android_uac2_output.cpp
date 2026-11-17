#include "android_uac2_output.h"
#include "android_uac2_iso_transport.h"

#include <algorithm>
#include <charconv>
#include <chrono>
#include <limits>
#include <mutex>
#include <thread>

#if defined(__ANDROID__)
// Optional capability export: older imported engines must never interpret a USB
// token as the system default device. No public struct/table layout is changed.
extern "C" __attribute__((visibility("default"))) std::uint32_t lazer_audio_android_usb_backend_version() {
    return 1;
}
#endif

namespace lazer::audio {
namespace {
constexpr char kFdPrefix[] = "android-usb-fd:";
class UsbOutput final : public AudioOutput {
public:
    ~UsbOutput() override { close(); }
    int32_t open(const AudioOutputRequest& request, const StreamDescription& source,
        AudioOutputSession& facts, std::string& error, LogProxy*) override {
        std::lock_guard<std::recursive_mutex> lock(mutex_);
        close();
        facts = {};
        error.clear();
        if (request.requireDoP || request.requireNativeDsd || (source.dsd && request.bitPerfect)) {
            error = "Android USB direct output currently supports PCM only; direct DSD is unavailable";
            return LazerAudioErrorUnsupported;
        }
        int fd = -1;
        if (request.deviceId.rfind(kFdPrefix, 0) != 0) {
            error = "Android USB permission has not produced a live connection";
            return LazerAudioErrorDevice;
        }
        const auto text = request.deviceId.substr(sizeof(kFdPrefix) - 1);
        const auto parsed = std::from_chars(text.data(), text.data() + text.size(), fd);
        if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size() || fd < 0) {
            error = "Invalid Android USB connection token";
            return LazerAudioErrorInvalidArgument;
        }
        if ((!source.dsd && (source.sampleRate < 8000 || source.sampleRate > 768000 ||
            source.bitsPerSample < 0 || source.bitsPerSample > 32)) ||
            source.channels < 1 || source.channels > 2) {
            error = "Android USB direct PCM requires mono/stereo at 8–768 kHz and at most 32 bits";
            return LazerAudioErrorUnsupported;
        }
        // Direct PCM preserves the source clock/layout. Do not silently ignore
        // a future caller's explicit resampling/downmix or precision request.
        if ((!source.dsd && request.desired.sampleRate > 0 && request.desired.sampleRate != source.sampleRate) ||
            (request.desired.channels > 0 && request.desired.channels != source.channels) ||
            (request.desired.bitsPerSample > 0 && request.desired.bitsPerSample != source.bitsPerSample) ||
            request.desired.doP || request.desired.nativeDsd) {
            error = "Android USB direct PCM requires the source rate, channels and precision";
            return LazerAudioErrorUnsupported;
        }
        android_uac2::NativeStreamConfig config{};
        // DSD metadata carries a byte clock, not a PCM clock. Use the same
        // preferred conversion clock as ALSA, then lower 44.1-family clocks.
        int rate = source.dsd ? 44100 * std::clamp(source.dsdRateMultiplier / 16, 4, 16) : source.sampleRate;
        const auto minimum_bits = static_cast<std::uint8_t>(source.dsd ? 24 : std::max(16, source.bitsPerSample));
        int result;
        for (;;) {
            usb_ = android_uac2::IsoTransportSession::Open(fd, &error);
            if (!usb_) return LazerAudioErrorDevice;
            result = usb_->StartPcm(rate, static_cast<std::uint8_t>(source.channels),
                minimum_bits, &config, &error);
            if (result >= 0 || !source.dsd || result != LIBUSB_ERROR_NOT_SUPPORTED || rate <= 44100) break;
            close();
            rate /= 2;
        }
        if (result < 0) {
            close();
            return result == LIBUSB_ERROR_NOT_SUPPORTED ? LazerAudioErrorUnsupported : LazerAudioErrorDevice;
        }
        if ((request.desired.containerBitsPerSample > 0 &&
             request.desired.containerBitsPerSample != config.subslot_size_bytes * 8) ||
            (request.desired.bitsPerSample > 0 &&
             request.desired.bitsPerSample != config.valid_bit_resolution)) {
            error = "Android USB endpoint does not provide the requested PCM precision/container width";
            close();
            return LazerAudioErrorUnsupported;
        }
        error.clear();
        target_.sampleRate = static_cast<int>(config.sample_rate_hz);
        target_.channels = config.channel_count;
        target_.bitsPerSample = config.valid_bit_resolution;
        target_.containerBitsPerSample = config.subslot_size_bytes * 8;
        facts.target = target_;
        facts.engineFormat = {target_.sampleRate, target_.channels};
        facts.formatSelection = source.dsd ? LazerAudioFormatSelectionExclusiveCommonRateFallback
            : target_.bitsPerSample == source.bitsPerSample
            ? LazerAudioFormatSelectionExclusiveSource
            : LazerAudioFormatSelectionExclusiveSameRateAlternate;
        facts.exclusive = true; // Both USB interfaces have actually been claimed.
        facts.bufferFrames = static_cast<int>(usb_->buffer_size_frames());
        facts.periodFrames = std::max(1, target_.sampleRate / 1000);
        facts.writeMode = OutputWriteMode::Variable;
        facts.primeBeforeStart = false;
        facts.description = "Android USB UAC2 direct PCM, " + std::to_string(target_.sampleRate) +
            " Hz, " + std::to_string(target_.channels) + " ch, " + std::to_string(target_.bitsPerSample) +
            " valid bits in " + std::to_string(target_.containerBitsPerSample) +
            " bits; verified device clock; system mixer bypassed";
        if (source.dsd) facts.description += "; DSD converted to PCM (not direct DSD)";
        return LazerAudioOk;
    }
    void close() override {
        std::lock_guard<std::recursive_mutex> lock(mutex_);
        if (usb_) usb_->Close();
        usb_.reset();
        submitted_ = 0;
    }
    int32_t start(std::string& error) override {
        std::lock_guard<std::recursive_mutex> lock(mutex_);
        if (!healthy(error)) return LazerAudioErrorDevice;
        usb_->SetPlaying(true);
        return LazerAudioOk;
    }
    int32_t stop(std::string& error) override {
        std::lock_guard<std::recursive_mutex> lock(mutex_);
        if (!healthy(error)) return LazerAudioErrorDevice;
        usb_->SetPlaying(false);
        return LazerAudioOk;
    }
    int32_t reset(std::string& error) override {
        std::lock_guard<std::recursive_mutex> lock(mutex_);
        if (!healthy(error)) return LazerAudioErrorDevice;
        usb_->SetPlaying(false);
        if (!usb_->Flush(500)) {
            error = "USB PCM flush did not complete";
            return LazerAudioErrorDevice;
        }
        submitted_ = 0;
        return LazerAudioOk;
    }
    OutputWaitResult waitForReady(int32_t timeout, std::string& error) override {
        if (writableFrames(error) > 0) return OutputWaitResult::Ready;
        if (!error.empty()) return OutputWaitResult::Error;
        std::this_thread::sleep_for(std::chrono::milliseconds(std::clamp(timeout, 0, 5)));
        const int frames = writableFrames(error);
        return !error.empty() ? OutputWaitResult::Error : frames > 0 ? OutputWaitResult::Ready : OutputWaitResult::Timeout;
    }
    int32_t queuedFrames(std::string& error) override {
        std::lock_guard<std::recursive_mutex> lock(mutex_);
        if (!healthy(error)) return -1;
        const auto played = usb_->played_frames_since_flush();
        return static_cast<int>(std::min<std::uint64_t>(submitted_ > played ? submitted_ - played : 0,
            std::numeric_limits<int>::max()));
    }
    int32_t writableFrames(std::string& error) override {
        std::lock_guard<std::recursive_mutex> lock(mutex_);
        const int queued = queuedFrames(error);
        return queued < 0 ? -1 : std::max(0, static_cast<int>(usb_->buffer_size_frames()) - queued);
    }
    OutputDrainResult drain(std::string& error) override {
        const int queued = queuedFrames(error);
        return queued < 0 ? OutputDrainResult::Error : queued == 0 ? OutputDrainResult::Drained : OutputDrainResult::Pending;
    }
    int32_t write(const std::uint8_t* bytes, int32_t frames, std::string& error) override {
        std::lock_guard<std::recursive_mutex> lock(mutex_);
        if (!healthy(error)) return LazerAudioErrorDevice;
        if (frames < 0 || (frames > 0 && bytes == nullptr)) return LazerAudioErrorInvalidArgument;
        const int accepted = usb_->Write(bytes, static_cast<std::size_t>(frames) * target_.frameBytes(), 0);
        if (accepted < 0) {
            error = usb_->LastError();
            if (error.empty()) error = "USB PCM write failed";
            return LazerAudioErrorDevice;
        }
        const int accepted_frames = accepted / target_.frameBytes();
        submitted_ += accepted_frames;
        return accepted_frames;
    }
    bool isOpen() const noexcept override {
        std::lock_guard<std::recursive_mutex> lock(mutex_);
        return usb_ != nullptr;
    }
private:
    bool healthy(std::string& error) {
        error.clear();
        if (!usb_) { error = "USB audio connection is closed"; return false; }
        if (usb_->error_code() < 0 || usb_->is_stalled()) {
            error = usb_->LastError();
            if (error.empty()) error = "USB audio transfer stalled or DAC was disconnected";
            return false;
        }
        return true;
    }
    mutable std::recursive_mutex mutex_;
    android_uac2::IsoTransportSession::Pointer usb_;
    TargetFormat target_{};
    std::uint64_t submitted_ = 0;
};

class RoutedOutput final : public AudioOutput {
public:
    explicit RoutedOutput(std::unique_ptr<AudioOutput> system) : system_(std::move(system)), usb_(new UsbOutput), active_(system_.get()) {}
    int32_t open(const AudioOutputRequest& request, const StreamDescription& source,
        AudioOutputSession& facts, std::string& error, LogProxy* log) override {
        close();
        // Persistent/unresolved and malformed USB tokens also fail in USB; never fall back to AAudio.
        active_ = request.deviceId.rfind("android-usb", 0) == 0 ? usb_.get() : system_.get();
        return active_->open(request, source, facts, error, log);
    }
    void close() override { active_->close(); }
    int32_t start(std::string& e) override { return active_->start(e); }
    int32_t stop(std::string& e) override { return active_->stop(e); }
    int32_t reset(std::string& e) override { return active_->reset(e); }
    OutputWaitResult waitForReady(int32_t t, std::string& e) override { return active_->waitForReady(t, e); }
    int32_t writableFrames(std::string& e) override { return active_->writableFrames(e); }
    int32_t queuedFrames(std::string& e) override { return active_->queuedFrames(e); }
    OutputDrainResult drain(std::string& e) override { return active_->drain(e); }
    int32_t write(const std::uint8_t* b, int32_t n, std::string& e) override { return active_->write(b, n, e); }
    bool isOpen() const noexcept override { return active_->isOpen(); }
private:
    std::unique_ptr<AudioOutput> system_, usb_;
    AudioOutput* active_;
};
} // namespace
std::unique_ptr<AudioOutput> createAndroidUsbAudioOutput() { return std::make_unique<UsbOutput>(); }
std::unique_ptr<AudioOutput> routeAndroidAudioOutput(std::unique_ptr<AudioOutput> system) {
    return std::make_unique<RoutedOutput>(std::move(system));
}
} // namespace lazer::audio
