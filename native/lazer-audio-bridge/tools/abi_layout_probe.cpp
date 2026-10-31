/* Prints the ABI layout the C compiler produces for `lazer_audio_api.h`.
 *
 * `lib/audio/native/lazer_audio_abi.dart` is a hand-written mirror of the same header; a wrong
 * field order or width there is silent corruption rather than a build error, so the Dart layout test
 * pins these numbers. Run this probe after any ABI change and update the test:
 *
 *   g++ -std=c++20 -o abi_layout_probe native/lazer-audio-bridge/tools/abi_layout_probe.cpp
 *   ./abi_layout_probe
 *
 * Build it with the same ABI the app ships for (x64 or arm64); the output is a list of
 * `sizeof`/`offsetof` lines the test compares against.
 */
#include <cstddef>
#include <cstdio>

#include "lazer_audio_api.h"

#define FIELD(type, field) \
    std::printf("offsetof %s.%s %zu\n", #type, #field, offsetof(type, field))

int main() {
    std::printf("sizeof LazerAudioReader %zu\n", sizeof(LazerAudioReader));
    FIELD(LazerAudioReader, read);
    FIELD(LazerAudioReader, seek);
    FIELD(LazerAudioReader, length);
    FIELD(LazerAudioReader, close);
    FIELD(LazerAudioReader, context);
    FIELD(LazerAudioReader, cancel);

    std::printf("sizeof LazerAudioOpenParams %zu\n", sizeof(LazerAudioOpenParams));
    FIELD(LazerAudioOpenParams, struct_size);
    FIELD(LazerAudioOpenParams, start_millis);
    FIELD(LazerAudioOpenParams, duration_hint_millis);
    FIELD(LazerAudioOpenParams, cue_start_frame75);
    FIELD(LazerAudioOpenParams, cue_end_frame75);
    FIELD(LazerAudioOpenParams, replay_gain_db);

    std::printf("sizeof LazerAudioDeviceConfig %zu\n", sizeof(LazerAudioDeviceConfig));
    FIELD(LazerAudioDeviceConfig, device_id);
    FIELD(LazerAudioDeviceConfig, exclusive);
    FIELD(LazerAudioDeviceConfig, resample_mode);
    FIELD(LazerAudioDeviceConfig, target_sample_rate);
    FIELD(LazerAudioDeviceConfig, buffer_millis);
    FIELD(LazerAudioDeviceConfig, bit_perfect);
    FIELD(LazerAudioDeviceConfig, dsd_output_mode);

    std::printf("sizeof LazerAudioEventHandler %zu\n", sizeof(LazerAudioEventHandler));
    std::printf("sizeof LazerAudioLogHandler %zu\n", sizeof(LazerAudioLogHandler));
    std::printf("sizeof LazerAudioEngineConfig %zu\n", sizeof(LazerAudioEngineConfig));
    FIELD(LazerAudioEngineConfig, abi_version);
    FIELD(LazerAudioEngineConfig, struct_size);
    FIELD(LazerAudioEngineConfig, device);
    FIELD(LazerAudioEngineConfig, events);
    FIELD(LazerAudioEngineConfig, log);

    std::printf("sizeof LazerAudioSnapshot %zu\n", sizeof(LazerAudioSnapshot));
    FIELD(LazerAudioSnapshot, state);
    FIELD(LazerAudioSnapshot, paused);
    FIELD(LazerAudioSnapshot, position_millis);
    FIELD(LazerAudioSnapshot, duration_millis);
    FIELD(LazerAudioSnapshot, buffered_percent);
    FIELD(LazerAudioSnapshot, error);
    FIELD(LazerAudioSnapshot, underrun_active);
    FIELD(LazerAudioSnapshot, underrun_frames);
    FIELD(LazerAudioSnapshot, terminal_event);
    FIELD(LazerAudioSnapshot, terminal_detail);
    FIELD(LazerAudioSnapshot, terminal_position_millis);
    FIELD(LazerAudioSnapshot, ring_fill_frames);
    FIELD(LazerAudioSnapshot, ring_capacity_frames);

    std::printf("sizeof LazerAudioStreamInfo %zu\n", sizeof(LazerAudioStreamInfo));
    FIELD(LazerAudioStreamInfo, codec);
    FIELD(LazerAudioStreamInfo, source_sample_rate);
    FIELD(LazerAudioStreamInfo, source_channels);
    FIELD(LazerAudioStreamInfo, source_bits_per_sample);
    FIELD(LazerAudioStreamInfo, source_bitrate_kbps);
    FIELD(LazerAudioStreamInfo, lossless);
    FIELD(LazerAudioStreamInfo, output_sample_rate);
    FIELD(LazerAudioStreamInfo, output_channels);
    FIELD(LazerAudioStreamInfo, output_bits_per_sample);
    FIELD(LazerAudioStreamInfo, output_exclusive);
    FIELD(LazerAudioStreamInfo, bit_perfect_active);
    FIELD(LazerAudioStreamInfo, output_container_bits_per_sample);
    FIELD(LazerAudioStreamInfo, output_is_float);
    FIELD(LazerAudioStreamInfo, output_format_initialized);
    FIELD(LazerAudioStreamInfo, source_format_kind);
    FIELD(LazerAudioStreamInfo, source_dsd_rate_multiplier);
    FIELD(LazerAudioStreamInfo, output_format_selection);
    FIELD(LazerAudioStreamInfo, output_peak_millidbfs);
    FIELD(LazerAudioStreamInfo, limiter_gain_reduction_millidb);
    FIELD(LazerAudioStreamInfo, output_clipped_sample_count);
    FIELD(LazerAudioStreamInfo, output_telemetry_valid);
    FIELD(LazerAudioStreamInfo, output_format_kind);
    FIELD(LazerAudioStreamInfo, output_dsd_rate_multiplier);
    FIELD(LazerAudioStreamInfo, output_coreaudio_mixability_known);
    FIELD(LazerAudioStreamInfo, output_coreaudio_non_mixable);
    FIELD(LazerAudioStreamInfo, output_dsp_active);
    FIELD(LazerAudioStreamInfo, output_format_matches_source);

    std::printf("sizeof LazerAudioEqBand %zu\n", sizeof(LazerAudioEqBand));
    FIELD(LazerAudioEqBand, kind);
    FIELD(LazerAudioEqBand, frequency_hz);
    FIELD(LazerAudioEqBand, gain_db);
    FIELD(LazerAudioEqBand, q);
    FIELD(LazerAudioEqBand, enabled);

    std::printf("sizeof LazerAudioDspConfig %zu\n", sizeof(LazerAudioDspConfig));
    FIELD(LazerAudioDspConfig, preamp_db);
    FIELD(LazerAudioDspConfig, band_count);
    FIELD(LazerAudioDspConfig, bands);
    FIELD(LazerAudioDspConfig, limiter_enabled);
    FIELD(LazerAudioDspConfig, limiter_threshold_db);
    FIELD(LazerAudioDspConfig, balance_channels);
    FIELD(LazerAudioDspConfig, crossfeed_enabled);
    FIELD(LazerAudioDspConfig, crossfeed_strength);
    FIELD(LazerAudioDspConfig, crossfeed_algorithm);
    FIELD(LazerAudioDspConfig, crossfeed_delay_ms);
    FIELD(LazerAudioDspConfig, crossfeed_cutoff_hz);

    std::printf("sizeof LazerAudioOutputDeviceInfo %zu\n", sizeof(LazerAudioOutputDeviceInfo));
    FIELD(LazerAudioOutputDeviceInfo, struct_size);
    FIELD(LazerAudioOutputDeviceInfo, flags);

    std::printf("sizeof LazerAudioDeviceInfo %zu\n", sizeof(LazerAudioDeviceInfo));
    FIELD(LazerAudioDeviceInfo, struct_size);
    FIELD(LazerAudioDeviceInfo, endpoint_state);
    FIELD(LazerAudioDeviceInfo, default_role_mask);
    FIELD(LazerAudioDeviceInfo, identity_kind);
    FIELD(LazerAudioDeviceInfo, endpoint_volume_query_hresult);
    FIELD(LazerAudioDeviceInfo, endpoint_volume_hardware_support_flags);

    std::printf("sizeof LazerAudioPcmFormatCandidate %zu\n", sizeof(LazerAudioPcmFormatCandidate));
    FIELD(LazerAudioPcmFormatCandidate, sample_rate);
    FIELD(LazerAudioPcmFormatCandidate, channels);
    FIELD(LazerAudioPcmFormatCandidate, container_bits);
    FIELD(LazerAudioPcmFormatCandidate, valid_bits);
    FIELD(LazerAudioPcmFormatCandidate, reserved);

    std::printf("sizeof LazerAudioPcmFormatProbeResult %zu\n", sizeof(LazerAudioPcmFormatProbeResult));
    std::printf("abi %u\n", LAZER_AUDIO_ABI_VERSION);
    return 0;
}
