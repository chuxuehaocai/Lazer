/* The only translation unit that crosses the JNA boundary. Every entry point narrows the opaque
 * handle, validates what the caller passed, and forwards to Engine; nothing here touches the device
 * or the decoder directly, so a bad pointer can only return an error code. */
#include <cstring>
#include <cstddef>
#include <algorithm>
#include <cmath>
#include <string>

#include "../include/lazer_audio_api.h"
#include "engine.h"

namespace {

lazer::audio::Engine *handle(LazerAudioEngine engine) {
    return reinterpret_cast<lazer::audio::Engine *>(engine);
}

constexpr int32_t kDefaultBufferMillis = 120;

bool copyOpenParams(const LazerAudioOpenParams *params, LazerAudioOpenParams &safe) {
    safe = LazerAudioOpenParams{sizeof(LazerAudioOpenParams), 0, 0, 0, 0, 0.0};
    if (params == nullptr) return true;

    uint32_t suppliedSize = 0;
    std::memcpy(&suppliedSize, params, sizeof(suppliedSize));
    constexpr uint32_t legacySize = static_cast<uint32_t>(
        offsetof(LazerAudioOpenParams, cue_start_frame75));
    constexpr uint32_t previousSize = static_cast<uint32_t>(
        offsetof(LazerAudioOpenParams, replay_gain_db));
    constexpr uint32_t currentSize = static_cast<uint32_t>(sizeof(LazerAudioOpenParams));
    if (suppliedSize < legacySize || (suppliedSize != legacySize &&
        suppliedSize != previousSize && suppliedSize < currentSize)) {
        return false;
    }
    std::memcpy(&safe, params, std::min<size_t>(suppliedSize, currentSize));
    safe.struct_size = currentSize;
    if (!std::isfinite(safe.replay_gain_db) || safe.replay_gain_db < -60.0 ||
        safe.replay_gain_db > 24.0) return false;
    return true;
}

}  // namespace

extern "C" {

int32_t lazer_audio_abi_version(void) {
    return static_cast<int32_t>(LAZER_AUDIO_ABI_VERSION);
}

LazerAudioEngine lazer_audio_create(const LazerAudioEngineConfig *config) {
    if (config == nullptr) return nullptr;
    if (config->abi_version != LAZER_AUDIO_ABI_VERSION) return nullptr;
    if (config->struct_size < sizeof(LazerAudioEngineConfig)) return nullptr;
    LazerAudioEngineConfig safe = *config;
    if (safe.device.buffer_millis <= 0) safe.device.buffer_millis = kDefaultBufferMillis;
    auto *engine = lazer::audio::Engine::create(safe);
    return reinterpret_cast<LazerAudioEngine>(engine);
}

void lazer_audio_destroy(LazerAudioEngine engine) {
    if (engine == nullptr) return;
    handle(engine)->destroy();
}

int32_t lazer_audio_open_file(
    LazerAudioEngine engine, const wchar_t *path, const LazerAudioOpenParams *params) {
    if (engine == nullptr || path == nullptr) return LazerAudioErrorInvalidArgument;
    LazerAudioOpenParams safe{};
    if (!copyOpenParams(params, safe)) return LazerAudioErrorInvalidArgument;
    return handle(engine)->open(path, nullptr, safe);
}

int32_t lazer_audio_open_file_utf8(
    LazerAudioEngine engine, const char *path_utf8, const LazerAudioOpenParams *params) {
    if (engine == nullptr || path_utf8 == nullptr || path_utf8[0] == '\0') {
        return LazerAudioErrorInvalidArgument;
    }
    std::wstring path;
    if (!lazer::audio::utf8StringToWide(path_utf8, path) || path.empty()) {
        return LazerAudioErrorInvalidArgument;
    }
    LazerAudioOpenParams safe{};
    if (!copyOpenParams(params, safe)) return LazerAudioErrorInvalidArgument;
    return handle(engine)->open(path.c_str(), nullptr, safe);
}

int32_t lazer_audio_open_reader(
    LazerAudioEngine engine, const LazerAudioReader *reader, const LazerAudioOpenParams *params) {
    if (engine == nullptr || reader == nullptr || reader->read == nullptr) {
        return LazerAudioErrorInvalidArgument;
    }
    /* Without a read callback there is nothing to demux; seek and length stay optional so a plain
     * forward-only stream still works, the engine then seeks by decoding. */
    LazerAudioOpenParams safe{};
    if (!copyOpenParams(params, safe)) return LazerAudioErrorInvalidArgument;
    return handle(engine)->open(nullptr, reader, safe);
}

int32_t lazer_audio_queue_reader(
    LazerAudioEngine engine, uint64_t queue_generation, const LazerAudioReader *reader,
    const LazerAudioOpenParams *params) {
    if (engine == nullptr || reader == nullptr || reader->read == nullptr) {
        return LazerAudioErrorInvalidArgument;
    }
    LazerAudioOpenParams safe{};
    if (!copyOpenParams(params, safe)) return LazerAudioErrorInvalidArgument;
    return handle(engine)->queueReader(queue_generation, *reader, safe);
}

int32_t lazer_audio_clear_queued_reader(LazerAudioEngine engine, uint64_t queue_generation) {
    if (engine == nullptr) return LazerAudioErrorInvalidArgument;
    return handle(engine)->clearQueuedReader(queue_generation);
}

int32_t lazer_audio_play(LazerAudioEngine engine) {
    if (engine == nullptr) return LazerAudioErrorInvalidArgument;
    return handle(engine)->play();
}

int32_t lazer_audio_pause(LazerAudioEngine engine) {
    if (engine == nullptr) return LazerAudioErrorInvalidArgument;
    return handle(engine)->pause();
}

int32_t lazer_audio_stop(LazerAudioEngine engine) {
    if (engine == nullptr) return LazerAudioErrorInvalidArgument;
    return handle(engine)->stop();
}

int32_t lazer_audio_seek(LazerAudioEngine engine, int64_t position_millis) {
    if (engine == nullptr) return LazerAudioErrorInvalidArgument;
    return handle(engine)->seek(position_millis);
}

int32_t lazer_audio_set_volume(LazerAudioEngine engine, double volume) {
    if (engine == nullptr) return LazerAudioErrorInvalidArgument;
    return handle(engine)->setVolume(volume);
}

int32_t lazer_audio_set_dsp(LazerAudioEngine engine, const LazerAudioDspConfig *dsp) {
    if (engine == nullptr) return LazerAudioErrorInvalidArgument;
    if (dsp == nullptr) {
        const LazerAudioDspConfig cleared{};
        return handle(engine)->setDsp(cleared);
    }
    if (dsp->band_count > 0 && dsp->bands == nullptr) return LazerAudioErrorInvalidArgument;
    return handle(engine)->setDsp(*dsp);
}

int32_t lazer_audio_set_device(LazerAudioEngine engine, const LazerAudioDeviceConfig *device) {
    if (engine == nullptr) return LazerAudioErrorInvalidArgument;
    LazerAudioDeviceConfig safe{};
    if (device != nullptr) {
        safe = *device;
        if (safe.buffer_millis <= 0) safe.buffer_millis = kDefaultBufferMillis;
    }
    return handle(engine)->setDevice(safe);
}

int32_t lazer_audio_snapshot(LazerAudioEngine engine, LazerAudioSnapshot *out) {
    if (engine == nullptr || out == nullptr) return LazerAudioErrorInvalidArgument;
    std::memset(out, 0, sizeof(*out));
    handle(engine)->snapshot(*out);
    return LazerAudioOk;
}

int32_t lazer_audio_stream_info(LazerAudioEngine engine, LazerAudioStreamInfo *out) {
    if (engine == nullptr || out == nullptr) return LazerAudioErrorInvalidArgument;
    std::memset(out, 0, sizeof(*out));
    handle(engine)->streamInfo(*out);
    return LazerAudioOk;
}

const char *lazer_audio_last_error(LazerAudioEngine engine) {
    if (engine == nullptr) return "";
    return handle(engine)->lastError().c_str();
}

const char *lazer_audio_build_information(void) {
    /* The string has to outlive this call because JNA copies it lazily; a function-local static is
     * written once and never reassigned, so the returned pointer stays valid for the process. */
    static const std::string information = lazer::audio::Engine::buildInformation();
    return information.c_str();
}

}  // extern "C"
