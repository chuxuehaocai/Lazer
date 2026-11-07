/* End-to-end, device-free verification of the bit-perfect claim and the three facts behind it.
 *
 * The engine used to publish a single `bit_perfect_active` flag decided at open time. A flag cannot
 * be checked, only believed, so ABI v25 publishes what it was derived from: whether the session is
 * exclusive, whether the float DSP/volume chain is on the signal path, and whether the output runs
 * the source's own rate/channels/depth. A Dart-side `OutputPathState` derives the verdict from those
 * three; this probe asserts that the derivation and the engine's flag agree, and that the audio bytes
 * really are the source bytes exactly when they say they are.
 *
 * A fake fixed-period endpoint captures the engine's actual output, so no device is needed. */
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

constexpr int32_t kChannels = 2;
constexpr int32_t kPeriodFrames = 512;
/* Long enough to need several ring refills, so the producer and the render thread really do hand
 * over mid-stream instead of the whole track fitting in one buffer. A whole number of device
 * periods, because a fixed-period endpoint pads its final packet: the comparison below is against
 * the source bytes with no padding at all, which is only meaningful when there is none. */
constexpr int32_t kSourceFrames = kPeriodFrames * 25;

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

int64_t sampleValue(int32_t frame, int32_t channel, int32_t bits) {
    const uint64_t span = uint64_t{1} << static_cast<uint32_t>(bits - 2);
    const uint64_t mixed = static_cast<uint64_t>(frame) * (channel == 0 ? 7'919u : 10'927u);
    return static_cast<int64_t>(mixed % span) - static_cast<int64_t>(span / 2);
}

void appendSample(std::vector<uint8_t> &bytes, int64_t sample, int32_t bytesPerSample) {
    const uint64_t packed = static_cast<uint64_t>(sample);
    for (int32_t index = 0; index < bytesPerSample; ++index) {
        bytes.push_back(static_cast<uint8_t>((packed >> (index * 8)) & 0xff));
    }
}

/* A deterministic integer PCM WAV; the data chunk is what a bit-perfect path must reproduce. */
std::vector<uint8_t> makePcmWave(int32_t frames, int32_t sampleRate, int32_t bits) {
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
        appendSample(bytes, sampleValue(frame, 0, bits), bytesPerSample);
        appendSample(bytes, sampleValue(frame, 1, bits), bytesPerSample);
    }
    return bytes;
}

struct MemoryReader {
    explicit MemoryReader(std::vector<uint8_t> value) : bytes(std::move(value)) {}
    std::vector<uint8_t> bytes;
    int64_t position = 0;
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

struct Capture {
    std::mutex mutex;
    std::condition_variable changed;
    std::vector<uint8_t> bytes;
    AudioOutputRequest request;
    TargetFormat target;
    int32_t formatSelection = LazerAudioFormatSelectionUnknown;
    int openCount = 0;
    std::vector<int32_t> events;
};

void onEvent(void *context, int32_t event, int32_t, int64_t) {
    auto *capture = static_cast<Capture *>(context);
    if (capture == nullptr) return;
    {
        std::lock_guard guard(capture->mutex);
        capture->events.push_back(event);
    }
    capture->changed.notify_all();
}

/* A fixed-period endpoint that reports exactly the format it was told to accept. `forceSampleRate`
 * models an endpoint whose native format is not the source's (the common "48 kHz only" case). */
class CaptureOutput final : public AudioOutput {
public:
    explicit CaptureOutput(std::shared_ptr<Capture> capture, int32_t forcedSampleRate = 0)
        : capture_(std::move(capture)), forcedSampleRate_(forcedSampleRate) {}

    int32_t open(const AudioOutputRequest &request, const StreamDescription &source,
        AudioOutputSession &session, std::string &, LogProxy *) override {
        std::lock_guard guard(capture_->mutex);
        ++capture_->openCount;
        const int32_t rate = forcedSampleRate_ > 0 ? forcedSampleRate_ : source.sampleRate;
        session.target.sampleRate = rate;
        session.target.channels = source.channels;
        session.target.bitsPerSample = source.bitsPerSample;
        session.target.containerBitsPerSample = source.bitsPerSample;
        session.engineFormat = {rate, source.channels};
        session.formatSelection = rate == source.sampleRate
            ? LazerAudioFormatSelectionExclusiveSource
            : LazerAudioFormatSelectionExclusiveCommonRateFallback;
        session.periodFrames = kPeriodFrames;
        session.bufferFrames = kPeriodFrames;
        session.exclusive = true;
        session.writeMode = OutputWriteMode::FixedPeriod;
        session.queueDepthAvailable = true;
        bytesPerFrame_ = session.target.frameBytes();
        capture_->request = request;
        capture_->target = session.target;
        capture_->formatSelection = session.formatSelection;
        open_ = true;
        return LazerAudioOk;
    }

    void close() override {
        std::lock_guard guard(capture_->mutex);
        open_ = false;
    }

    int32_t start(std::string &) override { return LazerAudioOk; }
    int32_t stop(std::string &) override { return LazerAudioOk; }
    int32_t reset(std::string &) override { return LazerAudioOk; }

    OutputWaitResult waitForReady(int32_t, std::string &) override {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
        return OutputWaitResult::Ready;
    }
    int32_t writableFrames(std::string &) override { return kPeriodFrames; }
    int32_t queuedFrames(std::string &) override { return 0; }
    OutputDrainResult drain(std::string &) override { return OutputDrainResult::Drained; }

    int32_t write(const uint8_t *bytes, int32_t frames, std::string &) override {
        if (bytes == nullptr || frames != kPeriodFrames || bytesPerFrame_ <= 0) {
            return LazerAudioErrorDevice;
        }
        std::lock_guard guard(capture_->mutex);
        const size_t byteCount = static_cast<size_t>(frames) * static_cast<size_t>(bytesPerFrame_);
        capture_->bytes.insert(capture_->bytes.end(), bytes, bytes + byteCount);
        capture_->changed.notify_all();
        return frames;
    }

    [[nodiscard]] bool isOpen() const noexcept override { return open_; }

private:
    std::shared_ptr<Capture> capture_;
    int32_t forcedSampleRate_ = 0;
    int32_t bytesPerFrame_ = 0;
    bool open_ = false;
};

bool waitForEnded(std::shared_ptr<Capture> capture, std::chrono::milliseconds timeout) {
    std::unique_lock guard(capture->mutex);
    return capture->changed.wait_for(guard, timeout, [&capture] {
        return std::find(capture->events.begin(), capture->events.end(),
            LazerAudioEventEnded) != capture->events.end();
    });
}

struct CapturedSession {
    LazerAudioStreamInfo info{};
    std::vector<uint8_t> bytes;
    int32_t openCount = 0;
    int32_t formatSelection = 0;
    bool ended = false;
};

/* Opens the same source once with the given device policy and reports what the engine claimed. */
bool runSession(int32_t forcedSampleRate, bool bitPerfect, double dspPreampDb,
    int32_t expectedSetDspResult, double initialVolume, CapturedSession &out,
    std::string &failure, double volumeAfterOpen = -1.0,
    int32_t sourceFrames = kSourceFrames, int32_t settleAfterOpenMillis = 0) {
    constexpr int32_t sampleRate = 44'100;
    constexpr int32_t bits = 16;
    MemoryReader source(makePcmWave(sourceFrames, sampleRate, bits));
    LazerAudioReader reader = asReader(source);
    auto capture = std::make_shared<Capture>();

    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.exclusive = 1;
    config.device.bit_perfect = bitPerfect ? 1 : 0;
    config.device.buffer_millis = 60;
    config.events.on_event = onEvent;
    config.events.context = capture.get();

    Engine *engine = Engine::create(
        config, std::make_unique<CaptureOutput>(capture, forcedSampleRate));
    if (engine == nullptr) {
        failure = "Engine::create failed";
        return false;
    }
    /* Match the app's required ordering: install user gain before open starts its producer thread. */
    const int32_t volumeResult = engine->setVolume(initialVolume);
    if (volumeResult != LazerAudioOk) {
        failure = "setVolume returned " + std::to_string(volumeResult) + " error=" + engine->lastError();
        engine->destroy();
        return false;
    }
    const LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 0, 0, 0};
    const int32_t openResult = engine->open(nullptr, &reader, params);
    if (openResult != LazerAudioOk) {
        failure = "open failed code=" + std::to_string(openResult) + " error=" + engine->lastError();
        engine->destroy();
        return false;
    }
    if (settleAfterOpenMillis > 0) {
        std::this_thread::sleep_for(std::chrono::milliseconds(settleAfterOpenMillis));
    }
    if (volumeAfterOpen >= 0.0) {
        const int32_t updateResult = engine->setVolume(volumeAfterOpen);
        if (updateResult != LazerAudioOk) {
            failure = "setVolume after open returned " + std::to_string(updateResult) +
                " error=" + engine->lastError();
            engine->destroy();
            return false;
        }
    }

    LazerAudioDspConfig dsp{};
    dsp.preamp_db = dspPreampDb;
    const int32_t dspResult = engine->setDsp(dsp);
    if (dspResult != expectedSetDspResult) {
        failure = "setDsp returned " + std::to_string(dspResult) + " error=" + engine->lastError();
        engine->destroy();
        return false;
    }

    engine->streamInfo(out.info);
    if (engine->play() != LazerAudioOk || !waitForEnded(capture, std::chrono::seconds(10))) {
        failure = "playback did not reach Ended";
        engine->destroy();
        return false;
    }
    out.ended = true;
    engine->stop();
    {
        std::lock_guard guard(capture->mutex);
        out.bytes = capture->bytes;
        out.openCount = capture->openCount;
        out.formatSelection = capture->formatSelection;
    }
    engine->destroy();
    return true;
}

/* The verdict the Dart side derives, expressed here so both can be compared. */
bool derivedBitPerfect(const LazerAudioStreamInfo &info) {
    return info.output_format_initialized != 0 && info.output_exclusive != 0 &&
        info.output_dsp_active == 0 && info.output_format_matches_source != 0;
}

std::vector<uint8_t> sourceBytes(int32_t frames, int32_t sampleRate, int32_t bits) {
    const std::vector<uint8_t> wave = makePcmWave(frames, sampleRate, bits);
    return std::vector<uint8_t>(wave.begin() + 44, wave.end());
}

/* Case 1: exclusive + bit-perfect + the source's own format => the device receives the source bytes,
 * byte for byte, and the three published facts say so. */
bool runBitExactCase() {
    CapturedSession session;
    std::string failure;
    if (!runSession(0, true, 0.0, LazerAudioOk, 1.0, session, failure)) {
        std::cerr << "FAIL: bit-exact session: " << failure << "\n";
        return false;
    }
    const std::vector<uint8_t> expected = sourceBytes(kSourceFrames, 44'100, 16);
    if (session.bytes != expected) {
        std::cerr << "FAIL: captured " << session.bytes.size() << " bytes, expected "
            << expected.size() << " identical source bytes\n";
        return false;
    }
    if (session.info.output_exclusive == 0 || session.info.output_dsp_active != 0 ||
        session.info.output_format_matches_source == 0) {
        std::cerr << "FAIL: exclusive=" << session.info.output_exclusive
            << " dsp_active=" << session.info.output_dsp_active
            << " format_matches_source=" << session.info.output_format_matches_source << "\n";
        return false;
    }
    if (session.info.bit_perfect_active == 0 || !derivedBitPerfect(session.info)) {
        std::cerr << "FAIL: the engine did not report bit-perfect for a bit-exact session\n";
        return false;
    }
    std::cout << "PASS: bit-perfect exclusive output reproduces the source PCM bytes exactly "
        << "(" << session.bytes.size() << " bytes) and reports exclusive + no DSP + format match\n";
    return true;
}

/* Case 2: the same source and endpoint, but the DSP is in the path. The three facts must show it
 * (dsp_active) and the flag must go with them. */
bool runDspInvalidatesCase() {
    CapturedSession session;
    std::string failure;
    if (!runSession(0, false, 6.0, LazerAudioOk, 1.0, session, failure)) {
        std::cerr << "FAIL: DSP session: " << failure << "\n";
        return false;
    }
    if (session.info.output_exclusive == 0) {
        std::cerr << "FAIL: the endpoint accepted exclusive mode but the session reports otherwise\n";
        return false;
    }
    if (session.info.output_dsp_active == 0) {
        std::cerr << "FAIL: dsp_active is 0 while the DSP path processed the stream\n";
        return false;
    }
    if (session.info.bit_perfect_active != 0 || derivedBitPerfect(session.info)) {
        std::cerr << "FAIL: bit-perfect was claimed while the DSP was in the path\n";
        return false;
    }
    const std::vector<uint8_t> expected = sourceBytes(kSourceFrames, 44'100, 16);
    if (session.bytes == expected) {
        std::cerr << "FAIL: the processed stream reproduced the source bytes exactly\n";
        return false;
    }
    std::cout << "PASS: DSP in the signal path clears bit-perfect and alters the output "
        << "(exclusive=1, dsp_active=1, format_matches_source="
        << session.info.output_format_matches_source << ")\n";
    return true;
}

/* Case 3: an endpoint whose native format is not the source's. The format fact must be false on its
 * own, even though the session is exclusive. */
bool runFormatMismatchCase() {
    CapturedSession session;
    std::string failure;
    if (!runSession(48'000, false, 0.0, LazerAudioOk, 1.0, session, failure)) {
        std::cerr << "FAIL: mismatched-format session: " << failure << "\n";
        return false;
    }
    if (session.info.output_format_matches_source != 0) {
        std::cerr << "FAIL: format_matches_source is 1 for a 44.1 kHz source on a 48 kHz endpoint\n";
        return false;
    }
    if (session.info.bit_perfect_active != 0 || derivedBitPerfect(session.info)) {
        std::cerr << "FAIL: bit-perfect was claimed across a sample-rate change\n";
        return false;
    }
    std::cout << "PASS: a resampled session reports format_matches_source=0 and is not bit-perfect "
        << "(source 44100 Hz, output " << session.info.output_sample_rate << " Hz)\n";
    return true;
}

/* Case 4: the honesty rule. A processing request cannot be honoured by a bit-perfect session, so it
 * must be refused with an error instead of being accepted and silently dropped. */
bool runBitPerfectRefusesDspCase() {
    CapturedSession session;
    std::string failure;
    if (!runSession(0, true, 6.0, LazerAudioErrorUnsupported, 1.0, session, failure)) {
        std::cerr << "FAIL: bit-perfect DSP refusal: " << failure << "\n";
        return false;
    }
    if (session.info.output_dsp_active != 0 || session.info.bit_perfect_active == 0) {
        std::cerr << "FAIL: a refused DSP request changed the reported path\n";
        return false;
    }
    const std::vector<uint8_t> expected = sourceBytes(kSourceFrames, 44'100, 16);
    if (session.bytes != expected) {
        std::cerr << "FAIL: a refused DSP request still altered the output\n";
        return false;
    }
    std::cout << "PASS: a DSP request during bit-perfect is refused with an error and the output "
        << "stays byte-exact\n";
    return true;
}

/* Capture the actual PCM emitted by Engine, including the first sample after an open. */
bool runFirstBlockVolumeCase() {
    constexpr double gains[]{0.0, 0.01, 0.1, 0.5, 1.0};
    constexpr int64_t sourceFirstSample = -8192; // frame 0 of makePcmWave(), left channel, 16-bit.
    constexpr int64_t tolerance = 2; // TPDF quantization can move a sample by at most two LSBs.
    for (const double gain : gains) {
        CapturedSession session;
        std::string failure;
        if (!runSession(0, false, 0.0, LazerAudioOk, gain, session, failure)) {
            std::cerr << "FAIL: first-block volume at " << gain << ": " << failure << "\n";
            return false;
        }
        if (session.bytes.size() < 2) {
            std::cerr << "FAIL: first-block volume captured no PCM sample\n";
            return false;
        }
        const uint16_t packed = static_cast<uint16_t>(session.bytes[0]) |
            static_cast<uint16_t>(static_cast<uint16_t>(session.bytes[1]) << 8);
        const int64_t actual = packed < 0x8000
            ? static_cast<int64_t>(packed)
            : static_cast<int64_t>(packed) - 0x1'0000;
        const int64_t expected = static_cast<int64_t>(std::llround(
            static_cast<double>(sourceFirstSample) * gain));
        if (std::abs(static_cast<int64_t>(actual) - expected) > tolerance) {
            std::cerr << "FAIL: first PCM sample at gain " << gain << " was " << actual
                << ", expected " << expected << " from the first frame\n";
            return false;
        }
    }
    CapturedSession changedDuringLoad;
    std::string failure;
    if (!runSession(0, false, 0.0, LazerAudioOk, 0.5, changedDuringLoad, failure, 0.1)) {
        std::cerr << "FAIL: volume changed after open: " << failure << "\n";
        return false;
    }
    if (changedDuringLoad.bytes.size() < 2) {
        std::cerr << "FAIL: volume changed after open captured no PCM sample\n";
        return false;
    }
    const uint16_t packed = static_cast<uint16_t>(changedDuringLoad.bytes[0]) |
        static_cast<uint16_t>(static_cast<uint16_t>(changedDuringLoad.bytes[1]) << 8);
    const int64_t actual = packed < 0x8000
        ? static_cast<int64_t>(packed)
        : static_cast<int64_t>(packed) - 0x1'0000;
    const int64_t expected = static_cast<int64_t>(std::llround(
        static_cast<double>(sourceFirstSample) * 0.1));
    if (std::abs(actual - expected) > tolerance) {
        std::cerr << "FAIL: first PCM sample after loading-time gain change was " << actual
            << ", expected " << expected << "\n";
        return false;
    }
    CapturedSession shortSource;
    if (!runSession(0, false, 0.0, LazerAudioOk, 0.5, shortSource, failure,
            0.1, 100, 20)) {
        std::cerr << "FAIL: gain refresh after a short source reached EOF: " << failure << "\n";
        return false;
    }
    if (shortSource.bytes.size() < 2) {
        std::cerr << "FAIL: short source refresh captured no PCM sample\n";
        return false;
    }
    const uint16_t shortPacked = static_cast<uint16_t>(shortSource.bytes[0]) |
        static_cast<uint16_t>(static_cast<uint16_t>(shortSource.bytes[1]) << 8);
    const int64_t shortActual = shortPacked < 0x8000
        ? static_cast<int64_t>(shortPacked)
        : static_cast<int64_t>(shortPacked) - 0x1'0000;
    if (std::abs(shortActual - expected) > tolerance) {
        std::cerr << "FAIL: short source first sample after gain refresh was " << shortActual
            << ", expected " << expected << "\n";
        return false;
    }
    std::cout << "PASS: captured Engine output starts at requested gain for mute, 1%, 10%, 50%, and unity\n";
    std::cout << "PASS: a gain change after open refreshes the prebuffer before the first output frame\n";
    std::cout << "PASS: a finished short source restarts its producer to refresh the first output frame\n";
    return true;
}

/* Manual next/open reuses the Engine object. Its next output session must keep the same user gain
 * even after the old stream and its platform output have been stopped and recreated. */
bool runReopenAtCurrentVolumeCase() {
    constexpr double gain = 0.1;
    constexpr int64_t sourceFirstSample = -2'097'152; // First left-channel sample of a 24-bit fixture.
    constexpr int64_t tolerance = 2;
    const auto failReopen = [](const std::string &reason) {
        std::cerr << "FAIL: " << reason << "\n";
        return false;
    };
    MemoryReader first(makePcmWave(kPeriodFrames, 44'100, 16));
    /* A manual format-changing next track must use the same gain after rebuilding the pipeline. */
    MemoryReader second(makePcmWave(kPeriodFrames, 96'000, 24));
    const LazerAudioReader firstReader = asReader(first);
    const LazerAudioReader secondReader = asReader(second);
    auto capture = std::make_shared<Capture>();
    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.exclusive = 1;
    config.device.buffer_millis = 60;
    config.events.on_event = onEvent;
    config.events.context = capture.get();
    Engine *engine = Engine::create(config, std::make_unique<CaptureOutput>(capture));
    if (engine == nullptr) return failReopen("reopen volume engine creation failed");

    const LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 0, 0, 0};
    if (engine->setVolume(gain) != LazerAudioOk ||
        engine->open(nullptr, &firstReader, params) != LazerAudioOk ||
        engine->play() != LazerAudioOk ||
        !waitForEnded(capture, std::chrono::seconds(5))) {
        std::cerr << "FAIL: first source did not finish in the reopen volume case: "
            << engine->lastError() << "\n";
        engine->destroy();
        return false;
    }
    if (engine->stop() != LazerAudioOk) {
        engine->destroy();
        return failReopen("first source could not stop before manual reopen");
    }
    size_t secondSourceOffset = 0;
    {
        std::lock_guard guard(capture->mutex);
        secondSourceOffset = capture->bytes.size();
        capture->events.clear();
    }
    if (engine->open(nullptr, &secondReader, params) != LazerAudioOk ||
        engine->play() != LazerAudioOk ||
        !waitForEnded(capture, std::chrono::seconds(5))) {
        std::cerr << "FAIL: second source did not finish after manual reopen: "
            << engine->lastError() << "\n";
        engine->destroy();
        return false;
    }
    engine->stop();
    engine->destroy();

    std::lock_guard guard(capture->mutex);
    if (capture->openCount != 2 || capture->target.sampleRate != 96'000 ||
        capture->target.bitsPerSample != 24 || secondSourceOffset + 3 > capture->bytes.size()) {
        return failReopen("format-changing manual reopen did not produce two complete output sessions");
    }
    const uint32_t packed = static_cast<uint32_t>(capture->bytes[secondSourceOffset]) |
        (static_cast<uint32_t>(capture->bytes[secondSourceOffset + 1]) << 8) |
        (static_cast<uint32_t>(capture->bytes[secondSourceOffset + 2]) << 16);
    const int64_t actual = packed < 0x80'0000
        ? static_cast<int64_t>(packed)
        : static_cast<int64_t>(packed) - 0x100'0000;
    const int64_t expected = static_cast<int64_t>(std::llround(sourceFirstSample * gain));
    if (std::abs(actual - expected) > tolerance) {
        std::cerr << "FAIL: first PCM sample after reopening the same Engine was " << actual
            << ", expected " << expected << "\n";
        return false;
    }
    std::cout << "PASS: reopening the same Engine at 96 kHz/24-bit preserves the 10% first-frame gain\n";
    return true;
}

}  // namespace

namespace lazer::audio {
std::unique_ptr<AudioOutput> createPlatformAudioOutput() { return nullptr; }
}  // namespace lazer::audio

int main() {
    const bool ok = runBitExactCase() && runDspInvalidatesCase() && runFormatMismatchCase() &&
        runBitPerfectRefusesDspCase() && runFirstBlockVolumeCase() &&
        runReopenAtCurrentVolumeCase();
    return ok ? 0 : 1;
}
