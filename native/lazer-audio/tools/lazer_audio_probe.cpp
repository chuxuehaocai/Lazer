/* Offline self test for the C ABI: opens a file, initializes WASAPI and prints the source/session
 * formats. With start-playback=0 it gives the pump time to decode into its ring but never starts the
 * endpoint. Built only with -DLAZER_AUDIO_BUILD_PROBE=ON so shipping builds never carry it. */
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <windows.h>

#include "../include/lazer_audio_api.h"

namespace {

void LAZER_AUDIO_CALL onLog(void *context, int32_t level, const char *message) {
    (void) context;
    static const char *names[] = {"debug", "info", "warn", "error"};
    const int32_t safe = level >= 0 && level < 4 ? level : 3;
    std::printf("[%s] %s\n", names[safe], message != nullptr ? message : "");
    std::fflush(stdout);
}

void LAZER_AUDIO_CALL onEvent(void *context, int32_t event, int32_t detail, int64_t positionMillis) {
    static const char *names[] = {"ready", "ended", "failed", "seek", "device-lost", "buffer"};
    const int32_t safe = event >= 0 && event < 6 ? event : 0;
    std::printf("event=%s detail=%d position=%lld\n", names[safe], detail,
        static_cast<long long>(positionMillis));
    std::fflush(stdout);
    if (event == LazerAudioEventEnded || event == LazerAudioEventFailed ||
        event == LazerAudioEventDeviceLost) {
        *static_cast<bool *>(context) = true;
    }
}

std::string toUtf8(const std::wstring &text) {
    const int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
        text.c_str(), -1, nullptr, 0, nullptr, nullptr);
    if (length <= 1) return {};
    std::string utf8(static_cast<size_t>(length), '\0');
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
            text.c_str(), -1, utf8.data(), length, nullptr, nullptr) != length) return {};
    return utf8;
}

}  // namespace

int wmain(int argc, wchar_t **argv) {
    if (argc < 2) {
        std::printf("usage: lazer-audio-probe <file> [start-millis] [seconds] [exclusive] [bit-perfect] [start-playback]\n");
        return 2;
    }
    const std::wstring path = argv[1];
    const std::string pathUtf8 = toUtf8(path);
    if (pathUtf8.empty()) {
        std::printf("input path is not valid Unicode\n");
        return 2;
    }
    const int64_t startMillis = argc > 2 ? _wtoi64(argv[2]) : 0;
    const int limitSeconds = argc > 3 ? _wtoi(argv[3]) : 4;
    const bool startPlayback = argc <= 6 || _wtoi(argv[6]) != 0;

    LazerAudioEngineConfig config{};
    config.abi_version = LAZER_AUDIO_ABI_VERSION;
    config.struct_size = sizeof(LazerAudioEngineConfig);
    config.device.exclusive = argc > 4 ? _wtoi(argv[4]) != 0 : 0;
    config.device.resample_mode = LazerAudioResampleNative;
    config.device.buffer_millis = 120;
    config.device.bit_perfect = argc > 5 ? _wtoi(argv[5]) != 0 : 0;
    config.events.on_event = &onEvent;
    config.log.on_log = &onLog;

    bool finished = false;
    config.events.context = &finished;

    std::printf("abi=%d build=%s\n", lazer_audio_abi_version(), lazer_audio_build_information());
    LazerAudioEngine engine = lazer_audio_create(&config);
    if (engine == nullptr) {
        std::printf("create failed\n");
        return 1;
    }

    LazerAudioOpenParams params{};
    params.struct_size = sizeof(params);
    params.start_millis = startMillis;
    const int32_t opened = lazer_audio_open_file_utf8(engine, pathUtf8.c_str(), &params);
    if (opened != LazerAudioOk) {
        std::printf("open failed: %d %s\n", opened, lazer_audio_last_error(engine));
        lazer_audio_destroy(engine);
        return 1;
    }

    LazerAudioStreamInfo info{};
    lazer_audio_stream_info(engine, &info);
    if (info.source_format_kind == LazerAudioSourceFormatDsd) {
        std::printf("codec=%s source=DSD%d/%dch lossless=%d output=%dHz/%dch/%d-valid/%d-container %s exclusive=%d initialized=%d bit-perfect=%d format-selection=%d\n",
            info.codec, info.source_dsd_rate_multiplier, info.source_channels, info.lossless,
            info.output_sample_rate, info.output_channels, info.output_bits_per_sample,
            info.output_container_bits_per_sample, info.output_is_float ? "float" : "integer",
            info.output_exclusive, info.output_format_initialized, info.bit_perfect_active,
            info.output_format_selection);
    } else {
        std::printf("codec=%s source=%dHz/%dch/%dbit lossless=%d output=%dHz/%dch/%d-valid/%d-container %s exclusive=%d initialized=%d bit-perfect=%d format-selection=%d\n",
        info.codec, info.source_sample_rate, info.source_channels, info.source_bits_per_sample,
        info.lossless, info.output_sample_rate, info.output_channels, info.output_bits_per_sample,
        info.output_container_bits_per_sample, info.output_is_float ? "float" : "integer",
        info.output_exclusive, info.output_format_initialized, info.bit_perfect_active,
        info.output_format_selection);
    }

    if (!startPlayback) {
        /* The pump decodes while the engine is paused until its ring fills. Wait briefly so this
         * path also catches a decoder/resampler failure without sending any audio to the endpoint. */
        LazerAudioSnapshot smokeSnapshot{};
        for (int attempt = 0; attempt < 25; ++attempt) {
            Sleep(20);
            lazer_audio_snapshot(engine, &smokeSnapshot);
            if (smokeSnapshot.state == LazerAudioStateFailed) break;
        }
        std::printf("decode-smoke: state=%d error=%d; output initialized; playback not started\n",
            smokeSnapshot.state, smokeSnapshot.error);
        lazer_audio_stop(engine);
        lazer_audio_destroy(engine);
        return info.output_format_initialized == 1 &&
            smokeSnapshot.state != LazerAudioStateFailed ? 0 : 1;
    }

    LazerAudioEqBand bands[2] = {};
    bands[0].kind = LazerAudioEqBandLowShelf;
    bands[0].frequency_hz = 120.0;
    bands[0].gain_db = 4.0;
    bands[0].q = 0.7;
    bands[0].enabled = 1;
    bands[1].kind = LazerAudioEqBandPeak;
    bands[1].frequency_hz = 3500.0;
    bands[1].gain_db = -3.0;
    bands[1].q = 1.2;
    bands[1].enabled = 1;
    LazerAudioDspConfig dsp{};
    dsp.preamp_db = -2.0;
    dsp.band_count = 2;
    dsp.bands = bands;
    dsp.limiter_enabled = 1;
    dsp.limiter_threshold_db = -1.0;
    if (config.device.bit_perfect == 0) {
        std::printf("dsp=%d\n", lazer_audio_set_dsp(engine, &dsp));
    }

    lazer_audio_set_volume(engine, config.device.bit_perfect != 0 ? 1.0 : 0.4);
    std::printf("play=%d\n", lazer_audio_play(engine));

    const ULONGLONG deadline = GetTickCount64() + static_cast<ULONGLONG>(limitSeconds) * 1000;
    LazerAudioSnapshot snapshot{};
    while (!finished && GetTickCount64() < deadline) {
        Sleep(200);
        lazer_audio_snapshot(engine, &snapshot);
        std::printf("state=%d position=%lld buffered=%d%%\n", snapshot.state,
            static_cast<long long>(snapshot.position_millis), snapshot.buffered_percent);
    }
    lazer_audio_snapshot(engine, &snapshot);
    std::printf("final state=%d position=%lld error=%d %s\n", snapshot.state,
        static_cast<long long>(snapshot.position_millis), snapshot.error,
        lazer_audio_last_error(engine));
    lazer_audio_stop(engine);
    lazer_audio_destroy(engine);
    return finished ? 0 : 3;
}
