/* Platform-neutral contract between the decode/DSP engine and a local PCM endpoint.
 * Backend capabilities describe what could be opened; AudioOutputSession describes only the
 * stream that actually opened. Neither is a readback of the physical format emitted by a DAC. */
#ifndef LAZER_AUDIO_OUTPUT_H
#define LAZER_AUDIO_OUTPUT_H

#include <cstdint>
#include <memory>
#include <string>

#include "internal.h"
#include "source.h"

namespace lazer::audio {

struct AudioOutputRequest {
    /* UTF-8 opaque device token; each backend resolves the token in its own device namespace. */
    std::string deviceId;
    /* Request backend-appropriate exclusive ownership where supported; session.exclusive reports
     * what the backend actually acquired. This is not equivalent across operating systems. */
    bool exclusive = false;
    int32_t bufferMillis = 120;
    TargetFormat desired{};
    bool bitPerfect = false;
    /* Require an exact 24-bit PCM carrier for a preformatted DoP payload; no format fallback. */
    bool requireDoP = false;
    /* Require an exact ALSA Native DSD word format for raw DSD; no PCM/DoP fallback. */
    bool requireNativeDsd = false;
};

/* FixedPeriod means each submission is exactly one negotiated period and readiness acknowledges
 * completion of the prior submission. Variable means write() accepts any currently writable frame
 * count. These are queueing rules, not claims about a DAC or about exclusive access. */
enum class OutputWriteMode : int32_t {
    Variable = 0,
    FixedPeriod = 1,
};

/* Facts returned after a backend successfully opens and initializes an output stream. */
struct AudioOutputSession {
    TargetFormat target{};
    PcmFormat engineFormat{};
    int32_t formatSelection = LazerAudioFormatSelectionUnknown;
    int32_t periodFrames = 0;
    int32_t bufferFrames = 0;
    std::string description;
    OutputWriteMode writeMode = OutputWriteMode::Variable;
    bool exclusive = false;
    bool primeBeforeStart = false;
    bool queueDepthAvailable = true;
    /* Set only by CoreAudio from the initialized virtual ASBD; this is HAL format metadata, not a
     * guarantee of bit-perfect output or physical DAC behavior. */
    bool coreAudioMixabilityKnown = false;
    bool coreAudioStreamNonMixable = false;
    /* True only when the backend initialized an exact DoP carrier PCM session. */
    bool doP = false;
    /* True only when the backend initialized an exact Native DSD session. */
    bool nativeDsd = false;
};

enum class OutputWaitResult : int32_t {
    Ready = 0,
    Timeout = 1,
    Error = 2,
};

enum class OutputDrainResult : int32_t {
    Drained = 0,
    Pending = 1,
    Error = 2,
};

class AudioOutput {
public:
    AudioOutput() = default;
    virtual ~AudioOutput() = default;

    AudioOutput(const AudioOutput &) = delete;
    AudioOutput &operator=(const AudioOutput &) = delete;

    virtual int32_t open(const AudioOutputRequest &request, const StreamDescription &source,
        AudioOutputSession &session, std::string &error, LogProxy *log) = 0;
    virtual void close() = 0;

    virtual int32_t start(std::string &error) = 0;
    virtual int32_t stop(std::string &error) = 0;
    virtual int32_t reset(std::string &error) = 0;

    /* Optional backend setup/cleanup runs on the engine's dedicated render thread. */
    virtual int32_t enterRenderThread(std::string &error) { (void)error; return LazerAudioOk; }
    virtual void leaveRenderThread() noexcept {}

    /* Waits for the backend's next writable period or queue update. Ready/Timeout are not errors. */
    virtual OutputWaitResult waitForReady(int32_t timeoutMillis, std::string &error) = 0;

    /* For Variable sessions, returns currently writable frames; for FixedPeriod, returns one period. */
    virtual int32_t writableFrames(std::string &error) = 0;

    /* Returns queued frames when session.queueDepthAvailable is true, or -1 on failure. */
    virtual int32_t queuedFrames(std::string &error) = 0;

    /* Non-blocking drain observation. Call after waitForReady() so backend completion state is fresh. */
    virtual OutputDrainResult drain(std::string &error) = 0;

    /* Copies whole frames to the endpoint. FixedPeriod sessions require exactly one period. */
    virtual int32_t write(const uint8_t *bytes, int32_t frameCount, std::string &error) = 0;

    [[nodiscard]] virtual bool isOpen() const noexcept = 0;
};

/* Implemented by the platform-selected backend translation unit. */
std::unique_ptr<AudioOutput> createPlatformAudioOutput();

}  // namespace lazer::audio

#endif  // LAZER_AUDIO_OUTPUT_H
