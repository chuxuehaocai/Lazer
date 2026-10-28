/* Engine-level regression for the global RequireDoP policy. A fake endpoint checks that PCM
 * remains ordinary PCM, while raw stereo DSD is submitted as DoP across variable frame grants. */
#include "engine.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <memory>
#include <mutex>
#include <thread>
#include <utility>
#include <vector>

namespace {

using namespace lazer::audio;

constexpr int32_t kPcmRate = 44'100;
constexpr int32_t kStereo = 2;
constexpr int32_t kPcmFrameBytes = 4;
constexpr int32_t kDsdBitRate = 2'822'400;
constexpr int32_t kDsdBlockBytes = 4096;

void append16(std::vector<uint8_t> &bytes, uint16_t value) {
    bytes.push_back(static_cast<uint8_t>(value));
    bytes.push_back(static_cast<uint8_t>(value >> 8));
}

void append32(std::vector<uint8_t> &bytes, uint32_t value) {
    for (int shift = 0; shift < 32; shift += 8) {
        bytes.push_back(static_cast<uint8_t>(value >> shift));
    }
}

void append64(std::vector<uint8_t> &bytes, uint64_t value) {
    for (int shift = 0; shift < 64; shift += 8) {
        bytes.push_back(static_cast<uint8_t>(value >> shift));
    }
}

std::vector<uint8_t> makePcm16Wave(int32_t frameCount) {
    std::vector<uint8_t> bytes;
    const uint32_t payloadBytes = static_cast<uint32_t>(frameCount * kPcmFrameBytes);
    bytes.insert(bytes.end(), {'R', 'I', 'F', 'F'});
    append32(bytes, 36 + payloadBytes);
    bytes.insert(bytes.end(), {'W', 'A', 'V', 'E', 'f', 'm', 't', ' '});
    append32(bytes, 16);
    append16(bytes, 1);
    append16(bytes, kStereo);
    append32(bytes, kPcmRate);
    append32(bytes, kPcmRate * kPcmFrameBytes);
    append16(bytes, kPcmFrameBytes);
    append16(bytes, 16);
    bytes.insert(bytes.end(), {'d', 'a', 't', 'a'});
    append32(bytes, payloadBytes);
    for (int32_t frame = 0; frame < frameCount; ++frame) {
        const int16_t left = static_cast<int16_t>(-12'000 + (frame * 37) % 24'000);
        const int16_t right = static_cast<int16_t>(9'000 - (frame * 53) % 18'000);
        append16(bytes, static_cast<uint16_t>(left));
        append16(bytes, static_cast<uint16_t>(right));
    }
    return bytes;
}

std::vector<uint8_t> makeStereoDsf(uint64_t durationMillis = 100, uint8_t patternSalt = 0,
    uint64_t extraBytesPerChannel = 0, int32_t dsdBitRate = kDsdBitRate) {
    const uint64_t bitCount = static_cast<uint64_t>(dsdBitRate) * durationMillis / 1000 +
        extraBytesPerChannel * 8;
    const uint64_t audioBytesPerChannel = (bitCount + 7) / 8;
    const uint64_t blocks = (audioBytesPerChannel + kDsdBlockBytes - 1) / kDsdBlockBytes;
    const uint64_t paddedBytesPerChannel = blocks * kDsdBlockBytes;
    const uint64_t payloadBytes = paddedBytesPerChannel * kStereo;
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
    append32(bytes, 1);  // format version
    append32(bytes, 0);  // format ID
    append32(bytes, 2);  // stereo channel type
    append32(bytes, kStereo);
    append32(bytes, static_cast<uint32_t>(dsdBitRate));
    append32(bytes, 8);
    append64(bytes, bitCount);
    append32(bytes, kDsdBlockBytes);
    append32(bytes, 0);
    bytes.insert(bytes.end(), {'d', 'a', 't', 'a'});
    append64(bytes, dataChunkBytes);

    std::array<std::vector<uint8_t>, kStereo> channels;
    for (int32_t channel = 0; channel < kStereo; ++channel) {
        auto &samples = channels[static_cast<size_t>(channel)];
        samples.resize(static_cast<size_t>(paddedBytesPerChannel), 0x69);
        for (uint64_t index = 0; index < audioBytesPerChannel; ++index) {
            const bool first = ((index + static_cast<uint64_t>(channel) * 3) & 1u) == 0;
            const uint8_t even = channel == 0 ? 0xAA : 0x33;
            const uint8_t odd = channel == 0 ? 0x55 : 0xCC;
            samples[static_cast<size_t>(index)] = static_cast<uint8_t>(
                (first ? even : odd) ^ patternSalt);
        }
    }
    for (uint64_t block = 0; block < blocks; ++block) {
        const size_t offset = static_cast<size_t>(block * kDsdBlockBytes);
        for (int32_t channel = 0; channel < kStereo; ++channel) {
            const auto &samples = channels[static_cast<size_t>(channel)];
            bytes.insert(bytes.end(), samples.begin() + static_cast<std::ptrdiff_t>(offset),
                samples.begin() + static_cast<std::ptrdiff_t>(offset + kDsdBlockBytes));
        }
    }
    return bytes;
}

struct MemoryReader {
    explicit MemoryReader(std::vector<uint8_t> input) : bytes(std::move(input)) {}
    std::vector<uint8_t> bytes;
    int64_t position = 0;
    std::mutex gateMutex;
    std::condition_variable gateChanged;
    int64_t gatePosition = 0;
    bool gateEnabled = false;
    bool gateBlocked = false;
    bool releaseGate = false;
};

int32_t readBytes(void *opaque, uint8_t *destination, int32_t count) {
    auto *reader = static_cast<MemoryReader *>(opaque);
    if (reader == nullptr || destination == nullptr || count <= 0) return LAZER_AUDIO_READER_IO_ERROR;
    {
        std::unique_lock gate(reader->gateMutex);
        if (reader->gateEnabled && reader->position >= reader->gatePosition && !reader->releaseGate) {
            reader->gateBlocked = true;
            reader->gateChanged.notify_all();
            reader->gateChanged.wait(gate, [reader] { return reader->releaseGate; });
            reader->gateEnabled = false;
        }
    }
    const int64_t remaining = static_cast<int64_t>(reader->bytes.size()) - reader->position;
    if (remaining <= 0) return LAZER_AUDIO_READER_EOF;
    const int32_t copied = static_cast<int32_t>(std::min<int64_t>(remaining, count));
    std::memcpy(destination, reader->bytes.data() + reader->position, static_cast<size_t>(copied));
    reader->position += copied;
    return copied;
}

int64_t seekBytes(void *opaque, int64_t position) {
    auto *reader = static_cast<MemoryReader *>(opaque);
    if (reader == nullptr || position < 0 || position > static_cast<int64_t>(reader->bytes.size())) return -1;
    reader->position = position;
    return position;
}

int64_t readerLength(void *opaque) {
    const auto *reader = static_cast<const MemoryReader *>(opaque);
    return reader == nullptr ? -1 : static_cast<int64_t>(reader->bytes.size());
}

bool waitForReaderGate(MemoryReader &reader) {
    std::unique_lock gate(reader.gateMutex);
    return reader.gateChanged.wait_for(gate, std::chrono::seconds(5), [&reader] {
        return reader.gateBlocked;
    });
}

void releaseReaderGate(MemoryReader &reader) {
    {
        std::lock_guard gate(reader.gateMutex);
        reader.releaseGate = true;
    }
    reader.gateChanged.notify_all();
}

LazerAudioReader asReader(MemoryReader &reader) {
    return LazerAudioReader{readBytes, seekBytes, readerLength, nullptr, &reader, nullptr};
}

struct Events {
    std::mutex mutex;
    std::condition_variable changed;
    std::vector<int32_t> values;
};

class SourceDopCapture final : public SourceConsumer {
public:
    int32_t accept(const uint8_t *bytes, int32_t frameCount) override {
        if (bytes == nullptr || frameCount <= 0) return 0;
        const size_t byteCount = static_cast<size_t>(frameCount) * kStereo * 3;
        bytes_.insert(bytes_.end(), bytes, bytes + byteCount);
        return frameCount;
    }

    bool shouldPump() const override { return true; }
    bool isCancelled() const override { return false; }

    std::vector<uint8_t> bytes_;
};

bool collectSourceDoP(const std::vector<uint8_t> &dsf, std::vector<uint8_t> &carrierBytes) {
    MemoryReader reader(dsf);
    const LazerAudioReader input = asReader(reader);
    AudioSource source(nullptr);
    const LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 0};
    if (source.openReader(input, params) != LazerAudioOk) {
        std::cerr << "source expected-payload open error: " << source.lastError() << '\n';
        return false;
    }

    TargetFormat target;
    target.sampleRate = kDsdBitRate / 16;
    target.channels = kStereo;
    target.bitsPerSample = 24;
    target.containerBitsPerSample = 24;
    target.doP = true;
    if (source.setTargetFormat(target) != LazerAudioOk) {
        std::cerr << "source expected-payload format error: " << source.lastError() << '\n';
        return false;
    }

    SourceDopCapture capture;
    const int32_t result = source.pump(capture);
    if (result != LazerAudioOk || !source.reachedEndOfStream()) {
        std::cerr << "source expected-payload pump error: " << source.lastError() << '\n';
        return false;
    }
    carrierBytes = std::move(capture.bytes_);
    return carrierBytes.size() % (kStereo * 3) == 0;
}

void onEvent(void *opaque, int32_t event, int32_t, int64_t) {
    auto *events = static_cast<Events *>(opaque);
    if (events == nullptr) return;
    {
        std::lock_guard guard(events->mutex);
        events->values.push_back(event);
    }
    events->changed.notify_all();
}

struct Capture {
    std::mutex mutex;
    std::condition_variable changed;
    std::vector<uint8_t> bytes;
    std::vector<int32_t> writeFrames;
    int64_t idleDoPFrames = 0;
    AudioOutputRequest request{};
    AudioOutputSession session{};
    std::vector<AudioOutputRequest> requests;
    int32_t openCount = 0;
    bool opened = false;
    bool invalidWrite = false;
};

class VariableCaptureOutput final : public AudioOutput {
public:
    explicit VariableCaptureOutput(std::shared_ptr<Capture> capture, bool paceWrites = false)
        : capture_(std::move(capture)), paceWrites_(paceWrites) {}

    int32_t open(const AudioOutputRequest &request, const StreamDescription &source,
        AudioOutputSession &session, std::string &, LogProxy *) override {
        std::lock_guard guard(capture_->mutex);
        capture_->request = request;
        capture_->requests.push_back(request);
        ++capture_->openCount;
        session.target.sampleRate = request.requireDoP ? request.desired.sampleRate : source.sampleRate;
        session.target.channels = source.channels;
        session.target.bitsPerSample = request.requireDoP ? 24 : source.bitsPerSample;
        session.target.containerBitsPerSample = session.target.bitsPerSample;
        session.target.doP = request.requireDoP;
        session.engineFormat = {session.target.sampleRate, session.target.channels};
        session.formatSelection = request.requireDoP
            ? LazerAudioFormatSelectionDoPCarrier
            : LazerAudioFormatSelectionExclusiveSource;
        session.periodFrames = 64;
        session.bufferFrames = 64;
        session.writeMode = OutputWriteMode::Variable;
        session.exclusive = true;
        session.queueDepthAvailable = true;
        session.doP = request.requireDoP;
        sampleRate_ = session.target.sampleRate;
        capture_->session = session;
        capture_->opened = true;
        opened_ = true;
        return LazerAudioOk;
    }

    void close() override { opened_ = false; }
    int32_t start(std::string &) override { return LazerAudioOk; }
    int32_t stop(std::string &) override { return LazerAudioOk; }
    int32_t reset(std::string &) override { return LazerAudioOk; }

    OutputWaitResult waitForReady(int32_t, std::string &) override {
        std::this_thread::sleep_for(std::chrono::microseconds(200));
        return OutputWaitResult::Ready;
    }

    int32_t writableFrames(std::string &) override {
        if (!initialGrantIssued_) {
            /* Give the producer time to fill the ring before starting the deterministic capture. */
            initialGrantIssued_ = true;
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
        static constexpr std::array<int32_t, 8> grants{7, 31, 3, 11, 53, 5, 17, 29};
        return grants[grantIndex_++ % grants.size()];
    }

    int32_t queuedFrames(std::string &) override { return 0; }
    OutputDrainResult drain(std::string &) override { return OutputDrainResult::Drained; }

    int32_t write(const uint8_t *bytes, int32_t frames, std::string &) override {
        if (!opened_ || bytes == nullptr || frames <= 0) {
            std::lock_guard guard(capture_->mutex);
            capture_->invalidWrite = true;
            return LazerAudioErrorDevice;
        }
        const int32_t frameBytes = capture_->session.target.frameBytes();
        int64_t idleDoPFrames = 0;
        if (capture_->session.doP) {
            for (int32_t frame = 0; frame < frames; ++frame) {
                const uint8_t *carrier = bytes + static_cast<size_t>(frame) * 6;
                if (carrier[0] == 0x69 && carrier[1] == 0x69 &&
                    carrier[3] == 0x69 && carrier[4] == 0x69) {
                    ++idleDoPFrames;
                }
            }
        }
        {
            std::lock_guard guard(capture_->mutex);
            capture_->writeFrames.push_back(frames);
            capture_->idleDoPFrames += idleDoPFrames;
            capture_->bytes.insert(capture_->bytes.end(), bytes,
                bytes + static_cast<size_t>(frames) * static_cast<size_t>(frameBytes));
            capture_->changed.notify_all();
        }
        if (paceWrites_ && sampleRate_ > 0) {
            /* Variable frame grants must advance at the simulated carrier clock. An unpaced fake
             * endpoint can spin faster than the producer and invent underrun idle frames. */
            paceMicros_ += static_cast<int64_t>(frames) * 1'000'000 / sampleRate_;
            if (paceMicros_ >= 1'000) {
                const int64_t elapsedMicros = paceMicros_ / 1'000 * 1'000;
                paceMicros_ -= elapsedMicros;
                /* Batch sub-millisecond grants; Windows may round every individual sleep up to
                 * a millisecond, which would make a per-write delay far slower than the carrier. */
                std::this_thread::sleep_for(std::chrono::microseconds(elapsedMicros));
            }
        }
        return frames;
    }

    [[nodiscard]] bool isOpen() const noexcept override { return opened_; }

private:
    std::shared_ptr<Capture> capture_;
    size_t grantIndex_ = 0;
    bool initialGrantIssued_ = false;
    bool opened_ = false;
    bool paceWrites_ = false;
    int32_t sampleRate_ = 0;
    int64_t paceMicros_ = 0;
};

bool waitForEnd(Events &events) {
    std::unique_lock guard(events.mutex);
    return events.changed.wait_for(guard, std::chrono::seconds(10), [&events] {
        return std::find(events.values.begin(), events.values.end(), LazerAudioEventEnded) !=
                events.values.end() ||
            std::find(events.values.begin(), events.values.end(), LazerAudioEventFailed) !=
                events.values.end() ||
            std::find(events.values.begin(), events.values.end(), LazerAudioEventDeviceLost) !=
                events.values.end();
    }) && std::find(events.values.begin(), events.values.end(), LazerAudioEventEnded) !=
        events.values.end();
}

int fail(const char *message) {
    std::cerr << "FAIL: " << message << '\n';
    return 1;
}

int runPcmCase() {
    constexpr int32_t pcmFrames = 2048;
    MemoryReader reader(makePcm16Wave(pcmFrames));
    const std::vector<uint8_t> expected(reader.bytes.begin() + 44, reader.bytes.end());
    const LazerAudioReader input = asReader(reader);
    Events events;
    auto capture = std::make_shared<Capture>();

    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.exclusive = 1;
    config.device.bit_perfect = 1;
    config.device.buffer_millis = 600;
    config.device.dsd_output_mode = LazerAudioDsdOutputRequireDoP;
    config.events.on_event = onEvent;
    config.events.context = &events;
    Engine *engine = Engine::create(config, std::make_unique<VariableCaptureOutput>(capture));
    if (engine == nullptr) return fail("PCM engine creation failed");

    const LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 0};
    if (engine->open(nullptr, &input, params) != LazerAudioOk) {
        engine->destroy();
        return fail("PCM reader did not open with global RequireDoP policy");
    }
    LazerAudioStreamInfo info{};
    engine->streamInfo(info);
    if (info.output_format_kind != LazerAudioOutputFormatPcm || info.output_dsd_rate_multiplier != 0 ||
        info.output_format_selection != LazerAudioFormatSelectionExclusiveSource) {
        engine->destroy();
        return fail("global RequireDoP changed a PCM stream's format or selection metadata");
    }
    if (engine->play() != LazerAudioOk || !waitForEnd(events)) {
        engine->destroy();
        return fail("PCM engine session did not reach clean EOF");
    }
    engine->destroy();

    std::lock_guard guard(capture->mutex);
    if (!capture->opened || capture->request.requireDoP || capture->request.desired.doP ||
        capture->session.doP || capture->session.target.bitsPerSample != 16) {
        return fail("PCM was opened through the DoP endpoint contract");
    }
    if (capture->invalidWrite || capture->bytes != expected) {
        return fail("PCM payload was not preserved as exact 16-bit PCM");
    }
    if (capture->writeFrames.size() < 8 ||
        *std::max_element(capture->writeFrames.begin(), capture->writeFrames.end()) >= 256) {
        return fail("PCM endpoint did not receive varied partial frame grants");
    }
    std::cout << "PASS: global RequireDoP leaves PCM as bit-perfect PCM across variable frame grants\n";
    return 0;
}

int runDopCase() {
    MemoryReader reader(makeStereoDsf());
    const LazerAudioReader input = asReader(reader);
    Events events;
    auto capture = std::make_shared<Capture>();

    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.buffer_millis = 120;
    config.device.dsd_output_mode = LazerAudioDsdOutputRequireDoP;
    config.events.on_event = onEvent;
    config.events.context = &events;
    Engine *engine = Engine::create(config, std::make_unique<VariableCaptureOutput>(capture));
    if (engine == nullptr) return fail("DoP engine creation failed");

    const LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 0};
    if (engine->open(nullptr, &input, params) != LazerAudioOk) {
        std::cerr << "open error: " << engine->lastError() << '\n';
        engine->destroy();
        return fail("raw stereo DSD reader did not open with RequireDoP");
    }
    LazerAudioStreamInfo info{};
    engine->streamInfo(info);
    if (info.output_format_kind != LazerAudioOutputFormatDoP ||
        info.output_dsd_rate_multiplier != 64 ||
        info.output_format_selection != LazerAudioFormatSelectionDoPCarrier) {
        engine->destroy();
        return fail("raw DSD stream did not publish its DoP carrier format and selection metadata");
    }
    if (engine->play() != LazerAudioOk || !waitForEnd(events)) {
        std::cerr << "events=";
        for (int32_t event : events.values) std::cerr << ' ' << event;
        std::cerr << " error=" << engine->lastError() << '\n';
        engine->destroy();
        return fail("DoP engine session did not reach clean EOF");
    }
    engine->destroy();

    std::lock_guard guard(capture->mutex);
    if (!capture->opened || !capture->request.requireDoP || !capture->request.exclusive ||
        capture->request.desired.sampleRate != 176'400 ||
        capture->request.desired.channels != kStereo ||
        capture->request.desired.bitsPerSample != 24 ||
        !capture->request.desired.doP || !capture->session.doP || !capture->session.exclusive) {
        return fail("raw DSD did not negotiate the exact exclusive DoP carrier");
    }
    if (capture->invalidWrite || capture->bytes.empty() || capture->bytes.size() % 6 != 0) {
        return fail("DoP capture was empty or not a sequence of stereo 24-bit carrier frames");
    }
    if (capture->writeFrames.size() < 8 ||
        *std::max_element(capture->writeFrames.begin(), capture->writeFrames.end()) >= 256) {
        return fail("DoP endpoint did not receive varied partial frame grants");
    }

    const size_t carrierFrames = capture->bytes.size() / 6;
    size_t separatedFrames = 0;
    bool markersValid = true;
    for (size_t frame = 0; frame < carrierFrames; ++frame) {
        const uint8_t *left = capture->bytes.data() + frame * 6;
        const uint8_t *right = left + 3;
        const uint8_t expectedMarker = (frame & 1u) == 0 ? 0x05 : 0xFA;
        markersValid = markersValid && left[2] == expectedMarker && right[2] == expectedMarker;
        if (left[0] != right[0] || left[1] != right[1]) ++separatedFrames;
    }
    if (!markersValid) return fail("DoP markers were not synchronized and alternating across partial grants");
    if (separatedFrames < carrierFrames / 4) return fail("stereo DSD payload lost channel separation");
    std::cout << "PASS: stereo DSD produced " << carrierFrames
        << " DoP frames with synchronized alternating markers under variable frame grants\n";
    return 0;
}

bool dopPayloadMatchesInOrder(const std::vector<uint8_t> &captured,
    const std::vector<uint8_t> &first, const std::vector<uint8_t> &second) {
    constexpr size_t frameBytes = static_cast<size_t>(kStereo) * 3;
    if (first.size() % frameBytes != 0 || second.size() % frameBytes != 0 ||
        captured.size() != first.size() + second.size()) {
        std::cerr << "DoP gapless size mismatch: captured=" << captured.size() / frameBytes
            << " first=" << first.size() / frameBytes
            << " second=" << second.size() / frameBytes << " carrier frames\n";
        return false;
    }

    const size_t firstFrames = first.size() / frameBytes;
    const size_t totalFrames = captured.size() / frameBytes;
    for (size_t frame = 0; frame < totalFrames; ++frame) {
        const std::vector<uint8_t> &expected = frame < firstFrames ? first : second;
        const size_t expectedFrame = frame < firstFrames ? frame : frame - firstFrames;
        const size_t capturedOffset = frame * frameBytes;
        const size_t expectedOffset = expectedFrame * frameBytes;
        const uint8_t expectedMarker = (frame & 1u) == 0 ? 0x05 : 0xFA;
        for (size_t channel = 0; channel < static_cast<size_t>(kStereo); ++channel) {
            const size_t capturedSample = capturedOffset + channel * 3;
            const size_t expectedSample = expectedOffset + channel * 3;
            if (captured[capturedSample] != expected[expectedSample] ||
                captured[capturedSample + 1] != expected[expectedSample + 1] ||
                captured[capturedSample + 2] != expectedMarker) {
                std::cerr << "DoP gapless mismatch at frame=" << frame << " channel=" << channel
                    << " expected=" << static_cast<int>(expected[expectedSample]) << ','
                    << static_cast<int>(expected[expectedSample + 1]) << ','
                    << static_cast<int>(expectedMarker) << " captured="
                    << static_cast<int>(captured[capturedSample]) << ','
                    << static_cast<int>(captured[capturedSample + 1]) << ','
                    << static_cast<int>(captured[capturedSample + 2]) << '\n';
                return false;
            }
        }
    }
    return true;
}

int runDoPGaplessCase() {
    /* Odd DSD-byte counts make each source's final carrier frame leave the next source starting at
     * the opposite marker phase. Different source patterns make a lost, duplicated or swapped
     * payload at the boundary visible in the byte-for-byte capture. The 120 ms endpoint request
     * yields a 21,168-frame ring target, rounded up by RingBuffer to 32,768 frames. Keep the active
     * fixture beyond that actual capacity: open() starts its decoder pump before queueReader() is
     * called, and a shorter fixture can race to EOF and make queueing legitimately unavailable. */
    const std::vector<uint8_t> firstDsf = makeStereoDsf(201, 0x00, 1);
    const std::vector<uint8_t> secondDsf = makeStereoDsf(121, 0x96, 1);
    std::vector<uint8_t> firstExpected;
    std::vector<uint8_t> secondExpected;
    if (!collectSourceDoP(firstDsf, firstExpected) || !collectSourceDoP(secondDsf, secondExpected)) {
        return fail("could not construct independent DoP payload references for the queue case");
    }
    if (firstExpected.size() % 6 != 0 || secondExpected.size() % 6 != 0 ||
        firstExpected.size() / 6 % 2 == 0) {
        return fail("gapless DoP fixtures did not create an odd first-track carrier boundary");
    }

    MemoryReader first(firstDsf);
    MemoryReader second(secondDsf);
    const LazerAudioReader firstReader = asReader(first);
    const LazerAudioReader secondReader = asReader(second);
    Events events;
    auto capture = std::make_shared<Capture>();

    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.buffer_millis = 120;
    config.device.dsd_output_mode = LazerAudioDsdOutputRequireDoP;
    config.events.on_event = onEvent;
    config.events.context = &events;
    /* This case crosses the ring boundary, so pace the fake endpoint at the carrier clock. */
    Engine *engine = Engine::create(config, std::make_unique<VariableCaptureOutput>(capture, true));
    if (engine == nullptr) return fail("DoP gapless engine creation failed");

    const LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 0};
    if (engine->open(nullptr, &firstReader, params) != LazerAudioOk) {
        std::cerr << "gapless first open error: " << engine->lastError() << '\n';
        engine->destroy();
        return fail("first raw DSD track did not open for gapless DoP");
    }
    const int32_t queued = engine->queueReader(1, secondReader, params);
    if (queued != LazerAudioOk) {
        std::cerr << "DoP gapless queueReader error=" << queued << " engine="
            << engine->lastError() << '\n';
        engine->destroy();
        return fail("compatible raw DSD successor was not prepared in the active DoP session");
    }
    if (engine->play() != LazerAudioOk || !waitForEnd(events)) {
        std::cerr << "gapless DoP error: " << engine->lastError() << '\n';
        {
            std::lock_guard guard(capture->mutex);
            std::cerr << "gapless DoP captured=" << capture->bytes.size() / 6
                << " idle=" << capture->idleDoPFrames << " writes="
                << capture->writeFrames.size() << '\n';
        }
        {
            std::lock_guard guard(events.mutex);
            std::cerr << "gapless DoP events=";
            for (int32_t event : events.values) std::cerr << event << ',';
            std::cerr << '\n';
        }
        engine->destroy();
        return fail("DoP gapless session did not reach clean EOF");
    }
    engine->destroy();

    int32_t trackChanges = 0;
    int32_t ends = 0;
    {
        std::lock_guard guard(events.mutex);
        for (const int32_t event : events.values) {
            if (event == LazerAudioEventTrackChanged) ++trackChanges;
            if (event == LazerAudioEventEnded) ++ends;
            if (event == LazerAudioEventFailed || event == LazerAudioEventDeviceLost) {
                return fail("DoP gapless session reported an output or decode failure");
            }
        }
    }

    std::lock_guard guard(capture->mutex);
    if (capture->openCount != 1 || capture->requests.size() != 1 ||
        !capture->requests.front().requireDoP ||
        capture->requests.front().desired.sampleRate != kDsdBitRate / 16) {
        return fail("DoP gapless boundary reopened or changed the initialized carrier session");
    }
    if (capture->invalidWrite || trackChanges != 1 || ends != 1) {
        return fail("DoP gapless session did not publish one boundary and one clean end");
    }
    if (!dopPayloadMatchesInOrder(capture->bytes, firstExpected, secondExpected)) {
        std::cerr << "DoP gapless idle carrier frames=" << capture->idleDoPFrames << '\n';
        return fail("DoP gapless payload order or continuous marker phase changed at the track boundary");
    }
    std::cout << "PASS: raw stereo DSD crossed one DoP session with ordered payload and continuous markers\n";
    return 0;
}

int runDoPIncompatibleFallbackCase() {
    MemoryReader first(makeStereoDsf());
    MemoryReader incompatible(makeStereoDsf(100, 0, 0, kDsdBitRate * 2));
    const LazerAudioReader firstReader = asReader(first);
    const LazerAudioReader incompatibleReader = asReader(incompatible);
    Events events;
    auto capture = std::make_shared<Capture>();

    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.buffer_millis = 120;
    config.device.dsd_output_mode = LazerAudioDsdOutputRequireDoP;
    config.events.on_event = onEvent;
    config.events.context = &events;
    Engine *engine = Engine::create(config, std::make_unique<VariableCaptureOutput>(capture));
    if (engine == nullptr) return fail("DoP fallback engine creation failed");

    const LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 0};
    if (engine->open(nullptr, &firstReader, params) != LazerAudioOk) {
        engine->destroy();
        return fail("first raw DSD track did not open before the incompatible queue check");
    }
    if (engine->queueReader(1, incompatibleReader, params) != LazerAudioErrorUnsupported) {
        engine->destroy();
        return fail("a DSD128 successor was not rejected from an active DSD64 DoP carrier");
    }
    {
        std::lock_guard guard(capture->mutex);
        if (capture->openCount != 1 || capture->requests.size() != 1) {
            engine->destroy();
            return fail("an incompatible DoP successor changed the active output session");
        }
    }

    /* This is the same stop/open fallback the desktop controller uses after queueReader reports
     * incompatibility: renegotiate the endpoint for the new DSD multiplier, then play it normally. */
    if (engine->stop() != LazerAudioOk || engine->open(nullptr, &incompatibleReader, params) != LazerAudioOk) {
        std::cerr << "fallback reopen error: " << engine->lastError() << '\n';
        engine->destroy();
        return fail("normal DoP re-open did not accept the incompatible DSD128 successor");
    }
    if (engine->play() != LazerAudioOk || !waitForEnd(events)) {
        std::cerr << "fallback playback error: " << engine->lastError() << '\n';
        engine->destroy();
        return fail("normal DoP fallback session did not reach clean EOF");
    }
    engine->destroy();

    int32_t trackChanges = 0;
    {
        std::lock_guard guard(events.mutex);
        for (const int32_t event : events.values) {
            if (event == LazerAudioEventTrackChanged) ++trackChanges;
        }
    }
    std::lock_guard guard(capture->mutex);
    if (capture->openCount != 2 || capture->requests.size() != 2 ||
        capture->requests[1].desired.sampleRate != kDsdBitRate / 8 || trackChanges != 0) {
        return fail("incompatible DSD did not use a fresh DoP carrier session without a gapless event");
    }
    std::cout << "PASS: incompatible DSD rate was rejected for queueing and played after carrier re-open\n";
    return 0;
}

int runDoPIdlePositionCase() {
    MemoryReader reader(makeStereoDsf(2'000));
    const LazerAudioReader input = asReader(reader);
    Events events;
    auto capture = std::make_shared<Capture>();

    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.buffer_millis = 120;
    config.device.dsd_output_mode = LazerAudioDsdOutputRequireDoP;
    config.events.on_event = onEvent;
    config.events.context = &events;
    Engine *engine = Engine::create(config, std::make_unique<VariableCaptureOutput>(capture));
    if (engine == nullptr) return fail("DoP idle-position engine creation failed");

    const LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 0};
    if (engine->open(nullptr, &input, params) != LazerAudioOk) {
        engine->destroy();
        return fail("long raw DSD reader did not open for idle-position test");
    }
    {
        std::lock_guard gate(reader.gateMutex);
        reader.gatePosition = reader.position;
        reader.gateEnabled = true;
    }
    if (engine->play() != LazerAudioOk) {
        releaseReaderGate(reader);
        engine->destroy();
        return fail("DoP idle-position stream did not start");
    }

    const bool readerBlocked = waitForReaderGate(reader);
    bool observedIdle = false;
    if (readerBlocked) {
        std::unique_lock guard(capture->mutex);
        observedIdle = capture->changed.wait_for(guard, std::chrono::seconds(5), [&capture] {
            return capture->idleDoPFrames >= 64;
        });
    }
    bool positionStable = false;
    if (readerBlocked && observedIdle) {
        LazerAudioSnapshot before{};
        engine->snapshot(before);
        std::this_thread::sleep_for(std::chrono::milliseconds(80));
        LazerAudioSnapshot after{};
        engine->snapshot(after);
        positionStable = after.position_millis <= before.position_millis + 1;
    }

    releaseReaderGate(reader);
    const bool cleanEnd = waitForEnd(events);
    engine->destroy();
    if (!readerBlocked) return fail("reader did not reach the deterministic source stall");
    if (!observedIdle) return fail("DoP endpoint did not emit idle carriers during the source stall");
    if (!positionStable) return fail("DoP idle carriers incorrectly advanced source position");
    if (!cleanEnd) return fail("DoP idle-position stream did not finish cleanly after reader resumed");
    std::cout << "PASS: DoP idle carriers keep device lock without advancing source position\n";
    return 0;
}

}  // namespace

namespace lazer::audio {
std::unique_ptr<AudioOutput> createPlatformAudioOutput() { return nullptr; }
}  // namespace lazer::audio

int main() {
    if (runPcmCase() != 0) return 1;
    if (runDopCase() != 0) return 1;
    if (runDoPGaplessCase() != 0) return 1;
    if (runDoPIncompatibleFallbackCase() != 0) return 1;
    if (runDoPIdlePositionCase() != 0) return 1;
    return 0;
}
