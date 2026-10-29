/* A pull-style, bounded PCM facade over the existing device-independent DSD source. */
#ifndef LAZER_AUDIO_DSD_PCM_DECODER_H
#define LAZER_AUDIO_DSD_PCM_DECODER_H

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "source.h"

namespace lazer::audio {

struct DsdPcmFormat {
    int32_t sampleRate = 0;
    int32_t channels = 0;
    int32_t dsdRateMultiplier = 0;
    int64_t durationMillis = 0;
    int64_t totalFrames = 0;
};

/*
 * Owns an AudioSource pump thread and a small PCM ring. Reads are frame-aligned, seek requests
 * discard queued pre-seek samples, and close interrupts both the reader and a back-pressured pump.
 * The target is interleaved float32 PCM or packed 24-bit DoP; the platform audio renderer remains
 * outside this class.
 */
class DsdPcmDecoder final : private SourceConsumer {
public:
    DsdPcmDecoder();
    ~DsdPcmDecoder() override;

    DsdPcmDecoder(const DsdPcmDecoder &) = delete;
    DsdPcmDecoder &operator=(const DsdPcmDecoder &) = delete;

    int32_t open(const LazerAudioReader &reader, int32_t targetSampleRate, DsdPcmFormat &format,
        bool doP = false);
    /* Returns LazerAudioOk; frameCount is zero only at clean EOF after the queue is drained. */
    int32_t readFrames(uint8_t *destination, int32_t capacityFrames,
        int32_t &frameCount, bool &endOfStream);
    int32_t seek(int64_t positionMillis);
    void close();

    [[nodiscard]] std::string lastError() const;
    [[nodiscard]] int32_t frameBytes() const;

private:
    int32_t accept(const uint8_t *bytes, int32_t frameCount) override;
    bool shouldPump() const override;
    bool isCancelled() const override;
    void onSeekApplied() override;
    void pumpLoop();
    void setFailure(std::string message);
    void clearQueuedFramesLocked();

    static constexpr int32_t kRingCapacityFrames = 32 * 1024;
    static constexpr int32_t kPreferredReadFrames = 2048;

    LogProxy log_;
    AudioSource source_;
    LazerAudioReader reader_{};
    std::thread worker_;
    mutable std::mutex mutex_;
    std::condition_variable changed_;
    std::vector<uint8_t> ring_;
    int32_t frameBytes_ = 0;
    int32_t ringReadFrame_ = 0;
    int32_t ringWriteFrame_ = 0;
    int32_t ringSizeFrames_ = 0;
    std::atomic<bool> cancelled_{false};
    bool opened_ = false;
    bool finished_ = false;
    bool endOfStream_ = false;
    std::string lastError_;
};

}  // namespace lazer::audio

#endif  // LAZER_AUDIO_DSD_PCM_DECODER_H
