#include "../include/lazer_audio_api.h"

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>

#include <cstring>
#include <limits>
#include <memory>
#include <new>
#include <string>
#include <vector>

namespace {

struct CatalogEntry {
    std::string token;
    std::string identity;
    std::string name;
    uint32_t flags = LazerAudioOutputDeviceFlagActive;
};

struct CatalogOwner {
    std::vector<CatalogEntry> entries;
};

AudioObjectPropertyAddress propertyAddress(AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    return AudioObjectPropertyAddress{selector, scope, kAudioObjectPropertyElementMain};
}

template <typename T>
bool getProperty(AudioObjectID object, AudioObjectPropertySelector selector,
    T &value, AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    auto address = propertyAddress(selector, scope);
    UInt32 size = static_cast<UInt32>(sizeof(T));
    return AudioObjectGetPropertyData(object, &address, 0, nullptr, &size, &value) == noErr &&
        size == sizeof(T);
}

template <typename T>
bool getPropertyArray(AudioObjectID object, AudioObjectPropertySelector selector,
    std::vector<T> &values, AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    values.clear();
    auto address = propertyAddress(selector, scope);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(object, &address, 0, nullptr, &size) != noErr ||
        size == 0 || size % sizeof(T) != 0) return false;
    try {
        values.resize(size / sizeof(T));
    } catch (...) {
        return false;
    }
    return AudioObjectGetPropertyData(object, &address, 0, nullptr, &size,
        values.data()) == noErr && size % sizeof(T) == 0;
}

std::string utf8(CFStringRef value) {
    if (value == nullptr) return {};
    const CFIndex maximum = CFStringGetMaximumSizeForEncoding(CFStringGetLength(value),
        kCFStringEncodingUTF8) + 1;
    if (maximum <= 0) return {};
    std::string result(static_cast<size_t>(maximum), '\0');
    if (!CFStringGetCString(value, result.data(), maximum, kCFStringEncodingUTF8)) return {};
    result.resize(std::strlen(result.c_str()));
    return result;
}

bool readString(AudioObjectID object, AudioObjectPropertySelector selector,
    std::string &result) {
    CFStringRef value = nullptr;
    if (!getProperty(object, selector, value) || value == nullptr) return false;
    result = utf8(value);
    CFRelease(value);
    return !result.empty();
}

bool isOutputDevice(AudioDeviceID device) {
    std::vector<AudioStreamID> streams;
    return getPropertyArray(device, kAudioDevicePropertyStreams, streams,
        kAudioDevicePropertyScopeOutput) && !streams.empty();
}

bool hasRequiredBytes(const std::string &value, uint32_t &required) {
    if (value.size() >= std::numeric_limits<uint32_t>::max()) return false;
    required = static_cast<uint32_t>(value.size() + 1);
    return true;
}

bool bufferCanHold(const char *buffer, uint32_t capacity, uint32_t required) {
    return buffer != nullptr && capacity >= required;
}

void copyString(const std::string &value, char *buffer) {
    std::memcpy(buffer, value.c_str(), value.size() + 1);
}

int32_t createCatalog(LazerAudioOutputDeviceCatalog *outCatalog) {
    if (outCatalog == nullptr) return LazerAudioErrorInvalidArgument;
    *outCatalog = nullptr;
    try {
        auto catalog = std::make_unique<CatalogOwner>();
        std::vector<AudioDeviceID> devices;
        if (!getPropertyArray(kAudioObjectSystemObject, kAudioHardwarePropertyDevices, devices)) {
            return LazerAudioErrorDevice;
        }
        AudioDeviceID defaultDevice = kAudioObjectUnknown;
        (void)getProperty(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice,
            defaultDevice);

        for (AudioDeviceID device : devices) {
            if (device == kAudioObjectUnknown || !isOutputDevice(device)) continue;
            UInt32 alive = 1;
            if (getProperty(device, kAudioDevicePropertyDeviceIsAlive, alive) && alive == 0) continue;

            CatalogEntry entry;
            if (!readString(device, kAudioDevicePropertyDeviceUID, entry.token)) continue;
            entry.identity = "coreaudio:uid:" + entry.token;
            if (!readString(device, kAudioObjectPropertyName, entry.name)) {
                entry.name = entry.token;
            }
            if (device == defaultDevice) entry.flags |= LazerAudioOutputDeviceFlagDefault;
            catalog->entries.push_back(std::move(entry));
        }
        if (catalog->entries.size() > std::numeric_limits<uint32_t>::max()) {
            return LazerAudioErrorDevice;
        }
        *outCatalog = reinterpret_cast<LazerAudioOutputDeviceCatalog>(catalog.release());
        return LazerAudioOk;
    } catch (const std::bad_alloc &) {
        return LazerAudioErrorNoMemory;
    } catch (...) {
        return LazerAudioErrorDevice;
    }
}

}  // namespace

extern "C" {

int32_t LAZER_AUDIO_CALL lazer_audio_output_device_catalog_create(
    LazerAudioOutputDeviceCatalog *out_catalog) {
    return createCatalog(out_catalog);
}

int32_t LAZER_AUDIO_CALL lazer_audio_output_device_catalog_count(
    LazerAudioOutputDeviceCatalog catalog, uint32_t *out_count) {
    if (catalog == nullptr || out_count == nullptr) return LazerAudioErrorInvalidArgument;
    const auto *entries = reinterpret_cast<const CatalogOwner *>(catalog);
    if (entries->entries.size() > std::numeric_limits<uint32_t>::max()) {
        return LazerAudioErrorDevice;
    }
    *out_count = static_cast<uint32_t>(entries->entries.size());
    return LazerAudioOk;
}

int32_t LAZER_AUDIO_CALL lazer_audio_output_device_catalog_get(
    LazerAudioOutputDeviceCatalog catalog,
    uint32_t index,
    LazerAudioOutputDeviceInfo *out_info,
    char *device_token_utf8,
    uint32_t device_token_capacity,
    uint32_t *out_device_token_bytes,
    char *identity_key_utf8,
    uint32_t identity_key_capacity,
    uint32_t *out_identity_key_bytes,
    char *display_name_utf8,
    uint32_t display_name_capacity,
    uint32_t *out_display_name_bytes) {
    if (catalog == nullptr || out_info == nullptr || out_device_token_bytes == nullptr ||
        out_identity_key_bytes == nullptr || out_display_name_bytes == nullptr) {
        return LazerAudioErrorInvalidArgument;
    }
    if (out_info->struct_size < sizeof(LazerAudioOutputDeviceInfo)) {
        return LazerAudioErrorInvalidArgument;
    }
    if ((device_token_utf8 == nullptr && device_token_capacity != 0) ||
        (identity_key_utf8 == nullptr && identity_key_capacity != 0) ||
        (display_name_utf8 == nullptr && display_name_capacity != 0)) {
        return LazerAudioErrorInvalidArgument;
    }
    const auto *entries = reinterpret_cast<const CatalogOwner *>(catalog);
    if (index >= entries->entries.size()) return LazerAudioErrorIndexOutOfRange;
    const CatalogEntry &entry = entries->entries[index];
    uint32_t tokenBytes = 0;
    uint32_t identityBytes = 0;
    uint32_t nameBytes = 0;
    if (!hasRequiredBytes(entry.token, tokenBytes) ||
        !hasRequiredBytes(entry.identity, identityBytes) ||
        !hasRequiredBytes(entry.name, nameBytes)) return LazerAudioErrorDevice;

    *out_device_token_bytes = tokenBytes;
    *out_identity_key_bytes = identityBytes;
    *out_display_name_bytes = nameBytes;
    out_info->struct_size = static_cast<uint32_t>(sizeof(LazerAudioOutputDeviceInfo));
    out_info->flags = entry.flags;
    if (!bufferCanHold(device_token_utf8, device_token_capacity, tokenBytes) ||
        !bufferCanHold(identity_key_utf8, identity_key_capacity, identityBytes) ||
        !bufferCanHold(display_name_utf8, display_name_capacity, nameBytes)) {
        return LazerAudioErrorBufferTooSmall;
    }
    copyString(entry.token, device_token_utf8);
    copyString(entry.identity, identity_key_utf8);
    copyString(entry.name, display_name_utf8);
    return LazerAudioOk;
}

void LAZER_AUDIO_CALL lazer_audio_output_device_catalog_destroy(
    LazerAudioOutputDeviceCatalog catalog) {
    delete reinterpret_cast<CatalogOwner *>(catalog);
}

}  // extern "C"
