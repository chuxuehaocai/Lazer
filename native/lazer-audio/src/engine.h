/* The engine: two threads and one ring. The pump thread turns the container into PCM blocks and runs
 * them through the DSP chain; the render thread owns the audio endpoint and drains the ring one
 * device period at a time. Control calls are answered from the caller's thread and only ever set
 * flags, so no JNA call can block on the device. */
#ifndef LAZER_AUDIO_ENGINE_H
#define LAZER_AUDIO_ENGINE_H

#include <atomic>
#include <cstdint>
#include <mutex>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "dsp_chain.h"
#include "internal.h"
#include "audio_output.h"
#include "ring_buffer.h"
#include "source.h"

namespace lazer::audio {

class Engine;

class Engine : public SourceConsumer {
public:
    static Engine *create(const LazerAudioEngineConfig &config);
    static Engine *create(const LazerAudioEngineConfig &config, std::unique_ptr<AudioOutput> output);
    void destroy();

    int32_t open(const wchar_t *path, const LazerAudioReader *reader,
        const LazerAudioOpenParams &params);
    int32_t queueReader(uint64_t queueGeneration, const LazerAudioReader &reader,
        const LazerAudioOpenParams &params);
    int32_t clearQueuedReader(uint64_t queueGeneration);
    int32_t play();
    int32_t pause();
    int32_t stop();
    int32_t seek(int64_t positionMillis);
    int32_t setVolume(double volume);
    int32_t setDsp(const LazerAudioDspConfig &dsp);
    int32_t setDevice(const LazerAudioDeviceConfig &device);
    void snapshot(LazerAudioSnapshot &out);
    void streamInfo(LazerAudioStreamInfo &out);
    [[nodiscard]] const std::string &lastError() const { return lastError_; }
    int32_t readLog(int32_t *level, char *message, uint32_t capacity) {
        return log_.read(level, message, capacity);
    }

    static std::string buildInformation();

private:
    struct SourceSlot;

    explicit Engine(LazerAudioEngineConfig config);
    Engine(LazerAudioEngineConfig config, std::unique_ptr<AudioOutput> output);
    ~Engine() override;

    /* SourceConsumer */
    int32_t accept(const uint8_t *bytes, int32_t frameCount) override;
    bool shouldPump() const override;
    bool isCancelled() const override;
    void onSeekApplied() override;

    void pumpLoop();
    void renderLoop();
    int32_t configurePipeline();
    /* True while the float DSP/volume chain is actually on the signal path. */
    [[nodiscard]] bool dspInPath() const;
    /* Position from atomics only: usable from the render thread, which must not take sourceMutex_. */
    [[nodiscard]] int64_t renderPositionMillis() const noexcept;
    /* Applies the codec-string commit the render thread asked for at a frame seam. Producer side. */
    void applyPendingPresentationCommit();
    void raise(int32_t event, int32_t detail, int64_t positionMillis);
    void publishTerminal(int32_t event, int32_t detail, int64_t positionMillis);
    void setError(const std::string &text, int32_t code);
    void setErrorLocked(const std::string &text, int32_t code);
    void joinThreads();
    void teardown();
    AudioSource &currentSource() noexcept;
    const AudioSource &currentSource() const noexcept;
    bool currentSourceEnded() const;
    void resetTimelineForSeek();
    int32_t tryStartQueuedSource(bool &started, std::string &error);
    void cancelCurrentSources();
    void retireCurrentSources();
    int64_t currentPositionMillis() const;
    int64_t currentPositionMillisLocked() const;
    uint64_t convertToOutput(const float *source, int32_t frames, uint8_t *destination);
    void resetDopMarker() noexcept;

    LazerAudioEngineConfig config_{};
    LogProxy log_;

    /* Guards the control-facing fields: state, error text and the descriptors published to the UI. */
    mutable std::mutex apiMutex_;
    /* Serializes open/stop/teardown while allowing worker errors to take apiMutex_ during joins. */
    std::mutex lifecycleMutex_;
    /* Protects the active and queued source slots while control/snapshot calls read metadata. */
    mutable std::mutex sourceMutex_;
    std::atomic<int32_t> state_{LazerAudioStateIdle};
    std::atomic<bool> paused_{true};
    std::atomic<bool> cancelled_{false};
    std::atomic<bool> stopping_{false};
    std::atomic<uint64_t> sessionGeneration_{0};
    std::atomic<uint64_t> queueGeneration_{0};
    std::string lastError_;
    std::atomic<int32_t> lastErrorCode_{LazerAudioOk};
    /* The first terminal writer publishes one coherent immutable event record before publishing
     * the terminal engine state. The record resets only after the previous session's workers join. */
    std::atomic<bool> terminalClaimed_{false};
    std::atomic<int32_t> terminalEvent_{-1};
    std::atomic<int32_t> terminalDetail_{0};
    std::atomic<int64_t> terminalPositionMillis_{0};

    std::shared_ptr<SourceSlot> source_;
    std::shared_ptr<SourceSlot> nextSource_;
    std::shared_ptr<SourceSlot> preparingSource_;
    /* During a queued transition, source_ is already decoding the successor while the ring still
     * contains frames from the audible track. Keep the last audible metadata until its frame seam.
     *
     * The render thread must be able to report the audible track without taking `sourceMutex_` — a
     * blocking acquisition inside the output callback is exactly what this engine forbids — so the
     * scalars it needs are mirrored twice: the producer fills `pendingPresentation_` when it prepares
     * a successor, and the render thread commits them into `activePresentation_` with plain atomic
     * stores at the frame seam. `presentationDescription_` keeps the full description (including the
     * codec string, which only the UI reads) and is committed by the producer once it observes the
     * render thread's commit counter. */
    struct RenderPresentation {
        std::atomic<int64_t> durationMillis{0};
        std::atomic<int64_t> seekTargetMillis{0};
        std::atomic<int32_t> sampleRate{0};
        std::atomic<int32_t> channels{0};
        std::atomic<int32_t> bitsPerSample{0};
        std::atomic<int32_t> bitrateKbps{0};
        std::atomic<int32_t> dsd{0};
        std::atomic<int32_t> dsdRateMultiplier{0};
        std::atomic<int32_t> lossless{0};

        /* Plain stores: each field is independent and only ever read as "the audible track's". */
        void publish(const StreamDescription &description, int64_t seekTarget) noexcept {
            durationMillis.store(description.durationMillis, std::memory_order_release);
            seekTargetMillis.store(seekTarget, std::memory_order_release);
            sampleRate.store(description.sampleRate, std::memory_order_release);
            channels.store(description.channels, std::memory_order_release);
            bitsPerSample.store(description.bitsPerSample, std::memory_order_release);
            bitrateKbps.store(description.bitrateKbps, std::memory_order_release);
            dsd.store(description.dsd ? 1 : 0, std::memory_order_release);
            dsdRateMultiplier.store(description.dsdRateMultiplier, std::memory_order_release);
            lossless.store(description.lossless ? 1 : 0, std::memory_order_release);
        }
    };

    RenderPresentation pendingPresentation_;
    RenderPresentation activePresentation_;
    StreamDescription presentationDescription_;
    StreamDescription pendingPresentationDescription_;
    int64_t presentationSeekTargetMillis_ = 0;
    int64_t pendingPresentationSeekTargetMillis_ = 0;
    int32_t presentationBufferedPercent_ = 0;
    /* The render thread asks for the codec-string commit; the producer applies it on its own thread. */
    std::atomic<uint64_t> presentationCommitRequested_{0};
    std::atomic<uint64_t> presentationCommitApplied_{0};
    /* Mirror of the current source's end-of-stream flag, published by the producer so the render
     * thread never has to take sourceMutex_ to ask. */
    std::atomic<bool> sourceEndedMirror_{false};
    std::unique_ptr<AudioOutput> output_;
    RingBuffer ring_;
    /* Ring hysteresis, published for the diagnostics panel (ABI v26). */
    std::atomic<int32_t> ringLowWatermarkFrames_{0};
    std::atomic<int32_t> ringHighWatermarkFrames_{0};
    /* Producer-side latch: feeding stops at the high watermark and resumes at the low one (or when
     * the pause has lasted longer than the engine's limit, so a parked consumer cannot latch it). */
    bool producerPausedForRing_ = false;
    std::chrono::steady_clock::time_point producerPausedSince_{};
    DspChain dsp_;

    std::atomic<double> volume_{1.0};
    std::atomic<bool> volumeDirty_{false};
    std::atomic<int64_t> volumeRampMillis_{200};

    std::wstring deviceId_;
    LazerAudioDeviceConfig device_{};
    AudioOutputSession outputSession_{};
    TargetFormat floatTarget_{};
    /* One packer spans a complete Native DSD output session, including queued source boundaries. */
    NativeDsdPacker nativeDsdPacker_{};
    bool dspBypassed_ = false;
    /* Set by configurePipeline: the initialized session runs the source's own rate, channel count
     * and depth, with no resampling and no requantization. Reported as
     * `output_format_matches_source` so "bit-perfect" can be checked instead of asserted. */
    bool formatMatchesSource_ = false;
    /* Pump-thread-only per-source ReplayGain ramp; starts at the opened track's gain and retargets
     * only after the queued successor has been activated at the producer-side frame boundary. */
    double replayGainCurrentLinear_ = 1.0;
    double replayGainTargetLinear_ = 1.0;
    int64_t replayGainRampRemainingFrames_ = 0;
    std::atomic<bool> bitPerfectActive_{false};
    std::atomic<bool> dopActive_{false};
    std::atomic<bool> nativeDsdActive_{false};
    std::atomic<int32_t> outputPeakMilliDbfs_{-120'000};
    std::atomic<int32_t> limiterGainReductionMilliDb_{0};
    std::atomic<uint64_t> outputClippedSampleCount_{0};
    std::atomic<bool> outputTelemetryValid_{false};
    uint64_t ditherState_ = 0x9e3779b97f4a7c15ULL;
    uint8_t dopNextMarker_ = 0x05;

    std::thread pumpThread_;
    std::thread renderThread_;

    /* Reused by the pump thread so a DSP block never allocates per frame. */
    std::vector<uint8_t> convertScratch_;
    std::vector<uint8_t> queuedPcmScratch_;
    std::vector<uint8_t> nativeDsdScratch_;

    /* Render-side accounting, reset whenever the producer flushes the ring for a seek. */
    std::atomic<int64_t> renderedFrames_{0};
    std::atomic<int64_t> writtenFrames_{0};
    std::atomic<int64_t> acceptedFrames_{0};
    std::atomic<int64_t> trackStartOutputFrame_{0};
    std::atomic<int64_t> pendingTrackChangedFrame_{-1};
    std::atomic<bool> pendingPresentationReady_{false};
    /* A seek into an activated, not-yet-presented successor preserves its output-frame boundary. */
    std::atomic<bool> pendingPresentationSeek_{false};
    std::atomic<bool> seekFlushRequested_{false};
    std::atomic<bool> endedRaised_{false};
    std::atomic<bool> pumpFinished_{false};
    std::atomic<int32_t> exclusiveInFlightAudioFrames_{0};
    std::atomic<int32_t> underrunActive_{0};
    std::atomic<uint64_t> underrunFrames_{0};
    bool streamStarted_ = false;
};

}  // namespace lazer::audio

#endif  // LAZER_AUDIO_ENGINE_H
