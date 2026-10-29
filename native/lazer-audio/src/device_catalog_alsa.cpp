#include "../include/lazer_audio_api.h"

#include <alsa/asoundlib.h>

#include <cerrno>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <new>
#include <string>
#include <utility>
#include <vector>

namespace {

struct CatalogEntry {
    std::string deviceToken;
    std::string identityKey;
    std::string displayName;
    uint32_t flags = LazerAudioOutputDeviceFlagActive;
};

struct ControlCloser {
    void operator()(snd_ctl_t *control) const noexcept {
        if (control != nullptr) snd_ctl_close(control);
    }
};

struct CardInfoCloser {
    void operator()(snd_ctl_card_info_t *info) const noexcept {
        if (info != nullptr) snd_ctl_card_info_free(info);
    }
};

struct PcmInfoCloser {
    void operator()(snd_pcm_info_t *info) const noexcept {
        if (info != nullptr) snd_pcm_info_free(info);
    }
};

using ControlHandle = std::unique_ptr<snd_ctl_t, ControlCloser>;
using CardInfoHandle = std::unique_ptr<snd_ctl_card_info_t, CardInfoCloser>;
using PcmInfoHandle = std::unique_ptr<snd_pcm_info_t, PcmInfoCloser>;

bool isValidUtf8(const std::string &value) noexcept {
    const auto *bytes = reinterpret_cast<const unsigned char *>(value.data());
    size_t index = 0;
    while (index < value.size()) {
        const unsigned char first = bytes[index];
        if (first <= 0x7fU) {
            ++index;
            continue;
        }

        size_t continuationCount = 0;
        uint32_t codePoint = 0;
        uint32_t minimumCodePoint = 0;
        if ((first & 0xe0U) == 0xc0U) {
            continuationCount = 1;
            codePoint = first & 0x1fU;
            minimumCodePoint = 0x80U;
        } else if ((first & 0xf0U) == 0xe0U) {
            continuationCount = 2;
            codePoint = first & 0x0fU;
            minimumCodePoint = 0x800U;
        } else if ((first & 0xf8U) == 0xf0U) {
            continuationCount = 3;
            codePoint = first & 0x07U;
            minimumCodePoint = 0x10000U;
        } else {
            return false;
        }

        if (continuationCount > value.size() - index - 1) return false;
        for (size_t offset = 1; offset <= continuationCount; ++offset) {
            const unsigned char next = bytes[index + offset];
            if ((next & 0xc0U) != 0x80U) return false;
            codePoint = (codePoint << 6U) | (next & 0x3fU);
        }
        if (codePoint < minimumCodePoint || codePoint > 0x10ffffU ||
            (codePoint >= 0xd800U && codePoint <= 0xdfffU)) {
            return false;
        }
        index += continuationCount + 1;
    }
    return true;
}

bool safeAlsaCardId(const std::string &cardId) noexcept {
    if (cardId.empty()) return false;
    for (const unsigned char ch : cardId) {
        if (!((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') ||
                (ch >= '0' && ch <= '9') || ch == '_' || ch == '-' || ch == '.')) {
            return false;
        }
    }
    return true;
}

std::string encodeIdentityPart(const std::string &value) {
    static constexpr char kHex[] = "0123456789ABCDEF";
    std::string encoded;
    encoded.reserve(value.size());
    for (const unsigned char ch : value) {
        const bool safe = (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') ||
            (ch >= '0' && ch <= '9') || ch == '_' || ch == '-' || ch == '.';
        if (safe) {
            encoded.push_back(static_cast<char>(ch));
        } else {
            encoded.push_back('%');
            encoded.push_back(kHex[ch >> 4U]);
            encoded.push_back(kHex[ch & 0x0fU]);
        }
    }
    return encoded;
}

std::string cardFallbackName(int cardNumber, int deviceNumber) {
    return "ALSA card " + std::to_string(cardNumber) + " playback device " +
        std::to_string(deviceNumber);
}

int32_t appendCard(int cardNumber, std::vector<CatalogEntry> &entries) {
    const std::string controlName = "hw:" + std::to_string(cardNumber);
    snd_ctl_t *rawControl = nullptr;
    const int openResult = snd_ctl_open(&rawControl, controlName.c_str(), SND_CTL_NONBLOCK);
    if (openResult < 0) {
        /* The card may have disappeared or become inaccessible after card enumeration. */
        return openResult == -ENOMEM ? LazerAudioErrorNoMemory : LazerAudioOk;
    }
    ControlHandle control(rawControl);

    snd_ctl_card_info_t *rawCardInfo = nullptr;
    const int cardInfoAlloc = snd_ctl_card_info_malloc(&rawCardInfo);
    if (cardInfoAlloc < 0) {
        return cardInfoAlloc == -ENOMEM ? LazerAudioErrorNoMemory : LazerAudioOk;
    }
    CardInfoHandle cardInfo(rawCardInfo);
    const int cardInfoResult = snd_ctl_card_info(control.get(), cardInfo.get());
    if (cardInfoResult < 0) {
        /* A hot-unplug between open and metadata read is not a catalog-wide failure. */
        return cardInfoResult == -ENOMEM ? LazerAudioErrorNoMemory : LazerAudioOk;
    }

    const char *rawCardId = snd_ctl_card_info_get_id(cardInfo.get());
    const std::string cardId = rawCardId != nullptr ? rawCardId : "";
    const bool stableIdAvailable = !cardId.empty();
    const bool cardIdUsableInToken = safeAlsaCardId(cardId);

    std::string cardName;
    if (const char *rawName = snd_ctl_card_info_get_name(cardInfo.get()); rawName != nullptr) {
        cardName = rawName;
    }
    const bool cardNameValid = isValidUtf8(cardName);

    snd_pcm_info_t *rawPcmInfo = nullptr;
    const int pcmInfoAlloc = snd_pcm_info_malloc(&rawPcmInfo);
    if (pcmInfoAlloc < 0) {
        return pcmInfoAlloc == -ENOMEM ? LazerAudioErrorNoMemory : LazerAudioOk;
    }
    PcmInfoHandle pcmInfo(rawPcmInfo);

    int deviceNumber = -1;
    for (;;) {
        const int nextResult = snd_ctl_pcm_next_device(control.get(), &deviceNumber);
        if (nextResult < 0) {
            if (nextResult == -ENOMEM) return LazerAudioErrorNoMemory;
            break;
        }
        if (deviceNumber < 0) break;

        snd_pcm_info_set_device(pcmInfo.get(), static_cast<unsigned int>(deviceNumber));
        snd_pcm_info_set_subdevice(pcmInfo.get(), 0);
        snd_pcm_info_set_stream(pcmInfo.get(), SND_PCM_STREAM_PLAYBACK);
        const int pcmInfoResult = snd_ctl_pcm_info(control.get(), pcmInfo.get());
        if (pcmInfoResult < 0) {
            /* This PCM may be capture-only or may have disappeared during enumeration. */
            if (pcmInfoResult == -ENOMEM) return LazerAudioErrorNoMemory;
            continue;
        }

        CatalogEntry entry;
        if (stableIdAvailable && cardIdUsableInToken) {
            entry.deviceToken = "hw:CARD=" + cardId + ",DEV=" + std::to_string(deviceNumber);
        } else {
            entry.deviceToken = "hw:" + std::to_string(cardNumber) + "," +
                std::to_string(deviceNumber);
        }

        if (stableIdAvailable) {
            entry.identityKey = "alsa:card:" + encodeIdentityPart(cardId) + ":pcm:" +
                std::to_string(deviceNumber);
        } else {
            entry.identityKey = "alsa:card-index:" + std::to_string(cardNumber) + ":pcm:" +
                std::to_string(deviceNumber);
            entry.flags |= LazerAudioOutputDeviceFlagIdentityEphemeral;
        }

        std::string pcmName;
        if (const char *rawPcmName = snd_pcm_info_get_name(pcmInfo.get());
            rawPcmName != nullptr) {
            pcmName = rawPcmName;
        }
        if (cardNameValid && isValidUtf8(pcmName)) {
            if (!cardName.empty()) entry.displayName = cardName;
            if (!pcmName.empty()) {
                if (!entry.displayName.empty()) entry.displayName += " — ";
                entry.displayName += pcmName;
            }
            if (entry.displayName.empty()) {
                entry.displayName = cardFallbackName(cardNumber, deviceNumber);
            }
            entry.displayName += " (" + entry.deviceToken + ")";
        } else {
            entry.displayName = cardFallbackName(cardNumber, deviceNumber) +
                " (" + entry.deviceToken + ")";
        }
        entries.push_back(std::move(entry));
    }
    return LazerAudioOk;
}

int32_t buildCatalog(LazerAudioOutputDeviceCatalog *outCatalog);

bool getRequiredBytes(const std::string &value, uint32_t &required) noexcept {
    if (value.size() >= std::numeric_limits<uint32_t>::max()) return false;
    required = static_cast<uint32_t>(value.size() + 1);
    return true;
}

bool bufferCanHold(const char *buffer, uint32_t capacity, uint32_t required) noexcept {
    return buffer != nullptr && capacity >= required;
}

void copyString(const std::string &value, char *buffer) noexcept {
    std::memcpy(buffer, value.c_str(), value.size() + 1);
}

}  // namespace

struct LazerAudioOutputDeviceCatalogT {
    std::vector<CatalogEntry> entries;
};

namespace {

int32_t buildCatalog(LazerAudioOutputDeviceCatalog *outCatalog) {
    if (outCatalog == nullptr) return LazerAudioErrorInvalidArgument;
    *outCatalog = nullptr;

    try {
        auto catalog = std::make_unique<LazerAudioOutputDeviceCatalogT>();
        int cardNumber = -1;
        int result = snd_card_next(&cardNumber);
        if (result < 0) return result == -ENOMEM
            ? LazerAudioErrorNoMemory : LazerAudioErrorDevice;
        while (cardNumber >= 0) {
            const int32_t cardResult = appendCard(cardNumber, catalog->entries);
            if (cardResult != LazerAudioOk) return cardResult;

            const int previousCardNumber = cardNumber;
            result = snd_card_next(&cardNumber);
            if (result < 0) return result == -ENOMEM
                ? LazerAudioErrorNoMemory : LazerAudioErrorDevice;
            if (cardNumber == previousCardNumber) return LazerAudioErrorDevice;
        }
        if (catalog->entries.size() > std::numeric_limits<uint32_t>::max()) {
            return LazerAudioErrorDevice;
        }
        *outCatalog = catalog.release();
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
    return buildCatalog(out_catalog);
}

int32_t LAZER_AUDIO_CALL lazer_audio_output_device_catalog_count(
    LazerAudioOutputDeviceCatalog catalog, uint32_t *out_count) {
    if (catalog == nullptr || out_count == nullptr) return LazerAudioErrorInvalidArgument;
    if (catalog->entries.size() > std::numeric_limits<uint32_t>::max()) {
        return LazerAudioErrorDevice;
    }
    *out_count = static_cast<uint32_t>(catalog->entries.size());
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
    if (index >= catalog->entries.size()) return LazerAudioErrorIndexOutOfRange;

    const CatalogEntry &entry = catalog->entries[index];
    uint32_t deviceTokenBytes = 0;
    uint32_t identityKeyBytes = 0;
    uint32_t displayNameBytes = 0;
    if (!getRequiredBytes(entry.deviceToken, deviceTokenBytes) ||
        !getRequiredBytes(entry.identityKey, identityKeyBytes) ||
        !getRequiredBytes(entry.displayName, displayNameBytes)) {
        return LazerAudioErrorDevice;
    }

    *out_device_token_bytes = deviceTokenBytes;
    *out_identity_key_bytes = identityKeyBytes;
    *out_display_name_bytes = displayNameBytes;
    out_info->struct_size = static_cast<uint32_t>(sizeof(LazerAudioOutputDeviceInfo));
    out_info->flags = entry.flags;

    const bool buffersFit =
        bufferCanHold(device_token_utf8, device_token_capacity, deviceTokenBytes) &&
        bufferCanHold(identity_key_utf8, identity_key_capacity, identityKeyBytes) &&
        bufferCanHold(display_name_utf8, display_name_capacity, displayNameBytes);
    if (!buffersFit) return LazerAudioErrorBufferTooSmall;

    copyString(entry.deviceToken, device_token_utf8);
    copyString(entry.identityKey, identity_key_utf8);
    copyString(entry.displayName, display_name_utf8);
    return LazerAudioOk;
}

void LAZER_AUDIO_CALL lazer_audio_output_device_catalog_destroy(
    LazerAudioOutputDeviceCatalog catalog) {
    delete catalog;
}

}  // extern "C"
