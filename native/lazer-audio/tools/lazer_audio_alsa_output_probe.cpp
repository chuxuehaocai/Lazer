/* Hardware-free checks for ALSA output negotiation and queue lifecycle. The `null` PCM is enabled
 * only when both explicit CMake test options are on; release builds accept direct hw: names only. */
#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include <alsa/asoundlib.h>

#include "output_alsa.h"
#include "output_alsa_recovery.h"

extern "C" int32_t lazer_audio_test_alsa_dop_null_negotiation(int32_t carrierRate,
    int32_t channels, int32_t *actualRate, int32_t *actualChannels,
    int32_t *validBits, int32_t *containerBits);
extern "C" int32_t lazer_audio_test_alsa_native_dsd_null_negotiation(
    int32_t dsdByteClock, int32_t dsdRateMultiplier, int32_t channels, int32_t formatIndex,
    int32_t *actualRate, int32_t *actualChannels, int32_t *validBits,
    int32_t *containerBits, int32_t *formatSelection);
extern "C" int32_t lazer_audio_test_alsa_dop_stage_bytes(const uint8_t *bytes,
    int32_t frameCount, int32_t channels, uint8_t *destination, int32_t destinationBytes);
extern "C" int32_t lazer_audio_test_alsa_dop_suspend_resume(int32_t alsaError,
    int32_t retryCount, int32_t finalResumeResult, int32_t *resumeCalls, int32_t *waitCalls);

namespace {

bool fail(const std::string &message) {
    std::fprintf(stderr, "FAIL: %s\n", message.c_str());
    return false;
}

std::string alsaError(const char *operation, int error) {
    return std::string(operation) + ": " + snd_strerror(error);
}

snd_pcm_format_t loopbackFormat(const lazer::audio::TargetFormat &format) {
    if (format.bitsPerSample == 16 && format.containerBitsPerSample == 16) {
        return SND_PCM_FORMAT_S16_LE;
    }
    if (format.bitsPerSample == 24 && format.containerBitsPerSample == 24) {
        return SND_PCM_FORMAT_S24_3LE;
    }
    if (format.bitsPerSample == 24 && format.containerBitsPerSample == 32) {
        return SND_PCM_FORMAT_S24_LE;
    }
    if (format.bitsPerSample == 32 && format.containerBitsPerSample == 32) {
        return SND_PCM_FORMAT_S32_LE;
    }
    return SND_PCM_FORMAT_UNKNOWN;
}

bool configureLoopbackCapture(const std::string &device,
    const lazer::audio::AudioOutputSession &outputSession, snd_pcm_t **capture,
    std::string &error) {
    const int opened = snd_pcm_open(capture, device.c_str(), SND_PCM_STREAM_CAPTURE,
        SND_PCM_NONBLOCK);
    if (opened < 0) {
        error = alsaError("could not open snd-aloop capture PCM", opened);
        return false;
    }

    snd_pcm_hw_params_t *hardware = nullptr;
    const int hardwareAllocated = snd_pcm_hw_params_malloc(&hardware);
    if (hardwareAllocated < 0 || hardware == nullptr) {
        error = hardwareAllocated < 0
            ? alsaError("could not allocate snd-aloop capture hardware parameters", hardwareAllocated)
            : "could not allocate snd-aloop capture hardware parameters";
        snd_pcm_close(*capture);
        *capture = nullptr;
        return false;
    }

    snd_pcm_format_t expectedFormat = loopbackFormat(outputSession.target);
    int result = expectedFormat == SND_PCM_FORMAT_UNKNOWN
        ? -EINVAL : snd_pcm_hw_params_any(*capture, hardware);
    if (result >= 0) result = snd_pcm_hw_params_set_access(*capture, hardware,
        SND_PCM_ACCESS_RW_INTERLEAVED);
    if (result >= 0) result = snd_pcm_hw_params_set_rate_resample(*capture, hardware, 0);
    if (result >= 0) result = snd_pcm_hw_params_set_format(*capture, hardware, expectedFormat);
    if (result >= 0) result = snd_pcm_hw_params_set_channels(*capture, hardware,
        static_cast<unsigned int>(outputSession.target.channels));
    if (result >= 0) result = snd_pcm_hw_params_set_rate(*capture, hardware,
        static_cast<unsigned int>(outputSession.target.sampleRate), 0);
    snd_pcm_uframes_t period = static_cast<snd_pcm_uframes_t>(outputSession.periodFrames);
    int direction = 0;
    if (result >= 0) result = snd_pcm_hw_params_set_period_size_near(
        *capture, hardware, &period, &direction);
    snd_pcm_uframes_t buffer = static_cast<snd_pcm_uframes_t>(outputSession.bufferFrames);
    if (result >= 0) result = snd_pcm_hw_params_set_buffer_size_near(*capture, hardware, &buffer);
    if (result >= 0) result = snd_pcm_hw_params(*capture, hardware);

    if (result >= 0) {
        snd_pcm_format_t actualFormat = SND_PCM_FORMAT_UNKNOWN;
        unsigned int actualRate = 0;
        unsigned int actualChannels = 0;
        snd_pcm_uframes_t actualPeriod = 0;
        snd_pcm_uframes_t actualBuffer = 0;
        result = snd_pcm_hw_params_current(*capture, hardware);
        if (result >= 0) result = snd_pcm_hw_params_get_format(hardware, &actualFormat);
        if (result >= 0) result = snd_pcm_hw_params_get_rate(hardware, &actualRate, &direction);
        if (result >= 0) result = snd_pcm_hw_params_get_channels(hardware, &actualChannels);
        if (result >= 0) result = snd_pcm_hw_params_get_period_size(hardware, &actualPeriod, &direction);
        if (result >= 0) result = snd_pcm_hw_params_get_buffer_size(hardware, &actualBuffer);
        if (result >= 0 && (actualFormat != expectedFormat ||
                actualRate != static_cast<unsigned int>(outputSession.target.sampleRate) ||
                actualChannels != static_cast<unsigned int>(outputSession.target.channels) ||
                actualPeriod != static_cast<snd_pcm_uframes_t>(outputSession.periodFrames) ||
                actualBuffer != static_cast<snd_pcm_uframes_t>(outputSession.bufferFrames))) {
            error = "snd-aloop capture readback did not match the direct output PCM parameters";
            result = -EINVAL;
        }
    }
    snd_pcm_hw_params_free(hardware);
    if (result < 0) {
        if (error.empty()) error = alsaError("could not configure exact snd-aloop capture PCM", result);
        snd_pcm_close(*capture);
        *capture = nullptr;
        return false;
    }

    snd_pcm_sw_params_t *software = nullptr;
    const int softwareAllocated = snd_pcm_sw_params_malloc(&software);
    if (softwareAllocated < 0 || software == nullptr) {
        error = softwareAllocated < 0
            ? alsaError("could not allocate snd-aloop capture software parameters", softwareAllocated)
            : "could not allocate snd-aloop capture software parameters";
        snd_pcm_close(*capture);
        *capture = nullptr;
        return false;
    }
    result = snd_pcm_sw_params_current(*capture, software);
    if (result >= 0) result = snd_pcm_sw_params_set_avail_min(*capture, software, 1);
    if (result >= 0) result = snd_pcm_sw_params_set_start_threshold(*capture, software, 1);
    if (result >= 0) result = snd_pcm_sw_params(*capture, software);
    snd_pcm_sw_params_free(software);
    if (result >= 0) result = snd_pcm_prepare(*capture);
    if (result < 0) {
        error = alsaError("could not prepare snd-aloop capture PCM", result);
        snd_pcm_close(*capture);
        *capture = nullptr;
        return false;
    }
    return true;
}

void appendLittleEndian(std::vector<uint8_t> &destination, int32_t value, int byteCount) {
    const uint32_t bits = static_cast<uint32_t>(value);
    for (int byte = 0; byte < byteCount; ++byte) {
        destination.push_back(static_cast<uint8_t>((bits >> (byte * 8)) & 0xffU));
    }
}

int32_t deterministicSample24(int32_t frame, int32_t channel) {
    const int64_t ramp = static_cast<int64_t>(frame) * 7'919 +
        static_cast<int64_t>(channel) * 104'729;
    return static_cast<int32_t>(ramp % 0x1000000LL - 0x800000LL);
}

void makeLoopbackSignal(int32_t bitsPerSample, int32_t containerBits, int32_t channels,
    int32_t frames, std::vector<uint8_t> &engineBytes, std::vector<uint8_t> &wireBytes) {
    const int engineBytesPerSample = containerBits / 8;
    const int wireBytesPerSample = containerBits / 8;
    engineBytes.reserve(static_cast<size_t>(frames) * static_cast<size_t>(channels) *
        static_cast<size_t>(engineBytesPerSample));
    wireBytes.reserve(engineBytes.capacity());
    for (int32_t frame = 0; frame < frames; ++frame) {
        for (int32_t channel = 0; channel < channels; ++channel) {
            const int32_t sample24 = deterministicSample24(frame, channel);
            if (bitsPerSample == 16) {
                const int32_t sample16 = sample24 / 256;
                appendLittleEndian(engineBytes, sample16, 2);
                appendLittleEndian(wireBytes, sample16, 2);
            } else if (bitsPerSample == 24 && containerBits == 24) {
                appendLittleEndian(engineBytes, sample24, 3);
                appendLittleEndian(wireBytes, sample24, 3);
            } else if (bitsPerSample == 24 && containerBits == 32) {
                /* The engine ABI stores 24 valid bits left-aligned; ALSA S24_LE requires the
                 * same signed sample low-aligned and sign-extended in its 32-bit container. */
                appendLittleEndian(engineBytes, sample24 * 256, 4);
                appendLittleEndian(wireBytes, sample24, 4);
            } else {
                const int32_t sample32 = sample24 * 256;
                appendLittleEndian(engineBytes, sample32, 4);
                appendLittleEndian(wireBytes, sample32, 4);
            }
        }
    }
}

bool writeFrames(lazer::audio::AlsaOutput &output, const std::vector<uint8_t> &bytes,
    int32_t frames, int32_t frameBytes, int32_t periodFrames, std::string &error) {
    int32_t offset = 0;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(8);
    while (offset < frames && std::chrono::steady_clock::now() < deadline) {
        const int32_t writable = output.writableFrames(error);
        if (writable < 0) return false;
        if (writable == 0) {
            if (output.waitForReady(20, error) == lazer::audio::OutputWaitResult::Error) return false;
            continue;
        }
        const int32_t count = std::min({frames - offset, writable,
            std::max(periodFrames, 1)});
        const int32_t written = output.write(bytes.data() +
            static_cast<size_t>(offset) * static_cast<size_t>(frameBytes), count, error);
        if (written != count) return false;
        offset += written;
    }
    if (offset != frames) {
        if (error.empty()) error = "snd-aloop playback write timed out before the test block was complete";
        return false;
    }
    return true;
}

bool drainOutput(lazer::audio::AlsaOutput &output, std::string &error) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(8);
    while (std::chrono::steady_clock::now() < deadline) {
        if (output.waitForReady(20, error) == lazer::audio::OutputWaitResult::Error) return false;
        const auto result = output.drain(error);
        if (result == lazer::audio::OutputDrainResult::Drained) return true;
        if (result == lazer::audio::OutputDrainResult::Error) return false;
    }
    error = "snd-aloop playback did not drain before the probe timeout";
    return false;
}

bool exerciseLoopbackFormat(int32_t bitsPerSample, int32_t sampleRate) {
    constexpr const char *playbackDevice = "hw:Loopback,0,0";
    constexpr const char *captureDevice = "hw:Loopback,1,0";
    lazer::audio::AudioOutputRequest request;
    request.deviceId = playbackDevice;
    request.exclusive = true;
    request.bufferMillis = 120;
    request.bitPerfect = true;
    request.desired.sampleRate = sampleRate;
    request.desired.channels = 2;

    lazer::audio::StreamDescription source;
    source.sampleRate = sampleRate;
    source.channels = 2;
    source.bitsPerSample = bitsPerSample;
    source.lossless = true;
    source.integerPcm = true;
    source.canonicalChannelLayout = true;
    source.decoderFormatMatchesStream = true;

    lazer::audio::AlsaOutput output;
    lazer::audio::AudioOutputSession session;
    std::string error;
    if (output.open(request, source, session, error, nullptr) != LazerAudioOk) {
        return fail("could not open direct snd-aloop output for " +
            std::to_string(sampleRate) + " Hz / " + std::to_string(bitsPerSample) + " bit: " + error);
    }
    if (!session.exclusive || session.target.sampleRate != sampleRate ||
        session.target.channels != 2 || session.target.bitsPerSample != bitsPerSample ||
        (session.target.containerBitsPerSample != bitsPerSample &&
            !(bitsPerSample == 24 && session.target.containerBitsPerSample == 32))) {
        return fail("direct snd-aloop output readback did not preserve the requested exact PCM tuple");
    }

    snd_pcm_t *capture = nullptr;
    if (!configureLoopbackCapture(captureDevice, session, &capture, error)) {
        return fail("could not configure paired snd-aloop capture: " + error);
    }

    const int32_t frames = std::min(4'096, session.bufferFrames);
    const int32_t frameBytes = session.target.frameBytes();
    if (frames <= 0 || frameBytes <= 0) {
        snd_pcm_close(capture);
        return fail("snd-aloop output negotiated invalid PCM dimensions");
    }
    std::vector<uint8_t> engineBytes;
    std::vector<uint8_t> expectedWireBytes;
    makeLoopbackSignal(bitsPerSample, session.target.containerBitsPerSample,
        session.target.channels, frames, engineBytes, expectedWireBytes);
    std::vector<uint8_t> capturedBytes(expectedWireBytes.size());
    std::atomic<bool> readerStarted{false};
    std::atomic<bool> cancelReader{false};
    std::string captureError;
    std::thread reader([&]() {
        readerStarted.store(true, std::memory_order_release);
        size_t offsetFrames = 0;
        const size_t totalFrames = static_cast<size_t>(frames);
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(8);
        while (offsetFrames < totalFrames && !cancelReader.load(std::memory_order_acquire) &&
            std::chrono::steady_clock::now() < deadline) {
            auto *destination = capturedBytes.data() + offsetFrames * static_cast<size_t>(frameBytes);
            const snd_pcm_uframes_t remaining = static_cast<snd_pcm_uframes_t>(
                totalFrames - offsetFrames);
            const snd_pcm_sframes_t received = snd_pcm_readi(capture, destination, remaining);
            if (received > 0) {
                offsetFrames += static_cast<size_t>(received);
                continue;
            }
            if (received == -EAGAIN || received == -EINTR) {
                const int ready = snd_pcm_wait(capture, 100);
                if (ready < 0 && ready != -EINTR && ready != -EAGAIN) {
                    captureError = alsaError("snd-aloop capture wait failed", ready);
                    return;
                }
                continue;
            }
            captureError = received == 0
                ? "snd-aloop capture returned no frames"
                : alsaError("snd-aloop capture read failed", static_cast<int>(received));
            return;
        }
        if (offsetFrames != totalFrames && !cancelReader.load(std::memory_order_acquire)) {
            captureError = "snd-aloop capture timed out before the test block was complete";
        }
    });

    while (!readerStarted.load(std::memory_order_acquire)) std::this_thread::yield();
    bool playbackPassed = output.start(error) == LazerAudioOk;
    if (playbackPassed) playbackPassed = writeFrames(output, engineBytes, frames,
        frameBytes, session.periodFrames, error);
    if (playbackPassed) playbackPassed = drainOutput(output, error);
    if (!playbackPassed) cancelReader.store(true, std::memory_order_release);
    reader.join();

    if (snd_pcm_close(capture) < 0) {
        playbackPassed = false;
        if (error.empty()) error = "could not close snd-aloop capture PCM";
    }
    if (!playbackPassed) return fail("snd-aloop direct output failed: " + error);
    if (!captureError.empty()) return fail("snd-aloop digital capture failed: " + captureError);
    if (capturedBytes != expectedWireBytes) {
        const auto mismatch = std::mismatch(capturedBytes.begin(), capturedBytes.end(),
            expectedWireBytes.begin());
        const size_t offset = static_cast<size_t>(std::distance(capturedBytes.begin(), mismatch.first));
        return fail("snd-aloop digital capture differs from expected PCM at byte " +
            std::to_string(offset));
    }

    std::printf("PASS: snd-aloop bit-perfect capture matched %d frames at %d Hz / %d-bit PCM\n",
        frames, sampleRate, bitsPerSample);
    return true;
}

bool exerciseFormat(int32_t bitsPerSample) {
    lazer::audio::AudioOutputRequest request;
    request.deviceId = "null";
    request.exclusive = true;
    request.bufferMillis = 120;
    request.bitPerfect = true;
    request.desired.sampleRate = 44'100;
    request.desired.channels = 2;

    lazer::audio::StreamDescription source;
    source.sampleRate = 44'100;
    source.channels = 2;
    source.bitsPerSample = bitsPerSample;
    source.lossless = true;
    source.integerPcm = true;
    source.canonicalChannelLayout = true;
    source.decoderFormatMatchesStream = true;

    lazer::audio::AlsaOutput output;
    lazer::audio::AudioOutputSession session;
    std::string error;
    const int32_t opened = output.open(request, source, session, error, nullptr);
    if (opened != LazerAudioOk) {
        return fail("could not negotiate " + std::to_string(bitsPerSample) + "-bit ALSA null PCM: " + error);
    }
    if (!output.isOpen() || session.target.sampleRate != 44'100 ||
        session.target.channels != 2 || session.target.bitsPerSample != bitsPerSample ||
        (bitsPerSample != 24 && session.target.containerBitsPerSample != bitsPerSample) ||
        (bitsPerSample == 24 && session.target.containerBitsPerSample != 24 &&
            session.target.containerBitsPerSample != 32)) {
        return fail("ALSA readback did not match the requested " +
            std::to_string(bitsPerSample) + "-bit PCM format");
    }
    if (session.exclusive || session.description.find("ALSA null") == std::string::npos) {
        return fail("the null PCM was incorrectly reported as a direct exclusive hardware endpoint");
    }

    if (output.start(error) != LazerAudioOk) {
        return fail("could not start ALSA null PCM: " + error);
    }
    const int32_t writable = output.writableFrames(error);
    if (writable <= 0) return fail("ALSA null PCM reported no writable frames: " + error);
    const int32_t frames = std::min({writable, session.periodFrames, 32});
    const int32_t frameBytes = session.target.frameBytes();
    if (frames <= 0 || frameBytes <= 0) return fail("ALSA negotiated invalid output queue dimensions");
    std::vector<uint8_t> silence(static_cast<size_t>(frames) * static_cast<size_t>(frameBytes), 0);
    const int32_t written = output.write(silence.data(), frames, error);
    if (written != frames) return fail("ALSA null PCM accepted only a partial test block: " + error);

    const auto readiness = output.waitForReady(0, error);
    if (readiness == lazer::audio::OutputWaitResult::Error) {
        return fail("ALSA null PCM readiness query failed: " + error);
    }
    const int32_t queued = output.queuedFrames(error);
    if (queued < 0) return fail("ALSA null PCM queue query failed: " + error);

    bool drained = false;
    for (int attempt = 0; attempt < 50; ++attempt) {
        error.clear();
        const auto result = output.drain(error);
        if (result == lazer::audio::OutputDrainResult::Error) {
            return fail("ALSA null PCM drain query failed: " + error);
        }
        if (result == lazer::audio::OutputDrainResult::Drained) {
            drained = true;
            break;
        }
        if (output.waitForReady(10, error) == lazer::audio::OutputWaitResult::Error) {
            return fail("ALSA null PCM readiness query failed while draining: " + error);
        }
    }
    if (!drained) return fail("ALSA null PCM did not drain the accepted test frames");

    if (output.stop(error) != LazerAudioOk) return fail("ALSA null PCM pause/stop failed: " + error);
    if (output.start(error) != LazerAudioOk) return fail("ALSA null PCM resume failed: " + error);
    if (output.reset(error) != LazerAudioOk) return fail("ALSA null PCM reset failed: " + error);
    if (output.drain(error) != lazer::audio::OutputDrainResult::Drained) {
        return fail("ALSA null PCM queue was not empty after reset: " + error);
    }
    output.close();
    if (output.isOpen()) return fail("ALSA null PCM remained open after close");

    std::printf("PASS: ALSA null PCM %d-bit negotiation, write, pause/resume, reset and drain\n",
        bitsPerSample);
    return true;
}

lazer::audio::AudioOutputRequest exactDopRequest(const std::string &device) {
    lazer::audio::AudioOutputRequest request;
    request.deviceId = device;
    request.requireDoP = true;
    request.exclusive = true;
    request.bufferMillis = 120;
    request.desired.sampleRate = 176'400;
    request.desired.channels = 2;
    request.desired.bitsPerSample = 24;
    request.desired.containerBitsPerSample = 24;
    return request;
}

lazer::audio::AudioOutputRequest exactNativeDsdRequest(const std::string &device) {
    lazer::audio::AudioOutputRequest request;
    request.deviceId = device;
    request.requireNativeDsd = true;
    request.exclusive = true;
    request.bufferMillis = 120;
    request.desired.sampleRate = 352'800;
    request.desired.channels = 2;
    request.desired.nativeDsd = true;
    return request;
}

lazer::audio::StreamDescription rawDsdDescription() {
    lazer::audio::StreamDescription source;
    source.sampleRate = 352'800;
    source.channels = 2;
    source.dsd = true;
    source.rawDsd = true;
    source.dsdRateMultiplier = 64;
    source.lossless = true;
    return source;
}

bool exerciseNativeDsdExactFormatNegotiation() {
    constexpr std::array<int32_t, 5> expectedSelections{
        LazerAudioFormatSelectionNativeDsdU32Be,
        LazerAudioFormatSelectionNativeDsdU32Le,
        LazerAudioFormatSelectionNativeDsdU16Be,
        LazerAudioFormatSelectionNativeDsdU16Le,
        LazerAudioFormatSelectionNativeDsdU8,
    };
    constexpr std::array<int32_t, 5> expectedWordBits{32, 32, 16, 16, 8};
    for (const int32_t multiplier : {64, 128, 256, 512, 1024}) {
        const int32_t dsdByteClock = static_cast<int32_t>(
            static_cast<int64_t>(44'100) * multiplier / 8);
        for (const int32_t channels : {1, 2}) {
            for (int32_t formatIndex = -1; formatIndex < 5; ++formatIndex) {
                int32_t actualRate = 0;
                int32_t actualChannels = 0;
                int32_t validBits = 0;
                int32_t containerBits = 0;
                int32_t formatSelection = LazerAudioFormatSelectionUnknown;
                const int32_t negotiated = lazer_audio_test_alsa_native_dsd_null_negotiation(
                    dsdByteClock, multiplier, channels, formatIndex, &actualRate,
                    &actualChannels, &validBits, &containerBits, &formatSelection);
                const int32_t selectedIndex = formatIndex < 0 ? 0 : formatIndex;
                const int32_t expectedBits = expectedWordBits[static_cast<size_t>(selectedIndex)];
                if (negotiated != LazerAudioOk || actualRate <= 0 || actualChannels != channels ||
                    validBits != expectedBits || containerBits != expectedBits ||
                    formatSelection != expectedSelections[static_cast<size_t>(selectedIndex)] ||
                    static_cast<int64_t>(actualRate) * (containerBits / 8) != dsdByteClock) {
                    return fail("test-only ALSA null route did not negotiate the exact " +
                        std::string(formatIndex < 0 ? "preferred" : "forced") +
                        " Native DSD clock/format for DSD" + std::to_string(multiplier) +
                        " " + std::to_string(channels) + "ch");
                }
            }
        }
    }

    /* Public Native DSD output remains direct-hw-only. The null negotiation hook above tests ALSA
     * rate/format acceptance only; it must not make the plugin usable as a production endpoint. */
    for (const char *device : {"null", "plughw:0,0"}) {
        auto request = exactNativeDsdRequest(device);
        lazer::audio::AlsaOutput output;
        lazer::audio::AudioOutputSession session;
        std::string error;
        const int32_t opened = output.open(request, rawDsdDescription(), session, error, nullptr);
        if (opened != LazerAudioErrorInvalidArgument || output.isOpen() ||
            error.find("direct hw:") == std::string::npos) {
            return fail("Native DSD public open accepted a plugin/null endpoint for " +
                std::string(device));
        }
    }
    std::puts("PASS: ALSA Native DSD negotiates every DSD_U8/U16/U32 endian tuple at DSD64-1024 clocks and rejects plugin endpoints");
    return true;
}

bool exerciseNativeDsdOutputLifecycle() {
    constexpr int32_t dsdByteClock = 352'800;
    constexpr std::array<int32_t, 5> nativeDsdSelections{
        LazerAudioFormatSelectionNativeDsdU32Be,
        LazerAudioFormatSelectionNativeDsdU32Le,
        LazerAudioFormatSelectionNativeDsdU16Be,
        LazerAudioFormatSelectionNativeDsdU16Le,
        LazerAudioFormatSelectionNativeDsdU8,
    };
    auto request = exactNativeDsdRequest("lazer-test:alsa-null");
    const auto source = rawDsdDescription();
    lazer::audio::AlsaOutput output;
    lazer::audio::AudioOutputSession session;
    std::string error;
    const int32_t opened = output.open(request, source, session, error, nullptr);
    if (opened != LazerAudioOk || !output.isOpen()) {
        return fail("test-only ALSA null route could not open the Native DSD output object: " + error);
    }

    const int32_t wordBytes = session.target.containerBitsPerSample / 8;
    if (!session.nativeDsd || session.doP || session.exclusive ||
        session.target.channels != source.channels || wordBytes <= 0 ||
        static_cast<int64_t>(session.target.sampleRate) * wordBytes != dsdByteClock ||
        session.target.bitsPerSample != session.target.containerBitsPerSample ||
        std::find(nativeDsdSelections.begin(), nativeDsdSelections.end(),
            session.formatSelection) == nativeDsdSelections.end()) {
        return fail("Native DSD null session did not report its exact non-hardware output tuple");
    }

    const auto submitFewCompleteWords = [&output, &session, &error]() {
        const int32_t writable = output.writableFrames(error);
        if (writable <= 0) {
            return fail("Native DSD ALSA null route reported no writable frames: " + error);
        }
        const int32_t frameCount = std::min(writable, 4);
        const int32_t frameBytes = session.target.frameBytes();
        if (frameBytes <= 0) return fail("Native DSD ALSA session reported an invalid frame size");
        std::vector<uint8_t> payload(static_cast<size_t>(frameCount) *
            static_cast<size_t>(frameBytes));
        for (size_t index = 0; index < payload.size(); ++index) {
            payload[index] = static_cast<uint8_t>((index * 37 + 0x5a) & 0xff);
        }
        const int32_t written = output.write(payload.data(), frameCount, error);
        return written == frameCount || fail("Native DSD ALSA null write failed: " + error);
    };
    const auto drainWithinBound = [&output, &error](const char *stage) {
        for (int attempt = 0; attempt < 50; ++attempt) {
            if (output.waitForReady(10, error) == lazer::audio::OutputWaitResult::Error) {
                return fail(std::string("Native DSD ALSA null readiness failed during ") + stage +
                    ": " + error);
            }
            const auto drain = output.drain(error);
            if (drain == lazer::audio::OutputDrainResult::Error) {
                return fail(std::string("Native DSD ALSA null drain failed during ") + stage +
                    ": " + error);
            }
            if (drain == lazer::audio::OutputDrainResult::Drained) return true;
        }
        return fail(std::string("Native DSD ALSA null queue did not drain during ") + stage);
    };

    if (output.start(error) != LazerAudioOk || !submitFewCompleteWords()) {
        return fail("Native DSD ALSA null route failed to start and submit complete words: " + error);
    }
    const auto readiness = output.waitForReady(0, error);
    if (readiness == lazer::audio::OutputWaitResult::Error || output.queuedFrames(error) < 0 ||
        !drainWithinBound("initial write")) {
        return fail("Native DSD ALSA null route failed readiness, queue, or drain observation: " + error);
    }
    if (output.stop(error) != LazerAudioOk || output.start(error) != LazerAudioOk ||
        !submitFewCompleteWords()) {
        return fail("Native DSD ALSA null route failed stop/resume and second write: " + error);
    }
    if (output.reset(error) != LazerAudioOk || output.queuedFrames(error) != 0 ||
        output.start(error) != LazerAudioOk || !submitFewCompleteWords() ||
        !drainWithinBound("post-reset write")) {
        return fail("Native DSD ALSA null route failed reset and subsequent output: " + error);
    }

    output.close();
    if (output.isOpen()) return fail("Native DSD ALSA null route remained open after close");
    std::puts("PASS: Native DSD ALSA output object opens, writes, stops/resumes, resets, drains and closes");
    return true;
}

bool exerciseDopExactCarrierNegotiation() {
    for (const int32_t channels : {1, 2}) {
        int32_t actualRate = 0;
        int32_t actualChannels = 0;
        int32_t validBits = 0;
        int32_t containerBits = 0;
        const int32_t negotiated = lazer_audio_test_alsa_dop_null_negotiation(
            176'400, channels, &actualRate, &actualChannels, &validBits, &containerBits);
        if (negotiated != LazerAudioOk || actualRate != 176'400 || actualChannels != channels ||
            validBits != 24 || containerBits != 24) {
            return fail("test-only ALSA null route did not accept exact 176.4 kHz " +
                std::to_string(channels) + "-channel S24_3LE DoP carrier params");
        }
    }

    /* Public DoP opens are deliberately direct-hw-only. Exercise null/plughw rejection through
     * the real backend and confirm neither name can enter PCM fallback negotiation. */
    for (const char *device : {"null", "plughw:0,0"}) {
        auto request = exactDopRequest(device);
        lazer::audio::AlsaOutput output;
        lazer::audio::AudioOutputSession session;
        std::string error;
        const int32_t opened = output.open(request, rawDsdDescription(), session, error, nullptr);
        if (opened != LazerAudioErrorInvalidArgument || output.isOpen() ||
            error.find("direct hw:") == std::string::npos) {
            return fail("DoP public open accepted a plugin/null endpoint or entered fallback for " +
                std::string(device));
        }
    }

    std::puts("PASS: ALSA DoP exact S24_3LE carrier tuple and direct-hw-only fallback rejection");
    return true;
}

bool exerciseDopMarkerBytesPassThrough() {
    const std::vector<uint8_t> dopFrames{
        0x11, 0x22, 0x05, 0xA1, 0xB2, 0x05,
        0x33, 0x44, 0xFA, 0xC3, 0xD4, 0xFA,
        0x55, 0x66, 0x05, 0xE5, 0xF6, 0x05,
    };
    std::vector<uint8_t> staged(dopFrames.size());
    const int32_t copied = lazer_audio_test_alsa_dop_stage_bytes(
        dopFrames.data(), 3, 2, staged.data(), static_cast<int32_t>(staged.size()));
    if (copied != 3 || staged != dopFrames) {
        return fail("ALSA DoP staging changed payload or synchronized marker bytes");
    }
    std::puts("PASS: ALSA DoP staging preserves carrier payload and marker bytes verbatim");
    return true;
}

bool exerciseDopRecoveryFailsWhenMarkerPhaseIsUnknown() {
    int32_t resumeCalls = -1;
    int32_t waitCalls = -1;
    if (lazer_audio_test_alsa_dop_suspend_resume(-EPIPE, 0, 0,
            &resumeCalls, &waitCalls) != 0 || resumeCalls != 0 || waitCalls != 0) {
        return fail("ALSA DoP XRUN did not fail immediately without preparing/replaying the queue");
    }
    if (lazer_audio_test_alsa_dop_suspend_resume(-ESTRPIPE, 0, 0,
            &resumeCalls, &waitCalls) != 1 || resumeCalls != 1 || waitCalls != 0) {
        return fail("ALSA DoP successful suspend resume did not preserve its existing queue");
    }
    if (lazer_audio_test_alsa_dop_suspend_resume(-ESTRPIPE, 2, 0,
            &resumeCalls, &waitCalls) != 1 || resumeCalls != 3 || waitCalls != 2) {
        return fail("ALSA DoP suspend resume did not wait through EAGAIN before retaining the queue");
    }
    if (lazer_audio_test_alsa_dop_suspend_resume(-ESTRPIPE, 0, -ENOSYS,
            &resumeCalls, &waitCalls) != 0 || resumeCalls != 1 || waitCalls != 0) {
        return fail("ALSA DoP failed suspend resume incorrectly fell back to prepare/requeue");
    }
    const int retryCount = static_cast<int>(lazer::audio::kAlsaSuspendResumeMaxWaitIntervals + 2);
    if (lazer_audio_test_alsa_dop_suspend_resume(-ESTRPIPE, retryCount, 0,
            &resumeCalls, &waitCalls) != 0 ||
        resumeCalls != static_cast<int>(lazer::audio::kAlsaSuspendResumeMaxWaitIntervals + 1) ||
        waitCalls != static_cast<int>(lazer::audio::kAlsaSuspendResumeMaxWaitIntervals)) {
        return fail("ALSA DoP suspend resume did not stop after its bounded EAGAIN retry window");
    }
    std::puts("PASS: ALSA DoP recovery stops on XRUN, failed resume, and bounded EAGAIN while preserving successful queue");
    return true;
}

}  // namespace

int main(int argc, char **argv) {
    if (argc == 2 && std::strcmp(argv[1], "--loopback") == 0) {
        for (const int32_t sampleRate : {44'100, 48'000, 96'000}) {
            if (!exerciseLoopbackFormat(16, sampleRate) ||
                !exerciseLoopbackFormat(24, sampleRate) ||
                !exerciseLoopbackFormat(32, sampleRate)) {
                return 1;
            }
        }
        return 0;
    }
    if (argc != 1) return fail("usage: lazer-audio-alsa-output-probe [--loopback]") ? 0 : 2;
    bool passed = true;
    passed &= exerciseFormat(16);
    passed &= exerciseFormat(24);
    passed &= exerciseFormat(32);
    passed &= exerciseNativeDsdExactFormatNegotiation();
    passed &= exerciseNativeDsdOutputLifecycle();
    passed &= exerciseDopExactCarrierNegotiation();
    passed &= exerciseDopMarkerBytesPassThrough();
    passed &= exerciseDopRecoveryFailsWhenMarkerPhaseIsUnknown();
    return passed ? 0 : 1;
}
