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
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <limits>
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
    bool sessionActive = false;
    bool failNextOpen = false;
    bool holdOpen = false;
    bool openEntered = false;
    bool releaseOpen = false;
    Engine *reentrantEngine = nullptr;
    int32_t readyControlResult = LazerAudioOk;
    std::vector<int32_t> events;
};

void onEvent(void *context, int32_t event, int32_t, int64_t) {
    auto *capture = static_cast<Capture *>(context);
    if (capture == nullptr) return;
    {
        std::lock_guard guard(capture->mutex);
        capture->events.push_back(event);
    }
    if (event == LazerAudioEventReady && capture->reentrantEngine != nullptr) {
        capture->readyControlResult = capture->reentrantEngine->setVolume(0.5);
    }
    capture->changed.notify_all();
}

/* A fixed-period endpoint that reports exactly the format it was told to accept. `forceSampleRate`
 * models an endpoint whose native format is not the source's (the common "48 kHz only" case). */
class CaptureOutput final : public AudioOutput {
public:
    explicit CaptureOutput(std::shared_ptr<Capture> capture, int32_t forcedSampleRate = 0,
        bool transparentUsb = false, bool hardwareExclusive = true)
        : capture_(std::move(capture)), forcedSampleRate_(forcedSampleRate),
          transparentUsb_(transparentUsb), hardwareExclusive_(hardwareExclusive) {}

    int32_t open(const AudioOutputRequest &request, const StreamDescription &source,
        AudioOutputSession &session, std::string &error, LogProxy *) override {
        std::unique_lock guard(capture_->mutex);
        ++capture_->openCount;
        if (capture_->holdOpen) {
            capture_->openEntered = true;
            capture_->changed.notify_all();
            capture_->changed.wait(guard, [this] { return capture_->releaseOpen; });
        }
        if (capture_->failNextOpen) {
            capture_->failNextOpen = false;
            error = "fake replacement device failure";
            return LazerAudioErrorDevice;
        }
        const int32_t rate = forcedSampleRate_ > 0 ? forcedSampleRate_ : source.sampleRate;
        session.target.sampleRate = rate;
        session.target.channels = source.channels;
        session.target.bitsPerSample = source.bitsPerSample;
        session.target.containerBitsPerSample = source.bitsPerSample;
        session.engineFormat = {rate, source.channels};
        session.formatSelection = rate == source.sampleRate
            ? LazerAudioFormatSelectionExclusiveSource
            : LazerAudioFormatSelectionExclusiveCommonRateFallback;
        if (transparentUsb_) session.formatSelection = LazerAudioFormatSelectionIosUsbPcm;
        session.periodFrames = kPeriodFrames;
        session.bufferFrames = kPeriodFrames;
        session.exclusive = hardwareExclusive_;
        session.transparentUsb = transparentUsb_;
        session.writeMode = OutputWriteMode::FixedPeriod;
        session.queueDepthAvailable = true;
        bytesPerFrame_ = session.target.frameBytes();
        capture_->request = request;
        capture_->target = session.target;
        capture_->formatSelection = session.formatSelection;
        open_ = true;
        capture_->sessionActive = true;
        return LazerAudioOk;
    }

    void close() override {
        std::lock_guard guard(capture_->mutex);
        open_ = false;
        capture_->sessionActive = false;
    }

    void closeForReplacement() override {
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
    [[nodiscard]] bool strictDirectOutputRequests() const noexcept override { return transparentUsb_; }

private:
    std::shared_ptr<Capture> capture_;
    int32_t forcedSampleRate_ = 0;
    int32_t bytesPerFrame_ = 0;
    bool transparentUsb_ = false;
    bool hardwareExclusive_ = true;
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
    int32_t expectedSetDspResult, CapturedSession &out, std::string &failure,
    bool transparentUsb = false, int32_t bits = 16) {
    constexpr int32_t sampleRate = 44'100;
    MemoryReader source(makePcmWave(kSourceFrames, sampleRate, bits));
    LazerAudioReader reader = asReader(source);
    auto capture = std::make_shared<Capture>();

    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.exclusive = transparentUsb ? 0 : 1;
    config.device.bit_perfect = bitPerfect ? 1 : 0;
    config.device.buffer_millis = 60;
    config.events.on_event = onEvent;
    config.events.context = capture.get();

    Engine *engine = Engine::create(
        config, std::make_unique<CaptureOutput>(capture, forcedSampleRate,
            transparentUsb, !transparentUsb));
    if (engine == nullptr) {
        failure = "Engine::create failed";
        return false;
    }
    const LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 0, 0, 0};
    const int32_t openResult = engine->open(nullptr, &reader, params);
    if (openResult != LazerAudioOk) {
        failure = "open failed code=" + std::to_string(openResult) + " error=" + engine->lastError();
        engine->destroy();
        return false;
    }

    LazerAudioDspConfig dsp{};
    dsp.preamp_db = dspPreampDb;
    const int32_t dspResult = engine->setDsp(dsp);
    if (dspResult != expectedSetDspResult) {
        failure = "setDsp returned " + std::to_string(dspResult) + " error=" + engine->lastError();
        engine->destroy();
        return false;
    }
    if (bitPerfect && engine->setVolume(0.5) != LazerAudioErrorUnsupported) {
        failure = "direct output accepted digital attenuation";
        engine->destroy();
        return false;
    }
    if (transparentUsb && bitPerfect && engine->setAutoMix(5000) != LazerAudioErrorUnsupported) {
        failure = "strict USB accepted AutoMix while active";
        engine->destroy();
        return false;
    }
    for (const double invalid : {std::numeric_limits<double>::quiet_NaN(),
            std::numeric_limits<double>::infinity(), -std::numeric_limits<double>::infinity()}) {
        if (engine->setVolume(invalid) != LazerAudioErrorInvalidArgument) {
            failure = "accepted a non-finite software volume";
            engine->destroy();
            return false;
        }
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
    const bool exactTransport = info.output_exclusive != 0 ||
        info.output_format_selection == LazerAudioFormatSelectionIosUsbPcm ||
        info.output_format_selection == LazerAudioFormatSelectionIosUsbDoP;
    return info.output_format_initialized != 0 && exactTransport &&
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
    if (!runSession(0, true, 0.0, LazerAudioOk, session, failure)) {
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
    if (!runSession(0, false, 6.0, LazerAudioOk, session, failure)) {
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
    if (!runSession(48'000, false, 0.0, LazerAudioOk, session, failure)) {
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
    if (!runSession(0, true, 6.0, LazerAudioErrorUnsupported, session, failure)) {
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

bool runTransparentUsbCase() {
    for (const int32_t bits : {16, 24}) {
        CapturedSession session;
        std::string failure;
        if (!runSession(0, true, -6.0, LazerAudioErrorUnsupported, session, failure,
                true, bits)) {
            std::cerr << "FAIL: USB direct PCM " << bits << ": " << failure << '\n';
            return false;
        }
        if (session.bytes != sourceBytes(kSourceFrames, 44'100, bits) ||
            session.info.output_exclusive != 0 || session.info.output_dsp_active != 0 ||
            session.info.bit_perfect_active != 1 || !derivedBitPerfect(session.info) ||
            session.info.output_format_selection != LazerAudioFormatSelectionIosUsbPcm) {
            std::cerr << "FAIL: USB PCM failed byte-exact / non-exclusive reporting contract\n";
            return false;
        }
    }
    std::cout << "PASS: validated USB 16/24-bit PCM bypasses DSP and volume, preserving source "
        "bytes while reporting exclusive=0\n";
    return true;
}

bool runUnvalidatedSharedRefusalCase(bool autoMix = false) {
    MemoryReader source(makePcmWave(kSourceFrames, 44'100, 16));
    LazerAudioReader reader = asReader(source);
    auto capture = std::make_shared<Capture>();
    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.bit_perfect = 1;
    Engine *engine = Engine::create(config,
        std::make_unique<CaptureOutput>(capture, 0, autoMix, false));
    if (engine == nullptr) return false;
    if (autoMix) engine->setAutoMix(5000);
    const LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 0, 0, 0};
    const int32_t result = engine->open(nullptr, &reader, params);
    LazerAudioStreamInfo info{};
    engine->streamInfo(info);
    const bool refused = result == LazerAudioErrorUnsupported &&
        info.bit_perfect_active == 0 && capture->bytes.empty();
    engine->destroy();
    if (!refused) std::cerr << "FAIL: shared output or AutoMix accepted strict PCM\n";
    else std::cout << (autoMix
        ? "PASS: AutoMix cannot silently downgrade a strict USB request\n"
        : "PASS: exact format alone cannot authorize shared-output bit-perfect\n");
    return refused;
}

bool runFailedReplacementReleasesSessionCase() {
    for (int variant = 0; variant < 4; ++variant) {
        MemoryReader first(makePcmWave(kSourceFrames, 44'100, 16));
        auto firstReader = asReader(first);
        MemoryReader replacement(variant == 1 ? std::vector<uint8_t>{}
            : makePcmWave(kSourceFrames, 44'100, 16));
        auto replacementReader = asReader(replacement);
        auto capture = std::make_shared<Capture>();
        LazerAudioEngineConfig config{};
        config.abi_version = LAZER_AUDIO_ABI_VERSION;
        config.struct_size = sizeof(config);
        config.device.bit_perfect = 1;
        auto *engine = Engine::create(config,
            std::make_unique<CaptureOutput>(capture, 0, true, false));
        if (engine == nullptr) return false;
        LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 0, 0, 0};
        if (engine->open(nullptr, &firstReader, params) != LazerAudioOk) {
            engine->destroy();
            return false;
        }
        if (variant == 0) params.replay_gain_db = std::numeric_limits<double>::quiet_NaN();
        if (variant == 2) params.replay_gain_db = -6.0;
        if (variant == 3) capture->failNextOpen = true;
        const int32_t result = engine->open(nullptr, &replacementReader, params);
        LazerAudioStreamInfo info{};
        engine->streamInfo(info);
        const bool released = result != LazerAudioOk && !capture->sessionActive &&
            info.output_format_initialized == 0 && info.bit_perfect_active == 0;
        engine->destroy();
        if (!released) {
            std::cerr << "FAIL: failed replacement retained its background session, case "
                << variant << '\n';
            return false;
        }
    }
    std::cout << "PASS: invalid parameters, sources, policies and device opens release retained "
        "background sessions\n";
    return true;
}

bool runControlsDuringStrictOpenCase() {
    MemoryReader source(makePcmWave(kSourceFrames, 44'100, 16));
    auto reader = asReader(source);
    auto capture = std::make_shared<Capture>();
    capture->holdOpen = true;
    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(config);
    config.device.bit_perfect = 1;
    config.events.on_event = onEvent;
    config.events.context = capture.get();
    auto *engine = Engine::create(config,
        std::make_unique<CaptureOutput>(capture, 0, true, false));
    if (engine == nullptr) return false;
    capture->reentrantEngine = engine;
    const LazerAudioOpenParams params{sizeof(LazerAudioOpenParams), 0, 0, 0, 0};
    int32_t openResult = LazerAudioErrorState;
    std::thread opening([&] { openResult = engine->open(nullptr, &reader, params); });
    bool entered = false;
    {
        std::unique_lock guard(capture->mutex);
        entered = capture->changed.wait_for(guard, std::chrono::seconds(5),
            [&] { return capture->openEntered; });
    }
    bool refused = entered;
    if (entered) {
        const int32_t volumeResult = engine->setVolume(0.5);
        const int32_t mixResult = engine->setAutoMix(5000);
        refused = volumeResult == LazerAudioErrorState && mixResult == LazerAudioErrorState;
        const LazerAudioEqBand band{LazerAudioEqBandPeak, 1000.0, 3.0, 0.7, 1};
        const float impulse[] = {1.0f, 1.0f};
        for (int variant = 0; variant < 5; ++variant) {
            LazerAudioDspConfig dsp{};
            if (variant == 0) dsp.preamp_db = -6.0;
            if (variant == 1) { dsp.band_count = 1; dsp.bands = &band; }
            if (variant == 2) dsp.crossfeed_enabled = 1;
            if (variant == 3) dsp.limiter_enabled = 1;
            if (variant == 4) {
                dsp.impulse_response = impulse;
                dsp.impulse_response_frames = 1;
                dsp.impulse_response_channels = 2;
            }
            refused = engine->setDsp(dsp) == LazerAudioErrorState && refused;
        }
    }
    {
        std::lock_guard guard(capture->mutex);
        capture->releaseOpen = true;
    }
    capture->changed.notify_all();
    opening.join();
    const bool ok = refused && openResult == LazerAudioOk &&
        capture->readyControlResult == LazerAudioErrorUnsupported;
    engine->destroy();
    if (!ok) std::cerr << "FAIL: controls raced strict-open policy or reentrant callback deadlocked\n";
    else std::cout << "PASS: strict-open policy is atomic against volume, AutoMix and DSP controls; "
        "reentrant Ready controls obey the initialized strict policy\n";
    return ok;
}

}  // namespace

namespace lazer::audio {
std::unique_ptr<AudioOutput> createPlatformAudioOutput() { return nullptr; }
}  // namespace lazer::audio

int main() {
    const bool ok = runBitExactCase() && runDspInvalidatesCase() && runFormatMismatchCase() &&
        runBitPerfectRefusesDspCase() && runTransparentUsbCase() && runUnvalidatedSharedRefusalCase() &&
        runUnvalidatedSharedRefusalCase(true) && runFailedReplacementReleasesSessionCase() &&
        runControlsDuringStrictOpenCase();
    return ok ? 0 : 1;
}
