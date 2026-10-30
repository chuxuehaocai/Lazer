/* Run on an Android device/emulator with a three-second PCM WAV fixture.
 * This uses the shipped C ABI and actual AAudio service, without a Flutter UI. */
#include "lazer_audio_api.h"

#include <chrono>
#include <atomic>
#include <dlfcn.h>
#include <iostream>
#include <stdexcept>
#include <thread>

namespace {
using namespace std::chrono_literals;
LazerAudioEngine engine = nullptr;
std::atomic<int> changes{0};

void require(bool value, const char *message) {
    if (!value) {
        const std::string detail = engine == nullptr ? "" : lazer_audio_last_error(engine);
        throw std::runtime_error(std::string(message) + ": " + detail);
    }
}

LazerAudioSnapshot snapshot() {
    LazerAudioSnapshot result{};
    require(lazer_audio_snapshot(engine, &result) == LazerAudioOk, "snapshot");
    require(result.state != LazerAudioStateFailed, "engine failed");
    return result;
}

template <typename Predicate>
void wait(Predicate predicate, const char *message) {
    for (int i = 0; i < 320; ++i) {
        if (predicate()) return;
        std::this_thread::sleep_for(25ms);
    }
    require(false, message);
}

template <typename Function>
Function symbol(void *library, const char *name) {
    auto function = reinterpret_cast<Function>(dlsym(library, name));
    require(function != nullptr, name);
    return function;
}

void streaming(const char *path, LazerAudioOpenParams &params) {
    void *bridge = dlopen("liblazer-audio-bridge.so", RTLD_NOW | RTLD_LOCAL);
    require(bridge != nullptr, "load reader bridge");
    const auto create = symbol<int32_t (*)(const char *, int64_t, void **)>(bridge, "lazer_bridge_reader_create");
    const auto finish = symbol<void (*)(void *, int32_t)>(bridge, "lazer_bridge_reader_finish");
    const auto destroy = symbol<void (*)(void *)>(bridge, "lazer_bridge_reader_destroy");
    LazerAudioReader readers[2]{};
    for (auto &reader : readers) {
        reader.read = symbol<decltype(reader.read)>(bridge, "lazer_bridge_reader_read");
        reader.seek = symbol<decltype(reader.seek)>(bridge, "lazer_bridge_reader_seek");
        reader.length = symbol<decltype(reader.length)>(bridge, "lazer_bridge_reader_length");
        reader.close = symbol<decltype(reader.close)>(bridge, "lazer_bridge_reader_close");
        reader.cancel = symbol<decltype(reader.cancel)>(bridge, "lazer_bridge_reader_cancel");
        require(create(path, -1, &reader.context) == 0, "create stream reader");
        finish(reader.context, 0);
    }
    require(lazer_audio_open_reader(engine, &readers[0], &params) == LazerAudioOk, "open bridged stream");
    require(lazer_audio_queue_reader(engine, 1, &readers[1], &params) == LazerAudioOk, "queue bridged successor");
    require(lazer_audio_play(engine) == LazerAudioOk, "play bridged stream");
    wait([] { return changes.load() == 1; }, "stream successor did not activate");
    wait([] { return snapshot().terminal_event == LazerAudioEventEnded; }, "streaming queue did not end");
    require(lazer_audio_stop(engine) == LazerAudioOk, "stop bridged stream");
    for (auto &reader : readers) destroy(reader.context);
    dlclose(bridge);
    std::cout << "Growing-file bridge and queued successor: passed\n";
}
}  // namespace

int main(int argc, char **argv) {
    try {
        require(argc == 2, "pass a three-second PCM WAV fixture");
        require(lazer_audio_abi_version() == LAZER_AUDIO_ABI_VERSION, "ABI version");
        LazerAudioEngineConfig config{};
        config.abi_version = LAZER_AUDIO_ABI_VERSION;
        config.struct_size = sizeof(config);
        config.device.buffer_millis = 120;
        config.events.on_event = [](void *, int32_t event, int32_t, int64_t) {
            if (event == LazerAudioEventTrackChanged) ++changes;
        };
        engine = lazer_audio_create(&config);
        require(engine != nullptr, "create");
        LazerAudioOpenParams params{};
        params.struct_size = sizeof(params);
        for (int cycle = 0; cycle < 3; ++cycle) {
            require(lazer_audio_open_file_utf8(engine, argv[1], &params) == LazerAudioOk, "open local WAV");
            LazerAudioStreamInfo info{};
            require(lazer_audio_stream_info(engine, &info) == LazerAudioOk, "stream info");
            require(info.source_sample_rate == 44100 && info.output_sample_rate > 0, "sample rate negotiation");
            std::cout << "cycle " << cycle << " source=" << info.source_sample_rate
                      << " output=" << info.output_sample_rate << '\n';
            require(lazer_audio_play(engine) == LazerAudioOk, "play");
            wait([] { return snapshot().position_millis > 200; }, "playback clock did not advance");
            require(lazer_audio_pause(engine) == LazerAudioOk, "pause");
            const auto paused = snapshot().position_millis;
            std::this_thread::sleep_for(200ms);
            require(snapshot().position_millis <= paused + 100, "pause did not hold position");
            require(lazer_audio_play(engine) == LazerAudioOk, "resume");
            wait([paused] { return snapshot().position_millis > paused + 100; }, "resume did not advance");
            require(lazer_audio_seek(engine, 1500) == LazerAudioOk, "seek");
            wait([] { return snapshot().position_millis >= 1500; }, "seek did not complete");
            wait([] { return snapshot().terminal_event == LazerAudioEventEnded; }, "tail did not drain");
            require(lazer_audio_stop(engine) == LazerAudioOk, "stop");
        }
        streaming(argv[1], params);
        require(lazer_audio_open_file_utf8(engine, "/missing-fixture.wav", &params) < 0,
                "missing files must fail");
        int32_t level = 0;
        char message[2048]{};
        require(lazer_audio_read_log(engine, &level, message, sizeof(message)) > 0,
                "native warnings/errors were not retained for export");
        lazer_audio_destroy(engine);
        engine = nullptr;
        std::cout << "Android AAudio playback, pause, resume, seek, end and reopen: passed\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        if (engine != nullptr) lazer_audio_destroy(engine);
        return 1;
    }
}
