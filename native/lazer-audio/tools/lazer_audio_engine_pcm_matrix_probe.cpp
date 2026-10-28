/* End-to-end, device-free regression for exact integer PCM output and gapless boundaries across
 * the format matrix. A fake fixed-period endpoint captures the engine's actual output bytes. */
#include "engine.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libavutil/mem.h>
}

namespace {

using namespace lazer::audio;

std::atomic<bool> gTraceBoundary{false};

constexpr int32_t kChannels = 2;
constexpr int32_t kPeriodFrames = 512;
constexpr int32_t kBoundaryFrameOffset = 339;
constexpr int32_t kSecondFrames = 173;  // Makes the final capture an exact number of periods.

int32_t firstTrackFramesForRate(int32_t sampleRate) {
    const int32_t engineRingWantedFrames = std::max(kPeriodFrames * 3, sampleRate * 60 / 1000);
    int32_t engineRingCapacity = 1;
    while (engineRingCapacity < engineRingWantedFrames) engineRingCapacity <<= 1;
    /* Keep the producer backpressured until the successor is queued, despite the engine's
     * power-of-two ring rounding; leave the A->B seam off the fixed-period boundary. */
    return engineRingCapacity + kBoundaryFrameOffset;
}

void append16(std::vector<uint8_t> &bytes, uint16_t value) {
    bytes.push_back(static_cast<uint8_t>(value & 0xff));
    bytes.push_back(static_cast<uint8_t>((value >> 8) & 0xff));
}

void append32(std::vector<uint8_t> &bytes, uint32_t value) {
    bytes.push_back(static_cast<uint8_t>(value & 0xff));
    bytes.push_back(static_cast<uint8_t>((value >> 8) & 0xff));
    bytes.push_back(static_cast<uint8_t>((value >> 16) & 0xff));
    bytes.push_back(static_cast<uint8_t>((value >> 24) & 0xff));
}

int64_t sampleValue(int32_t frame, int32_t channel, int32_t bits, int16_t seed) {
    const uint64_t span = uint64_t{1} << static_cast<uint32_t>(bits - 2);
    const uint64_t mixed = static_cast<uint64_t>(frame) * (channel == 0 ? 7'919u : 10'927u) +
        static_cast<uint64_t>(static_cast<uint16_t>(seed)) * (channel == 0 ? 313u : 719u);
    return static_cast<int64_t>(mixed % span) - static_cast<int64_t>(span / 2);
}

void appendSample(std::vector<uint8_t> &bytes, int64_t sample, int32_t bytesPerSample) {
    const uint64_t packed = static_cast<uint64_t>(sample);
    for (int32_t index = 0; index < bytesPerSample; ++index) {
        bytes.push_back(static_cast<uint8_t>((packed >> (index * 8)) & 0xff));
    }
}

std::vector<uint8_t> makePcmWave(int32_t frames, int32_t sampleRate, int32_t bits, int16_t seed) {
    const int32_t bytesPerSample = (bits + 7) / 8;
    const int32_t frameBytes = kChannels * bytesPerSample;
    const uint32_t dataBytes = static_cast<uint32_t>(frames * frameBytes);
    std::vector<uint8_t> bytes;
    bytes.reserve(44 + dataBytes);
    bytes.insert(bytes.end(), {'R', 'I', 'F', 'F'});
    append32(bytes, 36u + dataBytes);
    bytes.insert(bytes.end(), {'W', 'A', 'V', 'E', 'f', 'm', 't', ' '});
    append32(bytes, 16);
    append16(bytes, 1);
    append16(bytes, kChannels);
    append32(bytes, static_cast<uint32_t>(sampleRate));
    append32(bytes, static_cast<uint32_t>(sampleRate * frameBytes));
    append16(bytes, static_cast<uint16_t>(frameBytes));
    append16(bytes, static_cast<uint16_t>(bits));
    bytes.insert(bytes.end(), {'d', 'a', 't', 'a'});
    append32(bytes, dataBytes);
    for (int32_t frame = 0; frame < frames; ++frame) {
        appendSample(bytes, sampleValue(frame, 0, bits, seed), bytesPerSample);
        appendSample(bytes, sampleValue(frame, 1, bits, static_cast<int16_t>(-seed)), bytesPerSample);
    }
    return bytes;
}

struct MemoryReader {
    explicit MemoryReader(std::vector<uint8_t> value) : bytes(std::move(value)) {}
    std::vector<uint8_t> bytes;
    int64_t position = 0;
    std::atomic<int> closeCount{0};
};

int32_t readBytes(void *context, uint8_t *destination, int32_t length) {
    auto *reader = static_cast<MemoryReader *>(context);
    if (reader == nullptr || destination == nullptr || length <= 0) return LAZER_AUDIO_READER_IO_ERROR;
    const int64_t remaining = static_cast<int64_t>(reader->bytes.size()) - reader->position;
    if (remaining <= 0) return LAZER_AUDIO_READER_EOF;
    const int32_t count = static_cast<int32_t>(std::min<int64_t>(remaining, length));
    std::memcpy(destination, reader->bytes.data() + reader->position, static_cast<size_t>(count));
    reader->position += count;
    return count;
}

int64_t seekBytes(void *context, int64_t position) {
    auto *reader = static_cast<MemoryReader *>(context);
    if (reader == nullptr || position < 0 || position > static_cast<int64_t>(reader->bytes.size())) return -1;
    reader->position = position;
    return position;
}

int64_t readerLength(void *context) {
    const auto *reader = static_cast<MemoryReader *>(context);
    return reader == nullptr ? -1 : static_cast<int64_t>(reader->bytes.size());
}

void closeReader(void *context) {
    auto *reader = static_cast<MemoryReader *>(context);
    if (reader != nullptr) reader->closeCount.fetch_add(1, std::memory_order_release);
}

LazerAudioReader asReader(MemoryReader &reader) {
    return LazerAudioReader{readBytes, seekBytes, readerLength, closeReader, &reader};
}

struct Capture;

struct ProbeEvents {
    std::mutex mutex;
    std::condition_variable changed;
    std::vector<int32_t> events;
    std::vector<int64_t> eventPositionsMillis;
    std::vector<int64_t> capturedFramesAtEvent;
    Engine *engine = nullptr;
    Capture *capture = nullptr;
    int32_t callbackSourceBits = 0;
    int64_t callbackDurationMillis = 0;
    int64_t callbackPositionMillis = 0;
    bool callbackSnapshotRead = false;
};

int64_t captureFramesAtCallback(Capture *capture);

void onEvent(void *context, int32_t event, int32_t, int64_t positionMillis) {
    auto *events = static_cast<ProbeEvents *>(context);
    if (events == nullptr) return;
    const int64_t capturedFrames = captureFramesAtCallback(events->capture);
    {
        std::lock_guard guard(events->mutex);
        events->events.push_back(event);
        events->eventPositionsMillis.push_back(positionMillis);
        events->capturedFramesAtEvent.push_back(capturedFrames);
    }
    if (event == LazerAudioEventTrackChanged && events->engine != nullptr) {
        LazerAudioSnapshot snapshot{};
        LazerAudioStreamInfo streamInfo{};
        events->engine->snapshot(snapshot);
        events->engine->streamInfo(streamInfo);
        std::lock_guard guard(events->mutex);
        events->callbackSourceBits = streamInfo.source_bits_per_sample;
        events->callbackDurationMillis = snapshot.duration_millis;
        events->callbackPositionMillis = snapshot.position_millis;
        events->callbackSnapshotRead = true;
    }
    events->changed.notify_all();
}

struct Capture {
    struct OutputSession {
        AudioOutputRequest request;
        TargetFormat target;
        std::vector<uint8_t> bytes;
        int writeCount = 0;
    };

    std::mutex mutex;
    std::condition_variable changed;
    std::vector<uint8_t> bytes;
    std::vector<OutputSession> sessions;
    int openCount = 0;
    int startCount = 0;
    int closeCount = 0;
    int openWhileAlreadyOpenCount = 0;
    int writeCount = 0;
    int gateAfterWrites = 0;
    bool gateWaiting = false;
    bool gateReleased = false;
};

int64_t captureFramesAtCallback(Capture *capture) {
    if (capture == nullptr) return -1;
    std::lock_guard guard(capture->mutex);
    const int32_t frameBytes = capture->sessions.empty()
        ? kChannels * 2 : capture->sessions.back().target.frameBytes();
    return frameBytes > 0 ? static_cast<int64_t>(capture->bytes.size() / frameBytes) : -1;
}

class CaptureOutput final : public AudioOutput {
public:
    explicit CaptureOutput(std::shared_ptr<Capture> capture, bool floatOutput = false,
        int gateAfterWrites = 0)
        : capture_(std::move(capture)), floatOutput_(floatOutput) {
        capture_->gateAfterWrites = gateAfterWrites;
    }

    int32_t open(const AudioOutputRequest &request, const StreamDescription &source,
        AudioOutputSession &session, std::string &, LogProxy *) override {
        std::lock_guard guard(capture_->mutex);
        if (open_) ++capture_->openWhileAlreadyOpenCount;
        ++capture_->openCount;
        session.target.sampleRate = source.sampleRate;
        session.target.channels = source.channels;
        session.target.bitsPerSample = floatOutput_ ? 0 : source.bitsPerSample;
        session.target.containerBitsPerSample = floatOutput_ ? 32 : source.bitsPerSample;
        session.engineFormat = {source.sampleRate, source.channels};
        session.formatSelection = floatOutput_
            ? LazerAudioFormatSelectionSharedMix : LazerAudioFormatSelectionExclusiveSource;
        session.periodFrames = kPeriodFrames;
        session.bufferFrames = kPeriodFrames;
        session.exclusive = !floatOutput_;
        session.writeMode = OutputWriteMode::FixedPeriod;
        session.queueDepthAvailable = true;
        bytesPerFrame_ = session.target.frameBytes();
        Capture::OutputSession openedSession;
        openedSession.request = request;
        openedSession.target = session.target;
        capture_->sessions.push_back(std::move(openedSession));
        currentSessionIndex_ = static_cast<int32_t>(capture_->sessions.size()) - 1;
        open_ = true;
        return LazerAudioOk;
    }

    void close() override {
        std::lock_guard guard(capture_->mutex);
        if (open_) ++capture_->closeCount;
        open_ = false;
        currentSessionIndex_ = -1;
    }

    int32_t start(std::string &) override {
        std::lock_guard guard(capture_->mutex);
        ++capture_->startCount;
        return LazerAudioOk;
    }
    int32_t stop(std::string &) override { return LazerAudioOk; }
    int32_t reset(std::string &) override { return LazerAudioOk; }
    OutputWaitResult waitForReady(int32_t, std::string &) override {
        if (capture_->gateAfterWrites > 0) {
            std::unique_lock guard(capture_->mutex);
            if (capture_->writeCount >= capture_->gateAfterWrites && !capture_->gateReleased) {
                capture_->gateWaiting = true;
                capture_->changed.notify_all();
                capture_->changed.wait(guard, [this] { return capture_->gateReleased; });
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
        return OutputWaitResult::Ready;
    }
    int32_t writableFrames(std::string &) override { return kPeriodFrames; }
    int32_t queuedFrames(std::string &) override { return 0; }
    OutputDrainResult drain(std::string &) override { return OutputDrainResult::Drained; }
    int32_t write(const uint8_t *bytes, int32_t frames, std::string &) override {
        if (bytes == nullptr || frames != kPeriodFrames || bytesPerFrame_ <= 0 ||
            currentSessionIndex_ < 0) {
            return LazerAudioErrorDevice;
        }
        std::lock_guard guard(capture_->mutex);
        const size_t byteCount = static_cast<size_t>(frames) * static_cast<size_t>(bytesPerFrame_);
        capture_->bytes.insert(capture_->bytes.end(), bytes, bytes + byteCount);
        auto &session = capture_->sessions[static_cast<size_t>(currentSessionIndex_)];
        session.bytes.insert(session.bytes.end(), bytes, bytes + byteCount);
        ++session.writeCount;
        ++capture_->writeCount;
        capture_->changed.notify_all();
        return frames;
    }
    [[nodiscard]] bool isOpen() const noexcept override { return open_; }

private:
    std::shared_ptr<Capture> capture_;
    bool floatOutput_ = false;
    int32_t bytesPerFrame_ = 0;
    bool open_ = false;
    int32_t currentSessionIndex_ = -1;
};

void onLog(void *, int32_t level, const char *message) {
    if (gTraceBoundary.load(std::memory_order_acquire) && message != nullptr) {
        std::cerr << "native[" << level << "] " << message << "\n";
    }
}

bool runCase(int32_t sampleRate, int32_t bits, bool testCancellation) {
    const int32_t firstFrames = firstTrackFramesForRate(sampleRate);
    MemoryReader first(makePcmWave(firstFrames, sampleRate, bits, 5'000));
    MemoryReader cancelled(makePcmWave(31, sampleRate, bits, 2'000));
    MemoryReader second(makePcmWave(kSecondFrames, sampleRate, bits, -4'000));
    LazerAudioReader firstReader = asReader(first);
    LazerAudioReader cancelledReader = asReader(cancelled);
    LazerAudioReader secondReader = asReader(second);
    ProbeEvents events;
    auto capture = std::make_shared<Capture>();
    events.capture = capture.get();

    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.exclusive = 1;
    config.device.bit_perfect = 1;
    config.device.buffer_millis = 60;
    config.events.on_event = onEvent;
    config.events.context = &events;
    config.log.on_log = onLog;

    Engine *engine = Engine::create(config, std::make_unique<CaptureOutput>(capture));
    if (engine == nullptr) {
        std::cerr << "Engine::create failed\n";
        return false;
    }
    events.engine = engine;
    const LazerAudioOpenParams firstParams{sizeof(LazerAudioOpenParams), 0, 100};
    const int32_t openResult = engine->open(nullptr, &firstReader, firstParams);
    if (openResult != LazerAudioOk) {
        std::cerr << "Engine::open failed code=" << openResult << " error=" << engine->lastError() << "\n";
        engine->destroy();
        return false;
    }

    const LazerAudioOpenParams nextParams{sizeof(LazerAudioOpenParams), 0, 100};
    uint64_t nextGeneration = 1;
    if (testCancellation) {
        if (engine->queueReader(nextGeneration++, cancelledReader, nextParams) != LazerAudioOk ||
            engine->clearQueuedReader(nextGeneration++) != LazerAudioOk ||
            engine->queueReader(1, cancelledReader, nextParams) != LazerAudioErrorState) {
            std::cerr << "queued-reader cancel/generation check failed\n";
            engine->destroy();
            return false;
        }
    }
    const int32_t queueResult = engine->queueReader(nextGeneration, secondReader, nextParams);
    const int32_t playResult = queueResult == LazerAudioOk ? engine->play() : LazerAudioErrorState;
    if (queueResult != LazerAudioOk || playResult != LazerAudioOk) {
        std::cerr << "queue/play failed queue=" << queueResult << " play=" << playResult
            << " error=" << engine->lastError() << "\n";
        engine->destroy();
        return false;
    }

    bool ended = false;
    {
        std::unique_lock guard(events.mutex);
        ended = events.changed.wait_for(guard, std::chrono::seconds(5), [&] {
            return std::find(events.events.begin(), events.events.end(), LazerAudioEventEnded) !=
                events.events.end();
        });
    }
    engine->destroy();
    if (!ended) {
        std::cerr << "timed out waiting for Ended event\n";
        return false;
    }

    std::vector<uint8_t> expected(first.bytes.begin() + 44, first.bytes.end());
    expected.insert(expected.end(), second.bytes.begin() + 44, second.bytes.end());
    int32_t trackChanges = 0;
    int32_t ends = 0;
    {
        std::lock_guard guard(events.mutex);
        for (const int32_t event : events.events) {
            if (event == LazerAudioEventTrackChanged) ++trackChanges;
            if (event == LazerAudioEventEnded) ++ends;
        }
    }
    {
        std::lock_guard guard(capture->mutex);
        if (capture->openCount != 1 || capture->startCount != 1 || capture->closeCount != 1) {
            std::cerr << "capture lifecycle open/start/close=" << capture->openCount << "/"
                << capture->startCount << "/" << capture->closeCount << "\n";
            return false;
        }
        if (capture->bytes != expected) {
            const size_t common = std::min(capture->bytes.size(), expected.size());
            size_t mismatch = 0;
            while (mismatch < common && capture->bytes[mismatch] == expected[mismatch]) ++mismatch;
            std::cerr << "capture bytes expected/actual=" << expected.size() << "/"
                << capture->bytes.size() << " firstMismatch=" << mismatch;
            if (mismatch < common) {
                std::cerr << " expectedByte=" << static_cast<int>(expected[mismatch])
                    << " actualByte=" << static_cast<int>(capture->bytes[mismatch]);
            }
            std::cerr << "\n";
            return false;
        }
    }
    if (trackChanges != 1 || ends != 1 || first.closeCount.load() != 1 ||
        second.closeCount.load() != 1 ||
        (testCancellation && cancelled.closeCount.load() != 1)) {
        std::cerr << "events trackChanges/ended=" << trackChanges << "/" << ends
            << " reader close first/second/cancelled=" << first.closeCount.load() << "/"
            << second.closeCount.load() << "/" << cancelled.closeCount.load() << "\n";
        return false;
    }
    return true;
}

bool waitForWrites(const std::shared_ptr<Capture> &capture, int32_t count,
    std::chrono::milliseconds timeout) {
    std::unique_lock guard(capture->mutex);
    return capture->changed.wait_for(guard, timeout, [&] { return capture->writeCount >= count; });
}

void releaseCaptureGate(const std::shared_ptr<Capture> &capture) {
    {
        std::lock_guard guard(capture->mutex);
        capture->gateReleased = true;
    }
    capture->changed.notify_all();
}

bool waitForCaptureGate(const std::shared_ptr<Capture> &capture,
    std::chrono::milliseconds timeout) {
    std::unique_lock guard(capture->mutex);
    return capture->changed.wait_for(guard, timeout, [&] { return capture->gateWaiting; });
}

bool waitForEvent(ProbeEvents &events, int32_t event, std::chrono::milliseconds timeout) {
    std::unique_lock guard(events.mutex);
    return events.changed.wait_for(guard, timeout, [&] {
        return std::find(events.events.begin(), events.events.end(), event) != events.events.end();
    });
}

bool waitForEventCount(ProbeEvents &events, int32_t event, size_t count,
    std::chrono::milliseconds timeout) {
    std::unique_lock guard(events.mutex);
    return events.changed.wait_for(guard, timeout, [&] {
        return static_cast<size_t>(std::count(events.events.begin(), events.events.end(), event)) >= count;
    });
}

bool runPcmFormatReopenCase() {
    constexpr int32_t firstRate = 44'100;
    constexpr int32_t firstDepth = 16;
    constexpr int32_t nextRate = 96'000;
    constexpr int32_t nextDepth = 24;
    constexpr int32_t reopenFrames = kPeriodFrames;
    /* Queueability is only expected while the active source has not reached EOF. Keep the first
     * source beyond the engine's power-of-two input ring so a fast decoder cannot finish it before
     * this cross-rate compatibility check. */
    const int32_t firstFrames = ((firstTrackFramesForRate(firstRate) + kPeriodFrames - 1) /
        kPeriodFrames) * kPeriodFrames;
    MemoryReader first(makePcmWave(firstFrames, firstRate, firstDepth, 5'000));
    MemoryReader incompatible(makePcmWave(reopenFrames, nextRate, nextDepth, 2'000));
    MemoryReader second(makePcmWave(reopenFrames, nextRate, nextDepth, -4'000));
    LazerAudioReader firstReader = asReader(first);
    LazerAudioReader incompatibleReader = asReader(incompatible);
    LazerAudioReader secondReader = asReader(second);
    ProbeEvents events;
    auto capture = std::make_shared<Capture>();
    events.capture = capture.get();

    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.exclusive = 1;
    config.device.bit_perfect = 1;
    config.device.buffer_millis = 60;
    config.events.on_event = onEvent;
    config.events.context = &events;
    config.log.on_log = onLog;

    Engine *engine = Engine::create(config, std::make_unique<CaptureOutput>(capture));
    if (engine == nullptr) {
        std::cerr << "Engine::create failed for PCM format reopen probe\n";
        return false;
    }
    events.engine = engine;
    const LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 100};
    if (engine->open(nullptr, &firstReader, params) != LazerAudioOk) {
        std::cerr << "could not open first PCM format: " << engine->lastError() << "\n";
        engine->destroy();
        return false;
    }
    const int32_t incompatibleQueue = engine->queueReader(1, incompatibleReader, params);
    if (incompatibleQueue != LazerAudioErrorUnsupported) {
        std::cerr << "cross-rate PCM successor queue result=" << incompatibleQueue
            << " expected=" << LazerAudioErrorUnsupported << "\n";
        engine->destroy();
        return false;
    }
    if (engine->play() != LazerAudioOk ||
        !waitForEventCount(events, LazerAudioEventEnded, 1, std::chrono::seconds(5))) {
        std::cerr << "first PCM track did not finish before format reopen\n";
        engine->destroy();
        return false;
    }
    if (engine->stop() != LazerAudioOk) {
        std::cerr << "could not retire first PCM output session\n";
        engine->destroy();
        return false;
    }
    if (engine->open(nullptr, &secondReader, params) != LazerAudioOk) {
        std::cerr << "could not reopen second PCM format: " << engine->lastError() << "\n";
        engine->destroy();
        return false;
    }
    LazerAudioStreamInfo secondInfo{};
    engine->streamInfo(secondInfo);
    if (secondInfo.source_sample_rate != nextRate || secondInfo.output_sample_rate != nextRate ||
        secondInfo.source_bits_per_sample != nextDepth || secondInfo.output_bits_per_sample != nextDepth ||
        secondInfo.output_container_bits_per_sample != nextDepth) {
        std::cerr << "reopened PCM stream info source/output rate/depth="
            << secondInfo.source_sample_rate << "/" << secondInfo.output_sample_rate << "/"
            << secondInfo.source_bits_per_sample << "/" << secondInfo.output_bits_per_sample << "/"
            << secondInfo.output_container_bits_per_sample << "\n";
        engine->destroy();
        return false;
    }
    if (engine->play() != LazerAudioOk ||
        !waitForEventCount(events, LazerAudioEventEnded, 2, std::chrono::seconds(5))) {
        std::cerr << "second PCM track did not finish after format reopen\n";
        engine->destroy();
        return false;
    }
    engine->destroy();

    const std::vector<uint8_t> expectedFirst(first.bytes.begin() + 44, first.bytes.end());
    const std::vector<uint8_t> expectedSecond(second.bytes.begin() + 44, second.bytes.end());
    bool sessionChecks = false;
    int32_t trackChanges = 0;
    int32_t endedEvents = 0;
    {
        std::lock_guard guard(capture->mutex);
        sessionChecks = capture->openCount == 2 && capture->startCount == 2 &&
            capture->closeCount == 2 && capture->openWhileAlreadyOpenCount == 0 &&
            capture->sessions.size() == 2 &&
            capture->sessions[0].target.sampleRate == firstRate &&
            capture->sessions[0].target.bitsPerSample == firstDepth &&
            capture->sessions[0].target.containerBitsPerSample == firstDepth &&
            capture->sessions[0].request.desired.sampleRate == firstRate &&
            capture->sessions[0].bytes == expectedFirst &&
            capture->sessions[1].target.sampleRate == nextRate &&
            capture->sessions[1].target.bitsPerSample == nextDepth &&
            capture->sessions[1].target.containerBitsPerSample == nextDepth &&
            capture->sessions[1].request.desired.sampleRate == nextRate &&
            capture->sessions[1].bytes == expectedSecond;
    }
    {
        std::lock_guard guard(events.mutex);
        trackChanges = static_cast<int32_t>(std::count(
            events.events.begin(), events.events.end(), LazerAudioEventTrackChanged));
        endedEvents = static_cast<int32_t>(std::count(
            events.events.begin(), events.events.end(), LazerAudioEventEnded));
    }
    if (!sessionChecks || trackChanges != 0 || endedEvents != 2 ||
        first.closeCount.load() != 1 || incompatible.closeCount.load() != 1 ||
        second.closeCount.load() != 1) {
        std::cerr << "PCM format reopen checks sessions=" << sessionChecks
            << " trackChanges/ended=" << trackChanges << "/" << endedEvents
            << " reader closes=" << first.closeCount.load() << "/"
            << incompatible.closeCount.load() << "/" << second.closeCount.load() << "\n";
        return false;
    }
    std::cout << "PASS: cross-rate/depth PCM is rejected from gapless queue and reopened with the next exact output tuple\n";
    return true;
}

bool runPresentationBoundaryCase() {
    gTraceBoundary.store(true, std::memory_order_release);
    constexpr int32_t sampleRate = 44'100;
    constexpr int32_t firstFrames = 6'144;  // Larger than the fake engine's 4,096-frame ring.
    constexpr int32_t secondFrames = 1'024;
    MemoryReader first(makePcmWave(firstFrames, sampleRate, 16, 1'000));
    MemoryReader second(makePcmWave(secondFrames, sampleRate, 24, -2'000));
    LazerAudioReader firstReader = asReader(first);
    LazerAudioReader secondReader = asReader(second);
    ProbeEvents events;
    auto capture = std::make_shared<Capture>();

    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.exclusive = 0;
    config.device.bit_perfect = 0;
    config.device.buffer_millis = 60;
    config.events.on_event = onEvent;
    config.events.context = &events;
    config.log.on_log = onLog;

    Engine *engine = Engine::create(config, std::make_unique<CaptureOutput>(capture, true, 4));
    if (engine == nullptr) return false;
    events.engine = engine;
    const auto fail = [&](const char *message) {
        releaseCaptureGate(capture);
        engine->destroy();
        std::cerr << "FAIL: presentation-boundary case: " << message << "\n";
        return false;
    };

    const LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 100};
    const int32_t openResult = engine->open(nullptr, &firstReader, params);
    if (openResult != LazerAudioOk) return fail("could not open first source");
    if (engine->queueReader(1, secondReader, params) != LazerAudioOk) {
        return fail("could not prepare a same-rate successor");
    }
    if (engine->play() != LazerAudioOk) return fail("could not start fake output");
    if (!waitForWrites(capture, 4, std::chrono::seconds(5))) {
        return fail("fake output did not reach its gate");
    }

    const auto transitionDeadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (first.closeCount.load(std::memory_order_acquire) == 0 &&
        std::chrono::steady_clock::now() < transitionDeadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    if (first.closeCount.load(std::memory_order_acquire) != 1) {
        return fail("decoder did not activate the prepared successor");
    }

    LazerAudioSnapshot beforeBoundary{};
    LazerAudioStreamInfo streamBeforeBoundary{};
    engine->snapshot(beforeBoundary);
    engine->streamInfo(streamBeforeBoundary);
    bool changedBeforeBoundary = false;
    {
        std::lock_guard guard(events.mutex);
        changedBeforeBoundary = std::find(events.events.begin(), events.events.end(),
            LazerAudioEventTrackChanged) != events.events.end();
    }
    if (changedBeforeBoundary) return fail("TrackChanged fired before the output crossed the seam");
    if (beforeBoundary.duration_millis < 120 || beforeBoundary.duration_millis > 160 ||
        beforeBoundary.position_millis <= 0 || beforeBoundary.position_millis >= 120 ||
        streamBeforeBoundary.source_bits_per_sample != 16) {
        return fail("snapshot or stream info exposed successor metadata before its seam");
    }

    if (engine->seek(5) != LazerAudioOk) return fail("seek to activated successor was rejected");
    std::this_thread::sleep_for(std::chrono::milliseconds(50));

    LazerAudioSnapshot afterSeekBeforeBoundary{};
    LazerAudioStreamInfo streamAfterSeekBeforeBoundary{};
    engine->snapshot(afterSeekBeforeBoundary);
    engine->streamInfo(streamAfterSeekBeforeBoundary);
    bool changedBeforeSeekBoundary = false;
    {
        std::lock_guard guard(events.mutex);
        changedBeforeSeekBoundary = std::find(events.events.begin(), events.events.end(),
            LazerAudioEventTrackChanged) != events.events.end();
    }
    if (changedBeforeSeekBoundary || afterSeekBeforeBoundary.duration_millis < 120 ||
        afterSeekBeforeBoundary.duration_millis > 160 ||
        streamAfterSeekBeforeBoundary.source_bits_per_sample != 16) {
        return fail("successor presentation changed before post-seek output crossed its seam");
    }

    releaseCaptureGate(capture);
    if (!waitForEvent(events, LazerAudioEventTrackChanged, std::chrono::seconds(5))) {
        LazerAudioSnapshot failedSnapshot{};
        LazerAudioStreamInfo failedStream{};
        engine->snapshot(failedSnapshot);
        engine->streamInfo(failedStream);
        std::cerr << "DEBUG: post-seek state=" << failedSnapshot.state
            << " duration=" << failedSnapshot.duration_millis
            << " position=" << failedSnapshot.position_millis
            << " source-bits=" << failedStream.source_bits_per_sample
            << " second-closed=" << second.closeCount.load()
            << " writes=" << capture->writeCount
            << " error=" << engine->lastError() << "\n";
        return fail("TrackChanged was lost after seeking the activated successor");
    }
    bool callbackSnapshotMatches = false;
    {
        std::lock_guard guard(events.mutex);
        callbackSnapshotMatches = events.callbackSnapshotRead && events.callbackSourceBits == 24 &&
            events.callbackDurationMillis >= 20 && events.callbackDurationMillis <= 30 &&
            events.callbackPositionMillis >= 8 && events.callbackPositionMillis <= 24;
    }
    if (!callbackSnapshotMatches) {
        std::cerr << "DEBUG: callback snapshot read=" << events.callbackSnapshotRead
            << " source-bits=" << events.callbackSourceBits
            << " duration=" << events.callbackDurationMillis
            << " position=" << events.callbackPositionMillis << "\n";
        return fail("reentrant boundary callback did not observe the successor snapshot");
    }

    if (!waitForEvent(events, LazerAudioEventEnded, std::chrono::seconds(5))) {
        return fail("playback did not finish after the successor");
    }
    engine->destroy();
    int32_t trackChanges = 0;
    int32_t ends = 0;
    {
        std::lock_guard guard(events.mutex);
        for (const int32_t event : events.events) {
            if (event == LazerAudioEventTrackChanged) ++trackChanges;
            if (event == LazerAudioEventEnded) ++ends;
        }
    }
    if (trackChanges != 1 || ends != 1 || first.closeCount.load() != 1 ||
        second.closeCount.load() != 1) {
        std::cerr << "FAIL: presentation-boundary event/reader lifecycle mismatch\n";
        return false;
    }
    std::cout << "PASS: seek after successor activation targets that source and publishes its boundary after output\n";
    return true;
}

std::vector<uint8_t> makeRampPcmWave(int32_t frames, int32_t sampleRate,
    int64_t sourceFrameOffset = 0) {
    const int32_t frameBytes = kChannels * 2;
    const uint32_t dataBytes = static_cast<uint32_t>(frames * frameBytes);
    std::vector<uint8_t> bytes;
    bytes.reserve(44 + dataBytes);
    bytes.insert(bytes.end(), {'R', 'I', 'F', 'F'});
    append32(bytes, 36u + dataBytes);
    bytes.insert(bytes.end(), {'W', 'A', 'V', 'E', 'f', 'm', 't', ' '});
    append32(bytes, 16);
    append16(bytes, 1);
    append16(bytes, kChannels);
    append32(bytes, static_cast<uint32_t>(sampleRate));
    append32(bytes, static_cast<uint32_t>(sampleRate * frameBytes));
    append16(bytes, static_cast<uint16_t>(frameBytes));
    append16(bytes, 16);
    bytes.insert(bytes.end(), {'d', 'a', 't', 'a'});
    append32(bytes, dataBytes);
    for (int32_t frame = 0; frame < frames; ++frame) {
        const int32_t marker = static_cast<int32_t>((sourceFrameOffset + frame) % 60'000) - 30'000;
        appendSample(bytes, marker, 2);
        appendSample(bytes, -marker, 2);
    }
    return bytes;
}

std::vector<uint8_t> makeRampFlac(int32_t frames, int32_t sampleRate) {
    AVFormatContext *format = nullptr;
    AVCodecContext *encoderContext = nullptr;
    AVFrame *frame = nullptr;
    AVPacket *packet = nullptr;
    uint8_t *encodedBytes = nullptr;
    int encodedSize = 0;
    int32_t blockFrames = 4'608;
    int32_t position = 0;
    bool success = false;
    const AVCodec *encoder = avcodec_find_encoder(AV_CODEC_ID_FLAC);
    AVStream *stream = nullptr;
    if (encoder == nullptr) return {};
    if (avformat_alloc_output_context2(&format, nullptr, "flac", nullptr) < 0 ||
        format == nullptr) {
        avformat_free_context(format);
        return {};
    }
    encoderContext = avcodec_alloc_context3(encoder);
    if (encoderContext == nullptr) goto cleanup;
    encoderContext->sample_rate = sampleRate;
    encoderContext->sample_fmt = AV_SAMPLE_FMT_S16;
    encoderContext->bits_per_raw_sample = 16;
    encoderContext->time_base = AVRational{1, sampleRate};
    av_channel_layout_default(&encoderContext->ch_layout, kChannels);
    if ((format->oformat->flags & AVFMT_GLOBALHEADER) != 0) {
        encoderContext->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    }
    if (avcodec_open2(encoderContext, encoder, nullptr) < 0) goto cleanup;
    stream = avformat_new_stream(format, nullptr);
    if (stream == nullptr) goto cleanup;
    stream->time_base = encoderContext->time_base;
    if (avcodec_parameters_from_context(stream->codecpar, encoderContext) < 0) goto cleanup;
    if (avio_open_dyn_buf(&format->pb) < 0) goto cleanup;
    if (avformat_write_header(format, nullptr) < 0) goto cleanup;
    frame = av_frame_alloc();
    packet = av_packet_alloc();
    if (frame == nullptr || packet == nullptr) goto cleanup;
    blockFrames = encoderContext->frame_size > 0 ? encoderContext->frame_size : 4'608;
    while (position < frames) {
        av_frame_unref(frame);
        frame->format = encoderContext->sample_fmt;
        frame->sample_rate = sampleRate;
        if (av_channel_layout_copy(&frame->ch_layout, &encoderContext->ch_layout) < 0) goto cleanup;
        frame->nb_samples = std::min(blockFrames, frames - position);
        frame->pts = position;
        if (av_frame_get_buffer(frame, 0) < 0 || av_frame_make_writable(frame) < 0) goto cleanup;
        auto *samples = reinterpret_cast<int16_t *>(frame->data[0]);
        for (int32_t index = 0; index < frame->nb_samples; ++index) {
            const int32_t marker = (position + index) % 60'000 - 30'000;
            samples[index * kChannels] = static_cast<int16_t>(marker);
            samples[index * kChannels + 1] = static_cast<int16_t>(-marker);
        }
        if (avcodec_send_frame(encoderContext, frame) < 0) goto cleanup;
        for (;;) {
            const int result = avcodec_receive_packet(encoderContext, packet);
            if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) break;
            if (result < 0) goto cleanup;
            packet->stream_index = stream->index;
            av_packet_rescale_ts(packet, encoderContext->time_base, stream->time_base);
            const int writeResult = av_interleaved_write_frame(format, packet);
            av_packet_unref(packet);
            if (writeResult < 0) goto cleanup;
        }
        position += frame->nb_samples;
    }
    if (avcodec_send_frame(encoderContext, nullptr) < 0) goto cleanup;
    for (;;) {
        const int result = avcodec_receive_packet(encoderContext, packet);
        if (result == AVERROR_EOF || result == AVERROR(EAGAIN)) break;
        if (result < 0) goto cleanup;
        packet->stream_index = stream->index;
        av_packet_rescale_ts(packet, encoderContext->time_base, stream->time_base);
        const int writeResult = av_interleaved_write_frame(format, packet);
        av_packet_unref(packet);
        if (writeResult < 0) goto cleanup;
    }
    if (av_write_trailer(format) < 0) goto cleanup;
    encodedSize = avio_close_dyn_buf(format->pb, &encodedBytes);
    format->pb = nullptr;
    success = encodedSize > 0 && encodedBytes != nullptr;

cleanup:
    if (format != nullptr && format->pb != nullptr) {
        encodedSize = avio_close_dyn_buf(format->pb, &encodedBytes);
        format->pb = nullptr;
    }
    av_packet_free(&packet);
    av_frame_free(&frame);
    avcodec_free_context(&encoderContext);
    avformat_free_context(format);
    if (!success) {
        if (encodedBytes != nullptr) av_free(encodedBytes);
        return {};
    }
    std::vector<uint8_t> result(encodedBytes, encodedBytes + encodedSize);
    av_free(encodedBytes);
    return result;
}

void appendWaveFrames(std::vector<uint8_t> &destination, const std::vector<uint8_t> &wave,
    int64_t firstFrame, int64_t frameCount) {
    const size_t firstByte = 44 + static_cast<size_t>(firstFrame) * kChannels * 2;
    const size_t byteCount = static_cast<size_t>(frameCount) * kChannels * 2;
    destination.insert(destination.end(), wave.begin() + static_cast<std::ptrdiff_t>(firstByte),
        wave.begin() + static_cast<std::ptrdiff_t>(firstByte + byteCount));
}

bool runCueSegmentCase(int64_t cueEndFrame75, bool useFlac = false) {
    constexpr int32_t sampleRate = 48'000;
    constexpr int32_t physicalFrames = 32'768;
    constexpr int64_t cueStartFrame75 = 7;
    constexpr int64_t seekMillis = 200;
    constexpr int32_t capturedBeforeSeekFrames = 2 * kPeriodFrames;
    constexpr int64_t samplesPerCueFrame = sampleRate / 75;
    constexpr int64_t segmentStart = cueStartFrame75 * samplesPerCueFrame;
    const int64_t segmentEnd = cueEndFrame75 == -1
        ? physicalFrames : cueEndFrame75 * samplesPerCueFrame;
    const int64_t expectedDurationMillis =
        (segmentEnd - segmentStart) * 1000 / sampleRate;
    constexpr int64_t seekOffset = sampleRate * seekMillis / 1000;
    const std::vector<uint8_t> pcmWave = makeRampPcmWave(physicalFrames, sampleRate);
    const std::vector<uint8_t> sourceBytes = useFlac
        ? makeRampFlac(physicalFrames, sampleRate) : pcmWave;
    if (sourceBytes.empty()) {
        std::cerr << "FAIL: could not encode the in-memory FLAC fixture\n";
        return false;
    }
    MemoryReader source(sourceBytes);
    LazerAudioReader reader = asReader(source);
    ProbeEvents events;
    auto capture = std::make_shared<Capture>();

    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.exclusive = 1;
    config.device.bit_perfect = 1;
    config.device.buffer_millis = 60;
    config.events.on_event = onEvent;
    config.events.context = &events;
    config.log.on_log = onLog;

    Engine *engine = Engine::create(config,
        std::make_unique<CaptureOutput>(capture, false, 2));
    if (engine == nullptr) return false;
    events.engine = engine;
    const auto fail = [&](const char *message) {
        releaseCaptureGate(capture);
        LazerAudioSnapshot snapshot{};
        engine->snapshot(snapshot);
        std::cerr << "CUE diagnostics state/position/duration=" << snapshot.state << "/"
            << snapshot.position_millis << "/" << snapshot.duration_millis
            << " writes=" << capture->writeCount << " error=" << engine->lastError() << "\n";
        engine->destroy();
        std::cerr << "FAIL: CUE segment case: " << message << "\n";
        return false;
    };

    const LazerAudioOpenParams params{
        sizeof(LazerAudioOpenParams), 0, physicalFrames * 1000LL / sampleRate,
        cueStartFrame75, cueEndFrame75};
    const int32_t openResult = engine->open(nullptr, &reader, params);
    if (openResult != LazerAudioOk) {
        std::cerr << "CUE open code=" << openResult << " error=" << engine->lastError() << "\n";
        return fail("could not open a bounded WAV segment");
    }
    if (engine->play() != LazerAudioOk) return fail("could not start fake output");
    if (!waitForWrites(capture, 2, std::chrono::seconds(5)) ||
        !waitForCaptureGate(capture, std::chrono::seconds(5))) {
        return fail("fake output did not stop after the expected initial periods");
    }

    LazerAudioSnapshot beforeSeek{};
    engine->snapshot(beforeSeek);
    if (beforeSeek.duration_millis != expectedDurationMillis || beforeSeek.position_millis < 0 ||
        beforeSeek.position_millis >= 60) {
        std::cerr << "CUE pre-seek duration/position=" << beforeSeek.duration_millis << "/"
            << beforeSeek.position_millis << "\n";
        return fail("snapshot did not expose segment-relative duration and progress");
    }
    if (engine->seek(seekMillis) != LazerAudioOk) return fail("relative segment seek was rejected");
    const auto seekDeadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    LazerAudioSnapshot afterSeek{};
    do {
        engine->snapshot(afterSeek);
        if (afterSeek.position_millis >= seekMillis) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    } while (std::chrono::steady_clock::now() < seekDeadline);
    if (afterSeek.position_millis < seekMillis ||
        afterSeek.duration_millis != expectedDurationMillis) {
        std::cerr << "CUE post-seek duration/position=" << afterSeek.duration_millis << "/"
            << afterSeek.position_millis << "\n";
        return fail("seek target was not relative to the CUE segment");
    }
    releaseCaptureGate(capture);
    if (!waitForEvent(events, LazerAudioEventEnded, std::chrono::seconds(5))) {
        return fail("segment did not reach a clean Ended event");
    }

    std::vector<uint8_t> expected;
    appendWaveFrames(expected, pcmWave, segmentStart, capturedBeforeSeekFrames);
    appendWaveFrames(expected, pcmWave, segmentStart + seekOffset,
        segmentEnd - segmentStart - seekOffset);
    const int64_t capturedFrames = static_cast<int64_t>(expected.size() / (kChannels * 2));
    const int64_t paddedFrames = ((capturedFrames + kPeriodFrames - 1) / kPeriodFrames) * kPeriodFrames;
    expected.resize(static_cast<size_t>(paddedFrames) * kChannels * 2, 0);

    int32_t endedCount = 0;
    int32_t trackChangedCount = 0;
    {
        std::lock_guard guard(events.mutex);
        for (const int32_t event : events.events) {
            if (event == LazerAudioEventEnded) ++endedCount;
            if (event == LazerAudioEventTrackChanged) ++trackChangedCount;
        }
    }
    std::vector<uint8_t> actual;
    {
        std::lock_guard guard(capture->mutex);
        actual = capture->bytes;
    }
    engine->destroy();
    if (actual != expected || endedCount != 1 || trackChangedCount != 0 ||
        source.closeCount.load() != 1) {
        size_t mismatch = 0;
        while (mismatch < actual.size() && mismatch < expected.size() &&
            actual[mismatch] == expected[mismatch]) ++mismatch;
        std::cerr << "CUE capture expected/actual=" << expected.size() << "/" << actual.size()
            << " firstMismatch=" << mismatch << " Ended/TrackChanged=" << endedCount << "/"
            << trackChangedCount << " sourceClosed=" << source.closeCount.load();
        if (mismatch < actual.size() && mismatch < expected.size()) {
            std::cerr << " expectedByte=" << static_cast<int>(expected[mismatch])
                << " actualByte=" << static_cast<int>(actual[mismatch]);
        }
        if (actual.size() >= 4 && expected.size() >= 4) {
            std::cerr << " firstExpected=" << static_cast<int>(expected[0]) << ","
                << static_cast<int>(expected[1]) << "," << static_cast<int>(expected[2]) << ","
                << static_cast<int>(expected[3]) << " firstActual="
                << static_cast<int>(actual[0]) << "," << static_cast<int>(actual[1]) << ","
                << static_cast<int>(actual[2]) << "," << static_cast<int>(actual[3]);
        }
        std::cerr << "\n";
        return false;
    }
    std::cout << "PASS: " << (useFlac ? "FLAC" : "WAV") << " CUE segment end=" << cueEndFrame75
        << " clips exact ramp samples, reports relative seek/progress, and drains once\n";
    return true;
}

bool runCueGaplessCase() {
    constexpr int32_t sampleRate = 48'000;
    constexpr int64_t cueFramesPerSecond = 75;
    constexpr int64_t samplesPerCueFrame = sampleRate / cueFramesPerSecond;
    constexpr int64_t firstCueEndFrame75 = 7;
    constexpr int64_t successorCueStartFrame75 = firstCueEndFrame75;
    constexpr int64_t physicalCueEndFrame75 = 72;
    constexpr int64_t physicalFrames = physicalCueEndFrame75 * samplesPerCueFrame;
    constexpr int64_t firstSegmentFrames = firstCueEndFrame75 * samplesPerCueFrame;
    constexpr int64_t successorFrames =
        (physicalCueEndFrame75 - successorCueStartFrame75) * samplesPerCueFrame;
    constexpr int64_t sourceDurationMillis = physicalFrames * 1000 / sampleRate;
    constexpr int64_t successorDurationMillis =
        (successorFrames * 1000 + sampleRate / 2) / sampleRate;

    /* The first segment exceeds the engine's 4,096-frame ring and the seam is not a 512-frame
     * output-period boundary. The complete source is exactly 90 periods, so the capture needs no
     * end padding and can be compared byte-for-byte with the underlying WAV samples. */
    const std::vector<uint8_t> wave = makeRampPcmWave(static_cast<int32_t>(physicalFrames), sampleRate);
    MemoryReader first(wave);
    MemoryReader successor(wave);
    const LazerAudioReader firstReader = asReader(first);
    const LazerAudioReader successorReader = asReader(successor);
    ProbeEvents events;
    auto capture = std::make_shared<Capture>();
    events.capture = capture.get();

    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.exclusive = 1;
    config.device.bit_perfect = 1;
    config.device.buffer_millis = 60;
    config.events.on_event = onEvent;
    config.events.context = &events;
    config.log.on_log = onLog;

    Engine *engine = Engine::create(config, std::make_unique<CaptureOutput>(capture));
    if (engine == nullptr) {
        std::cerr << "FAIL: CUE gapless engine creation failed\n";
        return false;
    }
    events.engine = engine;
    const auto fail = [&](const char *message) {
        engine->destroy();
        std::cerr << "FAIL: CUE gapless case: " << message << "\n";
        return false;
    };

    const LazerAudioOpenParams firstParams{
        sizeof(LazerAudioOpenParams), 0, sourceDurationMillis, 0, firstCueEndFrame75};
    if (engine->open(nullptr, &firstReader, firstParams) != LazerAudioOk) {
        std::cerr << "CUE first-segment open error=" << engine->lastError() << "\n";
        return fail("could not open the first adjacent WAV CUE segment");
    }

    const LazerAudioOpenParams successorParams{
        sizeof(LazerAudioOpenParams), 0, sourceDurationMillis,
        successorCueStartFrame75, physicalCueEndFrame75};
    if (engine->queueReader(1, successorReader, successorParams) != LazerAudioOk) {
        std::cerr << "CUE successor queue error=" << engine->lastError() << "\n";
        return fail("could not prepare the adjacent WAV CUE successor");
    }
    if (engine->play() != LazerAudioOk) return fail("could not start fake output");
    if (!waitForEvent(events, LazerAudioEventEnded, std::chrono::seconds(5))) {
        std::cerr << "CUE gapless end error=" << engine->lastError() << "\n";
        return fail("timed out before the successor reached clean EOF");
    }

    std::vector<uint8_t> expected;
    appendWaveFrames(expected, wave, 0, firstSegmentFrames);
    appendWaveFrames(expected, wave, successorCueStartFrame75 * samplesPerCueFrame,
        successorFrames);

    int32_t trackChanges = 0;
    int32_t ends = 0;
    bool successorSnapshotRead = false;
    int64_t callbackDurationMillis = 0;
    int32_t callbackSourceBits = 0;
    std::vector<int32_t> observedEvents;
    std::vector<int64_t> eventPositions;
    std::vector<int64_t> framesAtEvents;
    {
        std::lock_guard guard(events.mutex);
        for (const int32_t event : events.events) {
            if (event == LazerAudioEventTrackChanged) ++trackChanges;
            if (event == LazerAudioEventEnded) ++ends;
        }
        observedEvents = events.events;
        eventPositions = events.eventPositionsMillis;
        framesAtEvents = events.capturedFramesAtEvent;
        successorSnapshotRead = events.callbackSnapshotRead;
        callbackDurationMillis = events.callbackDurationMillis;
        callbackSourceBits = events.callbackSourceBits;
    }

    std::vector<uint8_t> actual;
    {
        std::lock_guard guard(capture->mutex);
        actual = capture->bytes;
    }
    engine->destroy();

    if (actual != expected) {
        size_t mismatch = 0;
        while (mismatch < actual.size() && mismatch < expected.size() &&
            actual[mismatch] == expected[mismatch]) ++mismatch;
        const auto sampleAt = [](const std::vector<uint8_t> &bytes, int64_t frame,
            int32_t channel) -> int32_t {
            const size_t offset = static_cast<size_t>(frame) * kChannels * 2 + channel * 2;
            if (offset + 1 >= bytes.size()) return std::numeric_limits<int32_t>::min();
            const uint16_t raw = static_cast<uint16_t>(bytes[offset]) |
                (static_cast<uint16_t>(bytes[offset + 1]) << 8);
            return static_cast<int16_t>(raw);
        };
        const auto describeFrame = [&](const char *label, const std::vector<uint8_t> &bytes,
            int64_t frame) {
            const int32_t left = sampleAt(bytes, frame, 0);
            const int32_t right = sampleAt(bytes, frame, 1);
            std::cerr << "\n  " << label << " frame=" << frame << " samples=" << left << ","
                << right << " rampSourceFrame=" << (left == std::numeric_limits<int32_t>::min()
                    ? -1 : left + 30'000);
        };
        std::cerr << "CUE gapless capture expected/actual bytes=" << expected.size() << "/"
            << actual.size() << " frames=" << expected.size() / (kChannels * 2) << "/"
            << actual.size() / (kChannels * 2) << " firstMismatchByte=" << mismatch
            << " firstMismatchFrame=" << mismatch / (kChannels * 2)
            << " requestedSourceDurationMs=" << sourceDurationMillis
            << " segments=" << firstSegmentFrames << "+" << successorFrames
            << " successorDurationMs=" << successorDurationMillis << "\n";
        for (size_t index = 0; index < observedEvents.size(); ++index) {
            const int32_t event = observedEvents[index];
            const char *name = event == LazerAudioEventReady ? "Ready" :
                event == LazerAudioEventEnded ? "Ended" :
                event == LazerAudioEventFailed ? "Failed" :
                event == LazerAudioEventTrackChanged ? "TrackChanged" :
                event == LazerAudioEventSeekCompleted ? "SeekCompleted" :
                event == LazerAudioEventDeviceLost ? "DeviceLost" :
                event == LazerAudioEventBufferProgress ? "BufferProgress" : "Unknown";
            std::cerr << "  event[" << index << "]=" << name
                << " positionMs=" << (index < eventPositions.size() ? eventPositions[index] : -1)
                << " capturedFrames=" << (index < framesAtEvents.size() ? framesAtEvents[index] : -1)
                << "\n";
        }
        const int64_t mismatchFrame = static_cast<int64_t>(mismatch / (kChannels * 2));
        for (int64_t frame = std::max<int64_t>(0, mismatchFrame - 2);
            frame < std::min<int64_t>(static_cast<int64_t>(expected.size() / (kChannels * 2)),
                mismatchFrame + 4); ++frame) {
            describeFrame("expected", expected, frame);
            describeFrame("actual", actual, frame);
            std::cerr << "\n";
        }
        const int64_t seamFrame = firstSegmentFrames;
        std::cerr << "  seam expected output frame=" << seamFrame << "\n";
        for (int64_t frame = std::max<int64_t>(0, seamFrame - 3);
            frame < std::min<int64_t>(static_cast<int64_t>(actual.size() / (kChannels * 2)),
                seamFrame + 5); ++frame) {
            describeFrame("expected", expected, frame);
            describeFrame("actual", actual, frame);
            std::cerr << "\n";
        }
        int32_t discontinuities = 0;
        int32_t repeatedFrames = 0;
        for (int64_t frame = 1; frame < static_cast<int64_t>(actual.size() / (kChannels * 2)); ++frame) {
            const int32_t previous = sampleAt(actual, frame - 1, 0) + 30'000;
            const int32_t current = sampleAt(actual, frame, 0) + 30'000;
            if (current != previous + 1) {
                if (discontinuities < 12) {
                    std::cerr << "  actual source boundary at output frame=" << frame
                        << " previousSourceFrame=" << previous << " currentSourceFrame=" << current
                        << "\n";
                }
                ++discontinuities;
                if (current == previous) ++repeatedFrames;
            }
        }
        std::cerr << "  ramp discontinuities=" << discontinuities
            << " repeated-frame boundaries=" << repeatedFrames << "\n";
        return false;
    }
    {
        std::lock_guard guard(capture->mutex);
        if (capture->openCount != 1 || capture->startCount != 1 || capture->closeCount != 1) {
            std::cerr << "CUE gapless output lifecycle open/start/close=" << capture->openCount
                << "/" << capture->startCount << "/" << capture->closeCount << "\n";
            return false;
        }
    }
    if (trackChanges != 1 || ends != 1 || !successorSnapshotRead ||
        callbackDurationMillis != successorDurationMillis || callbackSourceBits != 16 ||
        first.closeCount.load() != 1 || successor.closeCount.load() != 1) {
        std::cerr << "CUE gapless events/duration/reader-close=" << trackChanges << "/" << ends
            << "/" << callbackDurationMillis << "/" << successorDurationMillis << "/"
            << first.closeCount.load() << "/" << successor.closeCount.load() << "\n";
        return false;
    }

    std::cout << "PASS: adjacent WAV CUE ranges [0, 7) and [7, 72) append "
        << firstSegmentFrames << "+" << successorFrames
        << " exact PCM frames in one output session; successor duration is "
        << callbackDurationMillis << " ms with one TrackChanged and one Ended event\n";
    return true;
}

bool runCueMultiFileGaplessCase() {
    constexpr int32_t sampleRate = 48'000;
    constexpr int64_t samplesPerCueFrame = sampleRate / 75;
    constexpr int64_t firstFileCueFrames = 7;
    constexpr int64_t secondFileCueFrames = 65;
    constexpr int64_t firstFileFrames = firstFileCueFrames * samplesPerCueFrame;
    constexpr int64_t secondFileFrames = secondFileCueFrames * samplesPerCueFrame;
    constexpr int64_t totalFrames = firstFileFrames + secondFileFrames;
    constexpr int32_t frameBytes = kChannels * 2;
    const int64_t firstDurationMillis = firstFileFrames * 1'000 / sampleRate;
    const int64_t secondDurationMillis =
        (secondFileFrames * 1'000 + sampleRate / 2) / sampleRate;

    /* Model two separate WAV files whose decoded samples meet exactly at the CUE seam. The seam
     * is deliberately off the 512-frame output-period boundary and the joined stream is exactly
     * 90 periods, so any inserted idle/padding frame makes the byte comparison fail. */
    const std::vector<uint8_t> firstWave = makeRampPcmWave(
        static_cast<int32_t>(firstFileFrames), sampleRate);
    const std::vector<uint8_t> secondWave = makeRampPcmWave(
        static_cast<int32_t>(secondFileFrames), sampleRate, firstFileFrames);
    MemoryReader first(firstWave);
    MemoryReader successor(secondWave);
    const LazerAudioReader firstReader = asReader(first);
    const LazerAudioReader successorReader = asReader(successor);
    ProbeEvents events;
    auto capture = std::make_shared<Capture>();
    events.capture = capture.get();

    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.exclusive = 1;
    config.device.bit_perfect = 1;
    config.device.buffer_millis = 60;
    config.events.on_event = onEvent;
    config.events.context = &events;
    config.log.on_log = onLog;

    Engine *engine = Engine::create(config, std::make_unique<CaptureOutput>(capture));
    if (engine == nullptr) {
        std::cerr << "FAIL: multi-file CUE gapless engine creation failed\n";
        return false;
    }
    events.engine = engine;
    const auto fail = [&](const char *message) {
        engine->destroy();
        std::cerr << "FAIL: multi-file CUE gapless case: " << message << "\n";
        return false;
    };

    const LazerAudioOpenParams firstParams{
        sizeof(LazerAudioOpenParams), 0, firstDurationMillis, 0, -1};
    if (engine->open(nullptr, &firstReader, firstParams) != LazerAudioOk) {
        std::cerr << "multi-file CUE first source open error=" << engine->lastError() << "\n";
        return fail("could not open the first file through physical EOF");
    }
    const LazerAudioOpenParams successorParams{
        sizeof(LazerAudioOpenParams), 0, secondDurationMillis, 0, -1};
    if (engine->queueReader(1, successorReader, successorParams) != LazerAudioOk) {
        std::cerr << "multi-file CUE successor queue error=" << engine->lastError() << "\n";
        return fail("could not prepare the second file from frame zero");
    }
    if (engine->play() != LazerAudioOk ||
        !waitForEvent(events, LazerAudioEventEnded, std::chrono::seconds(5))) {
        std::cerr << "multi-file CUE gapless end error=" << engine->lastError() << "\n";
        return fail("timed out before the second file reached clean EOF");
    }

    std::vector<uint8_t> expected;
    appendWaveFrames(expected, firstWave, 0, firstFileFrames);
    appendWaveFrames(expected, secondWave, 0, secondFileFrames);
    int32_t trackChanges = 0;
    int32_t ended = 0;
    bool successorSnapshotRead = false;
    int64_t callbackDurationMillis = 0;
    {
        std::lock_guard guard(events.mutex);
        for (const int32_t event : events.events) {
            if (event == LazerAudioEventTrackChanged) ++trackChanges;
            if (event == LazerAudioEventEnded) ++ended;
        }
        successorSnapshotRead = events.callbackSnapshotRead;
        callbackDurationMillis = events.callbackDurationMillis;
    }
    engine->destroy();

    std::vector<uint8_t> actual;
    int32_t openCount = 0;
    int32_t startCount = 0;
    int32_t closeCount = 0;
    {
        std::lock_guard guard(capture->mutex);
        actual = capture->bytes;
        openCount = capture->openCount;
        startCount = capture->startCount;
        closeCount = capture->closeCount;
    }
    if (actual.size() != expected.size() || actual != expected || trackChanges != 1 || ended != 1 ||
        !successorSnapshotRead || callbackDurationMillis != secondDurationMillis ||
        openCount != 1 || startCount != 1 || closeCount != 1 ||
        first.closeCount.load() != 1 || successor.closeCount.load() != 1) {
        std::cerr << "FAIL: multi-file CUE exact seam bytes=" << actual.size() << "/" << expected.size()
            << " events=" << trackChanges << "/" << ended
            << " session=" << openCount << "/" << startCount << "/" << closeCount
            << " duration=" << callbackDurationMillis << "/" << secondDurationMillis
            << " readers=" << first.closeCount.load() << "/" << successor.closeCount.load()
            << " totalFrames=" << totalFrames << " frameBytes=" << frameBytes << "\n";
        return false;
    }
    std::cout << "PASS: two separate WAV CUE sources append exact PCM frames through EOF in one output session\n";
    return true;
}

bool runCueFirstSegmentCase() {
    constexpr int32_t sampleRate = 48'000;
    constexpr int32_t physicalFrames = 72 * (sampleRate / 75);
    constexpr int64_t cueEndFrame75 = 7;
    constexpr int64_t segmentFrames = cueEndFrame75 * (sampleRate / 75);
    const std::vector<uint8_t> wave = makeRampPcmWave(physicalFrames, sampleRate);
    MemoryReader source(wave);
    const LazerAudioReader reader = asReader(source);
    ProbeEvents events;
    auto capture = std::make_shared<Capture>();
    events.capture = capture.get();

    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.exclusive = 1;
    config.device.bit_perfect = 1;
    config.device.buffer_millis = 60;
    config.events.on_event = onEvent;
    config.events.context = &events;
    config.log.on_log = onLog;

    Engine *engine = Engine::create(config, std::make_unique<CaptureOutput>(capture));
    if (engine == nullptr) return false;
    events.engine = engine;
    const LazerAudioOpenParams params{
        sizeof(LazerAudioOpenParams), 0, physicalFrames * 1000LL / sampleRate,
        0, cueEndFrame75};
    if (engine->open(nullptr, &reader, params) != LazerAudioOk ||
        engine->play() != LazerAudioOk ||
        !waitForEvent(events, LazerAudioEventEnded, std::chrono::seconds(5))) {
        std::cerr << "CUE first-segment open/play/end error=" << engine->lastError() << "\n";
        engine->destroy();
        return false;
    }
    std::vector<uint8_t> expected;
    appendWaveFrames(expected, wave, 0, segmentFrames);
    const int64_t paddedFrames = ((segmentFrames + kPeriodFrames - 1) / kPeriodFrames) * kPeriodFrames;
    expected.resize(static_cast<size_t>(paddedFrames) * kChannels * 2, 0);
    std::vector<uint8_t> actual;
    {
        std::lock_guard guard(capture->mutex);
        actual = capture->bytes;
    }
    engine->destroy();
    if (actual != expected || source.closeCount.load() != 1) {
        std::cerr << "CUE first-segment expected/actual bytes=" << expected.size() << "/"
            << actual.size() << "\n";
        return false;
    }
    std::cout << "PASS: standalone CUE range [0, 7) emits all " << segmentFrames
        << " source frames\n";
    return true;
}

bool runWholeTrackRegression() {
    constexpr int32_t sampleRate = 48'000;
    constexpr int32_t physicalFrames = 8'192;
    const std::vector<uint8_t> wave = makeRampPcmWave(physicalFrames, sampleRate);
    MemoryReader source(wave);
    LazerAudioReader reader = asReader(source);
    ProbeEvents events;
    auto capture = std::make_shared<Capture>();

    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.exclusive = 1;
    config.device.bit_perfect = 1;
    config.device.buffer_millis = 60;
    config.events.on_event = onEvent;
    config.events.context = &events;
    config.log.on_log = onLog;

    Engine *engine = Engine::create(config, std::make_unique<CaptureOutput>(capture));
    if (engine == nullptr) return false;
    events.engine = engine;
    const LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 0, 0, 0};
    if (engine->open(nullptr, &reader, params) != LazerAudioOk ||
        engine->play() != LazerAudioOk ||
        !waitForEvent(events, LazerAudioEventEnded, std::chrono::seconds(5))) {
        std::cerr << "FAIL: normal whole-track open/play/end failed: " << engine->lastError() << "\n";
        engine->destroy();
        return false;
    }
    int32_t endedCount = 0;
    {
        std::lock_guard guard(events.mutex);
        for (const int32_t event : events.events) {
            if (event == LazerAudioEventEnded) ++endedCount;
        }
    }
    std::vector<uint8_t> actual;
    {
        std::lock_guard guard(capture->mutex);
        actual = capture->bytes;
    }
    engine->destroy();
    const std::vector<uint8_t> expected(wave.begin() + 44, wave.end());
    if (actual != expected || endedCount != 1 || source.closeCount.load() != 1) {
        std::cerr << "FAIL: whole-track regression bytes/end/close=" << actual.size() << "/"
            << endedCount << "/" << source.closeCount.load() << " expected=" << expected.size() << "\n";
        return false;
    }
    std::cout << "PASS: (0, 0) open params retain byte-exact whole-track WAV playback and one Ended event\n";
    return true;
}

bool runMalformedCueRangeCase() {
    constexpr int32_t sampleRate = 48'000;
    const std::vector<uint8_t> wave = makeRampPcmWave(8'192, sampleRate);
    MemoryReader source(wave);
    LazerAudioReader reader = asReader(source);
    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.buffer_millis = 60;
    auto capture = std::make_shared<Capture>();
    Engine *engine = Engine::create(config, std::make_unique<CaptureOutput>(capture));
    if (engine == nullptr) return false;
    const LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 0, 8, 7};
    const int32_t result = engine->open(nullptr, &reader, params);
    const std::string error = engine->lastError();
    engine->destroy();
    if (result != LazerAudioErrorInvalidArgument ||
        error.find("CUE segment frame range is malformed") == std::string::npos) {
        std::cerr << "FAIL: malformed CUE range result=" << result << " error=" << error << "\n";
        return false;
    }
    std::cout << "PASS: malformed CUE range is rejected before playback\n";
    return true;
}

bool runReplayGainDspCase() {
    constexpr int32_t sampleRate = 44'100;
    constexpr int32_t frames = 8'192;
    MemoryReader source(makePcmWave(frames, sampleRate, 16, 7'000));
    LazerAudioReader reader = asReader(source);
    ProbeEvents events;
    auto capture = std::make_shared<Capture>();

    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.exclusive = 1;
    config.device.bit_perfect = 0;
    config.device.buffer_millis = 60;
    config.events.on_event = onEvent;
    config.events.context = &events;
    config.log.on_log = onLog;

    Engine *engine = Engine::create(config, std::make_unique<CaptureOutput>(capture));
    if (engine == nullptr) return false;
    events.engine = engine;
    LazerAudioDspConfig dsp{};
    dsp.preamp_db = 6.0;
    if (engine->setDsp(dsp) != LazerAudioOk) {
        engine->destroy();
        std::cerr << "FAIL: ReplayGain DSP config was rejected\n";
        return false;
    }
    const LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 100};
    if (engine->open(nullptr, &reader, params) != LazerAudioOk || engine->play() != LazerAudioOk) {
        std::cerr << "FAIL: could not start ReplayGain DSP probe: " << engine->lastError() << "\n";
        engine->destroy();
        return false;
    }
    if (!waitForWrites(capture, 1, std::chrono::seconds(5))) {
        std::cerr << "FAIL: ReplayGain DSP probe produced no output\n";
        engine->destroy();
        return false;
    }

    LazerAudioStreamInfo info{};
    engine->streamInfo(info);
    std::vector<uint8_t> raw(source.bytes.begin() + 44, source.bytes.end());
    bool outputChanged = false;
    {
        std::lock_guard guard(capture->mutex);
        const size_t compared = std::min(raw.size(), capture->bytes.size());
        outputChanged = compared > 0 && !std::equal(
            capture->bytes.begin(), capture->bytes.begin() + static_cast<std::ptrdiff_t>(compared),
            raw.begin());
    }
    const bool dspReported = info.bit_perfect_active == 0 && info.output_telemetry_valid != 0;
    bool ended = waitForEvent(events, LazerAudioEventEnded, std::chrono::seconds(5));
    engine->destroy();
    if (!outputChanged || !dspReported || !ended || source.closeCount.load() != 1) {
        std::cerr << "FAIL: ReplayGain DSP result changed=" << outputChanged
            << " processedTelemetry=" << dspReported << " ended=" << ended
            << " sourceClosed=" << source.closeCount.load() << "\n";
        return false;
    }
    std::cout << "PASS: ReplayGain preamp changes PCM, disables bit-perfect and enables DSP telemetry\n";
    return true;
}

bool runReplayGainGaplessCase() {
    constexpr int32_t sampleRate = 48'000;
    constexpr int32_t rampFrames = sampleRate * 5 / 1000;
    constexpr int32_t successorFrames = kPeriodFrames;
    const int32_t firstFrames = ((firstTrackFramesForRate(sampleRate) + kPeriodFrames - 1) /
        kPeriodFrames) * kPeriodFrames;
    const int32_t totalFrames = firstFrames + successorFrames;
    constexpr double successorGainDb = -6.0;
    const double successorGain = std::pow(10.0, successorGainDb / 20.0);
    MemoryReader first(makePcmWave(firstFrames, sampleRate, 16, 4'000));
    MemoryReader second(makePcmWave(successorFrames, sampleRate, 16, -3'000));
    LazerAudioReader firstReader = asReader(first);
    LazerAudioReader secondReader = asReader(second);
    ProbeEvents events;
    auto capture = std::make_shared<Capture>();
    events.capture = capture.get();

    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.exclusive = 0;
    config.device.bit_perfect = 0;
    config.device.buffer_millis = 60;
    config.events.on_event = onEvent;
    config.events.context = &events;
    config.log.on_log = onLog;

    Engine *engine = Engine::create(config, std::make_unique<CaptureOutput>(capture, true));
    if (engine == nullptr) return false;
    events.engine = engine;
    const LazerAudioOpenParams firstParams{
        sizeof(LazerAudioOpenParams), 0, 100, 0, 0, 0.0};
    const LazerAudioOpenParams successorParams{
        sizeof(LazerAudioOpenParams), 0, 100, 0, 0, successorGainDb};
    if (engine->open(nullptr, &firstReader, firstParams) != LazerAudioOk) {
        std::cerr << "FAIL: could not open first ReplayGain gapless track: "
            << engine->lastError() << "\n";
        engine->destroy();
        return false;
    }
    const int32_t queueResult = engine->queueReader(1, secondReader, successorParams);
    if (queueResult != LazerAudioOk) {
        std::cerr << "FAIL: could not queue different ReplayGain successor result="
            << queueResult << " error=" << engine->lastError() << "\n";
        engine->destroy();
        return false;
    }
    if (engine->play() != LazerAudioOk ||
        !waitForEventCount(events, LazerAudioEventEnded, 1, std::chrono::seconds(5))) {
        std::cerr << "FAIL: ReplayGain gapless stream did not finish: " << engine->lastError() << "\n";
        engine->destroy();
        return false;
    }

    std::vector<uint8_t> output;
    int32_t openCount = 0;
    int32_t startCount = 0;
    int32_t closeCount = 0;
    {
        std::lock_guard guard(capture->mutex);
        output = capture->bytes;
        openCount = capture->openCount;
        startCount = capture->startCount;
    }
    int32_t trackChanges = 0;
    int32_t endedEvents = 0;
    {
        std::lock_guard guard(events.mutex);
        for (const int32_t event : events.events) {
            if (event == LazerAudioEventTrackChanged) ++trackChanges;
            if (event == LazerAudioEventEnded) ++endedEvents;
        }
    }

    bool samplesMatch = output.size() == static_cast<size_t>(totalFrames * kChannels) * sizeof(float);
    double currentGain = 1.0;
    int32_t remainingRampFrames = 0;
    for (int32_t frame = 0; samplesMatch && frame < totalFrames; ++frame) {
        if (frame == firstFrames) remainingRampFrames = rampFrames;
        if (frame >= firstFrames && remainingRampFrames > 0) {
            currentGain += (successorGain - currentGain) / remainingRampFrames;
            --remainingRampFrames;
            if (remainingRampFrames == 0) currentGain = successorGain;
        }
        const bool isSuccessor = frame >= firstFrames;
        const int32_t sourceFrame = isSuccessor ? frame - firstFrames : frame;
        const int16_t seed = isSuccessor ? -3'000 : 4'000;
        for (int32_t channel = 0; channel < kChannels; ++channel) {
            float actual = 0.0f;
            const size_t sampleIndex = static_cast<size_t>(frame * kChannels + channel);
            std::memcpy(&actual, output.data() + sampleIndex * sizeof(float), sizeof(float));
            const int16_t sourceSample = static_cast<int16_t>(sampleValue(
                sourceFrame, channel, 16, channel == 0 ? seed : static_cast<int16_t>(-seed)));
            const float expected = static_cast<float>(sourceSample / 32768.0 * currentGain);
            if (std::abs(static_cast<double>(actual) - expected) > 2.0e-5) {
                std::cerr << "FAIL: ReplayGain sample mismatch at frame=" << frame
                    << " channel=" << channel << " actual=" << actual
                    << " expected=" << expected << " gain=" << currentGain << "\n";
                samplesMatch = false;
                break;
            }
        }
    }
    engine->destroy();
    {
        std::lock_guard guard(capture->mutex);
        closeCount = capture->closeCount;
    }
    if (!samplesMatch || trackChanges != 1 || endedEvents != 1 || openCount != 1 ||
        startCount != 1 || closeCount != 1 || first.closeCount.load() != 1 ||
        second.closeCount.load() != 1) {
        std::cerr << "FAIL: ReplayGain gapless lifecycle samples=" << samplesMatch
            << " trackChanges=" << trackChanges << " ended=" << endedEvents
            << " opens/starts/closes=" << openCount << "/" << startCount << "/" << closeCount
            << " readers=" << first.closeCount.load() << "/" << second.closeCount.load() << "\n";
        return false;
    }

    /* A source-level gain must never be silently ignored by direct bit-perfect/DoP paths. */
    MemoryReader bitPerfectFirst(makePcmWave(firstFrames, sampleRate, 16, 1'100));
    MemoryReader bitPerfectNext(makePcmWave(successorFrames, sampleRate, 16, -1'300));
    LazerAudioReader bitPerfectFirstReader = asReader(bitPerfectFirst);
    LazerAudioReader bitPerfectNextReader = asReader(bitPerfectNext);
    auto bitPerfectCapture = std::make_shared<Capture>();
    ProbeEvents bitPerfectEvents;
    bitPerfectEvents.capture = bitPerfectCapture.get();
    LazerAudioEngineConfig bitPerfectConfig = config;
    bitPerfectConfig.device.exclusive = 1;
    bitPerfectConfig.device.bit_perfect = 1;
    bitPerfectConfig.events.context = &bitPerfectEvents;
    Engine *bitPerfectEngine = Engine::create(bitPerfectConfig,
        std::make_unique<CaptureOutput>(bitPerfectCapture));
    if (bitPerfectEngine == nullptr ||
        bitPerfectEngine->open(nullptr, &bitPerfectFirstReader, firstParams) != LazerAudioOk) {
        if (bitPerfectEngine != nullptr) bitPerfectEngine->destroy();
        std::cerr << "FAIL: bit-perfect ReplayGain guard could not open control track\n";
        return false;
    }
    bitPerfectEvents.engine = bitPerfectEngine;
    if (bitPerfectEngine->queueReader(1, bitPerfectNextReader, successorParams) !=
        LazerAudioErrorUnsupported) {
        bitPerfectEngine->destroy();
        std::cerr << "FAIL: ReplayGain successor was accepted by bit-perfect output\n";
        return false;
    }
    if (bitPerfectEngine->play() != LazerAudioOk ||
        !waitForEventCount(bitPerfectEvents, LazerAudioEventEnded, 1, std::chrono::seconds(5))) {
        bitPerfectEngine->destroy();
        std::cerr << "FAIL: bit-perfect control track did not finish\n";
        return false;
    }
    bitPerfectEngine->stop();
    const int32_t rejectedOpen = bitPerfectEngine->open(
        nullptr, &bitPerfectNextReader, successorParams);
    int32_t bitPerfectOpenCount = 0;
    {
        std::lock_guard guard(bitPerfectCapture->mutex);
        bitPerfectOpenCount = bitPerfectCapture->openCount;
    }
    bitPerfectEngine->destroy();
    if (rejectedOpen != LazerAudioErrorUnsupported || bitPerfectOpenCount != 1) {
        std::cerr << "FAIL: ReplayGain open bypassed bit-perfect guard result=" << rejectedOpen
            << " output-opens=" << bitPerfectOpenCount << "\n";
        return false;
    }
    std::cout << "PASS: per-source ReplayGain ramps at a gapless seam and is rejected for bit-perfect output\n";
    return true;
}

}  // namespace

namespace lazer::audio {
std::unique_ptr<AudioOutput> createPlatformAudioOutput() { return nullptr; }
}  // namespace lazer::audio

int main(int argc, char **argv) {
    if (argc > 1 && std::string(argv[1]) == "--presentation-boundary") {
        return runPresentationBoundaryCase() ? 0 : 1;
    }
    if (argc > 1 && std::string(argv[1]) == "--pcm-format-reopen") {
        return runPcmFormatReopenCase() ? 0 : 1;
    }
    if (argc > 1 && std::string(argv[1]) == "--replaygain-dsp") {
        return runReplayGainDspCase() ? 0 : 1;
    }
    if (argc > 1 && std::string(argv[1]) == "--replaygain-gapless") {
        return runReplayGainGaplessCase() ? 0 : 1;
    }
    if (argc > 1 && std::string(argv[1]) == "--cue-segment") {
        return runCueSegmentCase(47) && runCueSegmentCase(-1) &&
            runCueSegmentCase(-1, true) &&
            runMalformedCueRangeCase() && runWholeTrackRegression() ? 0 : 1;
    }
    if (argc > 1 && std::string(argv[1]) == "--cue-gapless") {
        return runCueGaplessCase() && runCueMultiFileGaplessCase() ? 0 : 1;
    }
    if (argc > 1 && std::string(argv[1]) == "--cue-first-segment") {
        return runCueFirstSegmentCase() ? 0 : 1;
    }
    constexpr int32_t rates[] = {44'100, 48'000, 88'200, 96'000, 176'400, 192'000,
        352'800, 384'000, 705'600, 768'000};
    constexpr int32_t depths[] = {16, 24, 32};
    bool firstCase = true;
    for (const int32_t rate : rates) {
        for (const int32_t bits : depths) {
            if (!runCase(rate, bits, firstCase)) {
                std::cerr << "FAIL: exact PCM/gapless capture for " << rate << " Hz / " << bits
                    << " bit\n";
                return 1;
            }
            std::cout << "PASS: " << rate << " Hz / " << bits << " bit\n";
            firstCase = false;
        }
    }
    return runPcmFormatReopenCase() && runPresentationBoundaryCase() && runCueSegmentCase(47) &&
        runCueSegmentCase(-1) && runCueSegmentCase(-1, true) &&
        runMalformedCueRangeCase() &&
        runWholeTrackRegression() && runReplayGainDspCase() ? 0 : 1;
}
