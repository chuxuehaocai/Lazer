/* WASAPI renderer. One instance owns one audio endpoint: shared mode follows the system mix format
 * through an event-driven push; exclusive mode requests an endpoint-accepted format. Neither mode
 * reads back or certifies the physical format emitted by the DAC. */
#ifndef LAZER_AUDIO_OUTPUT_WASAPI_H
#define LAZER_AUDIO_OUTPUT_WASAPI_H

#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

/* WAVEFORMATEX is a typedef of an anonymous struct in mmreg.h, so it cannot be forward declared; the
 * real header is the only way to name it in the member below. */
#include <windows.h>
#include <mmreg.h>

#include "audio_output.h"

namespace lazer::audio {

class WasapiOutput final : public AudioOutput {
public:
    WasapiOutput() = default;
    ~WasapiOutput() override;

    WasapiOutput(const WasapiOutput &) = delete;
    WasapiOutput &operator=(const WasapiOutput &) = delete;

    int32_t open(const AudioOutputRequest &request, const StreamDescription &source,
        AudioOutputSession &session, std::string &error, LogProxy *log) override;
    void close() override;

    int32_t start(std::string &error) override;
    int32_t stop(std::string &error) override;
    int32_t reset(std::string &error) override;
    int32_t enterRenderThread(std::string &error) override;
    void leaveRenderThread() noexcept override;

    OutputWaitResult waitForReady(int32_t timeoutMillis, std::string &error) override;
    int32_t writableFrames(std::string &error) override;
    int32_t queuedFrames(std::string &error) override;
    OutputDrainResult drain(std::string &error) override;

    /* Copies whole frames into the render client's buffer. Returns frames accepted, which can be 0
     * when the endpoint is momentarily full, or a negative error. */
    int32_t write(const uint8_t *bytes, int32_t frameCount, std::string &error) override;

    /* Signalled by the endpoint when it is ready for the next period; shared and exclusive both use
     * event calling, so the render thread never has to busy-wait. */
    [[nodiscard]] int64_t submittedFrames() const noexcept {
        return submittedFrames_.load(std::memory_order_acquire);
    }
    [[nodiscard]] bool isOpen() const noexcept override { return audioClient_ != nullptr; }
    [[nodiscard]] bool isRunning() const noexcept { return running_; }
    [[nodiscard]] bool isExclusive() const noexcept { return exclusive_; }

private:
    void releaseCom();

    /* The device hands back a CoTaskMem block for the mix and native formats, and the exclusive
     * fallback reuses one of those, so the buffer that actually drove Initialize is remembered here
     * and freed on close. A format built on the stack is never owned. */
    WAVEFORMATEX *ownedFormat_ = nullptr;
    void *enumerator_ = nullptr;      /* IMMDeviceEnumerator */
    void *device_ = nullptr;           /* IMMDevice */
    void *audioClient_ = nullptr;      /* IAudioClient */
    void *renderClient_ = nullptr;     /* IAudioRenderClient */
    void *eventHandle_ = nullptr;      /* auto-reset HANDLE owned here */
    AudioOutputSession session_{};
    uint32_t bufferFrames_ = 0;
    uint32_t periodFrames_ = 0;
    uint64_t devicePeriodHundredNanos_ = 0;
    bool running_ = false;
    bool exclusive_ = false;
    std::atomic<bool> fixedPeriodPending_{false};
    bool comInitialised_ = false;
    bool renderThreadComInitialised_ = false;
    std::atomic<int64_t> submittedFrames_{0};
};

}  // namespace lazer::audio

#endif  // LAZER_AUDIO_OUTPUT_WASAPI_H
