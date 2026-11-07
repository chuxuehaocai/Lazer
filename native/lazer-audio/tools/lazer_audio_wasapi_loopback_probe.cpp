/* Opt-in host integration probe. Captures the engine's actual shared-mode WASAPI output through
 * Windows loopback, including a same-Engine cross-format reopen and an endpoint route change.
 * This is deliberately not registered with CTest: it emits a quiet synthetic tone on active
 * endpoints and requires a person to choose when to run it. */
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <limits>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include <windows.h>
#include <audioclient.h>
#include <ksmedia.h>
#include <mmdeviceapi.h>

#include "../include/lazer_audio_api.h"

namespace {

using Clock = std::chrono::steady_clock;

struct Endpoint {
    std::wstring id;
    std::wstring name;
    bool isDefault = false;
};

std::string toUtf8(const std::wstring &text) {
    const int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
        text.c_str(), -1, nullptr, 0, nullptr, nullptr);
    if (length <= 1) return {};
    std::string result(static_cast<size_t>(length), '\0');
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
            text.c_str(), -1, result.data(), length, nullptr, nullptr) != length) return {};
    result.resize(static_cast<size_t>(length - 1));
    return result;
}

bool write16(std::ofstream &file, uint16_t value) {
    const char bytes[]{static_cast<char>(value), static_cast<char>(value >> 8)};
    file.write(bytes, sizeof(bytes));
    return file.good();
}

bool write32(std::ofstream &file, uint32_t value) {
    const char bytes[]{static_cast<char>(value), static_cast<char>(value >> 8),
        static_cast<char>(value >> 16), static_cast<char>(value >> 24)};
    file.write(bytes, sizeof(bytes));
    return file.good();
}

bool makeToneFile(const std::wstring &path, int32_t rate, int32_t bits, double frequency) {
    constexpr int32_t channels = 2;
    constexpr double amplitude = 0.25;
    constexpr int32_t seconds = 3;
    const uint32_t frames = static_cast<uint32_t>(rate * seconds);
    const uint16_t blockAlign = static_cast<uint16_t>(channels * bits / 8);
    const uint32_t dataBytes = frames * blockAlign;
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    if (!file) return false;
    file.write("RIFF", 4);
    write32(file, 36 + dataBytes);
    file.write("WAVEfmt ", 8);
    write32(file, 16);
    write16(file, 1);
    write16(file, channels);
    write32(file, static_cast<uint32_t>(rate));
    write32(file, static_cast<uint32_t>(rate * blockAlign));
    write16(file, blockAlign);
    write16(file, static_cast<uint16_t>(bits));
    file.write("data", 4);
    write32(file, dataBytes);
    for (uint32_t frame = 0; frame < frames; ++frame) {
        const double phase = 2.0 * 3.14159265358979323846 * frequency * frame / rate;
        const double sample = amplitude * std::cos(phase);
        for (int32_t channel = 0; channel < channels; ++channel) {
            if (bits == 16) {
                const int16_t value = static_cast<int16_t>(std::llround(sample * 32767.0));
                write16(file, static_cast<uint16_t>(value));
            } else {
                const int32_t value = static_cast<int32_t>(std::llround(sample * 8388607.0));
                const char bytes[]{static_cast<char>(value), static_cast<char>(value >> 8),
                    static_cast<char>(value >> 16)};
                file.write(bytes, sizeof(bytes));
            }
        }
    }
    return file.good();
}

bool temporaryPath(std::wstring &path) {
    wchar_t directory[MAX_PATH]{};
    wchar_t file[MAX_PATH]{};
    const DWORD length = GetTempPathW(MAX_PATH, directory);
    if (length == 0 || length >= MAX_PATH || GetTempFileNameW(directory, L"lau", 0, file) == 0) {
        return false;
    }
    path.assign(file);
    return true;
}

bool readStringFromCatalog(
    LazerAudioDeviceCatalog catalog, uint32_t index, LazerAudioDeviceInfo &info,
    std::wstring &id, std::wstring &identity, std::wstring &name) {
    constexpr uint32_t capacity = 2048;
    std::vector<wchar_t> idBuffer(capacity), identityBuffer(capacity), nameBuffer(capacity);
    uint32_t idBytes = 0, identityBytes = 0, nameBytes = 0;
    info.struct_size = sizeof(info);
    const int32_t status = lazer_audio_device_catalog_get(catalog, index, &info,
        idBuffer.data(), capacity, &idBytes, identityBuffer.data(), capacity, &identityBytes,
        nameBuffer.data(), capacity, &nameBytes);
    if (status != LazerAudioOk) return false;
    id.assign(idBuffer.data());
    identity.assign(identityBuffer.data());
    name.assign(nameBuffer.data());
    return !id.empty();
}

std::vector<Endpoint> activeEndpoints() {
    std::vector<Endpoint> endpoints;
    LazerAudioDeviceCatalog catalog = nullptr;
    if (lazer_audio_device_catalog_create(&catalog) != LazerAudioOk || catalog == nullptr) {
        return endpoints;
    }
    uint32_t count = 0;
    if (lazer_audio_device_catalog_count(catalog, &count) == LazerAudioOk) {
        for (uint32_t index = 0; index < count; ++index) {
            LazerAudioDeviceInfo info{};
            Endpoint endpoint;
            std::wstring identity;
            if (!readStringFromCatalog(catalog, index, info, endpoint.id, identity, endpoint.name)) {
                continue;
            }
            if ((info.endpoint_state & LazerAudioEndpointStateActive) == 0) continue;
            endpoint.isDefault = info.default_role_mask != 0;
            endpoints.push_back(std::move(endpoint));
        }
    }
    lazer_audio_device_catalog_destroy(catalog);
    std::stable_sort(endpoints.begin(), endpoints.end(), [](const Endpoint &left, const Endpoint &right) {
        return left.isDefault && !right.isDefault;
    });
    return endpoints;
}

bool isFloatFormat(const WAVEFORMATEX *format) {
    if (format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) return true;
    if (format->wFormatTag != WAVE_FORMAT_EXTENSIBLE ||
        format->cbSize < sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) return false;
    const auto *extensible = reinterpret_cast<const WAVEFORMATEXTENSIBLE *>(format);
    return IsEqualGUID(extensible->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
}

bool isPcmFormat(const WAVEFORMATEX *format) {
    if (format->wFormatTag == WAVE_FORMAT_PCM) return true;
    if (format->wFormatTag != WAVE_FORMAT_EXTENSIBLE ||
        format->cbSize < sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) return false;
    const auto *extensible = reinterpret_cast<const WAVEFORMATEXTENSIBLE *>(format);
    return IsEqualGUID(extensible->SubFormat, KSDATAFORMAT_SUBTYPE_PCM);
}

double decodeSample(const uint8_t *sample, int32_t bits, bool isFloat) {
    if (isFloat && bits == 32) {
        float value = 0.0f;
        std::memcpy(&value, sample, sizeof(value));
        return std::isfinite(value) ? value : 0.0;
    }
    if (isFloat && bits == 64) {
        double value = 0.0;
        std::memcpy(&value, sample, sizeof(value));
        return std::isfinite(value) ? value : 0.0;
    }
    if (isFloat) return 0.0;
    if (bits == 8) return (static_cast<int32_t>(*sample) - 128) / 128.0;
    if (bits == 16) {
        int16_t value = 0;
        std::memcpy(&value, sample, sizeof(value));
        return value / 32768.0;
    }
    if (bits == 24) {
        int32_t value = static_cast<int32_t>(sample[0]) |
            (static_cast<int32_t>(sample[1]) << 8) | (static_cast<int32_t>(sample[2]) << 16);
        if ((value & 0x800000) != 0) value |= static_cast<int32_t>(0xFF000000);
        return value / 8388608.0;
    }
    if (bits == 32) {
        int32_t value = 0;
        std::memcpy(&value, sample, sizeof(value));
        return value / 2147483648.0;
    }
    return 0.0;
}

class LoopbackCapture {
public:
    ~LoopbackCapture() { stop(); }

    bool start(const std::wstring &endpointId, std::string &error) {
        error.clear();
        running_.store(true, std::memory_order_release);
        ready_ = false;
        failed_ = false;
        error_.clear();
        thread_ = std::thread([this, endpointId] { captureLoop(endpointId); });
        std::unique_lock lock(mutex_);
        if (!readyCondition_.wait_for(lock, std::chrono::seconds(5), [this] { return ready_; })) {
            error = "WASAPI loopback endpoint did not start before timeout";
            lock.unlock();
            stop();
            return false;
        }
        if (failed_) {
            error = error_;
            lock.unlock();
            stop();
            return false;
        }
        return true;
    }

    int64_t markMillis() const {
        return std::chrono::duration_cast<std::chrono::milliseconds>(
            Clock::now() - origin_).count();
    }

    double peakBetween(int64_t beginMillis, int64_t endMillis) const {
        std::lock_guard lock(samplesMutex_);
        double peak = 0.0;
        for (const PeakSample &sample : samples_) {
            if (sample.millis >= beginMillis && sample.millis < endMillis) {
                peak = std::max(peak, sample.peak);
            }
        }
        return peak;
    }

    void stop() {
        running_.store(false, std::memory_order_release);
        if (thread_.joinable()) thread_.join();
    }

private:
    struct PeakSample { int64_t millis; double peak; };

    void signalReady(bool failed, std::string error = {}) {
        {
            std::lock_guard lock(mutex_);
            failed_ = failed;
            error_ = std::move(error);
            ready_ = true;
        }
        readyCondition_.notify_all();
    }

    void captureLoop(const std::wstring &endpointId) {
        const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        const bool uninitializeCom = SUCCEEDED(com);
        IMMDeviceEnumerator *enumerator = nullptr;
        IMMDevice *device = nullptr;
        IAudioClient *client = nullptr;
        IAudioCaptureClient *capture = nullptr;
        WAVEFORMATEX *format = nullptr;
        std::string error;
        HRESULT result = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
            IID_PPV_ARGS(&enumerator));
        if (SUCCEEDED(result)) result = enumerator->GetDevice(endpointId.c_str(), &device);
        if (SUCCEEDED(result)) result = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL,
            nullptr, reinterpret_cast<void **>(&client));
        if (SUCCEEDED(result)) result = client->GetMixFormat(&format);
        const bool supported = format != nullptr && (isFloatFormat(format) || isPcmFormat(format)) &&
            (format->wBitsPerSample == 8 || format->wBitsPerSample == 16 ||
                format->wBitsPerSample == 24 || format->wBitsPerSample == 32 ||
                (isFloatFormat(format) && format->wBitsPerSample == 64));
        if (SUCCEEDED(result) && !supported) result = AUDCLNT_E_UNSUPPORTED_FORMAT;
        if (SUCCEEDED(result)) result = client->Initialize(AUDCLNT_SHAREMODE_SHARED,
            AUDCLNT_STREAMFLAGS_LOOPBACK, 1'000'000, 0, format, nullptr);
        if (SUCCEEDED(result)) result = client->GetService(IID_PPV_ARGS(&capture));
        if (SUCCEEDED(result)) result = client->Start();
        if (FAILED(result)) {
            char message[96]{};
            std::snprintf(message, sizeof(message), "WASAPI loopback initialization failed (0x%08X)",
                static_cast<unsigned>(result));
            error = message;
            signalReady(true, error);
        } else {
            origin_ = Clock::now();
            signalReady(false);
        }

        if (SUCCEEDED(result)) {
            const bool floating = isFloatFormat(format);
            const int32_t bits = format->wBitsPerSample;
            const uint32_t bytesPerSample = bits / 8;
            while (running_.load(std::memory_order_acquire)) {
                UINT32 packetFrames = 0;
                result = capture->GetNextPacketSize(&packetFrames);
                if (FAILED(result)) break;
                while (packetFrames > 0) {
                    BYTE *data = nullptr;
                    UINT32 frames = 0;
                    DWORD flags = 0;
                    result = capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr);
                    if (FAILED(result)) break;
                    double peak = 0.0;
                    if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) == 0 && data != nullptr) {
                        for (UINT32 frame = 0; frame < frames; ++frame) {
                            const uint8_t *frameData = data + static_cast<size_t>(frame) * format->nBlockAlign;
                            for (UINT32 channel = 0; channel < format->nChannels; ++channel) {
                                const double sample = decodeSample(
                                    frameData + static_cast<size_t>(channel) * bytesPerSample,
                                    bits, floating);
                                peak = std::max(peak, std::abs(sample));
                            }
                        }
                    }
                    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                        Clock::now() - origin_).count();
                    {
                        std::lock_guard lock(samplesMutex_);
                        samples_.push_back({elapsed, peak});
                    }
                    capture->ReleaseBuffer(frames);
                    result = capture->GetNextPacketSize(&packetFrames);
                    if (FAILED(result)) break;
                }
                if (FAILED(result)) break;
                Sleep(2);
            }
            client->Stop();
        }
        if (capture != nullptr) capture->Release();
        if (format != nullptr) CoTaskMemFree(format);
        if (client != nullptr) client->Release();
        if (device != nullptr) device->Release();
        if (enumerator != nullptr) enumerator->Release();
        if (uninitializeCom) CoUninitialize();
    }

    std::atomic<bool> running_{false};
    mutable std::mutex samplesMutex_;
    std::vector<PeakSample> samples_;
    std::mutex mutex_;
    std::condition_variable readyCondition_;
    bool ready_ = false;
    bool failed_ = false;
    std::string error_;
    Clock::time_point origin_{};
    std::thread thread_;
};

struct SessionResult {
    double earlyPeak = 0.0;
    double steadyPeak = 0.0;
    double ratio = 0.0;
};

bool runSession(LazerAudioEngine engine, const Endpoint &endpoint, const std::wstring &file,
    SessionResult &measurement) {
    LoopbackCapture capture;
    std::string captureError;
    if (!capture.start(endpoint.id, captureError)) {
        std::printf("FAIL route '%s': %s\n", toUtf8(endpoint.name).c_str(), captureError.c_str());
        return false;
    }
    const std::string path = toUtf8(file);
    if (path.empty()) {
        std::printf("FAIL route '%s': generated WAV path is not valid UTF-8\n",
            toUtf8(endpoint.name).c_str());
        return false;
    }
    LazerAudioOpenParams params{};
    params.struct_size = sizeof(params);
    const int32_t opened = lazer_audio_open_file_utf8(engine, path.c_str(), &params);
    if (opened != LazerAudioOk) {
        std::printf("FAIL route '%s': open returned %d: %s\n", toUtf8(endpoint.name).c_str(),
            opened, lazer_audio_last_error(engine));
        return false;
    }
    LazerAudioStreamInfo info{};
    lazer_audio_stream_info(engine, &info);
    std::printf("route '%s': source %d Hz/%d-bit -> output %d Hz/%d-bit exclusive=%d\n",
        toUtf8(endpoint.name).c_str(), info.source_sample_rate, info.source_bits_per_sample,
        info.output_sample_rate, info.output_bits_per_sample, info.output_exclusive);
    const int64_t mark = capture.markMillis();
    const int32_t played = lazer_audio_play(engine);
    if (played != LazerAudioOk) {
        std::printf("FAIL route '%s': play returned %d: %s\n", toUtf8(endpoint.name).c_str(),
            played, lazer_audio_last_error(engine));
        return false;
    }
    Sleep(1'000);
    measurement.earlyPeak = capture.peakBetween(mark, mark + 200);
    measurement.steadyPeak = capture.peakBetween(mark + 500, mark + 900);
    measurement.ratio = measurement.steadyPeak > 0.0
        ? measurement.earlyPeak / measurement.steadyPeak
        : std::numeric_limits<double>::infinity();
    std::printf("  loopback peak: first 200 ms=%.6f, 500-900 ms=%.6f, ratio=%.3f\n",
        measurement.earlyPeak, measurement.steadyPeak, measurement.ratio);
    capture.stop();
    return measurement.earlyPeak > 1.0e-6 && measurement.steadyPeak > 1.0e-6 &&
        measurement.ratio <= 1.8;
}

}  // namespace

int wmain() {
    const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(initialized) && initialized != RPC_E_CHANGED_MODE) {
        std::printf("FAIL: COM initialization failed (0x%08X)\n", static_cast<unsigned>(initialized));
        return 2;
    }
    const std::vector<Endpoint> endpoints = activeEndpoints();
    if (SUCCEEDED(initialized)) CoUninitialize();
    if (endpoints.empty()) {
        std::printf("SKIP: no active Windows render endpoints are available\n");
        return 2;
    }

    std::vector<Endpoint> routes;
    routes.push_back(endpoints.front());
    const auto alternate = std::find_if(endpoints.begin() + 1, endpoints.end(),
        [&routes](const Endpoint &endpoint) { return endpoint.id != routes.front().id; });
    if (alternate != endpoints.end()) routes.push_back(*alternate);
    for (const Endpoint &endpoint : routes) {
        std::printf("selected active endpoint%s: %s\n", endpoint.isDefault ? " (default)" : "",
            toUtf8(endpoint.name).c_str());
    }

    std::wstring firstFile, secondFile;
    if (!temporaryPath(firstFile) || !temporaryPath(secondFile) ||
        !makeToneFile(firstFile, 44'100, 16, 440.0) ||
        !makeToneFile(secondFile, 96'000, 24, 660.0)) {
        std::printf("FAIL: could not create temporary PCM fixtures\n");
        if (!firstFile.empty()) DeleteFileW(firstFile.c_str());
        if (!secondFile.empty()) DeleteFileW(secondFile.c_str());
        return 2;
    }

    LazerAudioEngineConfig engineConfig{};
    engineConfig.abi_version = LAZER_AUDIO_ABI_VERSION;
    engineConfig.struct_size = sizeof(engineConfig);
    engineConfig.device.device_id = routes.front().id.c_str();
    engineConfig.device.resample_mode = LazerAudioResampleNative;
    engineConfig.device.buffer_millis = 60;
    LazerAudioEngine engine = lazer_audio_create(&engineConfig);
    if (engine == nullptr) {
        std::printf("FAIL: native engine creation failed\n");
        DeleteFileW(firstFile.c_str());
        DeleteFileW(secondFile.c_str());
        return 2;
    }

    bool ok = lazer_audio_set_volume(engine, 0.1) == LazerAudioOk;
    SessionResult firstMeasurement;
    if (ok) ok = runSession(engine, routes.front(), firstFile, firstMeasurement);
    if (lazer_audio_stop(engine) != LazerAudioOk) ok = false;

    SessionResult secondMeasurement;
    if (ok) {
        if (lazer_audio_set_volume(engine, 0.1) != LazerAudioOk) ok = false;
        if (ok) ok = runSession(engine, routes.front(), secondFile, secondMeasurement);
        if (lazer_audio_stop(engine) != LazerAudioOk) ok = false;
    }

    SessionResult routeMeasurement;
    if (ok && routes.size() > 1) {
        LazerAudioDeviceConfig device{};
        device.device_id = routes[1].id.c_str();
        device.resample_mode = LazerAudioResampleNative;
        device.buffer_millis = 60;
        if (lazer_audio_set_device(engine, &device) != LazerAudioOk) {
            std::printf("FAIL: changing to endpoint '%s' failed: %s\n",
                toUtf8(routes[1].name).c_str(), lazer_audio_last_error(engine));
            ok = false;
        } else {
            ok = lazer_audio_set_volume(engine, 0.1) == LazerAudioOk &&
                runSession(engine, routes[1], firstFile, routeMeasurement);
            if (lazer_audio_stop(engine) != LazerAudioOk) ok = false;
        }
    }

    const double formatRatio = secondMeasurement.steadyPeak > 0.0
        ? secondMeasurement.steadyPeak / firstMeasurement.steadyPeak
        : std::numeric_limits<double>::infinity();
    if (ok && (firstMeasurement.steadyPeak <= 1.0e-6 ||
        secondMeasurement.steadyPeak <= 1.0e-6 || formatRatio < 0.5 || formatRatio > 2.0)) {
        std::printf("FAIL: steady loopback level changed unexpectedly across the format switch (ratio %.3f)\n",
            formatRatio);
        ok = false;
    }

    lazer_audio_destroy(engine);
    DeleteFileW(firstFile.c_str());
    DeleteFileW(secondFile.c_str());
    std::printf("%s: Windows WASAPI loopback gain/format/route probe\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
