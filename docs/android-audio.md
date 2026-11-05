# Android Audio Engine

The full native engine supports Android API 26 and newer on `armeabi-v7a` and
`arm64-v8a`. It uses the same decoder, gapless queue, DSP and public C ABI as the
desktop engines. AAudio provides shared PCM output. It does not advertise
exclusive, bit-perfect, DoP or native DSD output on Android.

FFmpeg resamples to the format AAudio actually negotiates. Float PCM is preferred;
16-bit PCM is the fallback. Pause preserves the output queue. Seek pauses and
flushes it before continuing. Start is asynchronous because some Android
AudioTrack implementations complete a resume only after the next PCM write.

## Interruptions and a reclaimed endpoint

The endpoint belongs to the platform, not to this stream. When another
application takes the output — a call, another player, a Bluetooth route change
or an unplugged headset — AAudio reports the loss through the stream's error
callback, and Android reclaims the device from the stream, including a stream
that is only paused. Recording that loss is the callback's whole job: AAudio
forbids stopping, closing or reopening a stream from inside it, and the callback
must not block. The backend therefore stores the loss, reports it on the next
query, write or `start()`, and writes one warning that names the endpoint it
happened on (`device <id>, <rate> Hz, <channels> ch, float|i16, buffer <n>
frames`) — Info is not retained in the log the application reads.

Recovery is the control path's job. Audio focus is Android's decision and is
owned by Dart (`audio_session`, `lib/audio/playback_session.dart`): losing focus
closes the output so the application stops holding audio it may no longer play,
and the engine is opened again — at the position it reached — when the
interruption ends. A loss reported while playing is treated the same way
(`AudioEngine`'s device failures), and playback only ends in a named error when
that second open does not come up. Engines whose player owns its own session
(`just_audio`) keep the plain pause/resume behaviour.

## Build and package

Install NDK `28.2.13676358`, CMake, Ninja, pkg-config, NASM, Make and a C compiler
on Linux or macOS. Set `ANDROID_HOME`, then run:

```sh
bash ci/build-android-audio.sh
flutter build apk --release --target-platform android-arm,android-arm64
python3 ci/verify-android-audio.py --apk build/app/outputs/flutter-apk/app-release.apk
```

The helper stages `liblazer-audio.so` and `liblazer-audio-bridge.so` for each ABI
under Android's `jniLibs` directory. The APK verifier checks ELF architecture,
required C exports, runtime dependencies, absence of private FFmpeg exports,
16 KiB load alignment and uncompressed ZIP-entry alignment. Release packaging
also rejects bundled FFmpeg source archives, license files and build metadata.

FFmpeg is built from a pinned LGPL revision with the file protocol and audio
decoders enabled. The profile stamp prevents an older DSD-only SDK from silently
being reused. The engine uses a version script to keep FFmpeg and static C++
runtime symbols local to its shared library.

Static FFmpeg linkage also produces a relinking archive for each ABI in `dist/`.
These archives contain static libraries, engine object files and a relink script.
The pinned FFmpeg revision and build options remain in the repository's
`native/lazer-audio/tools/build_android_dsd_ffmpeg.sh`. Rebuild
FFmpeg with changes, replace its archives and run that script to produce a
replacement engine. The app's Audio Engine importer accepts compatible
replacement libraries without requiring the original library's signature.

## Verification

The hardware-free checks exercise the production AAudio backend using a
controllable service implementation. They cover partial writes, byte offsets,
format fallback, asynchronous resume, queue drain, disconnects, failed opens and
resource cleanup. The owned native log queue is checked for thread/lifetime
safety, short destination buffers and bounded memory.

```sh
cmake -S native/lazer-audio/tests/aaudio -B build/aaudio-contract
cmake --build build/aaudio-contract --config Release
ctest --test-dir build/aaudio-contract -C Release --output-on-failure
```

`native/lazer-audio/tests/aaudio/android_smoke.cpp` can be cross-compiled against
the engine and run on a device or emulator with a three-second stereo 44.1 kHz
PCM WAV fixture. It checks the real AAudio service, playback position, pause,
resume, seek, draining, reopening and the growing-file bridge with a queued
successor. These checks establish functional playback; physical-device latency,
audible output quality and device-specific routing still need device testing.

The Dart integration disables the legacy native log callback because its
temporary string cannot outlive an asynchronous FFI callback. Bundled engines
provide the optional `lazer_audio_read_log` export instead. Older imported
engines remain compatible; their synchronous log callback is left unset.
