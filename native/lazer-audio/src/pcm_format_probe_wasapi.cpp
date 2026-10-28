/* Exact-format capability queries for Windows render endpoints.
 * A successful IsFormatSupported query is not a playback or physical-DAC verification. */
#include <windows.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <mmreg.h>
#include <ksmedia.h>

#include <cstdint>
#include <new>

#include "../include/lazer_audio_api.h"

namespace {

template <typename T>
class ComPtr final {
public:
    ComPtr() = default;
    ~ComPtr() { reset(); }

    ComPtr(const ComPtr &) = delete;
    ComPtr &operator=(const ComPtr &) = delete;

    T **put() {
        reset();
        return &value_;
    }

    T *get() const { return value_; }
    T *operator->() const { return value_; }
    explicit operator bool() const { return value_ != nullptr; }

    void reset(T *replacement = nullptr) {
        if (value_ != nullptr) value_->Release();
        value_ = replacement;
    }

private:
    T *value_ = nullptr;
};

/* S_FALSE still increments COM's initialization count. RPC_E_CHANGED_MODE is already a usable
 * apartment, but this call did not acquire an initialization count to release. */
class ComApartment final {
public:
    ComApartment() : result_(CoInitializeEx(nullptr, COINIT_MULTITHREADED)) {
        owns_initialization_ = result_ == S_OK || result_ == S_FALSE;
    }

    ~ComApartment() {
        if (owns_initialization_) CoUninitialize();
    }

    HRESULT result() const { return result_; }
    bool usable() const { return SUCCEEDED(result_) || result_ == RPC_E_CHANGED_MODE; }

private:
    HRESULT result_;
    bool owns_initialization_ = false;
};

int32_t mapSetupFailure(HRESULT hr) {
    return hr == E_OUTOFMEMORY ? LazerAudioErrorNoMemory : LazerAudioErrorDevice;
}

bool validCandidate(const LazerAudioPcmFormatCandidate &candidate) {
    if (candidate.sample_rate == 0 || candidate.channels == 0 || candidate.channels > 8 ||
        candidate.reserved != 0 || candidate.valid_bits == 0 ||
        candidate.valid_bits > candidate.container_bits) {
        return false;
    }
    if (candidate.container_bits != 8 && candidate.container_bits != 16 &&
        candidate.container_bits != 24 && candidate.container_bits != 32) {
        return false;
    }

    const uint32_t bytes_per_sample = candidate.container_bits / 8u;
    const uint32_t block_align = static_cast<uint32_t>(candidate.channels) * bytes_per_sample;
    const uint64_t average_bytes_per_second =
        static_cast<uint64_t>(candidate.sample_rate) * block_align;
    return block_align <= UINT16_MAX && average_bytes_per_second <= UINT32_MAX;
}

DWORD speakerMaskForChannels(uint16_t channels) {
    constexpr DWORD kFrontLeft = 0x00000001;
    constexpr DWORD kFrontRight = 0x00000002;
    constexpr DWORD kFrontCenter = 0x00000004;
    constexpr DWORD kLowFrequency = 0x00000008;
    constexpr DWORD kBackLeft = 0x00000010;
    constexpr DWORD kBackRight = 0x00000020;
    constexpr DWORD kBackCenter = 0x00000100;
    constexpr DWORD kSideLeft = 0x00000200;
    constexpr DWORD kSideRight = 0x00000400;

    switch (channels) {
        case 1: return kFrontCenter;
        case 2: return kFrontLeft | kFrontRight;
        case 3: return kFrontLeft | kFrontRight | kFrontCenter;
        case 4: return kFrontLeft | kFrontRight | kBackLeft | kBackRight;
        case 5: return kFrontLeft | kFrontRight | kFrontCenter | kBackLeft | kBackRight;
        case 6:
            return kFrontLeft | kFrontRight | kFrontCenter | kLowFrequency | kBackLeft | kBackRight;
        case 7:
            return kFrontLeft | kFrontRight | kFrontCenter | kLowFrequency | kBackLeft |
                kBackRight | kBackCenter;
        case 8:
            return kFrontLeft | kFrontRight | kFrontCenter | kLowFrequency | kBackLeft |
                kBackRight | kSideLeft | kSideRight;
        default: return 0;
    }
}

WAVEFORMATEXTENSIBLE makeWaveFormat(const LazerAudioPcmFormatCandidate &candidate) {
    WAVEFORMATEXTENSIBLE format{};
    const uint32_t bytes_per_sample = candidate.container_bits / 8u;
    const uint32_t block_align = static_cast<uint32_t>(candidate.channels) * bytes_per_sample;

    format.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
    format.Format.nChannels = candidate.channels;
    format.Format.nSamplesPerSec = candidate.sample_rate;
    format.Format.nAvgBytesPerSec = candidate.sample_rate * block_align;
    format.Format.nBlockAlign = static_cast<WORD>(block_align);
    format.Format.wBitsPerSample = candidate.container_bits;
    format.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
    format.Samples.wValidBitsPerSample = candidate.valid_bits;
    format.dwChannelMask = speakerMaskForChannels(candidate.channels);
    format.SubFormat = KSDATAFORMAT_SUBTYPE_PCM;
    return format;
}

}  // namespace

extern "C" {

int32_t LAZER_AUDIO_CALL lazer_audio_device_probe_pcm_formats(
    const wchar_t *endpoint_id,
    const LazerAudioPcmFormatCandidate *candidates,
    uint32_t candidate_count,
    LazerAudioPcmFormatProbeResult *out_results) {
    if (endpoint_id == nullptr || endpoint_id[0] == L'\0' || candidates == nullptr ||
        candidate_count == 0 || out_results == nullptr) {
        return LazerAudioErrorInvalidArgument;
    }
    for (uint32_t index = 0; index < candidate_count; ++index) {
        if (!validCandidate(candidates[index])) return LazerAudioErrorInvalidArgument;
    }

    ComApartment apartment;
    if (!apartment.usable()) return mapSetupFailure(apartment.result());

    try {
        ComPtr<IMMDeviceEnumerator> enumerator;
        HRESULT hr = CoCreateInstance(
            __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
            __uuidof(IMMDeviceEnumerator), reinterpret_cast<void **>(enumerator.put()));
        if (FAILED(hr) || !enumerator) return mapSetupFailure(FAILED(hr) ? hr : E_UNEXPECTED);

        ComPtr<IMMDevice> endpoint;
        hr = enumerator->GetDevice(endpoint_id, endpoint.put());
        if (FAILED(hr) || !endpoint) return mapSetupFailure(FAILED(hr) ? hr : E_UNEXPECTED);

        ComPtr<IAudioClient> audio_client;
        hr = endpoint->Activate(
            __uuidof(IAudioClient), CLSCTX_ALL, nullptr,
            reinterpret_cast<void **>(audio_client.put()));
        if (FAILED(hr) || !audio_client) return mapSetupFailure(FAILED(hr) ? hr : E_UNEXPECTED);

        for (uint32_t index = 0; index < candidate_count; ++index) {
            const WAVEFORMATEXTENSIBLE format = makeWaveFormat(candidates[index]);
            const HRESULT probe_hr = audio_client->IsFormatSupported(
                AUDCLNT_SHAREMODE_EXCLUSIVE, &format.Format, nullptr);
            out_results[index].native_status = static_cast<int32_t>(probe_hr);
            if (probe_hr == S_OK) {
                out_results[index].status = LazerAudioPcmFormatProbeSupported;
            } else if (probe_hr == AUDCLNT_E_UNSUPPORTED_FORMAT) {
                out_results[index].status = LazerAudioPcmFormatProbeUnsupported;
            } else {
                out_results[index].status = LazerAudioPcmFormatProbeError;
            }
        }
        return LazerAudioOk;
    } catch (const std::bad_alloc &) {
        return LazerAudioErrorNoMemory;
    } catch (...) {
        return LazerAudioErrorDevice;
    }
}

}  // extern "C"
