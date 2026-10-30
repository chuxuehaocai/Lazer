# Android Audio Engine

The full native engine supports Android API 26 and newer on `arm64-v8a` and
`x86_64`. It uses the same decoder, gapless queue, DSP and public C ABI as the
desktop engines. AAudio provides shared PCM output. It does not advertise
exclusive, bit-perfect, DoP or native DSD output on Android.

FFmpeg resamples to the format AAudio actually negotiates. Float PCM is preferred;
16-bit PCM is the fallback. Pause preserves the output queue. Seek pauses and
flushes it before continuing. Start is asynchronous because some Android
AudioTrack implementations complete a resume only after the next PCM write.

## Build and package

Install NDK `28.2.13676358`, CMake, Ninja, pkg-config, NASM, Make and a C compiler
on Linux or macOS. Set `ANDROID_HOME`, then run:

```sh
bash ci/build-android-audio.sh
flutter build apk --release --target-platform android-arm64,android-x64
python3 ci/verify-android-audio.py --apk build/app/outputs/flutter-apk/app-release.apk
```

The helper stages `liblazer-audio.so` and `liblazer-audio-bridge.so` for both ABIs
under Android's `jniLibs` directory. The APK verifier checks ELF architecture,
required C exports, runtime dependencies, absence of private FFmpeg exports,
16 KiB load alignment, uncompressed ZIP-entry alignment and license notices.

FFmpeg is built from a pinned LGPL revision with the file protocol and audio
decoders enabled. The profile stamp prevents an older DSD-only SDK from silently
being reused. The engine uses a version script to keep FFmpeg and static C++
runtime symbols local to its shared library.

Static FFmpeg linkage also produces a relinking archive for each ABI in `dist/`.
These archives contain the corresponding FFmpeg source, exact build information,
static archives, engine object files, licenses and a relink script. Rebuild
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
