/* Windows endpoint master-volume operations. This is IAudioEndpointVolume, not raw UAC control. */
#include <windows.h>
#include <audioclient.h>
#include <endpointvolume.h>
#include <mmdeviceapi.h>

#include <cmath>

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

/* S_FALSE still increments the COM initialization count. RPC_E_CHANGED_MODE means the caller
 * already has a usable apartment, which this scope must not uninitialize. */
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

class EndpointVolumeSession final {
public:
    HRESULT activate(const wchar_t *endpoint_id) {
        if (!apartment_.usable()) return apartment_.result();

        HRESULT hr = CoCreateInstance(
            __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
            __uuidof(IMMDeviceEnumerator), reinterpret_cast<void **>(enumerator_.put()));
        if (FAILED(hr) || !enumerator_) return FAILED(hr) ? hr : E_UNEXPECTED;

        hr = enumerator_->GetDevice(endpoint_id, device_.put());
        if (FAILED(hr) || !device_) return FAILED(hr) ? hr : E_UNEXPECTED;

        hr = device_->Activate(
            __uuidof(IAudioEndpointVolume), CLSCTX_ALL, nullptr,
            reinterpret_cast<void **>(volume_.put()));
        if (FAILED(hr) || !volume_) return FAILED(hr) ? hr : E_UNEXPECTED;
        return hr;
    }

    HRESULT queryHardwareSupport(DWORD *out_flags) {
        return volume_->QueryHardwareSupport(out_flags);
    }

    IAudioEndpointVolume *volume() const { return volume_.get(); }

private:
    /* Declared first so COM interfaces release before this apartment uninitializes. */
    ComApartment apartment_;
    ComPtr<IMMDeviceEnumerator> enumerator_;
    ComPtr<IMMDevice> device_;
    ComPtr<IAudioEndpointVolume> volume_;
};

bool validEndpointId(const wchar_t *endpoint_id) {
    return endpoint_id != nullptr && endpoint_id[0] != L'\0';
}

void initializeOutputs(uint32_t *out_hardware_flags, int32_t *out_hresult) {
    if (out_hardware_flags != nullptr) *out_hardware_flags = 0;
    if (out_hresult != nullptr) *out_hresult = static_cast<int32_t>(E_PENDING);
}

int32_t openHardwareEndpointVolume(
    const wchar_t *endpoint_id,
    EndpointVolumeSession &session,
    uint32_t *out_hardware_flags,
    int32_t *out_hresult) {
    HRESULT hr = session.activate(endpoint_id);
    *out_hresult = static_cast<int32_t>(hr);
    if (FAILED(hr)) return LazerAudioErrorDevice;

    DWORD hardware_flags = 0;
    hr = session.queryHardwareSupport(&hardware_flags);
    *out_hresult = static_cast<int32_t>(hr);
    if (FAILED(hr)) return LazerAudioErrorDevice;

    *out_hardware_flags = hardware_flags;
    if ((hardware_flags & ENDPOINT_HARDWARE_SUPPORT_VOLUME) == 0) {
        return LazerAudioErrorUnsupported;
    }
    return LazerAudioOk;
}

}  // namespace

extern "C" {

int32_t LAZER_AUDIO_CALL lazer_audio_endpoint_volume_get(
    const wchar_t *endpoint_id,
    float *out_scalar,
    uint32_t *out_hardware_flags,
    int32_t *out_hresult) {
    if (out_scalar != nullptr) *out_scalar = 0.0f;
    initializeOutputs(out_hardware_flags, out_hresult);
    if (!validEndpointId(endpoint_id) || out_scalar == nullptr ||
        out_hardware_flags == nullptr || out_hresult == nullptr) {
        return LazerAudioErrorInvalidArgument;
    }

    EndpointVolumeSession session;
    const int32_t setup = openHardwareEndpointVolume(
        endpoint_id, session, out_hardware_flags, out_hresult);
    if (setup != LazerAudioOk) return setup;

    float scalar = 0.0f;
    const HRESULT hr = session.volume()->GetMasterVolumeLevelScalar(&scalar);
    *out_hresult = static_cast<int32_t>(hr);
    if (FAILED(hr)) return LazerAudioErrorDevice;
    *out_scalar = scalar;
    return LazerAudioOk;
}

int32_t LAZER_AUDIO_CALL lazer_audio_endpoint_volume_set(
    const wchar_t *endpoint_id,
    float scalar,
    uint32_t *out_hardware_flags,
    int32_t *out_hresult) {
    initializeOutputs(out_hardware_flags, out_hresult);
    if (!validEndpointId(endpoint_id) || out_hardware_flags == nullptr ||
        out_hresult == nullptr || !std::isfinite(scalar) || scalar < 0.0f || scalar > 1.0f) {
        return LazerAudioErrorInvalidArgument;
    }

    EndpointVolumeSession session;
    const int32_t setup = openHardwareEndpointVolume(
        endpoint_id, session, out_hardware_flags, out_hresult);
    if (setup != LazerAudioOk) return setup;

    const HRESULT hr = session.volume()->SetMasterVolumeLevelScalar(scalar, nullptr);
    *out_hresult = static_cast<int32_t>(hr);
    return FAILED(hr) ? LazerAudioErrorDevice : LazerAudioOk;
}

}  // extern "C"
