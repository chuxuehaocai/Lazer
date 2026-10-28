/* End-to-end native Engine session test with a deterministic fake output. The two PCM WAV readers
 * cross one source EOF while retaining one fixed-period output session; the capture checks that the
 * boundary contributes no padded silence. */
#include "engine.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

using namespace lazer::audio;

constexpr int32_t kSampleRate = 44'100;
constexpr int32_t kChannels = 2;
constexpr int32_t kPeriodFrames = 512;
constexpr int32_t kFrameBytes = 4;
constexpr int32_t kDsdBitRate = 2'822'400;
constexpr int32_t kDsdBlockBytes = 4096;

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

void append64(std::vector<uint8_t> &bytes, uint64_t value) {
    for (int shift = 0; shift < 64; shift += 8) {
        bytes.push_back(static_cast<uint8_t>(value >> shift));
    }
}

std::vector<uint8_t> makePcm16Wave(int32_t frames, int16_t seed) {
    std::vector<uint8_t> bytes;
    bytes.reserve(44 + static_cast<size_t>(frames) * kFrameBytes);
    bytes.insert(bytes.end(), {'R', 'I', 'F', 'F'});
    append32(bytes, 36u + static_cast<uint32_t>(frames * kFrameBytes));
    bytes.insert(bytes.end(), {'W', 'A', 'V', 'E', 'f', 'm', 't', ' '});
    append32(bytes, 16);
    append16(bytes, 1);
    append16(bytes, kChannels);
    append32(bytes, kSampleRate);
    append32(bytes, kSampleRate * kFrameBytes);
    append16(bytes, kFrameBytes);
    append16(bytes, 16);
    bytes.insert(bytes.end(), {'d', 'a', 't', 'a'});
    append32(bytes, static_cast<uint32_t>(frames * kFrameBytes));
    for (int32_t frame = 0; frame < frames; ++frame) {
        const auto left = static_cast<int16_t>(seed + (frame * 37) % 12'000);
        const auto right = static_cast<int16_t>(-seed - (frame * 53) % 10'000);
        append16(bytes, static_cast<uint16_t>(left));
        append16(bytes, static_cast<uint16_t>(right));
    }
    return bytes;
}

std::vector<uint8_t> makeStereoDsf(uint64_t durationMillis) {
    const uint64_t bitCount = static_cast<uint64_t>(kDsdBitRate) * durationMillis / 1000;
    const uint64_t audioBytesPerChannel = bitCount / 8;
    const uint64_t blocks = (audioBytesPerChannel + kDsdBlockBytes - 1) / kDsdBlockBytes;
    const uint64_t paddedBytesPerChannel = blocks * kDsdBlockBytes;
    const uint64_t payloadBytes = paddedBytesPerChannel * kChannels;
    const uint64_t dataChunkBytes = 12 + payloadBytes;
    const uint64_t fileBytes = 28 + 52 + dataChunkBytes;

    std::vector<uint8_t> bytes;
    bytes.reserve(static_cast<size_t>(fileBytes));
    bytes.insert(bytes.end(), {'D', 'S', 'D', ' '});
    append64(bytes, 28);
    append64(bytes, fileBytes);
    append64(bytes, 0);
    bytes.insert(bytes.end(), {'f', 'm', 't', ' '});
    append64(bytes, 52);
    append32(bytes, 1);
    append32(bytes, 0);
    append32(bytes, 2);
    append32(bytes, kChannels);
    append32(bytes, kDsdBitRate);
    append32(bytes, 8);
    append64(bytes, bitCount);
    append32(bytes, kDsdBlockBytes);
    append32(bytes, 0);
    bytes.insert(bytes.end(), {'d', 'a', 't', 'a'});
    append64(bytes, dataChunkBytes);

    std::array<std::vector<uint8_t>, kChannels> channels;
    for (int32_t channel = 0; channel < kChannels; ++channel) {
        auto &samples = channels[static_cast<size_t>(channel)];
        samples.resize(static_cast<size_t>(paddedBytesPerChannel), 0x69);
        for (uint64_t index = 0; index < audioBytesPerChannel; ++index) {
            const bool first = ((index + static_cast<uint64_t>(channel) * 3) & 1u) == 0;
            const uint8_t even = channel == 0 ? 0xAA : 0x33;
            const uint8_t odd = channel == 0 ? 0x55 : 0xCC;
            samples[static_cast<size_t>(index)] = first ? even : odd;
        }
    }
    for (uint64_t block = 0; block < blocks; ++block) {
        const size_t offset = static_cast<size_t>(block * kDsdBlockBytes);
        for (int32_t channel = 0; channel < kChannels; ++channel) {
            const auto &samples = channels[static_cast<size_t>(channel)];
            bytes.insert(bytes.end(), samples.begin() + static_cast<std::ptrdiff_t>(offset),
                samples.begin() + static_cast<std::ptrdiff_t>(offset + kDsdBlockBytes));
        }
    }
    return bytes;
}

struct MemoryReader {
    explicit MemoryReader(std::vector<uint8_t> value) : bytes(std::move(value)) {}
    std::vector<uint8_t> bytes;
    int64_t position = 0;
    int closeCount = 0;
};

/* A seekable WAV reader that blocks after serving a prefix of FFmpeg's synchronous probe. The
 * preparation thread is kept outside the engine while clear/stop invokes the thread-safe cancel hook. */
struct GatedReader {
    GatedReader(std::vector<uint8_t> value, int64_t gate)
        : bytes(std::move(value)), gateOffset(gate) {}

    std::vector<uint8_t> bytes;
    const int64_t gateOffset;
    std::mutex mutex;
    std::condition_variable changed;
    int64_t position = 0;
    bool gateReached = false;
    bool released = false;
    bool cancelled = false;
    std::atomic<int> cancelCount{0};
    std::atomic<int> closeCount{0};
};

/* Source reader with two post-open gates. The first produces a real output starvation; releasing
 * it supplies enough PCM to observe recovery while the second gate keeps the source unfinished. */
struct StagedReader {
    explicit StagedReader(std::vector<uint8_t> value) : bytes(std::move(value)) {}

    std::vector<uint8_t> bytes;
    std::mutex mutex;
    std::condition_variable changed;
    int64_t position = 0;
    int64_t firstGateOffset = 0;
    int64_t secondGateOffset = 0;
    int releasedGates = 0;
    bool armed = false;
    bool firstGateReached = false;
    bool secondGateReached = false;
    bool cancelled = false;
    std::atomic<int> closeCount{0};
};

void armStagedReader(StagedReader &reader) {
    std::lock_guard guard(reader.mutex);
    reader.firstGateOffset = reader.position + 64;
    reader.secondGateOffset = reader.firstGateOffset +
        static_cast<int64_t>(kPeriodFrames) * kFrameBytes * 20;
    reader.armed = true;
}

int32_t readStagedBytes(void *context, uint8_t *destination, int32_t length) {
    auto *reader = static_cast<StagedReader *>(context);
    if (reader == nullptr || destination == nullptr || length <= 0) return LAZER_AUDIO_READER_IO_ERROR;
    std::unique_lock guard(reader->mutex);
    while (reader->armed && reader->releasedGates < 2 && !reader->cancelled) {
        const int stage = reader->releasedGates;
        const int64_t gateOffset = stage == 0 ? reader->firstGateOffset : reader->secondGateOffset;
        if (reader->position < gateOffset) break;
        if (stage == 0) reader->firstGateReached = true;
        else reader->secondGateReached = true;
        reader->changed.notify_all();
        reader->changed.wait(guard, [reader, stage] {
            return reader->releasedGates > stage || reader->cancelled;
        });
    }
    if (reader->cancelled) return LAZER_AUDIO_READER_IO_ERROR;
    if (reader->position >= static_cast<int64_t>(reader->bytes.size())) return LAZER_AUDIO_READER_EOF;
    int64_t limit = static_cast<int64_t>(reader->bytes.size());
    if (reader->armed && reader->releasedGates < 2) {
        limit = reader->releasedGates == 0 ? reader->firstGateOffset : reader->secondGateOffset;
    }
    const int64_t remaining = limit - reader->position;
    if (remaining <= 0) return LAZER_AUDIO_READER_IO_ERROR;
    const int32_t count = static_cast<int32_t>(std::min<int64_t>(remaining, length));
    std::memcpy(destination, reader->bytes.data() + reader->position, static_cast<size_t>(count));
    reader->position += count;
    return count;
}

int64_t seekStagedBytes(void *context, int64_t position) {
    auto *reader = static_cast<StagedReader *>(context);
    if (reader == nullptr) return -1;
    std::lock_guard guard(reader->mutex);
    if (position < 0 || position > static_cast<int64_t>(reader->bytes.size())) return -1;
    reader->position = position;
    return position;
}

int64_t stagedReaderLength(void *context) {
    const auto *reader = static_cast<StagedReader *>(context);
    return reader == nullptr ? -1 : static_cast<int64_t>(reader->bytes.size());
}

void closeStagedReader(void *context) {
    auto *reader = static_cast<StagedReader *>(context);
    if (reader != nullptr) reader->closeCount.fetch_add(1, std::memory_order_release);
}

void cancelStagedReader(void *context) {
    auto *reader = static_cast<StagedReader *>(context);
    if (reader == nullptr) return;
    {
        std::lock_guard guard(reader->mutex);
        reader->cancelled = true;
    }
    reader->changed.notify_all();
}

LazerAudioReader asReader(StagedReader &reader) {
    return LazerAudioReader{
        readStagedBytes, seekStagedBytes, stagedReaderLength, closeStagedReader, &reader,
        cancelStagedReader};
}

bool waitForStagedGate(StagedReader &reader, int stage, std::chrono::milliseconds timeout) {
    std::unique_lock guard(reader.mutex);
    return reader.changed.wait_for(guard, timeout, [&reader, stage] {
        return stage == 0 ? reader.firstGateReached : reader.secondGateReached;
    });
}

void releaseStagedGate(StagedReader &reader, int stage) {
    {
        std::lock_guard guard(reader.mutex);
        reader.releasedGates = std::max(reader.releasedGates, stage + 1);
    }
    reader.changed.notify_all();
}

int32_t readGatedBytes(void *context, uint8_t *destination, int32_t length) {
    auto *reader = static_cast<GatedReader *>(context);
    if (reader == nullptr || destination == nullptr || length <= 0) return LAZER_AUDIO_READER_IO_ERROR;
    std::unique_lock guard(reader->mutex);
    while (reader->position >= reader->gateOffset && !reader->released && !reader->cancelled &&
        reader->position < static_cast<int64_t>(reader->bytes.size())) {
        reader->gateReached = true;
        reader->changed.notify_all();
        reader->changed.wait(guard, [reader] { return reader->released || reader->cancelled; });
    }
    if (reader->cancelled) return LAZER_AUDIO_READER_IO_ERROR;
    if (reader->position >= static_cast<int64_t>(reader->bytes.size())) return LAZER_AUDIO_READER_EOF;
    int64_t limit = static_cast<int64_t>(reader->bytes.size());
    if (!reader->released) limit = std::min(limit, reader->gateOffset);
    const int64_t remaining = limit - reader->position;
    if (remaining <= 0) return LAZER_AUDIO_READER_IO_ERROR;
    const int32_t count = static_cast<int32_t>(std::min<int64_t>(remaining, length));
    std::memcpy(destination, reader->bytes.data() + reader->position, static_cast<size_t>(count));
    reader->position += count;
    return count;
}

int64_t seekGatedBytes(void *context, int64_t position) {
    auto *reader = static_cast<GatedReader *>(context);
    if (reader == nullptr) return -1;
    std::lock_guard guard(reader->mutex);
    if (position < 0 || position > static_cast<int64_t>(reader->bytes.size())) return -1;
    reader->position = position;
    return position;
}

int64_t gatedReaderLength(void *context) {
    const auto *reader = static_cast<GatedReader *>(context);
    return reader == nullptr ? -1 : static_cast<int64_t>(reader->bytes.size());
}

void closeGatedReader(void *context) {
    auto *reader = static_cast<GatedReader *>(context);
    if (reader != nullptr) reader->closeCount.fetch_add(1, std::memory_order_release);
}

void cancelGatedReader(void *context) {
    auto *reader = static_cast<GatedReader *>(context);
    if (reader == nullptr) return;
    reader->cancelCount.fetch_add(1, std::memory_order_release);
    {
        std::lock_guard guard(reader->mutex);
        reader->cancelled = true;
    }
    reader->changed.notify_all();
}

LazerAudioReader asReader(GatedReader &reader) {
    return LazerAudioReader{
        readGatedBytes, seekGatedBytes, gatedReaderLength, closeGatedReader, &reader,
        cancelGatedReader};
}

bool waitForGate(GatedReader &reader, std::chrono::milliseconds timeout) {
    std::unique_lock guard(reader.mutex);
    return reader.changed.wait_for(guard, timeout, [&reader] {
        return reader.gateReached || reader.cancelled;
    }) && reader.gateReached;
}

void releaseGate(GatedReader &reader) {
    {
        std::lock_guard guard(reader.mutex);
        reader.released = true;
    }
    reader.changed.notify_all();
}

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
    if (reader != nullptr) ++reader->closeCount;
}

LazerAudioReader asReader(MemoryReader &reader) {
    return LazerAudioReader{readBytes, seekBytes, readerLength, closeReader, &reader, nullptr};
}

struct ProbeEvents {
    std::mutex mutex;
    std::condition_variable changed;
    std::vector<int32_t> events;
    bool blockTerminalCallback = false;
    bool terminalCallbackEntered = false;
    bool releaseTerminalCallback = false;
    int32_t terminalDetail = 0;
    int64_t terminalPositionMillis = 0;
};

void onEvent(void *context, int32_t event, int32_t detail, int64_t positionMillis) {
    auto *events = static_cast<ProbeEvents *>(context);
    if (events == nullptr) return;
    std::unique_lock guard(events->mutex);
    events->events.push_back(event);
    if (event == LazerAudioEventEnded || event == LazerAudioEventFailed ||
        event == LazerAudioEventDeviceLost) {
        events->terminalDetail = detail;
        events->terminalPositionMillis = positionMillis;
        if (events->blockTerminalCallback && !events->releaseTerminalCallback) {
            events->terminalCallbackEntered = true;
            events->changed.notify_all();
            events->changed.wait(guard, [events] { return events->releaseTerminalCallback; });
        }
    }
    guard.unlock();
    events->changed.notify_all();
}

void onLog(void *, int32_t level, const char *message) {
    if (level >= LazerAudioLogDebug && message != nullptr) std::cerr << "engine: " << message << '\n';
}

struct Capture {
    std::mutex mutex;
    std::vector<uint8_t> bytes;
    int openCount = 0;
    int startCount = 0;
    int closeCount = 0;
    int waitCount = 0;
    int writableCount = 0;
    int drainCount = 0;
    int writeCount = 0;
    int failWriteNumber = 0;
};

class CaptureOutput final : public AudioOutput {
public:
    explicit CaptureOutput(std::shared_ptr<Capture> capture) : capture_(std::move(capture)) {}

    int32_t open(const AudioOutputRequest &, const StreamDescription &source,
        AudioOutputSession &session, std::string &, LogProxy *) override {
        std::lock_guard guard(capture_->mutex);
        ++capture_->openCount;
        session.target.sampleRate = source.dsd ? kSampleRate : source.sampleRate;
        session.target.channels = source.channels;
        session.target.bitsPerSample = source.dsd ? 16 : source.bitsPerSample;
        session.target.containerBitsPerSample = session.target.bitsPerSample;
        session.engineFormat = {session.target.sampleRate, source.channels};
        session.formatSelection = LazerAudioFormatSelectionExclusiveSource;
        session.periodFrames = kPeriodFrames;
        session.bufferFrames = kPeriodFrames;
        session.exclusive = true;
        session.writeMode = OutputWriteMode::FixedPeriod;
        session.queueDepthAvailable = true;
        open_ = true;
        return LazerAudioOk;
    }

    void close() override {
        std::lock_guard guard(capture_->mutex);
        if (open_) ++capture_->closeCount;
        open_ = false;
    }

    int32_t start(std::string &) override {
        std::lock_guard guard(capture_->mutex);
        ++capture_->startCount;
        running_ = true;
        return LazerAudioOk;
    }
    int32_t stop(std::string &) override { running_ = false; return LazerAudioOk; }
    int32_t reset(std::string &) override { return LazerAudioOk; }

    OutputWaitResult waitForReady(int32_t, std::string &) override {
        { std::lock_guard guard(capture_->mutex); ++capture_->waitCount; }
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
        return OutputWaitResult::Ready;
    }
    int32_t writableFrames(std::string &) override {
        std::lock_guard guard(capture_->mutex);
        ++capture_->writableCount;
        return kPeriodFrames;
    }
    int32_t queuedFrames(std::string &) override { return 0; }
    OutputDrainResult drain(std::string &) override {
        std::lock_guard guard(capture_->mutex);
        ++capture_->drainCount;
        return OutputDrainResult::Drained;
    }

    int32_t write(const uint8_t *bytes, int32_t frames, std::string &error) override {
        if (bytes == nullptr || frames != kPeriodFrames) return LazerAudioErrorDevice;
        std::lock_guard guard(capture_->mutex);
        ++capture_->writeCount;
        if (capture_->failWriteNumber > 0 && capture_->writeCount == capture_->failWriteNumber) {
            error = "simulated output device loss";
            return LazerAudioErrorDevice;
        }
        capture_->bytes.insert(capture_->bytes.end(), bytes,
            bytes + static_cast<size_t>(frames) * kFrameBytes);
        return frames;
    }
    [[nodiscard]] bool isOpen() const noexcept override { return open_; }

private:
    std::shared_ptr<Capture> capture_;
    bool open_ = false;
    bool running_ = false;
};

int fail(const char *message) {
    std::cerr << "FAIL: " << message << '\n';
    return 1;
}

struct QueueCall {
    std::mutex mutex;
    std::condition_variable changed;
    bool done = false;
    int32_t result = LazerAudioErrorState;
};

bool startBlockedPreparation(Engine &engine, GatedReader &reader, uint64_t generation,
    QueueCall &call, std::thread &queueThread) {
    const LazerAudioReader input = asReader(reader);
    const LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 2};
    queueThread = std::thread([&engine, &call, input, generation, params] {
        const int32_t result = engine.queueReader(generation, input, params);
        {
            std::lock_guard guard(call.mutex);
            call.result = result;
            call.done = true;
        }
        call.changed.notify_all();
    });

    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (std::chrono::steady_clock::now() < deadline) {
        if (waitForGate(reader, std::chrono::milliseconds(20))) return true;
        {
            std::lock_guard guard(call.mutex);
            if (call.done) break;
        }
    }
    releaseGate(reader);
    {
        std::unique_lock guard(call.mutex);
        call.changed.wait_for(guard, std::chrono::seconds(5), [&] { return call.done; });
    }
    if (queueThread.joinable()) queueThread.join();
    return false;
}

struct OperationCall {
    std::mutex mutex;
    std::condition_variable changed;
    bool done = false;
    int32_t result = LazerAudioErrorState;
};

bool runGatedCancellationCase(bool stopInsteadOfClear) {
    MemoryReader first(makePcm16Wave(44'101, 5'000));
    GatedReader next(makePcm16Wave(100'000, -4'000), 128 * 1024);
    LazerAudioReader firstReader = asReader(first);

    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.exclusive = 1;
    config.device.bit_perfect = 1;
    config.device.buffer_millis = 120;
    config.log.on_log = onLog;
    auto capture = std::make_shared<Capture>();
    Engine *engine = Engine::create(config, std::make_unique<CaptureOutput>(capture));
    if (engine == nullptr) return false;

    const LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 1'000};
    if (engine->open(nullptr, &firstReader, params) != LazerAudioOk) {
        engine->destroy();
        return false;
    }
    QueueCall queue;
    std::thread queueThread;
    if (!startBlockedPreparation(*engine, next, 1, queue, queueThread)) {
        engine->destroy();
        std::cerr << "FAIL: queue preparation did not block in the reader after its initial probe bytes\n";
        return false;
    }

    OperationCall operation;
    const auto started = std::chrono::steady_clock::now();
    std::thread operationThread([&] {
        const int32_t result = stopInsteadOfClear
            ? engine->stop() : engine->clearQueuedReader(2);
        {
            std::lock_guard guard(operation.mutex);
            operation.result = result;
            operation.done = true;
        }
        operation.changed.notify_all();
    });

    bool returned = false;
    {
        std::unique_lock guard(operation.mutex);
        returned = operation.changed.wait_for(guard, std::chrono::seconds(2),
            [&] { return operation.done; });
    }
    bool forcedRelease = false;
    if (!returned) {
        /* A broken cancel hook must not hang the whole probe; the assertion below records that
         * the operation needed this test-only escape hatch. */
        forcedRelease = true;
        releaseGate(next);
        std::unique_lock guard(operation.mutex);
        returned = operation.changed.wait_for(guard, std::chrono::seconds(3),
            [&] { return operation.done; });
    }
    operationThread.join();
    const auto elapsed = std::chrono::steady_clock::now() - started;
    const int32_t expected = stopInsteadOfClear ? LazerAudioOk : LazerAudioQueueCleared;
    const bool resultMatches = operation.result == expected;

    bool queueReturned = false;
    {
        std::unique_lock guard(queue.mutex);
        queueReturned = queue.changed.wait_for(guard, std::chrono::seconds(3),
            [&] { return queue.done; });
    }
    if (!queueReturned) {
        releaseGate(next);
        std::unique_lock guard(queue.mutex);
        queueReturned = queue.changed.wait_for(guard, std::chrono::seconds(3),
            [&] { return queue.done; });
    }
    if (queueThread.joinable()) queueThread.join();

    engine->destroy();
    const bool readerClosedOnce = next.closeCount.load(std::memory_order_acquire) == 1;
    const bool readerCancelledOnce = next.cancelCount.load(std::memory_order_acquire) == 1;
    if (!returned || forcedRelease || elapsed > std::chrono::seconds(2) || !resultMatches ||
        !queueReturned || queue.result == LazerAudioOk || !readerClosedOnce || !readerCancelledOnce) {
        std::cerr << "FAIL: gated reader " << (stopInsteadOfClear ? "stop" : "clear")
            << " completion=" << returned << " forcedRelease=" << forcedRelease
            << " result=" << operation.result << " cancel/close="
            << next.cancelCount.load(std::memory_order_acquire) << "/"
            << next.closeCount.load(std::memory_order_acquire) << " elapsed-ms="
            << std::chrono::duration_cast<std::chrono::milliseconds>(elapsed).count()
            << " queue-returned=" << queueReturned << " queue-result=" << queue.result << '\n';
        return false;
    }
    std::cout << "PASS: gated reader " << (stopInsteadOfClear ? "stop" : "clear")
        << " cancelled and closed exactly once\n";
    return true;
}

bool runBlockedOpenCancellationCase() {
    GatedReader opening(makePcm16Wave(100'000, -4'000), 128 * 1024);
    const LazerAudioReader reader = asReader(opening);

    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.exclusive = 1;
    config.device.bit_perfect = 1;
    config.device.buffer_millis = 120;
    config.log.on_log = onLog;
    auto capture = std::make_shared<Capture>();
    Engine *engine = Engine::create(config, std::make_unique<CaptureOutput>(capture));
    if (engine == nullptr) return false;

    const LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 1'000};
    QueueCall open;
    std::thread openThread([&] {
        const int32_t result = engine->open(nullptr, &reader, params);
        {
            std::lock_guard guard(open.mutex);
            open.result = result;
            open.done = true;
        }
        open.changed.notify_all();
    });
    if (!waitForGate(opening, std::chrono::seconds(5))) {
        releaseGate(opening);
        {
            std::unique_lock guard(open.mutex);
            open.changed.wait_for(guard, std::chrono::seconds(5), [&] { return open.done; });
        }
        if (openThread.joinable()) openThread.join();
        engine->destroy();
        std::cerr << "FAIL: main open did not block in the reader after its initial probe bytes\n";
        return false;
    }

    OperationCall stop;
    const auto started = std::chrono::steady_clock::now();
    std::thread stopThread([&] {
        const int32_t result = engine->stop();
        {
            std::lock_guard guard(stop.mutex);
            stop.result = result;
            stop.done = true;
        }
        stop.changed.notify_all();
    });
    bool stopReturned = false;
    {
        std::unique_lock guard(stop.mutex);
        stopReturned = stop.changed.wait_for(guard, std::chrono::seconds(2),
            [&] { return stop.done; });
    }
    bool forcedRelease = false;
    if (!stopReturned) {
        /* Keep a regression from hanging the test process if cancellation stops waking readers. */
        forcedRelease = true;
        releaseGate(opening);
        std::unique_lock guard(stop.mutex);
        stopReturned = stop.changed.wait_for(guard, std::chrono::seconds(3),
            [&] { return stop.done; });
    }
    stopThread.join();
    const auto elapsed = std::chrono::steady_clock::now() - started;

    bool openReturned = false;
    {
        std::unique_lock guard(open.mutex);
        openReturned = open.changed.wait_for(guard, std::chrono::seconds(3),
            [&] { return open.done; });
    }
    if (!openReturned) {
        releaseGate(opening);
        std::unique_lock guard(open.mutex);
        openReturned = open.changed.wait_for(guard, std::chrono::seconds(3),
            [&] { return open.done; });
    }
    if (openThread.joinable()) openThread.join();

    engine->destroy();
    const bool readerClosedOnce = opening.closeCount.load(std::memory_order_acquire) == 1;
    const bool readerCancelledOnce = opening.cancelCount.load(std::memory_order_acquire) == 1;
    if (!stopReturned || forcedRelease || elapsed > std::chrono::seconds(2) ||
        stop.result != LazerAudioOk || !openReturned || open.result == LazerAudioOk ||
        !readerClosedOnce || !readerCancelledOnce) {
        std::cerr << "FAIL: blocked main open stop completion=" << stopReturned
            << " forcedRelease=" << forcedRelease << " stop-result=" << stop.result
            << " open-returned=" << openReturned << " open-result=" << open.result
            << " cancel/close=" << opening.cancelCount.load(std::memory_order_acquire) << "/"
            << opening.closeCount.load(std::memory_order_acquire) << " elapsed-ms="
            << std::chrono::duration_cast<std::chrono::milliseconds>(elapsed).count() << '\n';
        return false;
    }
    std::cout << "PASS: stop cancelled a blocked main open and closed the reader exactly once\n";
    return true;
}

}  // namespace

namespace lazer::audio {
std::unique_ptr<AudioOutput> createPlatformAudioOutput() { return nullptr; }
}  // namespace lazer::audio

int runExistingFastGaplessCase() {
    /* A ends 69 frames into a 512-frame period. The combined session length is an exact number of
     * periods, so every captured frame must be source PCM; there is no legitimate final pad to hide
     * a seam. */
    constexpr int32_t firstFrames = 44'101;
    constexpr int32_t secondFrames = 443;
    MemoryReader first(makePcm16Wave(firstFrames, 5'000));
    MemoryReader cancelled(makePcm16Wave(31, 2'000));
    MemoryReader second(makePcm16Wave(secondFrames, -4'000));
    LazerAudioReader firstReader = asReader(first);
    LazerAudioReader cancelledReader = asReader(cancelled);
    LazerAudioReader secondReader = asReader(second);
    ProbeEvents events;
    auto capture = std::make_shared<Capture>();

    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.exclusive = 1;
    config.device.bit_perfect = 1;
    config.device.buffer_millis = 120;
    config.events.on_event = onEvent;
    config.events.context = &events;
    config.log.on_log = onLog;

    Engine *engine = Engine::create(config, std::make_unique<CaptureOutput>(capture));
    if (engine == nullptr) return fail("engine creation failed");

    const LazerAudioOpenParams firstParams{sizeof(LazerAudioOpenParams), 0, 1'000};
    const int32_t opened = engine->open(nullptr, &firstReader, firstParams);
    if (opened != LazerAudioOk) {
        engine->destroy();
        return fail("first PCM source did not open");
    }
    const LazerAudioOpenParams nextParams{sizeof(LazerAudioOpenParams), 0, 2};
    const int32_t staleQueued = engine->queueReader(1, cancelledReader, nextParams);
    if (staleQueued != LazerAudioOk) {
        engine->destroy();
        return fail("first successor did not prepare");
    }
    if (engine->clearQueuedReader(2) != LazerAudioOk) {
        engine->destroy();
        return fail("prepared successor did not cancel");
    }
    if (engine->queueReader(1, cancelledReader, nextParams) != LazerAudioErrorState) {
        engine->destroy();
        return fail("late queue generation was not rejected");
    }
    const int32_t queued = engine->queueReader(3, secondReader, nextParams);
    if (queued != LazerAudioOk) {
        engine->destroy();
        return fail("compatible successor did not prepare");
    }
    if (engine->play() != LazerAudioOk) {
        engine->destroy();
        return fail("output session did not start");
    }

    bool ended = false;
    {
        std::unique_lock guard(events.mutex);
        ended = events.changed.wait_for(guard, std::chrono::seconds(10), [&] {
            return std::find(events.events.begin(), events.events.end(), LazerAudioEventEnded) !=
                events.events.end();
        });
    }
    if (!ended) {
        LazerAudioSnapshot snapshot{};
        engine->snapshot(snapshot);
        {
            std::lock_guard guard(capture->mutex);
            std::cerr << "snapshot state=" << snapshot.state << " position=" << snapshot.position_millis
                << " duration=" << snapshot.duration_millis << " buffered=" << snapshot.buffered_percent
                << " captured="
                << capture->bytes.size() / kFrameBytes << " frames opens=" << capture->openCount
                << " starts=" << capture->startCount << " reader-pos=" << first.position << "/"
                << first.bytes.size() << " next-pos=" << second.position << "/" << second.bytes.size()
                << " closes=" << first.closeCount << "/" << second.closeCount << " waits="
                << capture->waitCount << " writable=" << capture->writableCount << " drains="
                << capture->drainCount << '\n';
        }
        {
            std::lock_guard guard(events.mutex);
            std::cerr << "events:";
            for (const int32_t event : events.events) std::cerr << ' ' << event;
            std::cerr << '\n';
        }
        engine->destroy();
        return fail("session did not finish within ten seconds");
    }
    if (engine->clearQueuedReader(4) != LazerAudioQueueAlreadyActive) {
        engine->destroy();
        return fail("a successor that crossed the boundary was reported as cancellable queue data");
    }
    engine->destroy();

    std::vector<uint8_t> expected = first.bytes;
    expected.erase(expected.begin(), expected.begin() + 44);
    std::vector<uint8_t> secondPcm = second.bytes;
    secondPcm.erase(secondPcm.begin(), secondPcm.begin() + 44);
    expected.insert(expected.end(), secondPcm.begin(), secondPcm.end());

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
            return fail("output was reopened or restarted at the source boundary");
        }
        if (capture->bytes != expected) return fail("captured PCM contains a gap, pad, or altered sample");
    }
    if (trackChanges != 1 || ends != 1) return fail("session did not publish one track boundary and one final end");
    if (first.closeCount != 1 || cancelled.closeCount != 1 || second.closeCount != 1) {
        return fail("a source reader was not closed exactly once");
    }

    std::cout << "PASS: " << firstFrames << "+" << secondFrames
        << " PCM frames crossed one fixed-period output session without an inserted frame\n";
    return 0;
}

int runUnderrunRecoveryCase() {
    StagedReader source(makeStereoDsf(5'000));
    const LazerAudioReader reader = asReader(source);
    ProbeEvents events;
    auto capture = std::make_shared<Capture>();

    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.exclusive = 1;
    config.device.bit_perfect = 0;
    config.device.buffer_millis = 120;
    config.events.on_event = onEvent;
    config.events.context = &events;
    config.log.on_log = onLog;
    Engine *engine = Engine::create(config, std::make_unique<CaptureOutput>(capture));
    if (engine == nullptr) return fail("underrun probe engine creation failed");

    const LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 5'000};
    if (engine->open(nullptr, &reader, params) != LazerAudioOk) {
        engine->destroy();
        return fail("underrun probe source did not open");
    }
    armStagedReader(source);
    if (engine->play() != LazerAudioOk) {
        engine->destroy();
        return fail("underrun probe output did not start");
    }

    bool firstGateReached = waitForStagedGate(source, 0, std::chrono::seconds(5));
    LazerAudioSnapshot starving{};
    engine->snapshot(starving);
    bool underflowObserved = false;
    const auto underflowDeadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (firstGateReached && std::chrono::steady_clock::now() < underflowDeadline) {
        engine->snapshot(starving);
        if (starving.underrun_active != 0 && starving.underrun_frames > 0) {
            underflowObserved = true;
            break;
        }
        if (starving.state == LazerAudioStateFailed || starving.state == LazerAudioStateStopped) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    if (!underflowObserved) {
        size_t capturedBytes = 0;
        {
            std::lock_guard guard(capture->mutex);
            capturedBytes = capture->bytes.size();
        }
        {
            std::lock_guard guard(source.mutex);
            std::cerr << "underrun debug: position=" << source.position << '/' << source.bytes.size()
                << " first=" << source.firstGateOffset << " second=" << source.secondGateOffset
                << " captured=" << capturedBytes / kFrameBytes << " last-error="
                << engine->lastError() << '\n';
        }
        releaseStagedGate(source, 0);
        releaseStagedGate(source, 1);
        std::cerr << "FAIL: first source gate=" << firstGateReached << " state=" << starving.state
            << " underrun=" << starving.underrun_active << '/' << starving.underrun_frames << '\n';
        engine->destroy();
        return fail("unfinished source padding was not reported as an underrun");
    }

    releaseStagedGate(source, 0);
    const bool secondGateReached = waitForStagedGate(source, 1, std::chrono::seconds(5));
    LazerAudioSnapshot recovered{};
    bool recoveryObserved = false;
    const auto recoveryDeadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    while (secondGateReached && std::chrono::steady_clock::now() < recoveryDeadline) {
        engine->snapshot(recovered);
        if (recovered.underrun_active == 0 && recovered.underrun_frames >= starving.underrun_frames) {
            recoveryObserved = true;
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    if (!recoveryObserved) {
        releaseStagedGate(source, 1);
        engine->destroy();
        std::cerr << "FAIL: second gate=" << secondGateReached << " state=" << recovered.state
            << " underrun=" << recovered.underrun_active << '/' << recovered.underrun_frames << '\n';
        return fail("source recovery did not clear active underrun state before EOF");
    }
    const uint64_t framesAtRecovery = recovered.underrun_frames;

    releaseStagedGate(source, 1);
    bool ended = false;
    {
        std::unique_lock guard(events.mutex);
        ended = events.changed.wait_for(guard, std::chrono::seconds(10), [&] {
            return std::find(events.events.begin(), events.events.end(), LazerAudioEventEnded) !=
                events.events.end();
        });
    }
    LazerAudioSnapshot finished{};
    engine->snapshot(finished);
    int32_t failedEvents = 0;
    {
        std::lock_guard guard(events.mutex);
        failedEvents = static_cast<int32_t>(std::count(
            events.events.begin(), events.events.end(), LazerAudioEventFailed));
    }
    engine->destroy();

    if (!ended || failedEvents != 0 || finished.state != LazerAudioStateStopped ||
        finished.underrun_active != 0 || finished.underrun_frames != framesAtRecovery ||
        source.closeCount.load(std::memory_order_acquire) != 1) {
        std::cerr << "FAIL: underrun recovery/end ended=" << ended << " failedEvents=" << failedEvents
            << " state=" << finished.state << " active=" << finished.underrun_active
            << " frames=" << framesAtRecovery << " -> " << finished.underrun_frames
            << " close=" << source.closeCount.load(std::memory_order_acquire) << '\n';
        return fail("clean EOF changed underrun telemetry or failed to close the source");
    }
    std::cout << "PASS: source starvation counted " << framesAtRecovery
        << " padded frames, recovered before EOF, and ignored clean-EOF tail padding\n";
    return 0;
}

int runTerminalPublicationCase() {
    MemoryReader source(makePcm16Wave(kSampleRate, 2'000));
    MemoryReader replacement(makePcm16Wave(128, -2'000));
    const LazerAudioReader sourceReader = asReader(source);
    const LazerAudioReader replacementReader = asReader(replacement);
    ProbeEvents events;
    events.blockTerminalCallback = true;
    auto capture = std::make_shared<Capture>();
    capture->failWriteNumber = 2;

    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.exclusive = 1;
    config.device.buffer_millis = 120;
    config.events.on_event = onEvent;
    config.events.context = &events;
    Engine *engine = Engine::create(config, std::make_unique<CaptureOutput>(capture));
    if (engine == nullptr) return fail("terminal publication probe engine creation failed");

    const LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 1'000};
    if (engine->open(nullptr, &sourceReader, params) != LazerAudioOk) {
        engine->destroy();
        return fail("terminal publication probe source did not open");
    }
    if (engine->play() != LazerAudioOk) {
        engine->destroy();
        return fail("terminal publication probe output did not start");
    }

    bool callbackBlocked = false;
    {
        std::unique_lock guard(events.mutex);
        callbackBlocked = events.changed.wait_for(guard, std::chrono::seconds(5), [&] {
            return events.terminalCallbackEntered;
        });
    }
    if (!callbackBlocked) {
        {
            std::lock_guard guard(events.mutex);
            events.releaseTerminalCallback = true;
        }
        events.changed.notify_all();
        engine->destroy();
        return fail("simulated device loss did not enter its terminal callback");
    }

    /* Keep the callback blocked longer than the old 50 ms polling grace window. The terminal state
     * and its event record must already be visible while the callback is still running. */
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    LazerAudioSnapshot failed{};
    engine->snapshot(failed);
    bool correctSnapshot = failed.state == LazerAudioStateFailed &&
        failed.terminal_event == LazerAudioEventDeviceLost &&
        failed.terminal_detail == 0 && failed.terminal_position_millis > 0;
    {
        std::lock_guard guard(events.mutex);
        events.releaseTerminalCallback = true;
    }
    events.changed.notify_all();
    if (!correctSnapshot) {
        engine->destroy();
        std::cerr << "FAIL: terminal snapshot state=" << failed.state << " event="
            << failed.terminal_event << " detail=" << failed.terminal_detail << " position="
            << failed.terminal_position_millis << '\n';
        return fail("snapshot did not publish a coherent device-loss terminal record");
    }

    int32_t terminalEvents = 0;
    int64_t callbackPosition = 0;
    {
        std::lock_guard guard(events.mutex);
        terminalEvents = static_cast<int32_t>(std::count_if(events.events.begin(), events.events.end(),
            [](int32_t event) {
                return event == LazerAudioEventEnded || event == LazerAudioEventFailed ||
                    event == LazerAudioEventDeviceLost;
            }));
        callbackPosition = events.terminalPositionMillis;
    }
    if (terminalEvents != 1 || callbackPosition != failed.terminal_position_millis) {
        engine->destroy();
        return fail("terminal callback and snapshot position did not describe one winning failure");
    }

    MemoryReader invalidSource(std::vector<uint8_t>{'n', 'o', 't', '-', 'a', '-', 'm', 'e', 'd', 'i', 'a'});
    const LazerAudioReader invalidReader = asReader(invalidSource);
    if (engine->open(nullptr, &invalidReader, params) == LazerAudioOk) {
        engine->destroy();
        return fail("invalid source unexpectedly opened during terminal classification probe");
    }
    LazerAudioSnapshot genericFailure{};
    engine->snapshot(genericFailure);
    if (genericFailure.state != LazerAudioStateFailed ||
        genericFailure.terminal_event != LazerAudioEventFailed ||
        genericFailure.terminal_position_millis != 0) {
        engine->destroy();
        return fail("source-open failure did not publish a generic terminal record");
    }

    /* A new session clears the prior terminal record only after joining old worker threads. */
    if (engine->open(nullptr, &replacementReader, params) != LazerAudioOk) {
        engine->destroy();
        return fail("terminal publication probe replacement source did not open");
    }
    LazerAudioSnapshot reopened{};
    engine->snapshot(reopened);
    engine->destroy();
    if (reopened.state != LazerAudioStateReady || reopened.terminal_event != -1 ||
        reopened.terminal_position_millis != 0) {
        return fail("fresh session retained terminal metadata from the previous stream");
    }

    std::cout << "PASS: delayed callback retained device-loss type/position and fresh open cleared it\n";
    return 0;
}

int main() {
    if (runExistingFastGaplessCase() != 0) return 1;
    if (runUnderrunRecoveryCase() != 0) return 1;
    if (runTerminalPublicationCase() != 0) return 1;
    if (!runGatedCancellationCase(false)) return 1;
    if (!runGatedCancellationCase(true)) return 1;
    if (!runBlockedOpenCancellationCase()) return 1;
    return 0;
}
