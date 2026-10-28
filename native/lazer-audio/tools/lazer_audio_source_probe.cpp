/* Offline decoder/resampler smoke test. It has no WASAPI dependency and never opens an output
 * endpoint, so it can validate DSD -> float PCM and EOF sample counts without producing sound. */
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <string>
#include <utility>
#include <vector>

#include "../src/source.h"

namespace {

std::filesystem::path pathFromUtf8(const std::string &value) {
    std::u8string encoded;
    encoded.reserve(value.size());
    for (const unsigned char byte : value) encoded.push_back(static_cast<char8_t>(byte));
    return std::filesystem::path(encoded);
}

bool verifyUtf8Conversions() {
    const std::string valid = "Lazer \xe9\x9f\xb3 \xf0\x9f\x8e\xa7";
    std::wstring wide;
    std::string roundTrip;
    if (!lazer::audio::utf8StringToWide(valid.c_str(), wide) ||
        !lazer::audio::wideStringToUtf8(wide.c_str(), roundTrip) || roundTrip != valid) return false;
    const std::string malformed[] = {
        std::string("\xc0\xaf", 2),       // overlong encoding
        std::string("\xed\xa0\x80", 3),   // UTF-16 surrogate code point
        std::string("\xf4\x90\x80\x80", 4), // above U+10FFFF
        std::string("\xe2\x82", 2),       // truncated sequence
    };
    for (const std::string &input : malformed) {
        std::wstring rejected;
        if (lazer::audio::utf8StringToWide(input.c_str(), rejected)) return false;
    }
    return true;
}

struct ProbeFileReaderContext {
    explicit ProbeFileReaderContext(
        const std::string &path, bool injectTransientShortRead, bool injectReaderError)
        : stream(pathFromUtf8(path), std::ios::binary),
          injectTransientShortRead(injectTransientShortRead),
          injectReaderError(injectReaderError) {
        if (!stream) return;
        stream.seekg(0, std::ios::end);
        const std::streamoff end = stream.tellg();
        if (end < 0) return;
        length = static_cast<int64_t>(end);
        stream.seekg(0, std::ios::beg);
    }

    std::ifstream stream;
    int64_t length = -1;
    bool injectTransientShortRead = false;
    int injectedReadCount = 0;
    bool injectedReadReset = false;
    bool injectReaderError = false;
    bool readerErrorPending = false;
    bool readerErrorInjected = false;
};

int32_t LAZER_AUDIO_CALL probeReaderRead(void *opaque, uint8_t *destination, int32_t length) {
    auto *reader = static_cast<ProbeFileReaderContext *>(opaque);
    if (reader == nullptr || !reader->stream || length <= 0) return -1;
    if (reader->readerErrorPending) {
        reader->readerErrorPending = false;
        reader->readerErrorInjected = true;
        return LAZER_AUDIO_READER_IO_ERROR;
    }
    int32_t request = length;
    if (reader->injectTransientShortRead && reader->injectedReadCount == 0) {
        request = 1;
        ++reader->injectedReadCount;
    } else if (reader->injectTransientShortRead && reader->injectedReadCount >= 1 &&
        reader->injectedReadCount <= 120) {
        ++reader->injectedReadCount;
        return 0;
    }
    reader->stream.read(reinterpret_cast<char *>(destination), request);
    const std::streamsize count = reader->stream.gcount();
    return count > 0 ? static_cast<int32_t>(count) : -1;
}

int64_t LAZER_AUDIO_CALL probeReaderSeek(void *opaque, int64_t position) {
    auto *reader = static_cast<ProbeFileReaderContext *>(opaque);
    if (reader == nullptr || !reader->stream || position < 0 || position > reader->length) return -1;
    reader->stream.clear();
    reader->stream.seekg(static_cast<std::streamoff>(position), std::ios::beg);
    if (reader->stream && position == 0 && reader->injectTransientShortRead &&
        !reader->injectedReadReset) {
        reader->injectedReadCount = 0;
        reader->injectedReadReset = true;
    }
    if (reader->stream && position == 0 && reader->injectReaderError) {
        reader->readerErrorPending = true;
        reader->injectReaderError = false;
    }
    return reader->stream ? position : -1;
}

int64_t LAZER_AUDIO_CALL probeReaderLength(void *opaque) {
    auto *reader = static_cast<ProbeFileReaderContext *>(opaque);
    return reader != nullptr ? reader->length : -1;
}

void LAZER_AUDIO_CALL probeReaderClose(void *opaque) {
    delete static_cast<ProbeFileReaderContext *>(opaque);
}

void LAZER_AUDIO_CALL onLog(void *context, int32_t level, const char *message) {
    (void) context;
    if (level >= LazerAudioLogWarning) {
        std::fprintf(stderr, "[native-audio] %s\n", message != nullptr ? message : "");
    }
}

class FloatPcmSink final : public lazer::audio::SourceConsumer {
public:
    int32_t accept(const uint8_t *bytes, int32_t frameCount) override {
        const auto *samples = reinterpret_cast<const float *>(bytes);
        const size_t sampleCount = static_cast<size_t>(frameCount) * channels;
        for (size_t index = 0; index < sampleCount; ++index) {
            const float sample = samples[index];
            finite = finite && std::isfinite(sample);
            peak = std::max(peak, std::abs(sample));
        }
        if (capture != nullptr) {
            capture->write(reinterpret_cast<const char *>(bytes),
                static_cast<std::streamsize>(sampleCount * sizeof(float)));
        }
        frames += frameCount;
        return frameCount;
    }

    bool shouldPump() const override { return true; }
    bool isCancelled() const override { return false; }

    int32_t channels = 2;
    std::ofstream *capture = nullptr;
    int64_t frames = 0;
    float peak = 0.0f;
    bool finite = true;
};

class DopSink final : public lazer::audio::SourceConsumer {
public:
    explicit DopSink(int32_t channelCount) : channels(channelCount) {}

    int32_t accept(const uint8_t *bytes, int32_t frameCount) override {
        if (bytes == nullptr || frameCount < 0 || (channels != 1 && channels != 2)) {
            valid = false;
            return 0;
        }
        for (int32_t frame = 0; frame < frameCount; ++frame) {
            const uint8_t expectedMarker = (frames & 1) == 0 ? 0x05 : 0xFA;
            for (int32_t channel = 0; channel < channels; ++channel) {
                const uint8_t *word = bytes +
                    (static_cast<size_t>(frame) * static_cast<size_t>(channels) +
                        static_cast<size_t>(channel)) * 3;
                markerSequenceValid = markerSequenceValid && word[2] == expectedMarker;
                hasNonIdlePayload = hasNonIdlePayload || word[0] != 0x69 || word[1] != 0x69;
            }
            ++frames;
        }
        if (capture != nullptr) {
            capture->write(reinterpret_cast<const char *>(bytes),
                static_cast<std::streamsize>(static_cast<size_t>(frameCount) *
                    static_cast<size_t>(channels) * 3));
        }
        return frameCount;
    }

    bool shouldPump() const override { return true; }
    bool isCancelled() const override { return false; }

    int32_t channels = 2;
    std::ofstream *capture = nullptr;
    int64_t frames = 0;
    bool markerSequenceValid = true;
    bool hasNonIdlePayload = false;
    bool valid = true;
};

}  // namespace

int runProbe(int argc, char **argv) {
    if (argc < 2) {
        std::fprintf(stderr,
            "usage: lazer-audio-source-probe <file> [target-rate|--dop] [capture.raw] [seek-millis|end] [seek-capture.raw] [--reader|--reader-eagain|--reader-error|--reader-error-pump]\n");
        return 2;
    }
    if (!verifyUtf8Conversions()) {
        std::fprintf(stderr, "UTF-8 path conversion round-trip or validation failed\n");
        return 1;
    }

    const std::string readerMode = argv[argc - 1];
    const bool injectReaderError = readerMode == "--reader-error";
    const bool injectPumpReaderError = readerMode == "--reader-error-pump";
    const bool useReader = readerMode == "--reader" || readerMode == "--reader-eagain" ||
        injectReaderError || injectPumpReaderError;
    const bool injectTransientShortRead = readerMode == "--reader-eagain";
    const int argumentCount = useReader ? argc - 1 : argc;
    const bool doPMode = argumentCount > 2 && std::string(argv[2]) == "--dop";

    lazer::audio::LogProxy log;
    log.install({&onLog, nullptr});
    lazer::audio::AudioSource source(&log);
    LazerAudioOpenParams params{};
    params.struct_size = sizeof(params);
    const std::string path = argv[1];
    LazerAudioReader reader{};
    ProbeFileReaderContext *activeReaderContext = nullptr;
    auto openSource = [&]() -> int32_t {
        if (!useReader) {
            std::wstring widePath;
            if (!lazer::audio::utf8StringToWide(path.c_str(), widePath)) {
                std::fprintf(stderr, "input path is not valid UTF-8\n");
                return LazerAudioErrorInvalidArgument;
            }
            return source.openFile(widePath.c_str(), params);
        }
        auto *readerContext = new ProbeFileReaderContext(
            path, injectTransientShortRead, injectReaderError);
        if (!readerContext->stream || readerContext->length < 0) {
            delete readerContext;
            return static_cast<int32_t>(LazerAudioErrorSource);
        }
        reader.read = &probeReaderRead;
        reader.seek = &probeReaderSeek;
        reader.length = &probeReaderLength;
        reader.close = &probeReaderClose;
        reader.context = readerContext;
        const int32_t result = source.openReader(reader, params);
        activeReaderContext = result == LazerAudioOk ? readerContext : nullptr;
        return result;
    };
    const int32_t opened = openSource();
    if (injectReaderError) {
        if (opened == LazerAudioErrorSource &&
            source.lastError().find("audio reader reported an I/O error") != std::string::npos) {
            std::printf("reader I/O error was surfaced instead of clean EOF\n");
            return 0;
        }
        std::fprintf(stderr, "reader I/O error was not surfaced: %d %s\n",
            opened, source.lastError().c_str());
        return 1;
    }
    if (opened != LazerAudioOk) {
        std::fprintf(stderr, "open failed: %d %s\n", opened, source.lastError().c_str());
        return 1;
    }
    if (injectPumpReaderError) {
        if (activeReaderContext == nullptr) {
            std::fprintf(stderr, "reader context was not retained after successful open\n");
            return 1;
        }
        activeReaderContext->readerErrorPending = true;
    }
    const auto &description = source.description();
    if (!description.dsd || description.dsdRateMultiplier <= 0) {
        std::fprintf(stderr, "expected a recognized DSD source, codec=%s\n", description.codec.c_str());
        return 1;
    }
    const int32_t targetRate = doPMode
        ? description.sampleRate / 2
        : (argumentCount > 2 ? std::atoi(argv[2]) : 44'100);
    FloatPcmSink sink;
    DopSink dopSink(description.channels);
    lazer::audio::SourceConsumer &consumer = doPMode
        ? static_cast<lazer::audio::SourceConsumer &>(dopSink)
        : static_cast<lazer::audio::SourceConsumer &>(sink);
    std::ofstream capture;
    std::string capturePath;
    if (argumentCount > 3 && std::string(argv[3]) != "-") {
        capturePath = argv[3];
        capture.open(capturePath, std::ios::binary);
        if (!capture) {
            std::fprintf(stderr, "could not create output capture file\n");
            return 1;
        }
        sink.capture = &capture;
        dopSink.capture = &capture;
    }
    lazer::audio::TargetFormat target{};
    target.sampleRate = targetRate;
    target.channels = description.channels;
    target.bitsPerSample = doPMode ? 24 : 0;
    target.containerBitsPerSample = doPMode ? 24 : 0;
    target.doP = doPMode;
    sink.channels = target.channels;
    const int32_t targetResult = source.setTargetFormat(target);
    if (targetResult != LazerAudioOk) {
        std::fprintf(stderr, "resampler setup failed: %d %s\n", targetResult, source.lastError().c_str());
        return 1;
    }

    const int32_t pumped = source.pump(consumer);
    if (injectPumpReaderError) {
        if (activeReaderContext != nullptr && activeReaderContext->readerErrorInjected &&
            pumped == LazerAudioErrorSource && !source.reachedEndOfStream() &&
            source.lastError().find("audio reader reported an I/O error") != std::string::npos) {
            std::printf("pump surfaced reader I/O error instead of clean EOF\n");
            return 0;
        }
        std::fprintf(stderr, "pump reader I/O error was not surfaced: %d eof=%d %s\n",
            pumped, source.reachedEndOfStream() ? 1 : 0, source.lastError().c_str());
        return 1;
    }
    if (pumped != LazerAudioOk || !source.reachedEndOfStream()) {
        std::fprintf(stderr, "decode failed: %d %s\n", pumped, source.lastError().c_str());
        return 1;
    }
    const int64_t outputFrames = doPMode ? dopSink.frames : sink.frames;
    const int64_t expectedFrames = description.durationMillis * targetRate / 1000;
    /* DSF duration can be inferred from its block-padded data size rather than the exact sample
     * count, so allow up to 10 ms of container-estimation error while still catching lost frames. */
    const int64_t tolerance = std::max<int64_t>(targetRate / 100, expectedFrames / 100);
    if (doPMode) {
        if (!dopSink.valid || !dopSink.markerSequenceValid || !dopSink.hasNonIdlePayload ||
            (capture.is_open() && !capture) ||
            std::llabs(outputFrames - expectedFrames) > tolerance) {
            std::fprintf(stderr,
                "invalid DoP: frames=%lld expected=%lld tolerance=%lld markers=%d payload=%d\n",
                static_cast<long long>(outputFrames), static_cast<long long>(expectedFrames),
                static_cast<long long>(tolerance), dopSink.markerSequenceValid ? 1 : 0,
                dopSink.hasNonIdlePayload ? 1 : 0);
            return 1;
        }
        std::printf("DSD%d %dch -> DoP %dHz 24-bit carrier: %lld frames, alternating markers=1, EOF=1\n",
            description.dsdRateMultiplier, description.channels, targetRate,
            static_cast<long long>(outputFrames));
    } else {
        if (!sink.finite || sink.peak < 0.001f || (capture.is_open() && !capture) ||
            std::llabs(outputFrames - expectedFrames) > tolerance) {
            std::fprintf(stderr,
                "invalid float PCM: frames=%lld expected=%lld tolerance=%lld finite=%d peak=%g\n",
                static_cast<long long>(outputFrames), static_cast<long long>(expectedFrames),
                static_cast<long long>(tolerance), sink.finite ? 1 : 0, sink.peak);
            return 1;
        }

        std::printf("DSD%d %dch -> float PCM %dHz: %lld frames, finite=1, peak=%g, EOF=1\n",
            description.dsdRateMultiplier, description.channels, targetRate,
            static_cast<long long>(outputFrames), sink.peak);
    }

    const std::string seekArgument = argumentCount > 4 ? argv[4] : "";
    const bool requestMediaEnd = seekArgument == "end";
    const int64_t seekMillis = requestMediaEnd
        ? description.durationMillis
        : seekArgument.empty() ? 0 : std::atoll(seekArgument.c_str());
    if (requestMediaEnd && seekMillis <= 0) {
        std::fprintf(stderr, "could not seek to media end because its duration is unknown\n");
        return 2;
    }
    if (seekMillis > 0) {
        if (seekMillis > description.durationMillis) {
            std::fprintf(stderr, "seek-millis must not exceed the source duration\n");
            return 2;
        }
        const bool seekAtEnd = seekMillis == description.durationMillis;
        const int64_t fullOutputFrames = outputFrames;
        const std::string seekCapturePath = argumentCount > 5 ? argv[5] : "";
        const bool compareCapture = capture.is_open() && !seekCapturePath.empty() &&
            seekCapturePath != "-" && !seekAtEnd;
        source.close();
        if (capture.is_open()) capture.close();

        const int32_t reopened = openSource();
        if (reopened != LazerAudioOk) {
            std::fprintf(stderr, "reopen before seek failed: %d %s\n",
                reopened, source.lastError().c_str());
            return 1;
        }
        source.requestSeek(seekMillis);
        target.channels = source.description().channels;
        std::ofstream seekCapture;
        if (!seekCapturePath.empty() && seekCapturePath != "-") {
            seekCapture.open(seekCapturePath, std::ios::binary);
            if (!seekCapture) {
            std::fprintf(stderr, "could not create seek output capture file\n");
            return 1;
        }
            sink.capture = &seekCapture;
            dopSink.capture = &seekCapture;
        } else {
            sink.capture = nullptr;
            dopSink.capture = nullptr;
        }
        sink.channels = target.channels;
        sink.frames = 0;
        sink.peak = 0.0f;
        sink.finite = true;
        dopSink.channels = target.channels;
        dopSink.frames = 0;
        dopSink.markerSequenceValid = true;
        dopSink.hasNonIdlePayload = false;
        dopSink.valid = true;
        const int32_t seekTargetResult = source.setTargetFormat(target);
        if (seekTargetResult != LazerAudioOk) {
            std::fprintf(stderr, "resampler setup before seek failed: %d %s\n",
                seekTargetResult, source.lastError().c_str());
            return 1;
        }
        const int32_t seekPumped = source.pump(consumer);
        const int64_t seekOutputFrames = doPMode ? dopSink.frames : sink.frames;
        const int64_t skippedFrames = static_cast<int64_t>(std::llround(
            static_cast<double>(seekMillis) * targetRate / 1000.0));
        const int64_t seekExpectedFrames = seekAtEnd
            ? 0 : std::max<int64_t>(0, fullOutputFrames - skippedFrames);
        /* Use the measured full decode as the duration reference; container estimates for padded
         * DSF blocks can be several milliseconds longer than their playable sample count. */
        constexpr int64_t seekTolerance = 2;
        if (seekPumped != LazerAudioOk || !source.reachedEndOfStream() ||
            (seekAtEnd && seekOutputFrames != 0) ||
            (!seekAtEnd && doPMode && (!dopSink.valid || !dopSink.markerSequenceValid ||
                !dopSink.hasNonIdlePayload)) ||
            (!seekAtEnd && !doPMode && (!sink.finite || sink.peak < 0.001f)) ||
            (seekExpectedFrames > 0 &&
                std::llabs(seekOutputFrames - seekExpectedFrames) > seekTolerance)) {
            std::fprintf(stderr,
                "invalid seek output: frames=%lld expected=%lld tolerance=%lld valid=%d eof=%d\n",
                static_cast<long long>(seekOutputFrames), static_cast<long long>(seekExpectedFrames),
                static_cast<long long>(seekTolerance),
                seekAtEnd ? (seekOutputFrames == 0) :
                    doPMode ? (dopSink.valid && dopSink.markerSequenceValid && dopSink.hasNonIdlePayload) : sink.finite,
                source.reachedEndOfStream() ? 1 : 0);
            return 1;
        }
        if (seekCapture.is_open()) seekCapture.close();
        if (compareCapture) {
            std::ifstream fullPcm(capturePath, std::ios::binary);
            std::ifstream seekPcm(seekCapturePath, std::ios::binary);
            const int64_t channelCount = source.description().channels;
            const int64_t bytesPerFrame = doPMode
                ? static_cast<int64_t>(channelCount) * 3
                : channelCount * static_cast<int64_t>(sizeof(float));
            const int64_t referenceOffset = skippedFrames * bytesPerFrame;
            if (!fullPcm || !seekPcm ||
                referenceOffset > std::numeric_limits<std::streamoff>::max()) {
                std::fprintf(stderr, "could not open PCM captures for seek comparison\n");
                return 1;
            }
            fullPcm.seekg(static_cast<std::streamoff>(referenceOffset));
            std::vector<uint8_t> reference(16'384 * static_cast<size_t>(bytesPerFrame));
            std::vector<uint8_t> actual(reference.size());
            int64_t remainingFrames = seekExpectedFrames;
            float maxDifference = 0.0f;
            bool capturesMatch = static_cast<bool>(fullPcm);
            while (capturesMatch && remainingFrames > 0) {
                const size_t count = static_cast<size_t>(std::min<int64_t>(
                    remainingFrames, static_cast<int64_t>(reference.size() /
                        static_cast<size_t>(bytesPerFrame))));
                const auto byteCount = static_cast<std::streamsize>(
                    count * static_cast<size_t>(bytesPerFrame));
                fullPcm.read(reinterpret_cast<char *>(reference.data()), byteCount);
                seekPcm.read(reinterpret_cast<char *>(actual.data()), byteCount);
                if (fullPcm.gcount() != byteCount || seekPcm.gcount() != byteCount) {
                    capturesMatch = false;
                    break;
                }
                if (doPMode) {
                    for (size_t frame = 0; frame < count; ++frame) {
                        for (int32_t channel = 0; channel < source.description().channels; ++channel) {
                            const size_t offset = frame * static_cast<size_t>(bytesPerFrame) +
                                static_cast<size_t>(channel) * 3;
                            capturesMatch = capturesMatch && reference[offset] == actual[offset] &&
                                reference[offset + 1] == actual[offset + 1];
                        }
                    }
                } else {
                    for (size_t offset = 0; offset < count * static_cast<size_t>(bytesPerFrame);
                        offset += sizeof(float)) {
                        float referenceSample = 0.0f;
                        float actualSample = 0.0f;
                        std::memcpy(&referenceSample, reference.data() + offset, sizeof(float));
                        std::memcpy(&actualSample, actual.data() + offset, sizeof(float));
                        maxDifference = std::max(maxDifference,
                            std::abs(referenceSample - actualSample));
                    }
                }
                remainingFrames -= static_cast<int64_t>(count);
            }
            constexpr float kSeekPcmTolerance = 0.00001f;
            if (!capturesMatch || (!doPMode && maxDifference > kSeekPcmTolerance)) {
                if (doPMode) {
                    std::fprintf(stderr, "seek DoP payload differs from full-decode suffix\n");
                } else {
                    std::fprintf(stderr,
                        "seek PCM differs from full-decode suffix: max-delta=%g tolerance=%g\n",
                        maxDifference, kSeekPcmTolerance);
                }
                return 1;
            }
            if (doPMode) std::printf("seek DoP payload matches full-decode suffix\n");
            else std::printf("seek PCM matches full-decode suffix: max-delta=%g\n", maxDifference);
        }
        if (seekAtEnd) {
            std::printf("seek %lldms at media end -> clean EOF, output frames=0\n",
                static_cast<long long>(seekMillis));
        } else if (doPMode) {
            std::printf("seek %lldms -> %lld DoP frames, alternating markers=1, EOF=1\n",
                static_cast<long long>(seekMillis), static_cast<long long>(seekOutputFrames));
        } else {
            std::printf("seek %lldms -> %lld frames, finite=1, peak=%g, EOF=1\n",
                static_cast<long long>(seekMillis), static_cast<long long>(seekOutputFrames), sink.peak);
        }
    }
    return 0;
}

#ifdef _WIN32
int wmain(int argc, wchar_t **wideArgv) {
    std::vector<std::string> arguments;
    arguments.reserve(static_cast<size_t>(argc));
    for (int index = 0; index < argc; ++index) {
        std::string argument;
        if (!lazer::audio::wideStringToUtf8(wideArgv[index], argument)) {
            std::fprintf(stderr, "argument is not valid Unicode\n");
            return 2;
        }
        arguments.push_back(std::move(argument));
    }
    std::vector<char *> argv;
    argv.reserve(arguments.size());
    for (std::string &argument : arguments) argv.push_back(argument.data());
    return runProbe(argc, argv.data());
}
#else
int main(int argc, char **argv) {
    return runProbe(argc, argv);
}
#endif
