/* The one piece of the iOS output path that cannot be written in portable C++.
 *
 * AVAudioSession is Objective-C, so the session is reduced to this narrow C++
 * interface and implemented in `ios_audio_session.mm`. `output_remoteio.cpp`
 * stays plain C++ against the AudioUnit C API, which lets the backend's state
 * machine be compiled and exercised on any host against a fake AudioUnit (see
 * `tests/remoteio/`), exactly like the AAudio backend is.
 *
 * The app already owns the audio session from Dart (`audio_session` in
 * `lib/audio/playback_session.dart`): category, options, interruption and
 * noisy-route handling are configured there and shared with the just_audio
 * path. This shim therefore never overwrites a category the app already set;
 * it only makes sure the session is active, asks for the rate and buffer the
 * caller wants, and reports the facts the OS actually granted.
 */
#ifndef LAZER_AUDIO_IOS_AUDIO_SESSION_H
#define LAZER_AUDIO_IOS_AUDIO_SESSION_H

#include <cstdint>
#include <string>

#include "lazer_audio_api.h"

namespace lazer::audio {

/* What the route granted, not what the caller asked for. */
struct IosSessionInfo {
    int32_t sampleRate = 0;
    /* Frames the system asks for per IO callback; 0 when the route does not say. */
    int32_t ioBufferFrames = 0;
    /* Route latency in frames at `sampleRate`; 0 when unavailable. */
    int32_t outputLatencyFrames = 0;
    /* `AVAudioSessionPortDescription.portType`, e.g. "Speaker", "BluetoothA2DP". */
    std::string route;
};

/* A notification snapshot; reading it never calls Objective-C or the audio unit.
 * A backend consumes changes on its control/render-producer thread, never from
 * the real-time AudioUnit callback. */
struct IosSessionState {
    uint64_t revision = 0;
    bool interrupted = false;
    bool mediaServicesAvailable = true;
    bool mayResume = true;
};

IosSessionState iosSessionState() noexcept;

/* An explicit play request may resume after a removed headset or an interruption
 * that did not grant automatic resumption. Recovery must never call this. */
void iosSessionRequestResume() noexcept;

/* Activates the shared audio session for playback. Safe to call repeatedly.
 *
 * Returns `LazerAudioOk`, or a `LazerAudioError*` code with `error` filled. */
int32_t iosSessionActivate(int32_t preferredSampleRate, int32_t bufferMillis,
    IosSessionInfo &info, std::string &error);

/* Releases the session and lets other apps resume their audio. */
void iosSessionDeactivate();

}  // namespace lazer::audio

#endif  // LAZER_AUDIO_IOS_AUDIO_SESSION_H
