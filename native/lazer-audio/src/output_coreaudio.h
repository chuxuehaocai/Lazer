/* CoreAudio HAL device output. The Engine writes interleaved PCM into a bounded SPSC queue; a
 * realtime AudioDeviceIOProc copies it into the stream buffers negotiated by the HAL. */
#ifndef LAZER_AUDIO_OUTPUT_COREAUDIO_H
#define LAZER_AUDIO_OUTPUT_COREAUDIO_H

#include <CoreAudio/CoreAudio.h>

#include <atomic>
#include <cstdint>
#include <string>
#include <vector>

#include "audio_output.h"
#include "coreaudio_callback_health.h"
#include "coreaudio_pcm_queue.h"

namespace lazer::audio {

class CoreAudioOutput final : public AudioOutput {
public:
    CoreAudioOutput() = default;
    ~CoreAudioOutput() override;

    CoreAudioOutput(const CoreAudioOutput &) = delete;
    CoreAudioOutput &operator=(const CoreAudioOutput &) = delete;

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
    static constexpr uint8_t kCallbackHealthMonitoring = 0x01;
    static constexpr uint8_t kCallbackHealthLost = 0x02;

    static OSStatus ioProc(AudioObjectID device, const AudioTimeStamp *now,
        const AudioBufferList *input, const AudioTimeStamp *inputTime,
        AudioBufferList *output, const AudioTimeStamp *outputTime, void *clientData);
    OSStatus render(const AudioTimeStamp *outputTime, AudioBufferList *output) noexcept;

    AudioDeviceID device_ = kAudioObjectUnknown;
    AudioStreamID stream_ = kAudioObjectUnknown;
    AudioDeviceIOProcID ioProcId_ = nullptr;
    AudioStreamBasicDescription streamFormat_{};
    AudioStreamBasicDescription originalStreamFormat_{};
    AudioStreamBasicDescription selectedStreamFormat_{};
    AudioOutputSession session_{};
    CoreAudioPcmQueue queue_;
    LogProxy *log_ = nullptr;
    uint32_t bufferFrames_ = 0;
    uint32_t outputLatencyFrames_ = 0;
    uint32_t streamLatencyFrames_ = 0;
    int32_t sampleBytes_ = 0;
    bool interleaved_ = true;
    bool littleEndian_ = true;
    bool ownsHog_ = false;
    bool changedNominalRate_ = false;
    bool hasOriginalStreamFormat_ = false;
    bool hasSelectedStreamFormat_ = false;
    bool changedStreamFormat_ = false;
    bool latencyMetadataKnown_ = false;
    std::atomic<bool> running_{false};
    uint8_t nextDoPMarker_ = 0x05;
    double originalNominalRate_ = 0.0;
    double selectedNominalRate_ = 0.0;
    double hostClockFrequency_ = 0.0;
    std::atomic<bool> callbackFailed_{false};
    std::atomic<uint64_t> ioProcCallbackSequence_{0};
    std::atomic<uint8_t> callbackHealthState_{0};
    std::atomic<uint64_t> lastObservedCallbackSequence_{0};
    std::atomic<uint64_t> lastCallbackObservedMillis_{0};
    std::atomic<uint64_t> lastIoProcHostTime_{0};
    std::atomic<bool> hasIoProcHostTime_{false};
    std::atomic<uint64_t> callbackStallTimeoutMillis_{1000};
    std::atomic<uint32_t> outputCallbacksInFlight_{0};
    std::atomic<bool> outputTimingUnknown_{false};
    std::atomic<uint64_t> lastOutputSampleDeadline_{0};
    std::atomic<bool> hasOutputSampleDeadline_{false};
    std::atomic<uint64_t> lastOutputHostDeadline_{0};
    std::atomic<bool> hasOutputHostDeadline_{false};
};

}  // namespace lazer::audio

#endif  // LAZER_AUDIO_OUTPUT_COREAUDIO_H
