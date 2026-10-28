/* Exercises pull-style Android DSD decoding without an audio device. */
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "../src/dsd_pcm_decoder.h"

namespace {

std::filesystem::path pathFromUtf8(const std::string &value) {
    std::u8string encoded;
    encoded.reserve(value.size());
    for (const unsigned char byte : value) encoded.push_back(static_cast<char8_t>(byte));
    return std::filesystem::path(encoded);
}

struct FileReaderContext {
    explicit FileReaderContext(const std::string &path) : stream(pathFromUtf8(path), std::ios::binary) {
        if (!stream) return;
        stream.seekg(0, std::ios::end);
        const std::streamoff end = stream.tellg();
        if (end < 0) return;
        length = static_cast<int64_t>(end);
        stream.seekg(0, std::ios::beg);
    }

    std::ifstream stream;
    int64_t length = -1;
    std::atomic<bool> cancelled{false};
};

int32_t LAZER_AUDIO_CALL readFile(void *opaque, uint8_t *destination, int32_t length) {
    auto *reader = static_cast<FileReaderContext *>(opaque);
    if (reader == nullptr || destination == nullptr || length <= 0) {
        return LAZER_AUDIO_READER_IO_ERROR;
    }
    if (reader->cancelled.load(std::memory_order_acquire)) return LAZER_AUDIO_READER_IO_ERROR;
    reader->stream.read(reinterpret_cast<char *>(destination), length);
    const std::streamsize count = reader->stream.gcount();
    if (count > 0) return static_cast<int32_t>(count);
    return reader->stream.eof() ? LAZER_AUDIO_READER_EOF : LAZER_AUDIO_READER_IO_ERROR;
}

int64_t LAZER_AUDIO_CALL seekFile(void *opaque, int64_t position) {
    auto *reader = static_cast<FileReaderContext *>(opaque);
    if (reader == nullptr || reader->cancelled.load(std::memory_order_acquire) ||
        position < 0 || position > reader->length) return -1;
    reader->stream.clear();
    reader->stream.seekg(static_cast<std::streamoff>(position), std::ios::beg);
    return reader->stream ? position : -1;
}

int64_t LAZER_AUDIO_CALL lengthFile(void *opaque) {
    const auto *reader = static_cast<FileReaderContext *>(opaque);
    return reader != nullptr ? reader->length : -1;
}

void LAZER_AUDIO_CALL cancelFile(void *opaque) {
    auto *reader = static_cast<FileReaderContext *>(opaque);
    if (reader != nullptr) reader->cancelled.store(true, std::memory_order_release);
}

void LAZER_AUDIO_CALL closeFile(void *opaque) {
    delete static_cast<FileReaderContext *>(opaque);
}

struct OpenDecoder {
    lazer::audio::DsdPcmDecoder decoder;
    lazer::audio::DsdPcmFormat format;
};

int32_t openDecoder(
    OpenDecoder &opened, const std::string &path, int32_t sampleRate,
    FileReaderContext **contextOut, bool doP = false) {
    auto *context = new FileReaderContext(path);
    if (!context->stream || context->length < 0) {
        delete context;
        return LazerAudioErrorSource;
    }
    LazerAudioReader reader{};
    reader.read = &readFile;
    reader.seek = &seekFile;
    reader.length = &lengthFile;
    reader.close = &closeFile;
    reader.context = context;
    reader.cancel = &cancelFile;
    const int32_t result = opened.decoder.open(reader, sampleRate, opened.format, doP);
    if (result == LazerAudioOk) {
        if (contextOut != nullptr) *contextOut = context;
    }
    /* AudioSource owns and closes the callback context once open() is attempted. */
    return result;
}

bool readToEnd(lazer::audio::DsdPcmDecoder &decoder, int32_t frameBytes,
    std::vector<uint8_t> &output) {
    constexpr int32_t kReadFrames = 257;  // exercise non-power-of-two pull boundaries
    std::vector<uint8_t> buffer(static_cast<size_t>(kReadFrames) * frameBytes);
    for (;;) {
        int32_t frames = 0;
        bool endOfStream = false;
        const int32_t result = decoder.readFrames(buffer.data(), kReadFrames, frames, endOfStream);
        if (result != LazerAudioOk || frames < 0 || frames > kReadFrames) return false;
        const size_t bytes = static_cast<size_t>(frames) * frameBytes;
        output.insert(output.end(), buffer.begin(), buffer.begin() + static_cast<ptrdiff_t>(bytes));
        if (endOfStream) return frames >= 0;
        if (frames == 0) return false;
    }
}

bool verifySamples(const std::vector<uint8_t> &pcm, float &peak) {
    if (pcm.empty() || pcm.size() % sizeof(float) != 0) return false;
    peak = 0.0f;
    for (size_t offset = 0; offset < pcm.size(); offset += sizeof(float)) {
        float sample = 0.0f;
        std::memcpy(&sample, pcm.data() + offset, sizeof(sample));
        if (!std::isfinite(sample)) return false;
        peak = std::max(peak, std::abs(sample));
    }
    return peak > 0.001f;
}

bool compareSuffix(const std::vector<uint8_t> &full, const std::vector<uint8_t> &tail,
    int32_t frameBytes, int64_t skipFrames) {
    if (frameBytes <= 0 || skipFrames < 0) return false;
    const uint64_t offset = static_cast<uint64_t>(skipFrames) * static_cast<uint64_t>(frameBytes);
    if (offset > full.size() || tail.size() != full.size() - static_cast<size_t>(offset)) return false;
    constexpr float kMaximumSampleDifference = 0.00001f;
    for (size_t byte = 0; byte < tail.size(); byte += sizeof(float)) {
        float expected = 0.0f;
        float actual = 0.0f;
        std::memcpy(&expected, full.data() + static_cast<size_t>(offset) + byte, sizeof(expected));
        std::memcpy(&actual, tail.data() + byte, sizeof(actual));
        if (!std::isfinite(expected) || !std::isfinite(actual) ||
            std::abs(expected - actual) > kMaximumSampleDifference) return false;
    }
    return true;
}

bool saveCapture(const std::string &path, const std::vector<uint8_t> &bytes) {
    if (path.empty() || path == "-") return true;
    std::ofstream output(path, std::ios::binary);
    if (!output) return false;
    output.write(reinterpret_cast<const char *>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
    return static_cast<bool>(output);
}

int runCancelProbe(const std::string &path, int32_t sampleRate) {
    OpenDecoder opened;
    const int32_t result = openDecoder(opened, path, sampleRate, nullptr);
    if (result != LazerAudioOk) {
        std::fprintf(stderr, "open for cancellation probe failed: %d %s\n",
            result, opened.decoder.lastError().c_str());
        return 1;
    }
    /* Leave the consumer idle so the bounded ring applies back-pressure before teardown. */
    std::this_thread::sleep_for(std::chrono::milliseconds(150));
    const auto started = std::chrono::steady_clock::now();
    opened.decoder.close();
    const auto elapsed = std::chrono::steady_clock::now() - started;
    if (elapsed > std::chrono::seconds(3)) {
        std::fprintf(stderr, "cancellation took too long: %lld ms\n",
            static_cast<long long>(std::chrono::duration_cast<std::chrono::milliseconds>(elapsed).count()));
        return 1;
    }
    std::printf("back-pressured DSD decoder cancelled in %lld ms\n",
        static_cast<long long>(std::chrono::duration_cast<std::chrono::milliseconds>(elapsed).count()));
    return 0;
}

bool verifyDopMarkers(const std::vector<uint8_t> &carrier) {
    if (carrier.empty() || carrier.size() % 6 != 0) return false;
    uint8_t expected = 0x05;
    for (size_t offset = 0; offset < carrier.size(); offset += 6) {
        if (carrier[offset + 2] != expected || carrier[offset + 5] != expected) return false;
        expected = expected == 0x05 ? 0xFA : 0x05;
    }
    return true;
}

bool compareDopPayload(const std::vector<uint8_t> &expected, const std::vector<uint8_t> &actual) {
    if (expected.size() != actual.size() || expected.size() % 6 != 0) return false;
    for (size_t offset = 0; offset < actual.size(); offset += 6) {
        if (actual[offset] != expected[offset] || actual[offset + 1] != expected[offset + 1] ||
            actual[offset + 3] != expected[offset + 3] || actual[offset + 4] != expected[offset + 4]) {
            return false;
        }
    }
    return true;
}

int runDopProbe(const std::string &path) {
    OpenDecoder opened;
    const int32_t result = openDecoder(opened, path, 0, nullptr, true);
    if (result != LazerAudioOk) {
        std::fprintf(stderr, "DoP open failed: %d %s\n", result, opened.decoder.lastError().c_str());
        return 1;
    }
    if (opened.format.channels != 2 || opened.format.dsdRateMultiplier < 64 ||
        opened.format.dsdRateMultiplier > 256) {
        std::fprintf(stderr, "DoP returned an unsupported channel layout or Android carrier rate\n");
        return 1;
    }
    const int32_t expectedRate = 44'100 * opened.format.dsdRateMultiplier / 16;
    const int32_t frameBytes = opened.decoder.frameBytes();
    if (opened.format.sampleRate != expectedRate || frameBytes != 6) {
        std::fprintf(stderr, "DoP must use the exact stereo PCM24 carrier rate and six-byte frame\n");
        return 1;
    }

    std::vector<uint8_t> full;
    if (!readToEnd(opened.decoder, frameBytes, full) || !verifyDopMarkers(full)) {
        std::fprintf(stderr, "DoP decode failed or emitted invalid alternating channel markers: %s\n",
            opened.decoder.lastError().c_str());
        return 1;
    }
    const int64_t fullFrames = static_cast<int64_t>(full.size() / 6);
    if (opened.format.totalFrames > 0 && fullFrames != opened.format.totalFrames) {
        std::fprintf(stderr, "DoP decoded %lld frames but the source declared %lld\n",
            static_cast<long long>(fullFrames), static_cast<long long>(opened.format.totalFrames));
        return 1;
    }

    constexpr int64_t seekMillis = 100;
    OpenDecoder seeked;
    if (openDecoder(seeked, path, 0, nullptr, true) != LazerAudioOk ||
        seeked.decoder.seek(seekMillis) != LazerAudioOk) {
        std::fprintf(stderr, "DoP seek setup failed: %s\n", seeked.decoder.lastError().c_str());
        return 1;
    }
    std::vector<uint8_t> tail;
    if (!readToEnd(seeked.decoder, seeked.decoder.frameBytes(), tail) || !verifyDopMarkers(tail)) {
        std::fprintf(stderr, "DoP seek suffix has invalid carrier frames: %s\n",
            seeked.decoder.lastError().c_str());
        return 1;
    }
    const int64_t skippedFrames = static_cast<int64_t>(std::llround(
        static_cast<double>(seekMillis) * opened.format.sampleRate / 1000.0));
    if (skippedFrames > fullFrames ||
        !compareDopPayload(
            std::vector<uint8_t>(full.begin() + skippedFrames * 6, full.end()), tail)) {
        std::fprintf(stderr, "DoP seek did not preserve the exact DSD payload suffix\n");
        return 1;
    }
    std::printf("DSD%d DoP: %d Hz PCM24 carrier, %lld frames, seek and marker phases verified\n",
        opened.format.dsdRateMultiplier, opened.format.sampleRate,
        static_cast<long long>(fullFrames));
    return 0;
}

int runExpectDopUnsupported(const std::string &path) {
    OpenDecoder opened;
    const int32_t result = openDecoder(opened, path, 0, nullptr, true);
    if (result == LazerAudioOk) {
        opened.decoder.close();
        std::fprintf(stderr, "DST must not be converted to a DoP carrier\n");
        return 1;
    }
    std::printf("unsupported DoP source rejected as required: %s\n", opened.decoder.lastError().c_str());
    return 0;
}

int runProbe(int argc, char **argv) {
    if (argc < 3) {
        std::fprintf(stderr,
            "usage: lazer-audio-dsd-pcm-probe <file.dsf|file.dff> <target-rate> [seek-ms] [full.raw] [seek.raw]\n"
            "       lazer-audio-dsd-pcm-probe <file.dsf|file.dff> <target-rate> --cancel-only\n"
            "       lazer-audio-dsd-pcm-probe <file.dsf|file.dff> 0 --dop|--expect-dop-unsupported\n");
        return 2;
    }
    const std::string path = argv[1];
    char *rateEnd = nullptr;
    const long parsedRate = std::strtol(argv[2], &rateEnd, 10);
    if (rateEnd == argv[2] || *rateEnd != '\0' || parsedRate < 0 ||
        parsedRate > std::numeric_limits<int32_t>::max()) {
        std::fprintf(stderr, "target-rate must be zero (automatic) or a positive 32-bit integer\n");
        return 2;
    }
    int32_t sampleRate = static_cast<int32_t>(parsedRate);
    if (argc > 3 && std::string(argv[3]) == "--dop") return runDopProbe(path);
    if (argc > 3 && std::string(argv[3]) == "--expect-dop-unsupported") {
        return runExpectDopUnsupported(path);
    }
    if (argc > 3 && std::string(argv[3]) == "--cancel-only") {
        return runCancelProbe(path, sampleRate);
    }

    const int64_t requestedSeekMillis = argc > 3 ? std::atoll(argv[3]) : 0;
    const std::string fullCapture = argc > 4 ? argv[4] : "";
    const std::string seekCapture = argc > 5 ? argv[5] : "";
    OpenDecoder opened;
    const int32_t result = openDecoder(opened, path, sampleRate, nullptr);
    if (result != LazerAudioOk) {
        std::fprintf(stderr, "open failed: %d %s\n", result, opened.decoder.lastError().c_str());
        return 1;
    }
    if (opened.format.channels < 1 || opened.format.channels > 8 ||
        opened.format.dsdRateMultiplier < 64 || opened.format.dsdRateMultiplier > 1024) {
        std::fprintf(stderr, "decoder returned an invalid DSD format\n");
        return 1;
    }
    const int32_t expectedSampleRate = sampleRate > 0 ? sampleRate :
        std::min(44'100 * opened.format.dsdRateMultiplier / 16, 192'000);
    if (opened.format.sampleRate != expectedSampleRate) {
        std::fprintf(stderr,
            "decoder returned PCM rate %d for requested %d Hz (expected %d)\n",
            opened.format.sampleRate, sampleRate, expectedSampleRate);
        return 1;
    }
    sampleRate = opened.format.sampleRate;
    std::printf("DSD%d converted to %d Hz float PCM\n",
        opened.format.dsdRateMultiplier, sampleRate);
    const int32_t frameBytes = opened.decoder.frameBytes();
    if (frameBytes != opened.format.channels * static_cast<int32_t>(sizeof(float))) {
        std::fprintf(stderr, "decoder frame size does not match interleaved float PCM\n");
        return 1;
    }

    std::vector<uint8_t> full;
    if (!readToEnd(opened.decoder, frameBytes, full)) {
        std::fprintf(stderr, "DSD-to-PCM read failed: %s\n", opened.decoder.lastError().c_str());
        return 1;
    }
    const int64_t decodedFrames = static_cast<int64_t>(
        full.size() / static_cast<size_t>(frameBytes));
    if (opened.format.totalFrames > 0 && decodedFrames != opened.format.totalFrames) {
        std::fprintf(stderr, "decoded %lld frames but the source declared %lld\n",
            static_cast<long long>(decodedFrames),
            static_cast<long long>(opened.format.totalFrames));
        return 1;
    }
    float peak = 0.0f;
    if (!verifySamples(full, peak) || !saveCapture(fullCapture, full)) {
        std::fprintf(stderr, "full decode was silent/non-finite or capture failed\n");
        return 1;
    }
    if (requestedSeekMillis < 0 || requestedSeekMillis > opened.format.durationMillis) {
        std::fprintf(stderr, "seek-ms must be within the reported media duration\n");
        return 2;
    }
    if (requestedSeekMillis > 0) {
        const int64_t skippedFrames = static_cast<int64_t>(std::llround(
            static_cast<double>(requestedSeekMillis) * sampleRate / 1000.0));

        /* Seek during playback while unread PCM is still queued, so no pre-seek frames may leak. */
        OpenDecoder active;
        const int32_t activeOpen = openDecoder(active, path, sampleRate, nullptr);
        if (activeOpen != LazerAudioOk) {
            std::fprintf(stderr, "second decoder open failed: %d %s\n",
                activeOpen, active.decoder.lastError().c_str());
            return 1;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(25));
        std::vector<uint8_t> firstRead(static_cast<size_t>(257) * frameBytes);
        int32_t firstFrames = 0;
        bool firstReadEof = false;
        if (active.decoder.readFrames(firstRead.data(), 257, firstFrames, firstReadEof) != LazerAudioOk ||
            firstFrames <= 0 || firstReadEof || active.decoder.seek(requestedSeekMillis) != LazerAudioOk) {
            std::fprintf(stderr, "seek during queued playback could not be requested\n");
            return 1;
        }
        std::vector<uint8_t> activeTail;
        if (!readToEnd(active.decoder, frameBytes, activeTail) ||
            !compareSuffix(full, activeTail, frameBytes, skippedFrames)) {
            std::fprintf(stderr, "queued pre-seek PCM escaped or active seek suffix differs\n");
            return 1;
        }

        if (opened.decoder.seek(requestedSeekMillis) != LazerAudioOk) {
            std::fprintf(stderr, "seek request failed\n");
            return 1;
        }
        std::vector<uint8_t> tail;
        if (!readToEnd(opened.decoder, frameBytes, tail) ||
            !compareSuffix(full, tail, frameBytes, skippedFrames) || !saveCapture(seekCapture, tail)) {
            std::fprintf(stderr, "seek output does not match the full-decode suffix: %s\n",
                opened.decoder.lastError().c_str());
            return 1;
        }

        /* A second seek after EOF verifies that the producer parks and can resume repeatedly. */
        if (opened.decoder.seek(0) != LazerAudioOk) {
            std::fprintf(stderr, "rewind request after EOF failed\n");
            return 1;
        }
        std::vector<uint8_t> rewind;
        if (!readToEnd(opened.decoder, frameBytes, rewind) || !compareSuffix(full, rewind, frameBytes, 0)) {
            std::fprintf(stderr, "rewind after EOF does not reproduce the first decode\n");
            return 1;
        }
        std::printf("seek %lld ms and rewind after EOF match the original PCM\n",
            static_cast<long long>(requestedSeekMillis));
    }

    std::printf("DSD%d %dch -> float PCM %dHz: %lld/%lld frames, finite=1, peak=%g, EOF=1\n",
        opened.format.dsdRateMultiplier, opened.format.channels, sampleRate,
        static_cast<long long>(decodedFrames),
        static_cast<long long>(opened.format.totalFrames), peak);
    return 0;
}

}  // namespace

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
