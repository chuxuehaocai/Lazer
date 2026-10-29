/* Offline Engine-level regression for the Linux Native DSD session contract. A fake endpoint
 * verifies the exact direct request and initialized DSD clock without requiring ALSA hardware. */
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
#include <thread>
#include <utility>
#include <vector>

namespace {

using namespace lazer::audio;

constexpr int32_t kDsdByteClock = 352'800; // DSD64 / 8
constexpr int32_t kNativeDsdRate = 88'200; // U32 words at the DSD byte clock
constexpr int32_t kStereo = 2;
constexpr int32_t kNativeFrameBytes = kStereo * 4;
constexpr int32_t kDsfBlockBytes = 4096;
constexpr std::array<uint8_t, kNativeFrameBytes> kExpectedFirstFrame{
    0xAA, 0x55, 0xAA, 0x55, 0x33, 0xCC, 0x33, 0xCC,
};

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

uint8_t dsdPatternByte(int32_t channel, uint64_t index, uint8_t seed) {
    if (seed == 0) {
        const uint8_t even = channel == 0 ? 0xAA : 0x33;
        const uint8_t odd = channel == 0 ? 0x55 : 0xCC;
        return (index & 1u) == 0 ? even : odd;
    }
    return static_cast<uint8_t>(seed + channel * 53 + index * 17);
}

std::vector<uint8_t> makeStereoDsf(uint64_t durationMillis = 1000, uint8_t seed = 0,
    int32_t multiplier = 64) {
    const uint64_t dsdByteClock = static_cast<uint64_t>(44'100) * multiplier / 8;
    const uint64_t bitCount = dsdByteClock * 8 * durationMillis / 1000;
    const uint64_t audioBytesPerChannel = (bitCount + 7) / 8;
    const uint64_t blocks = (audioBytesPerChannel + kDsfBlockBytes - 1) / kDsfBlockBytes;
    const uint64_t paddedBytesPerChannel = blocks * kDsfBlockBytes;
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
    append32(bytes, 1); // format version
    append32(bytes, 0); // raw DSD
    append32(bytes, 2); // stereo channel type
    append32(bytes, kStereo);
    append32(bytes, static_cast<uint32_t>(dsdByteClock * 8)); // DSD bit rate in DSF metadata
    append32(bytes, 8); // MSB first
    append64(bytes, bitCount);
    append32(bytes, kDsfBlockBytes);
    append32(bytes, 0);
    bytes.insert(bytes.end(), {'d', 'a', 't', 'a'});
    append64(bytes, dataChunkBytes);

    std::array<std::vector<uint8_t>, kStereo> channels;
    for (int32_t channel = 0; channel < kStereo; ++channel) {
        auto &samples = channels[static_cast<size_t>(channel)];
        samples.resize(static_cast<size_t>(paddedBytesPerChannel), 0x69);
        for (uint64_t index = 0; index < audioBytesPerChannel; ++index) {
            samples[static_cast<size_t>(index)] = dsdPatternByte(channel, index, seed);
        }
    }
    for (uint64_t block = 0; block < blocks; ++block) {
        const size_t offset = static_cast<size_t>(block * kDsfBlockBytes);
        for (int32_t channel = 0; channel < kStereo; ++channel) {
            const auto &samples = channels[static_cast<size_t>(channel)];
            bytes.insert(bytes.end(), samples.begin() + static_cast<std::ptrdiff_t>(offset),
                samples.begin() + static_cast<std::ptrdiff_t>(offset + kDsfBlockBytes));
        }
    }
    return bytes;
}

std::vector<uint8_t> makeStereoPcmWav() {
    constexpr uint32_t sampleRate = 44'100;
    constexpr uint16_t channels = 2;
    constexpr uint16_t bitsPerSample = 16;
    constexpr uint32_t frameCount = 4'410;
    constexpr uint32_t dataBytes = frameCount * channels * (bitsPerSample / 8);
    std::vector<uint8_t> bytes;
    bytes.reserve(44 + dataBytes);
    bytes.insert(bytes.end(), {'R', 'I', 'F', 'F'});
    append32(bytes, 36 + dataBytes);
    bytes.insert(bytes.end(), {'W', 'A', 'V', 'E', 'f', 'm', 't', ' '});
    append32(bytes, 16);
    append16(bytes, 1);
    append16(bytes, channels);
    append32(bytes, sampleRate);
    append32(bytes, sampleRate * channels * (bitsPerSample / 8));
    append16(bytes, channels * (bitsPerSample / 8));
    append16(bytes, bitsPerSample);
    bytes.insert(bytes.end(), {'d', 'a', 't', 'a'});
    append32(bytes, dataBytes);
    bytes.resize(bytes.size() + dataBytes, 0);
    return bytes;
}

struct MemoryReader {
    explicit MemoryReader(std::vector<uint8_t> input) : bytes(std::move(input)) {}
    std::vector<uint8_t> bytes;
    int64_t position = 0;
};

int32_t readBytes(void *opaque, uint8_t *destination, int32_t count) {
    auto *reader = static_cast<MemoryReader *>(opaque);
    if (reader == nullptr || destination == nullptr || count <= 0) return LAZER_AUDIO_READER_IO_ERROR;
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

LazerAudioReader asReader(MemoryReader &reader) {
    return LazerAudioReader{readBytes, seekBytes, readerLength, nullptr, &reader, nullptr};
}

class RawDsdCaptureConsumer final : public SourceConsumer {
public:
    int32_t accept(const uint8_t *bytes, int32_t frames) override {
        if (bytes == nullptr || frames <= 0) return 0;
        const size_t count = static_cast<size_t>(frames) * channels;
        bytes_.insert(bytes_.end(), bytes, bytes + count);
        return frames;
    }
    bool shouldPump() const override { return true; }
    bool isCancelled() const override { return false; }

    int32_t channels = kStereo;
    std::vector<uint8_t> bytes_;
};

bool decodeRawDsd(const std::vector<uint8_t> &encoded, std::vector<uint8_t> &rawBytes) {
    MemoryReader reader(encoded);
    const LazerAudioReader input = asReader(reader);
    AudioSource source(nullptr);
    const LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 0};
    if (source.prepareReader(input) != LazerAudioOk ||
        source.openReader(input, params) != LazerAudioOk) return false;
    TargetFormat target;
    target.sampleRate = source.description().sampleRate;
    target.channels = source.description().channels;
    target.bitsPerSample = 8;
    target.containerBitsPerSample = 8;
    target.nativeDsdRawBytes = true;
    if (source.setTargetFormat(target) != LazerAudioOk) return false;
    RawDsdCaptureConsumer consumer;
    consumer.channels = target.channels;
    if (source.pump(consumer) != LazerAudioOk || !source.reachedEndOfStream()) return false;
    rawBytes = std::move(consumer.bytes_);
    return rawBytes.size() % static_cast<size_t>(target.channels) == 0;
}

struct Capture {
    std::mutex mutex;
    std::condition_variable changed;
    AudioOutputRequest request{};
    AudioOutputSession session{};
    std::vector<uint8_t> bytes;
    int32_t openCount = 0;
    int32_t startCount = 0;
    int32_t closeCount = 0;
    int32_t writeCount = 0;
    std::vector<int32_t> events;
    bool invalidWrite = false;
};

void onEvent(void *opaque, int32_t event, int32_t, int64_t) {
    auto *capture = static_cast<Capture *>(opaque);
    if (capture == nullptr) return;
    {
        std::lock_guard guard(capture->mutex);
        capture->events.push_back(event);
    }
    capture->changed.notify_all();
}

class NativeDsdCaptureOutput final : public AudioOutput {
public:
    NativeDsdCaptureOutput(std::shared_ptr<Capture> capture, bool wrongClock,
        bool allowPcm = false, int32_t startupDelayMillis = 0,
        int32_t nativeWordBytes = 4)
        : capture_(std::move(capture)), wrongClock_(wrongClock), allowPcm_(allowPcm),
          startupDelayMillis_(startupDelayMillis), nativeWordBytes_(nativeWordBytes) {}

    int32_t open(const AudioOutputRequest &request, const StreamDescription &source,
        AudioOutputSession &session, std::string &error, LogProxy *) override {
        std::lock_guard guard(capture_->mutex);
        capture_->request = request;
        ++capture_->openCount;
        if (allowPcm_ && !source.dsd && !request.requireNativeDsd) {
            TargetFormat target;
            target.sampleRate = source.sampleRate;
            target.channels = source.channels;
            target.bitsPerSample = 16;
            target.containerBitsPerSample = 16;
            session.target = target;
            session.engineFormat = PcmFormat{target.sampleRate, target.channels};
            session.formatSelection = LazerAudioFormatSelectionSharedMix;
            session.periodFrames = 128;
            session.bufferFrames = 512;
            session.writeMode = OutputWriteMode::Variable;
            session.queueDepthAvailable = true;
            capture_->session = session;
            open_ = true;
            return LazerAudioOk;
        }
        if (!request.requireNativeDsd || !request.exclusive || request.bitPerfect ||
            !request.desired.nativeDsd || request.desired.doP || !source.dsd || !source.rawDsd ||
            source.sampleRate != kDsdByteClock || source.channels != kStereo) {
            error = "engine did not request direct Native DSD for raw stereo DSD";
            return LazerAudioErrorUnsupported;
        }

        TargetFormat target;
        target.sampleRate = kDsdByteClock / nativeWordBytes_;
        if (wrongClock_) target.sampleRate /= 2;
        target.channels = kStereo;
        target.bitsPerSample = nativeWordBytes_ * 8;
        target.containerBitsPerSample = nativeWordBytes_ * 8;
        target.nativeDsd = true;
        target.nativeDsdBigEndian = true;
        session.target = target;
        session.engineFormat = PcmFormat{target.sampleRate, target.channels};
        session.formatSelection = nativeWordBytes_ == 1
            ? LazerAudioFormatSelectionNativeDsdU8
            : nativeWordBytes_ == 2 ? LazerAudioFormatSelectionNativeDsdU16Be
                                    : LazerAudioFormatSelectionNativeDsdU32Be;
        session.periodFrames = 128;
        session.bufferFrames = 512;
        session.writeMode = OutputWriteMode::Variable;
        session.exclusive = true;
        session.queueDepthAvailable = true;
        session.nativeDsd = true;
        capture_->session = session;
        open_ = true;
        return LazerAudioOk;
    }

    void close() override {
        open_.store(false, std::memory_order_release);
        std::lock_guard guard(capture_->mutex);
        ++capture_->closeCount;
    }
    int32_t start(std::string &) override {
        if (!open_) return LazerAudioErrorState;
        startedAt_ = std::chrono::steady_clock::now();
        std::lock_guard guard(capture_->mutex);
        ++capture_->startCount;
        return LazerAudioOk;
    }
    int32_t stop(std::string &) override { return LazerAudioOk; }
    int32_t reset(std::string &) override { return LazerAudioOk; }

    OutputWaitResult waitForReady(int32_t, std::string &) override {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
        return OutputWaitResult::Ready;
    }

    int32_t writableFrames(std::string &) override {
        if (startupDelayMillis_ > 0 && startedAt_ != std::chrono::steady_clock::time_point{} &&
            std::chrono::steady_clock::now() - startedAt_ <
                std::chrono::milliseconds(startupDelayMillis_)) {
            return 0;
        }
        return 32;
    }
    int32_t queuedFrames(std::string &) override { return 0; }
    OutputDrainResult drain(std::string &) override { return OutputDrainResult::Drained; }

    int32_t write(const uint8_t *bytes, int32_t frames, std::string &) override {
        if (!open_ || bytes == nullptr || frames <= 0) {
            std::lock_guard guard(capture_->mutex);
            capture_->invalidWrite = true;
            return LazerAudioErrorDevice;
        }
        std::lock_guard guard(capture_->mutex);
        capture_->bytes.insert(capture_->bytes.end(), bytes,
            bytes + static_cast<size_t>(frames) *
                static_cast<size_t>(capture_->session.target.frameBytes()));
        ++capture_->writeCount;
        capture_->changed.notify_all();
        return frames;
    }

    [[nodiscard]] bool isOpen() const noexcept override {
        return open_.load(std::memory_order_acquire);
    }

private:
    std::shared_ptr<Capture> capture_;
    bool wrongClock_ = false;
    bool allowPcm_ = false;
    int32_t startupDelayMillis_ = 0;
    int32_t nativeWordBytes_ = 4;
    std::chrono::steady_clock::time_point startedAt_{};
    std::atomic<bool> open_{false};
};

bool hasExpectedDsdPayload(const Capture &capture) {
    return std::search(capture.bytes.begin(), capture.bytes.end(),
        kExpectedFirstFrame.begin(), kExpectedFirstFrame.end()) != capture.bytes.end();
}

bool waitForNativePayload(const std::shared_ptr<Capture> &capture) {
    std::unique_lock guard(capture->mutex);
    return capture->changed.wait_for(guard, std::chrono::seconds(5), [&capture] {
        return hasExpectedDsdPayload(*capture);
    });
}

int fail(const char *message) {
    std::cerr << "FAIL: " << message << '\n';
    return 1;
}

int runNativeDsdCase() {
    MemoryReader reader(makeStereoDsf());
    const LazerAudioReader input = asReader(reader);
    auto capture = std::make_shared<Capture>();

    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.dsd_output_mode = LazerAudioDsdOutputRequireNative;
    config.device.buffer_millis = 120;
    Engine *engine = Engine::create(config,
        std::make_unique<NativeDsdCaptureOutput>(capture, false));
    if (engine == nullptr) return fail("Native DSD engine creation failed");

    const LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 0};
    const int32_t opened = engine->open(nullptr, &input, params);
    if (opened != LazerAudioOk) {
        std::cerr << "open error: " << engine->lastError() << '\n';
        engine->destroy();
        return fail("raw stereo DSD did not open through the required Native DSD path");
    }

    LazerAudioStreamInfo info{};
    engine->streamInfo(info);
    if (info.output_format_kind != LazerAudioOutputFormatNativeDsd ||
        info.output_dsd_rate_multiplier != 64 ||
        info.output_format_selection != LazerAudioFormatSelectionNativeDsdU32Be ||
        info.output_sample_rate != kNativeDsdRate || info.output_channels != kStereo ||
        info.output_bits_per_sample != 32 || info.output_container_bits_per_sample != 32 ||
        info.output_telemetry_valid != 0 || info.bit_perfect_active != 0) {
        engine->destroy();
        return fail("Native DSD session telemetry was reported as PCM or bit-perfect PCM");
    }

    if (engine->setVolume(0.5) != LazerAudioErrorUnsupported) {
        engine->destroy();
        return fail("software volume was accepted during Native DSD output");
    }
    const LazerAudioEqBand band{LazerAudioEqBandPeak, 1000.0, 3.0, 1.0, 1};
    const LazerAudioDspConfig dsp{0.0, 1, &band, 0, -1.0, 0};
    if (engine->setDsp(dsp) != LazerAudioErrorUnsupported) {
        engine->destroy();
        return fail("EQ was accepted during Native DSD output");
    }

    if (engine->play() != LazerAudioOk || !waitForNativePayload(capture)) {
        std::cerr << "play error: " << engine->lastError() << '\n';
        engine->destroy();
        return fail("Native DSD output did not submit packed frames to the fake endpoint");
    }
    if (engine->stop() != LazerAudioOk) {
        engine->destroy();
        return fail("stop failed while Native DSD output was active");
    }
    engine->destroy();

    std::lock_guard guard(capture->mutex);
    if (capture->openCount != 1 || !capture->request.requireNativeDsd ||
        !capture->request.exclusive || capture->request.bitPerfect ||
        !capture->request.desired.nativeDsd || capture->request.desired.doP ||
        capture->request.desired.sampleRate != kDsdByteClock ||
        capture->request.desired.channels != kStereo || !capture->session.nativeDsd ||
        capture->session.doP || !capture->session.exclusive ||
        capture->session.target.sampleRate * (capture->session.target.containerBitsPerSample / 8) !=
            kDsdByteClock || capture->session.target.channels != kStereo ||
        capture->session.target.bitsPerSample != 32 || capture->invalidWrite ||
        capture->writeCount == 0 || capture->bytes.empty() ||
        capture->bytes.size() % kNativeFrameBytes != 0) {
        return fail("the fake endpoint did not receive the exact direct U32 Native DSD clock and frames");
    }
    const auto firstPackedDsdFrame = std::search(capture->bytes.begin(), capture->bytes.end(),
        kExpectedFirstFrame.begin(), kExpectedFirstFrame.end());
    if (firstPackedDsdFrame == capture->bytes.end()) {
        return fail("Native DSD output contained no source payload matching the packed DSF data");
    }
    std::cout << "PASS: DSD64 opened as exclusive Native DSD U32_BE at 88.2 kHz; telemetry, DSP guards and stop are correct\n";
    return 0;
}

int runWrongClockCase() {
    MemoryReader reader(makeStereoDsf());
    const LazerAudioReader input = asReader(reader);
    auto capture = std::make_shared<Capture>();

    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.dsd_output_mode = LazerAudioDsdOutputRequireNative;
    Engine *engine = Engine::create(config,
        std::make_unique<NativeDsdCaptureOutput>(capture, true));
    if (engine == nullptr) return fail("Native DSD wrong-clock engine creation failed");

    const LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 0};
    const int32_t opened = engine->open(nullptr, &input, params);
    const std::string error = engine->lastError();
    engine->destroy();
    if (opened != LazerAudioErrorUnsupported ||
        error.find("Native DSD format contract") == std::string::npos) {
        std::cerr << "open result=" << opened << " error=" << error << '\n';
        return fail("an invalid Native DSD output clock was not rejected by the engine contract");
    }
    std::cout << "PASS: mismatched Native DSD word clock was rejected before playback\n";
    return 0;
}

int runNativeModeChangeRejectionCase() {
    MemoryReader pcmReader(makeStereoPcmWav());
    MemoryReader dsdReader(makeStereoDsf(100, 0x68));
    const LazerAudioReader pcmInput = asReader(pcmReader);
    const LazerAudioReader dsdInput = asReader(dsdReader);
    auto capture = std::make_shared<Capture>();

    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.dsd_output_mode = LazerAudioDsdOutputRequireNative;
    Engine *engine = Engine::create(config,
        std::make_unique<NativeDsdCaptureOutput>(capture, false, true));
    if (engine == nullptr) return fail("Native DSD mode-guard engine creation failed");

    const LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 0};
    if (engine->open(nullptr, &pcmInput, params) != LazerAudioOk) {
        std::cerr << "PCM-session open error: " << engine->lastError() << '\n';
        engine->destroy();
        return fail("PCM did not open in a RequireNative policy session");
    }
    if (engine->queueReader(1, dsdInput, params) != LazerAudioErrorUnsupported) {
        engine->destroy();
        return fail("raw DSD successor was accepted into an active PCM session under RequireNative");
    }
    engine->destroy();

    std::lock_guard guard(capture->mutex);
    if (capture->openCount != 1 || capture->session.nativeDsd ||
        capture->session.target.bitsPerSample != 16) {
        return fail("RequireNative mode-change rejection reopened or changed the active PCM session");
    }
    std::cout << "PASS: RequireNative rejects PCM→Native DSD queue mode changes without reopening the PCM session\n";
    return 0;
}

std::vector<uint8_t> packExpectedNativeDsd(const std::vector<uint8_t> &rawBytes,
    size_t wordBytes = 4) {
    NativeDsdPacker packer(kStereo, wordBytes, true);
    const size_t inputFrames = rawBytes.size() / kStereo;
    const size_t outputFrameBytes = static_cast<size_t>(kStereo) * wordBytes;
    const size_t capacityFrames = (inputFrames + wordBytes - 1) / wordBytes + 1;
    std::vector<uint8_t> packed(capacityFrames * outputFrameBytes);
    const NativeDsdPackResult result = packer.pack(rawBytes.data(), inputFrames,
        packed.data(), capacityFrames);
    if (result.status == NativeDsdPackStatus::OutputFull ||
        result.consumedInputFrames != inputFrames) return {};
    packed.resize(result.producedOutputFrames * outputFrameBytes);
    if (packer.hasPendingInput()) {
        const size_t offset = packed.size();
        packed.resize(offset + outputFrameBytes);
        const NativeDsdPackResult flushed = packer.flush(packed.data() + offset, 1);
        if (flushed.status != NativeDsdPackStatus::Ok || flushed.producedOutputFrames != 1) {
            return {};
        }
    }
    return packed;
}

bool beginsWithNativePayload(const Capture &capture, const std::vector<uint8_t> &expected,
    size_t outputFrameBytes) {
    if (expected.empty() || outputFrameBytes == 0 ||
        capture.bytes.size() < expected.size() || capture.bytes.size() % outputFrameBytes != 0) {
        return false;
    }
    size_t firstPayload = 0;
    while (firstPayload + outputFrameBytes <= capture.bytes.size()) {
        const auto frameBegin = capture.bytes.begin() +
            static_cast<std::ptrdiff_t>(firstPayload);
        const bool idle = std::all_of(frameBegin,
            frameBegin + static_cast<std::ptrdiff_t>(outputFrameBytes),
            [](uint8_t byte) { return byte == 0x69; });
        if (!idle) break;
        firstPayload += outputFrameBytes;
    }
    return firstPayload + expected.size() <= capture.bytes.size() &&
        std::equal(expected.begin(), expected.end(),
            capture.bytes.begin() + static_cast<std::ptrdiff_t>(firstPayload));
}

bool waitForEvent(const std::shared_ptr<Capture> &capture, int32_t event) {
    std::unique_lock guard(capture->mutex);
    return capture->changed.wait_for(guard, std::chrono::seconds(10), [&capture, event] {
        return std::find(capture->events.begin(), capture->events.end(), event) !=
            capture->events.end();
    });
}

int runNativeDsdSeekAlignmentCase(int32_t wordBytes) {
    constexpr int64_t seekMillis = 2'301;
    constexpr size_t expectedOutputFrames = 16;
    constexpr uint8_t seed = 0x27;
    const std::vector<uint8_t> encoded = makeStereoDsf(5'000, seed);
    std::vector<uint8_t> rawBytes;
    if (!decodeRawDsd(encoded, rawBytes)) {
        return fail("could not decode the Native DSD seek-alignment fixture");
    }

    const int32_t physicalWordRate = kDsdByteClock / wordBytes;
    const int64_t targetWordIndex = (seekMillis * physicalWordRate + 500) / 1'000;
    const int64_t targetRawFrame = targetWordIndex * wordBytes;
    const int64_t totalRawFrames = static_cast<int64_t>(rawBytes.size() / kStereo);
    if (targetRawFrame < 0 || targetRawFrame >= totalRawFrames) {
        return fail("Native DSD seek target falls outside its fixture");
    }
    const size_t rawOffset = static_cast<size_t>(targetRawFrame) * kStereo;
    const std::vector<uint8_t> suffixRaw(rawBytes.begin() +
        static_cast<std::ptrdiff_t>(rawOffset), rawBytes.end());
    const std::vector<uint8_t> expectedPacked = packExpectedNativeDsd(
        suffixRaw, static_cast<size_t>(wordBytes));
    const size_t outputFrameBytes = static_cast<size_t>(kStereo) * wordBytes;
    const size_t expectedBytes = expectedOutputFrames * outputFrameBytes;
    if (expectedPacked.size() < expectedBytes) {
        return fail("Native DSD seek fixture is too short for its packed prefix");
    }
    const std::vector<uint8_t> expectedPrefix(expectedPacked.begin(),
        expectedPacked.begin() + static_cast<std::ptrdiff_t>(expectedBytes));

    MemoryReader reader(encoded);
    const LazerAudioReader input = asReader(reader);
    auto capture = std::make_shared<Capture>();
    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.dsd_output_mode = LazerAudioDsdOutputRequireNative;
    config.device.buffer_millis = 2'500;
    Engine *engine = Engine::create(config,
        std::make_unique<NativeDsdCaptureOutput>(capture, false, false, 100, wordBytes));
    if (engine == nullptr) return fail("Native DSD seek engine creation failed");

    const LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 0};
    if (engine->open(nullptr, &input, params) != LazerAudioOk) {
        std::cerr << "Native DSD seek open error: " << engine->lastError() << '\n';
        engine->destroy();
        return fail("Native DSD seek source did not open");
    }
    if (engine->seek(seekMillis) != LazerAudioOk || engine->play() != LazerAudioOk) {
        std::cerr << "Native DSD seek/play error: " << engine->lastError() << '\n';
        engine->destroy();
        return fail("Native DSD seek or playback request failed");
    }
    {
        std::unique_lock guard(capture->mutex);
        const bool matched = capture->changed.wait_for(guard, std::chrono::seconds(8), [&] {
            return beginsWithNativePayload(*capture, expectedPrefix, outputFrameBytes);
        });
        if (!matched) {
            std::cerr << "Native DSD U" << wordBytes * 8
                      << " seek expected word index=" << targetWordIndex
                      << " raw frame=" << targetRawFrame
                      << " captured bytes=" << capture->bytes.size() << '\n';
            guard.unlock();
            engine->destroy();
            return fail("Native DSD seek payload did not start at the expected word boundary");
        }
    }
    if (engine->stop() != LazerAudioOk) {
        engine->destroy();
        return fail("Native DSD seek test could not stop the engine");
    }
    engine->destroy();

    std::lock_guard guard(capture->mutex);
    if (capture->openCount != 1 || capture->session.target.sampleRate != physicalWordRate ||
        capture->session.target.containerBitsPerSample != wordBytes * 8 ||
        capture->invalidWrite) {
        return fail("Native DSD seek fake endpoint used an unexpected word format");
    }
    std::cout << "PASS: Native DSD U" << wordBytes * 8
              << " seek at 2301 ms begins at raw-frame word boundary "
              << targetRawFrame << '\n';
    return 0;
}

int runNativeDsdGaplessCase() {
    /* A ends two bytes into a U32 word. B must complete that word directly; only final EOF may
     * append the 0x69 idle pattern. */
    MemoryReader firstReader(makeStereoDsf(1002, 0x12));
    MemoryReader successorReader(makeStereoDsf(1000, 0xA5));
    MemoryReader incompatibleReader(makeStereoDsf(40, 0xD1, 128));
    const LazerAudioReader firstInput = asReader(firstReader);
    const LazerAudioReader successorInput = asReader(successorReader);
    const LazerAudioReader incompatibleInput = asReader(incompatibleReader);
    auto capture = std::make_shared<Capture>();

    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.dsd_output_mode = LazerAudioDsdOutputRequireNative;
    /* Keep the fake device not-ready briefly after start so the real Engine/decoder threads can
     * stage both short tracks in the ring. The session fits in that ring; playback then checks the
     * exact seam bytes without racing the renderer against an unrealistically instant endpoint. */
    config.device.buffer_millis = 2500;
    config.events.on_event = onEvent;
    config.events.context = capture.get();
    Engine *engine = Engine::create(config,
        std::make_unique<NativeDsdCaptureOutput>(capture, false, false, 100));
    if (engine == nullptr) return fail("Native DSD gapless engine creation failed");

    const LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 0};
    if (engine->open(nullptr, &firstInput, params) != LazerAudioOk) {
        std::cerr << "gapless open error: " << engine->lastError() << '\n';
        engine->destroy();
        return fail("first raw DSD source did not open for Native DSD gapless");
    }
    LazerAudioOpenParams incompatibleParams = params;
    if (engine->queueReader(1, incompatibleInput, incompatibleParams) !=
        LazerAudioErrorUnsupported) {
        engine->destroy();
        return fail("a DSD128 successor was accepted into the active DSD64 Native DSD session");
    }
    LazerAudioOpenParams replayGainParams = params;
    replayGainParams.replay_gain_db = 1.0;
    if (engine->queueReader(2, successorInput, replayGainParams) !=
        LazerAudioErrorUnsupported) {
        engine->destroy();
        return fail("non-zero ReplayGain was accepted for a Native DSD successor");
    }
    if (engine->queueReader(3, successorInput, params) != LazerAudioOk) {
        std::cerr << "gapless queue error: " << engine->lastError() << '\n';
        engine->destroy();
        return fail("compatible raw DSD successor was rejected");
    }
    if (engine->play() != LazerAudioOk || !waitForEvent(capture, LazerAudioEventEnded)) {
        std::cerr << "gapless play error: " << engine->lastError() << '\n';
        engine->destroy();
        return fail("Native DSD gapless session did not end cleanly");
    }
    engine->destroy();

    std::vector<uint8_t> captured;
    std::vector<int32_t> events;
    int32_t openCount = 0;
    int32_t startCount = 0;
    bool invalidWrite = false;
    {
        std::lock_guard guard(capture->mutex);
        captured = capture->bytes;
        events = capture->events;
        openCount = capture->openCount;
        startCount = capture->startCount;
        invalidWrite = capture->invalidWrite;
    }
    std::vector<uint8_t> raw;
    std::vector<uint8_t> successorRaw;
    if (!decodeRawDsd(firstReader.bytes, raw) ||
        !decodeRawDsd(successorReader.bytes, successorRaw)) {
        return fail("could not independently decode raw DSD bytes for the gapless reference");
    }
    raw.insert(raw.end(), successorRaw.begin(), successorRaw.end());
    const std::vector<uint8_t> expected = packExpectedNativeDsd(raw);
    if (expected.empty() || std::search(captured.begin(), captured.end(), expected.begin(),
        expected.end()) == captured.end()) {
        size_t bestOffset = 0;
        size_t bestMatched = 0;
        for (size_t offset = 0; offset < captured.size(); ++offset) {
            size_t matched = 0;
            while (matched < expected.size() && offset + matched < captured.size() &&
                captured[offset + matched] == expected[matched]) {
                ++matched;
            }
            if (matched > bestMatched) {
                bestOffset = offset;
                bestMatched = matched;
            }
        }
        std::cerr << "gapless captured bytes=" << captured.size()
            << " expected contiguous payload=" << expected.size()
            << " best prefix=" << bestMatched << " at captured offset=" << bestOffset;
        if (bestMatched < expected.size() && bestOffset + bestMatched < captured.size()) {
            std::cerr << " mismatch expected=0x" << std::hex
                << static_cast<int>(expected[bestMatched]) << " captured=0x"
                << static_cast<int>(captured[bestOffset + bestMatched]) << std::dec;
        }
        std::cerr << '\n';
        return fail("Native DSD A→B payload was not contiguous or had seam padding");
    }
    const int32_t trackChanges = static_cast<int32_t>(std::count(events.begin(), events.end(),
        LazerAudioEventTrackChanged));
    const int32_t ended = static_cast<int32_t>(std::count(events.begin(), events.end(),
        LazerAudioEventEnded));
    const auto track = std::find(events.begin(), events.end(), LazerAudioEventTrackChanged);
    const auto end = std::find(events.begin(), events.end(), LazerAudioEventEnded);
    if (openCount != 1 || startCount != 1 || invalidWrite || trackChanges != 1 || ended != 1 ||
        track == events.end() || end == events.end() || track >= end) {
        return fail("Native DSD gapless session lifecycle or track/ended event order was incorrect");
    }
    std::cout << "PASS: compatible raw DSD successors share one U32_BE session; the partial word crosses the seam without idle padding, incompatible rate/ReplayGain are rejected, and TrackChanged precedes Ended\n";
    return 0;
}

} // namespace

namespace lazer::audio {
std::unique_ptr<AudioOutput> createPlatformAudioOutput() { return nullptr; }
} // namespace lazer::audio

int main() {
    if (runNativeDsdCase() != 0) return 1;
    if (runWrongClockCase() != 0) return 1;
    if (runNativeModeChangeRejectionCase() != 0) return 1;
    for (const int32_t wordBytes : {1, 2, 4}) {
        if (runNativeDsdSeekAlignmentCase(wordBytes) != 0) return 1;
    }
    if (runNativeDsdGaplessCase() != 0) return 1;
    return 0;
}
