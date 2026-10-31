/* Stress test for the output ring and the producer's watermark policy.
 *
 * The engine's render thread must never be the reason a sample is late, and a late decode must show
 * up as a counted, explainable underrun rather than as silence nobody notices. This probe drives the
 * engine with a synthetic long stream through a *paced* fake endpoint that consumes at a device-like
 * rate, so the whole producer -> ring -> render path runs the way it does against WASAPI in shared
 * mode. Two cases:
 *
 *   1. clean run     — the producer keeps up; underruns must be exactly zero.
 *   2. stalled run   — the endpoint stops consuming for longer than the ring can cover; the padded
 *                      frames must be counted, bounded by the stall, and the state must recover.
 *
 * It also asserts the published watermarks are sane and that the ring never exceeds its capacity. */
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

constexpr int32_t kSampleRate = 44'100;
constexpr int32_t kChannels = 2;
constexpr int32_t kBits = 16;
constexpr int32_t kPeriodFrames = 512;
/* ~40 s of audio: long enough that a per-block cost would show up, short enough to run offline. */
constexpr int32_t kSourceFrames = kSampleRate * 40;
/* Device queue the fake endpoint exposes to the engine's render thread. */
constexpr int32_t kDeviceQueueFrames = kPeriodFrames * 8;

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

std::vector<uint8_t> makePcmWave(int32_t frames) {
    const int32_t bytesPerSample = kBits / 8;
    const int32_t frameBytes = kChannels * bytesPerSample;
    const uint32_t dataBytes = static_cast<uint32_t>(frames * frameBytes);
    std::vector<uint8_t> bytes;
    bytes.reserve(44 + static_cast<size_t>(dataBytes));
    bytes.insert(bytes.end(), {'R', 'I', 'F', 'F'});
    append32(bytes, 36u + dataBytes);
    bytes.insert(bytes.end(), {'W', 'A', 'V', 'E', 'f', 'm', 't', ' '});
    append32(bytes, 16);
    append16(bytes, 1);
    append16(bytes, kChannels);
    append32(bytes, kSampleRate);
    append32(bytes, static_cast<uint32_t>(kSampleRate * frameBytes));
    append16(bytes, static_cast<uint16_t>(frameBytes));
    append16(bytes, kBits);
    bytes.insert(bytes.end(), {'d', 'a', 't', 'a'});
    append32(bytes, dataBytes);
    for (int32_t frame = 0; frame < frames; ++frame) {
        const int16_t value = static_cast<int16_t>(
            static_cast<int32_t>(std::lround(12'000.0 * std::sin(frame * 0.05))));
        for (int32_t channel = 0; channel < kChannels; ++channel) {
            append16(bytes, static_cast<uint16_t>(value));
        }
    }
    return bytes;
}

struct MemoryReader {
    explicit MemoryReader(std::vector<uint8_t> value) : bytes(std::move(value)) {}
    std::vector<uint8_t> bytes;
    int64_t position = 0;
    /* Producer-side stall: the decoder stops delivering bytes for a while, which is what actually
     * starves the device. Stalling the endpoint instead would only stop the engine from writing. */
    int64_t stallAtBytes = -1;
    int32_t stallMillis = 0;
    bool stalled = false;
};

int32_t readBytes(void *context, uint8_t *destination, int32_t length) {
    auto *reader = static_cast<MemoryReader *>(context);
    if (reader == nullptr || destination == nullptr || length <= 0) return LAZER_AUDIO_READER_IO_ERROR;
    if (!reader->stalled && reader->stallMillis > 0 && reader->stallAtBytes >= 0 &&
        reader->position >= reader->stallAtBytes) {
        reader->stalled = true;
        std::this_thread::sleep_for(std::chrono::milliseconds(reader->stallMillis));
    }
    const int64_t remaining = static_cast<int64_t>(reader->bytes.size()) - reader->position;
    if (remaining <= 0) return LAZER_AUDIO_READER_EOF;
    const int32_t count = static_cast<int32_t>(std::min<int64_t>(remaining, length));
    std::memcpy(destination, reader->bytes.data() + reader->position, static_cast<size_t>(count));
    reader->position += count;
    return count;
}

int64_t seekBytes(void *context, int64_t position) {
    auto *reader = static_cast<MemoryReader *>(context);
    if (reader == nullptr || position < 0 || position > static_cast<int64_t>(reader->bytes.size())) {
        return -1;
    }
    reader->position = position;
    return position;
}

int64_t readerLength(void *context) {
    const auto *reader = static_cast<MemoryReader *>(context);
    return reader == nullptr ? -1 : static_cast<int64_t>(reader->bytes.size());
}

void closeReader(void *) {}

LazerAudioReader asReader(MemoryReader &reader) {
    return LazerAudioReader{readBytes, seekBytes, readerLength, closeReader, &reader};
}

struct Events {
    std::mutex mutex;
    std::condition_variable changed;
    std::vector<int32_t> events;
};

void onEvent(void *context, int32_t event, int32_t, int64_t) {
    auto *events = static_cast<Events *>(context);
    if (events == nullptr) return;
    {
        std::lock_guard guard(events->mutex);
        events->events.push_back(event);
    }
    events->changed.notify_all();
}

/* A device that consumes fixed periods on its own clock. `stallAfterPeriods`/`stallMicros` inject a
 * single long stall, which is what a driver hiccup or a busy endpoint looks like to the engine. */
class PacedOutput final : public AudioOutput {
public:
    PacedOutput(int32_t periodMicros, int32_t stallAfterPeriods, int32_t stallMicros)
        : periodMicros_(periodMicros), stallAfterPeriods_(stallAfterPeriods),
          stallMicros_(stallMicros) {}

    int32_t open(const AudioOutputRequest &, const StreamDescription &source,
        AudioOutputSession &session, std::string &, LogProxy *) override {
        session.target.sampleRate = source.sampleRate;
        session.target.channels = source.channels;
        session.target.bitsPerSample = source.bitsPerSample;
        session.target.containerBitsPerSample = source.bitsPerSample;
        session.engineFormat = {source.sampleRate, source.channels};
        session.formatSelection = LazerAudioFormatSelectionSharedMix;
        session.periodFrames = kPeriodFrames;
        session.bufferFrames = kDeviceQueueFrames;
        session.exclusive = false;
        session.writeMode = OutputWriteMode::Variable;
        session.queueDepthAvailable = true;
        bytesPerFrame_ = session.target.frameBytes();
        submittedFrames_.store(0);
        consumedFrames_.store(0);
        periods_ = 0;
        open_ = true;
        return LazerAudioOk;
    }

    void close() override { open_ = false; }
    int32_t start(std::string &) override { return LazerAudioOk; }
    int32_t stop(std::string &) override { return LazerAudioOk; }
    int32_t reset(std::string &) override { return LazerAudioOk; }

    OutputWaitResult waitForReady(int32_t, std::string &) override {
        /* One device period of simulated time; the stall case pays it all at once. */
        ++periods_;
        const bool stalling = stallAfterPeriods_ > 0 && periods_ >= stallAfterPeriods_ &&
            periods_ < stallAfterPeriods_ + stallMicros_ / std::max(periodMicros_, 1);
        if (stalling) {
            if (!stallCounted_) {
                stallCounted_ = true;
                std::this_thread::sleep_for(std::chrono::microseconds(stallMicros_));
            }
            return OutputWaitResult::Ready;
        }
        std::this_thread::sleep_for(std::chrono::microseconds(periodMicros_));
        consumedFrames_.fetch_add(kPeriodFrames, std::memory_order_acq_rel);
        return OutputWaitResult::Ready;
    }

    int32_t writableFrames(std::string &) override {
        const int64_t outstanding = submittedFrames_.load(std::memory_order_acquire) -
            consumedFrames_.load(std::memory_order_acquire);
        return static_cast<int32_t>(std::max<int64_t>(kDeviceQueueFrames - outstanding, 0));
    }

    int32_t queuedFrames(std::string &) override {
        return static_cast<int32_t>(std::max<int64_t>(
            submittedFrames_.load(std::memory_order_acquire) -
                consumedFrames_.load(std::memory_order_acquire), 0));
    }

    OutputDrainResult drain(std::string &) override { return OutputDrainResult::Drained; }

    int32_t write(const uint8_t *bytes, int32_t frames, std::string &) override {
        if (bytes == nullptr || frames <= 0 || bytesPerFrame_ <= 0) return LazerAudioErrorDevice;
        submittedFrames_.fetch_add(frames, std::memory_order_acq_rel);
        return frames;
    }

    [[nodiscard]] bool isOpen() const noexcept override { return open_; }

private:
    int32_t periodMicros_ = 0;
    int32_t stallAfterPeriods_ = 0;
    int32_t stallMicros_ = 0;
    int32_t bytesPerFrame_ = 0;
    int32_t periods_ = 0;
    bool stallCounted_ = false;
    bool open_ = false;
    std::atomic<int64_t> submittedFrames_{0};
    std::atomic<int64_t> consumedFrames_{0};
};

struct RunResult {
    bool reachedEnd = false;
    uint64_t underrunFrames = 0;
    bool underrunActiveAtEnd = false;
    int64_t peakFill = 0;
    int32_t capacity = 0;
    int32_t lowMark = 0;
    int32_t highMark = 0;
    int32_t renderedFrames = 0;
    std::string error;
};

bool runStress(int32_t stallMicros, RunResult &result) {
    MemoryReader source(makePcmWave(kSourceFrames));
    LazerAudioReader reader = asReader(source);
    Events events;

    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.exclusive = 0;
    config.device.bit_perfect = 0;
    config.device.buffer_millis = 60;
    config.events.on_event = onEvent;
    config.events.context = &events;

    /* 512 frames per period at 44.1 kHz is 11.6 ms of audio; consuming it in 200 us runs the whole
     * pipeline about 58x faster than real time while keeping the same back-pressure shape. */
    constexpr int32_t periodMicros = 200;
    if (stallMicros > 0) {
        source.stallAtBytes = static_cast<int64_t>(source.bytes.size()) * 2 / 5;
        source.stallMillis = stallMicros / 1000;
    }
    Engine *engine = Engine::create(config, std::make_unique<PacedOutput>(periodMicros, 0, 0));
    if (engine == nullptr) {
        result.error = "Engine::create failed";
        return false;
    }
    const LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 0, 0, 0};
    const int32_t openResult = engine->open(nullptr, &reader, params);
    if (openResult != LazerAudioOk) {
        result.error = "open failed: " + engine->lastError();
        engine->destroy();
        return false;
    }
    if (engine->play() != LazerAudioOk) {
        result.error = "play failed: " + engine->lastError();
        engine->destroy();
        return false;
    }

    LazerAudioSnapshot snapshot{};
    bool ended = false;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(120);
    int64_t lastPosition = -1;
    int64_t stalledSince = 0;
    while (std::chrono::steady_clock::now() < deadline) {
        engine->snapshot(snapshot);
        result.peakFill = std::max<int64_t>(result.peakFill, snapshot.ring_fill_frames);
        result.capacity = snapshot.ring_capacity_frames;
        result.lowMark = snapshot.ring_low_watermark_frames;
        result.highMark = snapshot.ring_high_watermark_frames;
        if (snapshot.position_millis == lastPosition) {
            if (stalledSince == 0) stalledSince = snapshot.position_millis;
        } else {
            stalledSince = 0;
            lastPosition = snapshot.position_millis;
        }
        bool terminal = false;
        {
            std::lock_guard guard(events.mutex);
            terminal = std::find(events.events.begin(), events.events.end(),
                LazerAudioEventEnded) != events.events.end();
        }
        if (terminal) {
            ended = true;
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    engine->snapshot(snapshot);
    result.underrunFrames = snapshot.underrun_frames;
    result.underrunActiveAtEnd = snapshot.underrun_active != 0;
    result.renderedFrames = static_cast<int32_t>(snapshot.position_millis);
    result.peakFill = std::max<int64_t>(result.peakFill, snapshot.ring_fill_frames);
    if (!ended) result.error = "playback did not finish";
    engine->stop();
    engine->destroy();
    result.reachedEnd = ended;
    return ended;
}

}  // namespace

namespace lazer::audio {
std::unique_ptr<AudioOutput> createPlatformAudioOutput() { return nullptr; }
}  // namespace lazer::audio

int main() {
    bool ok = true;

    /* Case 1: a producer that keeps up must not underrun at all. */
    RunResult clean;
    if (!runStress(0, clean)) {
        std::cerr << "FAIL: clean run: " << clean.error << "\n";
        return 1;
    }
    if (clean.underrunFrames != 0 || clean.underrunActiveAtEnd) {
        std::cerr << "FAIL: clean run reported " << clean.underrunFrames
            << " padded frames with no stall injected\n";
        ok = false;
    }
    if (clean.lowMark <= 0 || clean.highMark <= clean.lowMark || clean.highMark > clean.capacity) {
        std::cerr << "FAIL: watermarks are " << clean.lowMark << "/" << clean.highMark
            << " for a " << clean.capacity << "-frame ring\n";
        ok = false;
    }
    if (clean.peakFill > clean.capacity || clean.highMark <= 0) {
        std::cerr << "FAIL: ring fill reached " << clean.peakFill << " of " << clean.capacity << "\n";
        ok = false;
    }
    if (ok) {
        std::cout << "PASS: 40 s through a paced endpoint with no stall: 0 padded frames, fill peak "
            << clean.peakFill << "/" << clean.capacity << ", watermarks "
            << clean.lowMark << "/" << clean.highMark << "\n";
    }

    /* Case 2: a stall longer than the ring can cover must be counted, bounded and recovered from. */
    constexpr int32_t stallMillis = 800;
    constexpr int32_t stallMicros = stallMillis * 1000;
    RunResult stalled;
    if (!runStress(stallMicros, stalled)) {
        std::cerr << "FAIL: stalled run: " << stalled.error << "\n";
        return 1;
    }
    const int64_t ringCoverMillis = stalled.capacity * 1000LL / kSampleRate;
    const int64_t explainable = static_cast<int64_t>(stallMicros) * kSampleRate / 1'000'000;
    if (stalled.underrunFrames == 0) {
        std::cerr << "FAIL: a " << stallMillis << " ms stall produced no underrun at all\n";
        ok = false;
    } else if (static_cast<int64_t>(stalled.underrunFrames) > explainable) {
        std::cerr << "FAIL: " << stalled.underrunFrames << " padded frames exceed the "
            << explainable << " frames the injected stall can explain\n";
        ok = false;
    } else if (stalled.underrunActiveAtEnd) {
        std::cerr << "FAIL: the session was still starving after the stall ended\n";
        ok = false;
    } else {
        std::cout << "PASS: a " << stallMillis << " ms stall (ring covers ~" << ringCoverMillis
            << " ms) produced " << stalled.underrunFrames << " padded frames, bounded by the stall, "
            << "and recovered\n";
    }
    return ok ? 0 : 1;
}
