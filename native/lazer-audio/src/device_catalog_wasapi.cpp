/* Read-only snapshot of Windows render endpoints for the additive device-catalog C ABI. */
#include <windows.h>
#include <mmdeviceapi.h>
#include <endpointvolume.h>
#include <functiondiscoverykeys_devpkey.h>
#include <propvarutil.h>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <memory>
#include <new>
#include <string>
#include <utility>
#include <vector>

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

struct CoTaskMemDeleter {
    void operator()(wchar_t *value) const noexcept {
        if (value != nullptr) CoTaskMemFree(value);
    }
};

using CoTaskMemString = std::unique_ptr<wchar_t, CoTaskMemDeleter>;

class PropVariant final {
public:
    PropVariant() { PropVariantInit(&value_); }
    ~PropVariant() { PropVariantClear(&value_); }
    PropVariant(const PropVariant &) = delete;
    PropVariant &operator=(const PropVariant &) = delete;

    PROPVARIANT *get() { return &value_; }
    const PROPVARIANT &value() const { return value_; }

private:
    PROPVARIANT value_{};
};

/* CoInitializeEx returning S_FALSE still increments this thread's COM initialization count and
 * must be paired with CoUninitialize. RPC_E_CHANGED_MODE means COM is already initialized on this
 * thread in another apartment; it is usable here, but this scope must not uninitialize it. */
class ComApartment final {
public:
    ComApartment() : result_(CoInitializeEx(nullptr, COINIT_MULTITHREADED)) {
        owns_initialization_ = result_ == S_OK || result_ == S_FALSE;
    }

    ~ComApartment() {
        if (owns_initialization_) CoUninitialize();
    }

    bool usable() const { return SUCCEEDED(result_) || result_ == RPC_E_CHANGED_MODE; }

private:
    HRESULT result_;
    bool owns_initialization_ = false;
};

struct CatalogEntry {
    std::wstring endpoint_id;
    std::wstring identity_key;
    std::wstring friendly_name;
    uint32_t endpoint_state = 0;
    uint32_t default_role_mask = 0;
    uint32_t identity_kind = LazerAudioDeviceIdentityEndpointId;
    int32_t endpoint_volume_query_hresult = E_NOTIMPL;
    uint32_t endpoint_volume_hardware_support_flags = 0;
};

}  // namespace

struct LazerAudioDeviceCatalogT {
    std::vector<CatalogEntry> entries;
};

namespace {

/* PKEY_AudioEndpoint_StableId is absent from some installed SDK headers. Keep its documented
 * endpoint-property key here so older SDK builds can query it and safely fall back when the OS or
 * endpoint does not expose the property. */
constexpr PROPERTYKEY kAudioEndpointStableIdKey = {
    {0x1da5d803, 0xd492, 0x4edd, {0x8c, 0x23, 0xe0, 0xc0, 0xff, 0xee, 0x7f, 0x0e}},
    12};

HRESULT copyEndpointId(IMMDevice *device, std::wstring &out_id) {
    CoTaskMemString id;
    wchar_t *raw_id = nullptr;
    const HRESULT hr = device->GetId(&raw_id);
    id.reset(raw_id);
    if (FAILED(hr) || !id) return FAILED(hr) ? hr : E_UNEXPECTED;
    out_id.assign(id.get());
    return S_OK;
}

void readEndpointProperties(IMMDevice *device, CatalogEntry &entry) {
    ComPtr<IPropertyStore> property_store;
    if (FAILED(device->OpenPropertyStore(STGM_READ, property_store.put()))) return;

    PropVariant name;
    if (SUCCEEDED(property_store->GetValue(PKEY_Device_FriendlyName, name.get())) &&
        name.value().vt == VT_LPWSTR && name.value().pwszVal != nullptr) {
        entry.friendly_name.assign(name.value().pwszVal);
    }
    if (entry.friendly_name.empty()) {
        PropVariant description;
        if (SUCCEEDED(property_store->GetValue(PKEY_Device_DeviceDesc, description.get())) &&
            description.value().vt == VT_LPWSTR && description.value().pwszVal != nullptr) {
            entry.friendly_name.assign(description.value().pwszVal);
        }
    }

    PropVariant stable_id;
    if (SUCCEEDED(property_store->GetValue(kAudioEndpointStableIdKey, stable_id.get())) &&
        stable_id.value().vt == VT_LPWSTR && stable_id.value().pwszVal != nullptr &&
        stable_id.value().pwszVal[0] != L'\0') {
        entry.identity_key.assign(stable_id.value().pwszVal);
        entry.identity_kind = LazerAudioDeviceIdentityStableId;
    }
}

bool isSameEndpoint(IMMDeviceEnumerator *enumerator, const std::wstring &candidate_id, ERole role) {
    ComPtr<IMMDevice> default_device;
    if (FAILED(enumerator->GetDefaultAudioEndpoint(eRender, role, default_device.put()))) return false;

    CoTaskMemString default_id;
    wchar_t *raw_default_id = nullptr;
    if (FAILED(default_device->GetId(&raw_default_id))) return false;
    default_id.reset(raw_default_id);
    if (!default_id) return false;
    return candidate_id == default_id.get();
}

int32_t buildCatalog(LazerAudioDeviceCatalog *out_catalog) {
    if (out_catalog == nullptr) return LazerAudioErrorInvalidArgument;
    *out_catalog = nullptr;

    ComApartment apartment;
    if (!apartment.usable()) return LazerAudioErrorDevice;

    try {
        auto catalog = std::make_unique<LazerAudioDeviceCatalogT>();

        ComPtr<IMMDeviceEnumerator> enumerator;
        HRESULT hr = CoCreateInstance(
            __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
            __uuidof(IMMDeviceEnumerator), reinterpret_cast<void **>(enumerator.put()));
        if (FAILED(hr) || !enumerator) return LazerAudioErrorDevice;

        ComPtr<IMMDeviceCollection> endpoints;
        hr = enumerator->EnumAudioEndpoints(eRender, DEVICE_STATEMASK_ALL, endpoints.put());
        if (FAILED(hr) || !endpoints) return LazerAudioErrorDevice;

        UINT endpoint_count = 0;
        hr = endpoints->GetCount(&endpoint_count);
        if (FAILED(hr)) return LazerAudioErrorDevice;
        catalog->entries.reserve(endpoint_count);

        for (UINT index = 0; index < endpoint_count; ++index) {
            ComPtr<IMMDevice> endpoint;
            if (FAILED(endpoints->Item(index, endpoint.put())) || !endpoint) {
                // A device can disappear while a catalog snapshot is being built. Skip that
                // entry; the remaining entries still form a useful consistent snapshot.
                continue;
            }

            CatalogEntry entry;
            if (FAILED(copyEndpointId(endpoint.get(), entry.endpoint_id))) continue;
            DWORD endpoint_state = 0;
            if (FAILED(endpoint->GetState(&endpoint_state))) {
                continue;
            }
            entry.endpoint_state = endpoint_state;

            if ((endpoint_state & DEVICE_STATE_ACTIVE) != 0) {
                ComPtr<IAudioEndpointVolume> endpoint_volume;
                HRESULT volume_hr = endpoint->Activate(
                    __uuidof(IAudioEndpointVolume), CLSCTX_ALL, nullptr,
                    reinterpret_cast<void **>(endpoint_volume.put()));
                if (SUCCEEDED(volume_hr) && endpoint_volume) {
                    DWORD support_flags = 0;
                    volume_hr = endpoint_volume->QueryHardwareSupport(&support_flags);
                    entry.endpoint_volume_query_hresult = static_cast<int32_t>(volume_hr);
                    if (SUCCEEDED(volume_hr)) {
                        entry.endpoint_volume_hardware_support_flags = support_flags;
                    }
                } else {
                    entry.endpoint_volume_query_hresult = static_cast<int32_t>(
                        FAILED(volume_hr) ? volume_hr : E_UNEXPECTED);
                }
            }

            entry.identity_key = entry.endpoint_id;
            readEndpointProperties(endpoint.get(), entry);
            if (entry.friendly_name.empty()) entry.friendly_name = entry.endpoint_id;

            if (isSameEndpoint(enumerator.get(), entry.endpoint_id, eConsole)) {
                entry.default_role_mask |= LazerAudioDeviceDefaultRoleConsole;
            }
            if (isSameEndpoint(enumerator.get(), entry.endpoint_id, eMultimedia)) {
                entry.default_role_mask |= LazerAudioDeviceDefaultRoleMultimedia;
            }
            if (isSameEndpoint(enumerator.get(), entry.endpoint_id, eCommunications)) {
                entry.default_role_mask |= LazerAudioDeviceDefaultRoleCommunications;
            }

            catalog->entries.push_back(std::move(entry));
        }

        *out_catalog = catalog.release();
        return LazerAudioOk;
    } catch (const std::bad_alloc &) {
        return LazerAudioErrorNoMemory;
    } catch (...) {
        return LazerAudioErrorDevice;
    }
}

template <typename T>
uint32_t requiredChars(const T &value) {
    const size_t count = value.size() + 1u;
    return count > UINT32_MAX ? 0u : static_cast<uint32_t>(count);
}

bool bufferCanHold(const wchar_t *buffer, uint32_t capacity, uint32_t required) {
    return buffer != nullptr && capacity >= required;
}

void copyString(const std::wstring &value, wchar_t *buffer) {
    std::memcpy(buffer, value.c_str(), (value.size() + 1u) * sizeof(wchar_t));
}

}  // namespace

extern "C" {

int32_t LAZER_AUDIO_CALL lazer_audio_device_catalog_create(
    LazerAudioDeviceCatalog *out_catalog) {
    return buildCatalog(out_catalog);
}

int32_t LAZER_AUDIO_CALL lazer_audio_device_catalog_count(
    LazerAudioDeviceCatalog catalog, uint32_t *out_count) {
    if (catalog == nullptr || out_count == nullptr) return LazerAudioErrorInvalidArgument;
    if (catalog->entries.size() > UINT32_MAX) return LazerAudioErrorDevice;
    *out_count = static_cast<uint32_t>(catalog->entries.size());
    return LazerAudioOk;
}

int32_t LAZER_AUDIO_CALL lazer_audio_device_catalog_get(
    LazerAudioDeviceCatalog catalog,
    uint32_t index,
    LazerAudioDeviceInfo *out_info,
    wchar_t *endpoint_id,
    uint32_t endpoint_id_capacity,
    uint32_t *out_endpoint_id_chars,
    wchar_t *identity_key,
    uint32_t identity_key_capacity,
    uint32_t *out_identity_key_chars,
    wchar_t *friendly_name,
    uint32_t friendly_name_capacity,
    uint32_t *out_friendly_name_chars) {
    if (catalog == nullptr || out_info == nullptr || out_endpoint_id_chars == nullptr ||
        out_identity_key_chars == nullptr || out_friendly_name_chars == nullptr) {
        return LazerAudioErrorInvalidArgument;
    }
    if (out_info->struct_size < sizeof(LazerAudioDeviceInfo)) {
        return LazerAudioErrorInvalidArgument;
    }
    if ((endpoint_id == nullptr && endpoint_id_capacity != 0) ||
        (identity_key == nullptr && identity_key_capacity != 0) ||
        (friendly_name == nullptr && friendly_name_capacity != 0)) {
        return LazerAudioErrorInvalidArgument;
    }
    if (index >= catalog->entries.size()) return LazerAudioErrorIndexOutOfRange;

    const CatalogEntry &entry = catalog->entries[index];
    const uint32_t endpoint_id_chars = requiredChars(entry.endpoint_id);
    const uint32_t identity_key_chars = requiredChars(entry.identity_key);
    const uint32_t friendly_name_chars = requiredChars(entry.friendly_name);
    if (endpoint_id_chars == 0 || identity_key_chars == 0 || friendly_name_chars == 0) {
        return LazerAudioErrorDevice;
    }

    *out_endpoint_id_chars = endpoint_id_chars;
    *out_identity_key_chars = identity_key_chars;
    *out_friendly_name_chars = friendly_name_chars;

    out_info->struct_size = sizeof(LazerAudioDeviceInfo);
    out_info->endpoint_state = entry.endpoint_state;
    out_info->default_role_mask = entry.default_role_mask;
    out_info->identity_kind = entry.identity_kind;
    out_info->endpoint_volume_query_hresult = entry.endpoint_volume_query_hresult;
    out_info->endpoint_volume_hardware_support_flags =
        entry.endpoint_volume_hardware_support_flags;

    const bool buffers_fit =
        bufferCanHold(endpoint_id, endpoint_id_capacity, endpoint_id_chars) &&
        bufferCanHold(identity_key, identity_key_capacity, identity_key_chars) &&
        bufferCanHold(friendly_name, friendly_name_capacity, friendly_name_chars);
    if (!buffers_fit) return LazerAudioErrorBufferTooSmall;

    copyString(entry.endpoint_id, endpoint_id);
    copyString(entry.identity_key, identity_key);
    copyString(entry.friendly_name, friendly_name);
    return LazerAudioOk;
}

void LAZER_AUDIO_CALL lazer_audio_device_catalog_destroy(LazerAudioDeviceCatalog catalog) {
    delete catalog;
}

}  // extern "C"
