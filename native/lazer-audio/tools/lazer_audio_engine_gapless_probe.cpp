/* End-to-end native Engine session test with a deterministic fake output. The two PCM WAV readers
 * cross one source EOF while retaining one fixed-period output session; the capture checks that the
 * boundary contributes no padded silence. */
#include "engine.h"

#include <algorithm>
#include <array>
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

std::vector<uint8_t> makeChannelMarkerWaveAt(bool rightChannel, uint16_t amplitude,
    int32_t sampleRate = kSampleRate, int32_t seconds = 2) {
    auto bytes = makePcm16Wave(sampleRate * seconds, 0);
    for (int shift = 0; shift < 32; shift += 8) {
        bytes[24 + shift / 8] = static_cast<uint8_t>(sampleRate >> shift);
        bytes[28 + shift / 8] = static_cast<uint8_t>((sampleRate * kFrameBytes) >> shift);
    }
    for (size_t frame = 0; frame < static_cast<size_t>(sampleRate * seconds); ++frame) {
        const size_t offset = 44 + frame * kFrameBytes;
        const uint16_t left = rightChannel ? 0 : amplitude;
        const uint16_t right = rightChannel ? amplitude : 0;
        bytes[offset] = static_cast<uint8_t>(left);
        bytes[offset + 1] = static_cast<uint8_t>(left >> 8);
        bytes[offset + 2] = static_cast<uint8_t>(right);
        bytes[offset + 3] = static_cast<uint8_t>(right >> 8);
    }
    return bytes;
}

std::vector<uint8_t> makeChannelMarkerWave(bool rightChannel, int32_t sampleRate = kSampleRate,
    int32_t seconds = 2) {
    return makeChannelMarkerWaveAt(rightChannel, 8192, sampleRate, seconds);
}

/* The AutoMix transition contract a probe has to predict, in closed form.
 *
 * The two decks cross on an equal-power curve, the incoming one carries the level match
 * (`correction` eases from the measured gain back to unity by the end of the overlap), and the bass
 * changes hands around the middle: each deck's low band is taken out while the other one owns it.
 * `bassAmount` is 0.75 for these fixtures: both are constant-amplitude markers, so all of their
 * energy sits in the low band and the clash is maximal. */
constexpr double kProbeBassAmount = 0.75;

double probeOutgoingSwap(double progress) {
    return progress >= 0.5
        ? 0.5 - 0.5 * std::cos(2.0 * 3.14159265358979323846 * (progress - 0.5)) : 0.0;
}

double probeIncomingSwap(double progress) {
    return progress < 0.5 ? std::sin(2.0 * 3.14159265358979323846 * progress) : 0.0;
}

double probeOutgoingLane(double marker, double progress) {
    return marker * std::cos(progress * 1.57079632679489661923) *
        (1.0 - kProbeBassAmount * probeOutgoingSwap(progress));
}

/* A click track: the marker, gated into short bursts every half second (120 BPM), starting at
 * `firstClickSeconds`. Used to give the transition planner a beat to align to. */
std::vector<uint8_t> makeClickTrack(bool rightChannel, double firstClickSeconds, int32_t seconds) {
    std::vector<uint8_t> wave = makeChannelMarkerWaveAt(rightChannel, 8192, kSampleRate, seconds);
    const int64_t frames = static_cast<int64_t>(seconds) * kSampleRate;
    constexpr double kBeatSeconds = 0.5;
    constexpr double kBurstSeconds = 0.05;
    for (int64_t frame = 0; frame < frames; ++frame) {
        const double at = static_cast<double>(frame) / kSampleRate;
        const double phase = std::fmod(at - firstClickSeconds, kBeatSeconds);
        if (phase >= 0.0 && phase < kBurstSeconds) continue;
        const size_t offset = 44 + static_cast<size_t>(frame) * kFrameBytes;
        for (int32_t byte = 0; byte < kFrameBytes && offset + byte < wave.size(); ++byte) {
            wave[offset + byte] = 0;
        }
    }
    return wave;
}

/* The frames where a channel's marker starts, which is where a click is. */
std::vector<int64_t> markerOnsets(const std::vector<uint8_t> &bytes, int32_t channel,
    int64_t from, int64_t to) {
    std::vector<int64_t> onsets;
    bool inside = false;
    for (int64_t frame = std::max<int64_t>(from, 0); frame < to; ++frame) {
        const size_t offset = static_cast<size_t>(frame) * kFrameBytes + channel * 2;
        if (offset + 1 >= bytes.size()) break;
        const int16_t value = static_cast<int16_t>(static_cast<uint16_t>(bytes[offset]) |
            (static_cast<uint16_t>(bytes[offset + 1]) << 8));
        const bool loud = std::abs(value) > 2000;
        if (loud && !inside) onsets.push_back(frame);
        inside = loud;
    }
    return onsets;
}

double probeIncomingLane(double marker, double progress, double correction) {
    return marker * correction * std::sin(progress * 1.57079632679489661923) *
        (1.0 - kProbeBassAmount * probeIncomingSwap(progress));
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
    std::atomic<int> closeCount{0};
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

struct SlowSuccessor {
    MemoryReader input{makeChannelMarkerWave(true, kSampleRate, 20)};
    const std::thread::id openingThread = std::this_thread::get_id();
    std::mutex mutex;
    std::condition_variable changed;
    bool released = false;
    bool cancelled = false;
    int64_t gateAfterBytes = 0;
    bool releaseRemainder = false;
};

LazerAudioReader asReader(SlowSuccessor &reader) {
    return LazerAudioReader{
        [](void *context, uint8_t *destination, int32_t length) -> int32_t {
            auto &slow = *static_cast<SlowSuccessor *>(context);
            std::unique_lock guard(slow.mutex);
            if (std::this_thread::get_id() != slow.openingThread) {
                slow.changed.wait(guard, [&] { return slow.released || slow.cancelled; });
                if (slow.gateAfterBytes > 0) {
                    slow.changed.wait(guard, [&] {
                        return slow.input.position < slow.gateAfterBytes ||
                            slow.releaseRemainder || slow.cancelled;
                    });
                    if (!slow.releaseRemainder && slow.input.position < slow.gateAfterBytes) {
                        length = static_cast<int32_t>(std::min<int64_t>(length,
                            slow.gateAfterBytes - slow.input.position));
                    }
                }
            }
            return slow.cancelled ? LAZER_AUDIO_READER_IO_ERROR :
                readBytes(&slow.input, destination, length);
        },
        [](void *context, int64_t position) -> int64_t {
            auto &slow = *static_cast<SlowSuccessor *>(context);
            return seekBytes(&slow.input, position);
        },
        [](void *context) -> int64_t {
            return readerLength(&static_cast<SlowSuccessor *>(context)->input);
        },
        [](void *context) { closeReader(&static_cast<SlowSuccessor *>(context)->input); },
        &reader,
        [](void *context) {
            auto &slow = *static_cast<SlowSuccessor *>(context);
            { std::lock_guard guard(slow.mutex); slow.cancelled = true; }
            slow.changed.notify_all();
        },
    };
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
    const std::atomic<int> *closeBeforeTrackChanged = nullptr;
    bool readerLifetimeOkay = true;
};

void onEvent(void *context, int32_t event, int32_t detail, int64_t positionMillis) {
    auto *events = static_cast<ProbeEvents *>(context);
    if (events == nullptr) return;
    if (event == LazerAudioEventTrackChanged && events->closeBeforeTrackChanged != nullptr &&
        events->closeBeforeTrackChanged->load(std::memory_order_acquire) != 1) {
        events->readerLifetimeOkay = false;
    }
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

int runAutoMixOverlapCase(bool resampledSuccessor) {
    MemoryReader first(makeChannelMarkerWave(false));
    MemoryReader second(makeChannelMarkerWave(true, resampledSuccessor ? 48'000 : kSampleRate));
    const auto firstReader = asReader(first);
    const auto secondReader = asReader(second);
    ProbeEvents events;
    events.closeBeforeTrackChanged = &first.closeCount;
    auto capture = std::make_shared<Capture>();
    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.exclusive = 1;
    config.device.bit_perfect = 1;  // AutoMix selects processed PCM on this same device.
    config.device.buffer_millis = 120;
    config.events.on_event = onEvent;
    config.events.context = &events;
    auto *engine = Engine::create(config, std::make_unique<CaptureOutput>(capture));
    if (engine == nullptr) return fail("AutoMix engine creation failed");
    const LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 2'000};
    if (engine->setAutoMix(500) != LazerAudioOk ||
        engine->open(nullptr, &firstReader, params) != LazerAudioOk ||
        engine->queueReader(1, secondReader, params) != LazerAudioOk ||
        engine->play() != LazerAudioOk) {
        engine->destroy();
        return fail("AutoMix PCM session did not prepare and start");
    }
    bool ended = false;
    {
        std::unique_lock guard(events.mutex);
        ended = events.changed.wait_for(guard, std::chrono::seconds(10), [&] {
            return std::find(events.events.begin(), events.events.end(), LazerAudioEventEnded) !=
                events.events.end();
        });
    }
    LazerAudioSnapshot snapshot{};
    engine->snapshot(snapshot);
    engine->destroy();
    if (!ended || snapshot.state != LazerAudioStateStopped) return fail("AutoMix session failed to end");
    constexpr int64_t overlap = kSampleRate / 2;
    constexpr int64_t start = kSampleRate * 3 / 2;
    constexpr int64_t actualFrames = kSampleRate * 4 - overlap;
    std::lock_guard guard(capture->mutex);
    if (capture->openCount != 1 || capture->startCount != 1 || capture->closeCount != 1) {
        return fail("AutoMix reopened or restarted the selected output device");
    }
    const int64_t capturedFrames = static_cast<int64_t>(capture->bytes.size() / kFrameBytes);
    if (capturedFrames < actualFrames || capturedFrames >= actualFrames + kPeriodFrames) {
        return fail("AutoMix did not consume the incoming prefix exactly once");
    }
    const auto sample = [&](int64_t frame, int channel) {
        const size_t offset = static_cast<size_t>(frame) * kFrameBytes + channel * 2;
        return static_cast<int16_t>(static_cast<uint16_t>(capture->bytes[offset]) |
            (static_cast<uint16_t>(capture->bytes[offset + 1]) << 8));
    };
    int bothMarkers = 0;
    for (int64_t frame = 0; frame < actualFrames - 64; ++frame) {
        const int left = sample(frame, 0);
        const int right = sample(frame, 1);
        if (std::abs(left) < 100 && std::abs(right) < 100) return fail("AutoMix inserted a silent gap");
        if (frame >= start && frame < kSampleRate * 2) {
            const double phase = static_cast<double>(frame - start) / (overlap - 1);
            if (std::abs(left - probeOutgoingLane(8192, phase)) > 5 ||
                std::abs(right - probeIncomingLane(8192, phase, 1.0)) > 5) {
                return fail("AutoMix output did not follow both equal-power overlap gains");
            }
            if (left > 1000 && right > 1000) ++bothMarkers;
        }
        if (frame > start && frame < kSampleRate * 2 + 64 &&
            (std::abs(left - sample(frame - 1, 0)) > 5 ||
             std::abs(right - sample(frame - 1, 1)) > 5)) {
            return fail("AutoMix introduced a gain jump at the overlap boundary");
        }
    }
    if (bothMarkers < overlap / 4 || snapshot.underrun_frames != 0 || !events.readerLifetimeOkay ||
        snapshot.position_millis != 2'000 ||
        std::count(events.events.begin(), events.events.end(), LazerAudioEventTrackChanged) != 1) {
        return fail("AutoMix did not present one continuous overlapping transition");
    }
    std::cout << "PASS: AutoMix mixed both channel markers for 500 ms on one output session"
        << (resampledSuccessor ? " across 44100/48000 Hz sources\n" : "\n");
    return 0;
}

int runAutoMixCancelAndSeekCase() {
    MemoryReader first(makeChannelMarkerWave(false));
    MemoryReader second(makeChannelMarkerWave(true));
    MemoryReader replacement(makeChannelMarkerWave(true));
    const auto firstReader = asReader(first);
    const auto secondReader = asReader(second);
    const auto replacementReader = asReader(replacement);
    ProbeEvents events;
    auto capture = std::make_shared<Capture>();
    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.exclusive = 1;
    config.device.buffer_millis = 120;
    config.events.on_event = onEvent;
    config.events.context = &events;
    auto *engine = Engine::create(config, std::make_unique<CaptureOutput>(capture));
    if (engine == nullptr) return fail("AutoMix cancellation engine creation failed");
    const LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 2'000};
    if (engine->setAutoMix(500) != LazerAudioOk ||
        engine->open(nullptr, &firstReader, params) != LazerAudioOk ||
        engine->queueReader(1, secondReader, params) != LazerAudioOk ||
        engine->play() != LazerAudioOk) {
        engine->destroy();
        return fail("AutoMix cancellation session did not start");
    }
    bool overlapAudible = false;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (std::chrono::steady_clock::now() < deadline) {
        {
            std::lock_guard guard(capture->mutex);
            overlapAudible = capture->bytes.size() / kFrameBytes >
                static_cast<size_t>(kSampleRate * 8 / 5);
        }
        if (overlapAudible) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    if (!overlapAudible || engine->pause() != LazerAudioOk ||
        engine->clearQueuedReader(2) != LazerAudioQueueCleared || second.closeCount != 1) {
        engine->destroy();
        return fail("an overlapping incoming reader was not synchronously cancelled and closed");
    }
    size_t pausedFrames = 0;
    {
        std::lock_guard guard(capture->mutex);
        pausedFrames = capture->bytes.size() / kFrameBytes;
    }
    if (engine->seek(250) != LazerAudioOk) {
        engine->destroy();
        return fail("AutoMix outgoing seek failed after cancelling an overlap");
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(25));
    bool paused = false;
    size_t resumeFrames = 0;
    {
        std::lock_guard guard(capture->mutex);
        resumeFrames = capture->bytes.size() / kFrameBytes;
        paused = resumeFrames <= pausedFrames + kPeriodFrames;
    }
    if (!paused || engine->queueReader(3, replacementReader, params) != LazerAudioOk ||
        engine->play() != LazerAudioOk) {
        engine->destroy();
        return fail("AutoMix paused source did not prepare a replacement and resume");
    }
    bool ended = false;
    {
        std::unique_lock guard(events.mutex);
        ended = events.changed.wait_for(guard, std::chrono::seconds(10), [&] {
            return std::find(events.events.begin(), events.events.end(), LazerAudioEventEnded) !=
                events.events.end();
        });
    }
    engine->destroy();
    if (!ended || first.closeCount != 1 || second.closeCount != 1 || replacement.closeCount != 1 ||
        std::count(events.events.begin(), events.events.end(), LazerAudioEventTrackChanged) != 1 ||
        std::count(events.events.begin(), events.events.end(), LazerAudioEventFailed) != 0) {
        return fail("cancel/seek/resume retained an incoming reader or published a stale transition");
    }
    {
        std::lock_guard guard(capture->mutex);
        constexpr size_t expectedFramesAfterSeek = kSampleRate * 13 / 4;
        const size_t framesAfterSeek = capture->bytes.size() / kFrameBytes - resumeFrames;
        if (framesAfterSeek < expectedFramesAfterSeek ||
            framesAfterSeek >= expectedFramesAfterSeek + kPeriodFrames) {
            return fail("AutoMix counted pre-seek or cancelled incoming samples in the replacement transition");
        }
    }
    std::cout << "PASS: paused AutoMix cancelled incoming PCM, sought outgoing and mixed a replacement\n";
    return 0;
}

int runAutoMixSlowSuccessorCase() {
    MemoryReader first(makeChannelMarkerWave(false, kSampleRate, 8));
    SlowSuccessor second;
    second.gateAfterBytes = 44 + static_cast<int64_t>(kSampleRate * 7 / 2) * kFrameBytes;
    const auto firstReader = asReader(first);
    const auto secondReader = asReader(second);
    ProbeEvents events;
    auto capture = std::make_shared<Capture>();
    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.exclusive = 1;
    config.device.buffer_millis = 120;
    config.events.on_event = onEvent;
    config.events.context = &events;
    auto *engine = Engine::create(config, std::make_unique<CaptureOutput>(capture));
    if (engine == nullptr) return fail("slow AutoMix engine creation failed");
    const LazerAudioOpenParams firstParams{sizeof(LazerAudioOpenParams), 0, 8'000};
    const LazerAudioOpenParams nextParams{sizeof(LazerAudioOpenParams), 0, 20'000};
    if (engine->setAutoMix(3'000) != LazerAudioOk ||
        engine->open(nullptr, &firstReader, firstParams) != LazerAudioOk ||
        engine->queueReader(1, secondReader, nextParams) != LazerAudioOk ||
        engine->play() != LazerAudioOk) {
        engine->destroy();
        return fail("slow AutoMix successor did not prepare");
    }
    bool reachedTail = false;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);
    while (std::chrono::steady_clock::now() < deadline) {
        {
            std::lock_guard guard(capture->mutex);
            reachedTail = capture->bytes.size() / kFrameBytes >
                static_cast<size_t>(kSampleRate * 15 / 2);
        }
        if (reachedTail) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    bool unchangedOutgoing = reachedTail;
    size_t outgoingFramesBeforeRelease = 0;
    {
        std::lock_guard guard(capture->mutex);
        outgoingFramesBeforeRelease = capture->bytes.size() / kFrameBytes;
        /* The first planned overlap frame is A's 5s mark. Everything before it must remain
         * full-gain even though the successor is still gated behind the network reader. */
        for (size_t offset = kSampleRate * 4 * kFrameBytes;
            offset + kFrameBytes <= capture->bytes.size(); offset += kFrameBytes) {
            if (offset >= static_cast<size_t>(kSampleRate * 5 * kFrameBytes)) break;
            const int left = static_cast<int16_t>(capture->bytes[offset] |
                (static_cast<uint16_t>(capture->bytes[offset + 1]) << 8));
            const int right = static_cast<int16_t>(capture->bytes[offset + 2] |
                (static_cast<uint16_t>(capture->bytes[offset + 3]) << 8));
            if (std::abs(left - 8192) > 2 || std::abs(right) > 2) unchangedOutgoing = false;
        }
    }
    { std::lock_guard guard(second.mutex); second.released = true; }
    second.changed.notify_all();
    bool handedOff = false;
    {
        std::unique_lock guard(events.mutex);
        handedOff = events.changed.wait_for(guard, std::chrono::seconds(20), [&] {
            return std::find(events.events.begin(), events.events.end(), LazerAudioEventTrackChanged) !=
                events.events.end();
        });
    }
    { std::lock_guard guard(second.mutex); second.releaseRemainder = true; }
    second.changed.notify_all();
    bool ended = false;
    {
        std::unique_lock guard(events.mutex);
        ended = events.changed.wait_for(guard, std::chrono::seconds(40), [&] {
            return std::find(events.events.begin(), events.events.end(), LazerAudioEventEnded) !=
                events.events.end();
        });
    }
    LazerAudioSnapshot snapshot{};
    engine->snapshot(snapshot);
    engine->destroy();
    if (!unchangedOutgoing || !handedOff || !ended || snapshot.underrun_frames != 0 ||
        std::count(events.events.begin(), events.events.end(), LazerAudioEventTrackChanged) != 1) {
        std::cerr << "slow successor: unchanged=" << unchangedOutgoing << " handoff=" << handedOff
            << " ended=" << ended << " underruns=" << snapshot.underrun_frames
            << " A-frames-before-release=" << outgoingFramesBeforeRelease << '\n';
        return fail("an unready incoming source faded or stalled the outgoing tail");
    }
    std::cout << "PASS: slow successor kept outgoing PCM at full gain until its entire overlap was ready\n";
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

/* The transition contract of the reference player this mixer follows: the incoming song joins at
 * its measured level relative to the outgoing one (not at whatever level it was mastered at), that
 * match eases back to unity before the hand-off, and the sum of two full-level songs is kept inside
 * full scale instead of clipping. */
int runAutoMixLevelMatchCase() {
    struct Case {
        uint16_t outgoingMarker;
        uint16_t incomingMarker;
        /* Level ratio to the outgoing side, before the clamp the contract allows. */
        double ratio;
    };
    const Case cases[] = {
        {8192, 2048, 4.0},
        {2048, 8192, 0.25},
        {30000, 30000, 1.0},
    };
    for (const Case &testCase : cases) {
        MemoryReader first(makeChannelMarkerWaveAt(false, testCase.outgoingMarker));
        MemoryReader second(makeChannelMarkerWaveAt(true, testCase.incomingMarker));
        const auto firstReader = asReader(first);
        const auto secondReader = asReader(second);
        ProbeEvents events;
        events.closeBeforeTrackChanged = &first.closeCount;
        auto capture = std::make_shared<Capture>();
        LazerAudioEngineConfig config{};
        config.abi_version = LAZER_AUDIO_ABI_VERSION;
        config.struct_size = sizeof(config);
        config.device.exclusive = 1;
        config.device.bit_perfect = 1;
        config.device.buffer_millis = 120;
        config.events.on_event = onEvent;
        config.events.context = &events;
        auto *engine = Engine::create(config, std::make_unique<CaptureOutput>(capture));
        if (engine == nullptr) return fail("AutoMix level-match engine creation failed");
        const LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 2'000};
        if (engine->setAutoMix(500) != LazerAudioOk ||
            engine->open(nullptr, &firstReader, params) != LazerAudioOk ||
            engine->queueReader(1, secondReader, params) != LazerAudioOk ||
            engine->play() != LazerAudioOk) {
            engine->destroy();
            return fail("AutoMix level-match session did not start");
        }
        bool ended = false;
        {
            std::unique_lock guard(events.mutex);
            ended = events.changed.wait_for(guard, std::chrono::seconds(10), [&] {
                return std::find(events.events.begin(), events.events.end(), LazerAudioEventEnded) !=
                    events.events.end();
            });
        }
        engine->destroy();
        if (!ended) return fail("AutoMix level-match session failed to end");

        constexpr int64_t overlap = kSampleRate / 2;
        constexpr int64_t start = kSampleRate * 3 / 2;
        std::lock_guard guard(capture->mutex);
        const auto sample = [&](int64_t frame, int channel) {
            const size_t offset = static_cast<size_t>(frame) * kFrameBytes + channel * 2;
            return static_cast<int16_t>(static_cast<uint16_t>(capture->bytes[offset]) |
                (static_cast<uint16_t>(capture->bytes[offset + 1]) << 8));
        };
        const double expectedGain = std::clamp(testCase.ratio, 0.5, 2.0);
        /* Two sources that are already near full scale must not sum past it: the peak guard is
         * what is under test there, and it folds both sides together, so only the ceiling is
         * asserted. The quieter pairs keep the guard idle and pin the level match itself. */
        const bool peakGuardCase = testCase.outgoingMarker >= 20'000;
        int64_t checked = 0;
        int64_t limited = 0;
        for (int64_t frame = start; frame < start + overlap - 32; ++frame) {
            /* After the measurement window and its ramp the correction is stable, so the shape of
             * the transition can be compared sample by sample. */
            const double progress = static_cast<double>(frame - start) / (overlap - 1);
            if (progress < 0.75) continue;
            const double left = sample(frame, 0);
            const double right = sample(frame, 1);
            if (std::abs(left) >= 32'000 || std::abs(right) >= 32'000) {
                return fail("AutoMix mixture reached full scale instead of limiting");
            }
            if (peakGuardCase) {
                if (std::abs(left) > 30'000 || std::abs(right) > 30'000) ++limited;
                continue;
            }
            const double outgoing = probeOutgoingLane(testCase.outgoingMarker, progress);
            const double correction = expectedGain + (1.0 - expectedGain) * progress;
            const double incoming =
                probeIncomingLane(testCase.incomingMarker, progress, correction);
            if (std::abs(left - outgoing) > 8 || std::abs(right - incoming) > 8) {
                std::cerr << "FAIL: AutoMix level match at frame " << frame << " progress "
                    << progress << ": left " << left << " (expected " << outgoing
                    << "), right " << right << " (expected " << incoming << ")\n";
                return fail("AutoMix did not match the incoming song's level to the outgoing one");
            }
            ++checked;
        }
        if (peakGuardCase) {
            if (limited == 0) return fail("AutoMix peak guard never engaged on two full-scale sources");
            continue;
        }
        if (checked == 0) return fail("AutoMix level match had no stable window to check");
        /* The match must be gone by the end of the overlap: the hand-off cannot step the level. */
        const double atHandoff = sample(start + overlap - 1, 1);
        if (std::abs(atHandoff - testCase.incomingMarker) > 400) {
            std::cerr << "FAIL: AutoMix hand-off level " << atHandoff << " for an incoming marker of "
                << testCase.incomingMarker << '\n';
            return fail("AutoMix left a level step at the hand-off");
        }
    }
    std::cout << "PASS: AutoMix matched the incoming level through the overlap and handed off at unity\n";
    return 0;
}


/* The incoming song's silent intro must not be mixed: overlapping dead air with the outgoing tail
 * is what makes a transition sound like a gap. The reference player's planner starts the incoming
 * deck after that silence, and so does this mixer. */
int runAutoMixSilentIntroCase() {
    /* Eight hundred milliseconds of silence, then the marker, on the right channel. */
    std::vector<uint8_t> incoming = makeChannelMarkerWaveAt(true, 8192);
    const size_t firstSample = 44;
    const size_t silentBytes = static_cast<size_t>(kSampleRate * 800 / 1000) * kFrameBytes;
    std::fill(incoming.begin() + static_cast<long>(firstSample),
        incoming.begin() + static_cast<long>(firstSample + silentBytes), 0);

    MemoryReader first(makeChannelMarkerWave(false));
    MemoryReader secondReader(incoming);
    const auto firstReader = asReader(first);
    const auto secondReaderRef = asReader(secondReader);
    ProbeEvents events;
    events.closeBeforeTrackChanged = &first.closeCount;
    auto capture = std::make_shared<Capture>();
    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.exclusive = 1;
    config.device.bit_perfect = 1;
    config.device.buffer_millis = 120;
    config.events.on_event = onEvent;
    config.events.context = &events;
    auto *engine = Engine::create(config, std::make_unique<CaptureOutput>(capture));
    if (engine == nullptr) return fail("AutoMix silent-intro engine creation failed");
    const LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 2'000};
    if (engine->setAutoMix(500) != LazerAudioOk ||
        engine->open(nullptr, &firstReader, params) != LazerAudioOk ||
        engine->queueReader(1, secondReaderRef, params) != LazerAudioOk ||
        engine->play() != LazerAudioOk) {
        engine->destroy();
        return fail("AutoMix silent-intro session did not start");
    }
    bool ended = false;
    {
        std::unique_lock guard(events.mutex);
        ended = events.changed.wait_for(guard, std::chrono::seconds(10), [&] {
            return std::find(events.events.begin(), events.events.end(), LazerAudioEventEnded) !=
                events.events.end();
        });
    }
    engine->destroy();
    if (!ended) return fail("AutoMix silent-intro session failed to end");

    constexpr int64_t overlap = kSampleRate / 2;
    constexpr int64_t start = kSampleRate * 3 / 2;
    std::lock_guard guard(capture->mutex);
    const auto sample = [&](int64_t frame, int channel) {
        const size_t offset = static_cast<size_t>(frame) * kFrameBytes + channel * 2;
        return static_cast<int16_t>(static_cast<uint16_t>(capture->bytes[offset]) |
            (static_cast<uint16_t>(capture->bytes[offset + 1]) << 8));
    };
    /* A quarter into the overlap the incoming song must already be playing: without the skip its
     * first 800 ms are silence, which would still cover this frame. */
    const int64_t probeFrame = start + overlap / 4;
    const double progress = static_cast<double>(probeFrame - start) / (overlap - 1);
    const double expectedRight = probeIncomingLane(8192, progress, 1.0);
    const double right = sample(probeFrame, 1);
    if (std::abs(right - expectedRight) > 8) {
        std::cerr << "FAIL: AutoMix incoming at the overlap's quarter: " << right
            << " (expected " << expectedRight << ")\n";
        return fail("AutoMix mixed the incoming song's silent intro instead of skipping it");
    }
    int64_t quiet = 0;
    for (int64_t frame = start; frame < start + overlap / 4; ++frame) {
        if (std::abs(sample(frame, 1)) < 50) ++quiet;
    }
    if (quiet > overlap / 8) {
        return fail("AutoMix left the incoming song silent through the first half of the overlap");
    }
    std::cout << "PASS: AutoMix skipped the incoming song's silent intro\n";
    return 0;
}


/* Two songs at the same tempo whose bars start at different moments. The planner has to start the
 * incoming one on its own beat *and* in phase with the outgoing one: without that the two kick
 * patterns fight for the whole overlap, which is the one thing a beat-aligned transition is for. */
int runAutoMixBeatAlignCase() {
    MemoryReader first(makeClickTrack(false, 0.0, 12));
    MemoryReader second(makeClickTrack(true, 0.25, 12));
    const auto firstReader = asReader(first);
    const auto secondReaderRef = asReader(second);
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
    auto *engine = Engine::create(config, std::make_unique<CaptureOutput>(capture));
    if (engine == nullptr) return fail("beat-align engine creation failed");
    const LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 12'000};
    if (engine->setAutoMix(3'000) != LazerAudioOk ||
        engine->open(nullptr, &firstReader, params) != LazerAudioOk ||
        engine->queueReader(1, secondReaderRef, params) != LazerAudioOk ||
        engine->play() != LazerAudioOk) {
        engine->destroy();
        return fail("beat-align session did not start");
    }
    bool ended = false;
    {
        std::unique_lock guard(events.mutex);
        ended = events.changed.wait_for(guard, std::chrono::seconds(40), [&] {
            return std::find(events.events.begin(), events.events.end(), LazerAudioEventEnded) !=
                events.events.end();
        });
    }
    engine->destroy();
    if (!ended) return fail("beat-align session failed to end");

    /* The overlap is the last three seconds of a twelve second track. */
    constexpr int64_t overlap = kSampleRate * 3;
    const int64_t start = kSampleRate * 9;
    std::lock_guard guard(capture->mutex);
    const std::vector<int64_t> outgoing = markerOnsets(capture->bytes, 0, start,
        start + overlap * 3 / 5);
    const std::vector<int64_t> incoming = markerOnsets(capture->bytes, 1, start,
        start + overlap * 3 / 5);
    if (outgoing.size() < 3 || incoming.size() < 3) {
        std::cerr << "FAIL: not enough clicks in the overlap: " << outgoing.size() << " and "
            << incoming.size() << "\n";
        return fail("the beat-align session did not place clicks in the overlap");
    }
    const int64_t tolerance = kSampleRate / 32;  /* 31 ms, about three analysis hops */
    int64_t entryError = INT64_MAX;
    int64_t worst = 0;
    for (size_t index = 0; index < incoming.size(); ++index) {
        int64_t nearest = INT64_MAX;
        for (int64_t other : outgoing) nearest = std::min(nearest, std::abs(other - incoming[index]));
        worst = std::max(worst, nearest);
        if (index == 0) entryError = nearest;
    }
    if (entryError > tolerance) {
        std::cerr << "FAIL: the incoming song's first click is " << entryError
            << " frames from the outgoing song's nearest one\n";
        return fail("the incoming song did not enter on the outgoing song's beat");
    }
    /* Both songs' tempos are estimated from a few seconds, so their grids drift apart by a few tens
     * of milliseconds across the overlap; holding them together for its whole length is what the
     * reference player's rate matching is for, and the engine does not resample the decks. */
    if (worst > tolerance * 4) {
        std::cerr << "FAIL: the two grids drift " << worst << " frames apart across the overlap\n";
        return fail("the incoming song's beats drifted off the outgoing song's");
    }
    std::cout << "PASS: AutoMix entered the incoming song on the outgoing song's beat (entry off by "
        << entryError << " frames, worst " << worst << ")\n";
    return 0;
}

int main(int argc, char **argv) {
    if (argc > 1 && std::string(argv[1]) == "--automix-slow") return runAutoMixSlowSuccessorCase();
    if (runExistingFastGaplessCase() != 0) return 1;
    if (runAutoMixOverlapCase(false) != 0) return 1;
    if (runAutoMixOverlapCase(true) != 0) return 1;
    if (runAutoMixLevelMatchCase() != 0) return 1;
    if (runAutoMixSilentIntroCase() != 0) return 1;
    if (runAutoMixBeatAlignCase() != 0) return 1;
    if (runAutoMixCancelAndSeekCase() != 0) return 1;
    if (runAutoMixSlowSuccessorCase() != 0) return 1;
    if (runUnderrunRecoveryCase() != 0) return 1;
    if (runTerminalPublicationCase() != 0) return 1;
    if (!runGatedCancellationCase(false)) return 1;
    if (!runGatedCancellationCase(true)) return 1;
    if (!runBlockedOpenCancellationCase()) return 1;
    return 0;
}
