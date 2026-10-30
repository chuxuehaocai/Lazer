#include "audio_output.h"

#include <aaudio/AAudio.h>
#include <algorithm>
#include <chrono>
#include <thread>
#include <mutex>

namespace lazer::audio {
namespace {

class AAudioOutput final : public AudioOutput {
public:
    ~AAudioOutput() override { close(); }

    int32_t open(const AudioOutputRequest &request, const StreamDescription &source,
        AudioOutputSession &session, std::string &error, LogProxy *) override {
        std::lock_guard<std::recursive_mutex> guard(mutex_);
        error.clear();
        close();
        session = AudioOutputSession{};
        if (request.bitPerfect || request.requireDoP || request.requireNativeDsd) {
            error = "Android AAudio supports mixed PCM; direct DSD and bit-perfect output are unavailable";
            return LazerAudioErrorUnsupported;
        }
        AAudioStreamBuilder *builder = nullptr;
        aaudio_result_t result = AAudio_createStreamBuilder(&builder);
        if (result != AAUDIO_OK) return failed(result, error);
        AAudioStreamBuilder_setDirection(builder, AAUDIO_DIRECTION_OUTPUT);
        AAudioStreamBuilder_setFormat(builder, AAUDIO_FORMAT_PCM_FLOAT);
        AAudioStreamBuilder_setSharingMode(builder, AAUDIO_SHARING_MODE_SHARED);
        AAudioStreamBuilder_setPerformanceMode(builder, AAUDIO_PERFORMANCE_MODE_NONE);
        AAudioStreamBuilder_setChannelCount(builder, std::clamp(source.channels, 1, 2));
        // Let Android select its native sample clock; FFmpeg resamples once to
        // the negotiated rate, avoiding a second system conversion.
        if (request.desired.sampleRate > 0 && request.desired.sampleRate != source.sampleRate) {
            AAudioStreamBuilder_setSampleRate(builder, request.desired.sampleRate);
        }
        result = AAudioStreamBuilder_openStream(builder, &stream_);
        if (result != AAUDIO_OK) {
            if (stream_ != nullptr) { AAudioStream_close(stream_); stream_ = nullptr; }
            AAudioStreamBuilder_setFormat(builder, AAUDIO_FORMAT_PCM_I16);
            result = AAudioStreamBuilder_openStream(builder, &stream_);
        }
        AAudioStreamBuilder_delete(builder);
        if (result != AAUDIO_OK) { close(); return failed(result, error); }
        target_ = TargetFormat{};
        target_.sampleRate = AAudioStream_getSampleRate(stream_);
        target_.channels = AAudioStream_getChannelCount(stream_);
        if (target_.sampleRate <= 0 || target_.channels < 1 || target_.channels > 2) {
            error = "Android negotiated an invalid sample clock or channel count";
            close();
            return LazerAudioErrorDevice;
        }
        const auto format = AAudioStream_getFormat(stream_);
        if (format != AAUDIO_FORMAT_PCM_FLOAT && format != AAUDIO_FORMAT_PCM_I16) {
            error = "Android negotiated an unsupported PCM format";
            close();
            return LazerAudioErrorUnsupported;
        }
        target_.bitsPerSample = format == AAUDIO_FORMAT_PCM_FLOAT ? 0 : 16;
        target_.containerBitsPerSample = format == AAUDIO_FORMAT_PCM_FLOAT ? 32 : 16;
        const int32_t requested = static_cast<int32_t>(
            static_cast<int64_t>(target_.sampleRate) * std::clamp(request.bufferMillis, 20, 1000) / 1000);
        const int32_t capacity = AAudioStream_getBufferCapacityInFrames(stream_);
        const int32_t resized = AAudioStream_setBufferSizeInFrames(stream_, std::min(requested, capacity));
        if (resized < 0) { close(); return failed(resized, error); }
        if (capacity <= 0 || AAudioStream_getBufferSizeInFrames(stream_) <= 0) {
            error = "Android returned an empty output buffer";
            close();
            return LazerAudioErrorDevice;
        }
        session = AudioOutputSession{};
        session.target = target_;
        session.engineFormat = {target_.sampleRate, target_.channels};
        session.formatSelection = LazerAudioFormatSelectionSharedMix;
        session.bufferFrames = AAudioStream_getBufferSizeInFrames(stream_);
        session.periodFrames = std::max(1, AAudioStream_getFramesPerBurst(stream_));
        session.writeMode = OutputWriteMode::Variable;
        // Variable-write accounting belongs to the render loop. Engine priming
        // uses a fixed-period ledger and would lose the first PCM buffer here.
        session.primeBeforeStart = false;
        session.description = "Android AAudio shared PCM";
        return LazerAudioOk;
    }

    void close() override {
        std::lock_guard<std::recursive_mutex> guard(mutex_);
        if (stream_ != nullptr) {
            AAudioStream_close(stream_);
            stream_ = nullptr;
        }
    }

    int32_t start(std::string &error) override {
        std::lock_guard<std::recursive_mutex> guard(mutex_);
        error.clear();
        if (stream_ == nullptr) return LazerAudioErrorInvalidArgument;
        const auto state = AAudioStream_getState(stream_);
        if (state == AAUDIO_STREAM_STATE_STARTED || state == AAUDIO_STREAM_STATE_STARTING) return LazerAudioOk;
        // Legacy AudioTrack may wait for the next PCM write before completing
        // a resume. Waiting here would keep the engine's render loop paused.
        const auto result = AAudioStream_requestStart(stream_);
        return result == AAUDIO_OK ? LazerAudioOk : failed(result, error);
    }

    int32_t stop(std::string &error) override {
        std::lock_guard<std::recursive_mutex> guard(mutex_);
        error.clear();
        if (stream_ == nullptr) return LazerAudioOk;
        const auto state = AAudioStream_getState(stream_);
        if (state == AAUDIO_STREAM_STATE_PAUSING) return awaitState(AAUDIO_STREAM_STATE_PAUSED, error);
        if (state == AAUDIO_STREAM_STATE_PAUSED || state == AAUDIO_STREAM_STATE_OPEN ||
            state == AAUDIO_STREAM_STATE_FLUSHED) return LazerAudioOk;
        const auto result = AAudioStream_requestPause(stream_);
        if (result != AAUDIO_OK) return failed(result, error);
        return awaitState(AAUDIO_STREAM_STATE_PAUSED, error);
    }

    int32_t reset(std::string &error) override {
        std::lock_guard<std::recursive_mutex> guard(mutex_);
        error.clear();
        if (stream_ == nullptr) return LazerAudioOk;
        const int32_t stopped = stop(error);
        if (stopped != LazerAudioOk) return stopped;
        const auto state = AAudioStream_getState(stream_);
        if (state == AAUDIO_STREAM_STATE_OPEN || state == AAUDIO_STREAM_STATE_FLUSHED) return LazerAudioOk;
        const auto result = AAudioStream_requestFlush(stream_);
        if (result != AAUDIO_OK) return failed(result, error);
        return awaitState(AAUDIO_STREAM_STATE_FLUSHED, error);
    }

    OutputWaitResult waitForReady(int32_t timeoutMillis, std::string &error) override {
        // Never hold the device lock while sleeping: pause/seek/teardown must
        // not wait behind a full buffer. One burst is enough, bounded at 20ms.
        if (writableFrames(error) > 0) return OutputWaitResult::Ready;
        if (!error.empty()) return OutputWaitResult::Error;
        int32_t burstMillis = 1;
        {
            std::lock_guard<std::recursive_mutex> guard(mutex_);
            if (stream_ != nullptr && target_.sampleRate > 0) {
                burstMillis = std::max(1, static_cast<int32_t>(
                    static_cast<int64_t>(AAudioStream_getFramesPerBurst(stream_)) * 1000 / target_.sampleRate));
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(
            std::clamp(timeoutMillis, 0, std::min(burstMillis, 20))));
        const int32_t ready = writableFrames(error);
        return !error.empty() ? OutputWaitResult::Error
            : ready > 0 ? OutputWaitResult::Ready : OutputWaitResult::Timeout;
    }

    int32_t writableFrames(std::string &error) override {
        std::lock_guard<std::recursive_mutex> guard(mutex_);
        const int32_t queued = queuedFrames(error);
        return queued < 0 ? -1 : std::max(0, AAudioStream_getBufferSizeInFrames(stream_) - queued);
    }

    int32_t queuedFrames(std::string &error) override {
        std::lock_guard<std::recursive_mutex> guard(mutex_);
        error.clear();
        if (stream_ == nullptr) {
            error = "Android audio output disconnected";
            return -1;
        }
        aaudio_stream_state_t state = AAUDIO_STREAM_STATE_UNKNOWN;
        const auto update = AAudioStream_waitForStateChange(stream_, AAUDIO_STREAM_STATE_UNKNOWN, &state, 0);
        if (state == AAUDIO_STREAM_STATE_DISCONNECTED ||
            (update != AAUDIO_OK && update != AAUDIO_ERROR_TIMEOUT)) {
            return failed(state == AAUDIO_STREAM_STATE_DISCONNECTED ? AAUDIO_ERROR_DISCONNECTED : update, error);
        }
        const int64_t written = AAudioStream_getFramesWritten(stream_);
        const int64_t read = AAudioStream_getFramesRead(stream_);
        if (written < 0 || read < 0) return failed(static_cast<aaudio_result_t>(std::min(written, read)), error);
        return static_cast<int32_t>(std::clamp<int64_t>(written - read, 0,
            AAudioStream_getBufferSizeInFrames(stream_)));
    }

    OutputDrainResult drain(std::string &error) override {
        std::lock_guard<std::recursive_mutex> guard(mutex_);
        const int32_t queued = queuedFrames(error);
        return queued < 0 ? OutputDrainResult::Error
            : queued == 0 ? OutputDrainResult::Drained : OutputDrainResult::Pending;
    }

    int32_t write(const uint8_t *bytes, int32_t frames, std::string &error) override {
        std::lock_guard<std::recursive_mutex> guard(mutex_);
        error.clear();
        if (stream_ == nullptr || bytes == nullptr || frames < 0) return LazerAudioErrorInvalidArgument;
        int32_t offset = 0;
        while (offset < frames) {
            const auto result = AAudioStream_write(stream_, bytes + static_cast<size_t>(offset) * target_.frameBytes(),
                frames - offset, 100'000'000);
            if (result < 0) return failed(result, error);
            if (result == 0) return failed(AAUDIO_ERROR_TIMEOUT, error);
            offset += result;
        }
        return offset;
    }

    bool isOpen() const noexcept override {
        std::lock_guard<std::recursive_mutex> guard(mutex_); return stream_ != nullptr; }

private:
    static int32_t failed(aaudio_result_t result, std::string &error) {
        error = std::string("AAudio: ") + AAudio_convertResultToText(result);
        return LazerAudioErrorDevice;
    }
    int32_t awaitState(aaudio_stream_state_t wanted, std::string &error) {
        for (int attempt = 0; attempt < 10; ++attempt) {
            const auto state = AAudioStream_getState(stream_);
            if (state == wanted) return LazerAudioOk;
            if (state == AAUDIO_STREAM_STATE_DISCONNECTED) return failed(AAUDIO_ERROR_DISCONNECTED, error);
            aaudio_stream_state_t next = state;
            const auto result = AAudioStream_waitForStateChange(stream_, state, &next, 50'000'000);
            if (next == wanted) return LazerAudioOk;
            if (next == AAUDIO_STREAM_STATE_DISCONNECTED) return failed(AAUDIO_ERROR_DISCONNECTED, error);
            if (result != AAUDIO_OK && result != AAUDIO_ERROR_TIMEOUT) return failed(result, error);
        }
        return failed(AAUDIO_ERROR_TIMEOUT, error);
    }
    mutable std::recursive_mutex mutex_;
    AAudioStream *stream_ = nullptr;
    TargetFormat target_{};
};
}  // namespace

std::unique_ptr<AudioOutput> createPlatformAudioOutput() {
    return std::make_unique<AAudioOutput>();
}
}  // namespace lazer::audio
