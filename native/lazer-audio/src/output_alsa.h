/* Direct ALSA hw PCM output. This backend intentionally opens only hw: device names: it must not
 * route through plughw, default, dmix, PulseAudio, or PipeWire plugins. */
#ifndef LAZER_AUDIO_OUTPUT_ALSA_H
#define LAZER_AUDIO_OUTPUT_ALSA_H

#include <cstddef>
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

#include "audio_output.h"

namespace lazer::audio {

class AlsaOutput final : public AudioOutput {
public:
    AlsaOutput() = default;
    ~AlsaOutput() override;

    AlsaOutput(const AlsaOutput &) = delete;
    AlsaOutput &operator=(const AlsaOutput &) = delete;

    int32_t open(const AudioOutputRequest &request, const StreamDescription &source,
        AudioOutputSession &session, std::string &error, LogProxy *log) override;
    void close() override;

    int32_t start(std::string &error) override;
    int32_t stop(std::string &error) override;
    int32_t reset(std::string &error) override;

    OutputWaitResult waitForReady(int32_t timeoutMillis, std::string &error) override;
    int32_t writableFrames(std::string &error) override;
    int32_t queuedFrames(std::string &error) override;
    OutputDrainResult drain(std::string &error) override;
    int32_t write(const uint8_t *bytes, int32_t frameCount, std::string &error) override;

    [[nodiscard]] bool isOpen() const noexcept override;

private:
    /* ALSA types stay out of this header so including the platform contract does not require
     * publishing alsa-lib's headers to the rest of the native engine. */
    int32_t flushStaged(std::string &error);
    int32_t recover(std::string &error, int alsaError);
    int32_t normalizeAlsaState(std::string &error);
    int32_t currentQueuedFrames(std::string &error);
    void pruneSubmitted(size_t framesPlayed);
    void compactQueue(std::vector<uint8_t> &queue, size_t &offsetFrames);
    void requeueSubmittedAtFront();

    mutable std::mutex mutex_;
    void *pcm_ = nullptr;  /* snd_pcm_t */
    AudioOutputSession session_{};
    LogProxy *log_ = nullptr;
    std::string deviceName_;
    int32_t bufferFrames_ = 0;
    int32_t periodFrames_ = 0;
    int32_t frameBytes_ = 0;
    int pollDescriptorCount_ = 0;
    bool running_ = false;
    bool hardwarePaused_ = false;
    bool pauseSupported_ = false;
    bool shift24ToLow_ = false;

    /* ALSA writei is allowed to accept fewer frames than requested. The bounded staging queue
     * keeps the AudioOutput contract lossless across short writes; submittedBytes_ mirrors frames
     * still queued in hardware so a device without pause support can drop/reprepare and replay them. */
    std::vector<uint8_t> stagedBytes_;
    size_t stagedOffsetFrames_ = 0;
    std::vector<uint8_t> submittedBytes_;
    size_t submittedOffsetFrames_ = 0;
};

}  // namespace lazer::audio

#endif  // LAZER_AUDIO_OUTPUT_ALSA_H
