# Android Audio Engine

The full native engine supports Android API 26 and newer on `armeabi-v7a`,
`arm64-v8a` and `x86_64`. It uses the same decoder, gapless queue, DSP and public C ABI as the
desktop engines. AAudio provides shared PCM output. It does not advertise
exclusive, bit-perfect, DoP or native DSD output on Android.

FFmpeg resamples to the format AAudio actually negotiates. Float PCM is preferred;
16-bit PCM is the fallback. Pause preserves the output queue. Seek pauses and
flushes it before continuing. Start is asynchronous because some Android
AudioTrack implementations complete a resume only after the next PCM write.

## Build and package

Install NDK `28.2.13676358`, CMake, Ninja, pkg-config, NASM, Make and a C compiler
on Linux. Set `ANDROID_HOME`, then run:

```sh
bash ci/build-android-audio.sh
flutter build apk --release --target-platform android-arm,android-arm64,android-x64
python3 ci/verify-android-audio.py --apk build/app/outputs/flutter-apk/app-release.apk
```

The helper stages `liblazer-audio.so` and `liblazer-audio-bridge.so` for each ABI
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

## USB Audio Class 2 (UAC2) transport (not shipped)

`native/lazer-audio/src/android_uac2_jni.cpp`, `android_uac2_iso_transport.cpp` and
`android_uac2_packetizer.cpp` implement a USB Audio Class 2 isochronous output transport,
reusing `dop_packer.cpp`, and are linked into a `lazer-uac2` shared library
(`native/lazer-audio/CMakeLists.txt:67-79`). libusb is pinned to commit
`87a55632db62c9bdc58cd31d3ccfa673f1bb017f` with SHA-256
`26733c3eee2475c062e14f80a62ece4b33ee3b33fc0c88b2758964412a42b7e0`
(`native/lazer-audio/CMakeLists.txt:34-37`) and built from its own sources as the `usb-1.0`
shared library (`:44-65`). `android_uac2_jni.cpp:109-345` exports the
`dev.naominet.lazer.AndroidUac2NativeIsoBridge` methods: open, start, write, set-playing,
flush, stop, close, plus packet, frame and error counters. No Kotlin class of that name
exists.

None of it reaches the APK. The whole block sits under
`if(ANDROID AND NOT LAZER_ANDROID_BUILD_ENGINE)` (`native/lazer-audio/CMakeLists.txt:9`), with
`LAZER_ANDROID_BUILD_UAC2` defaulting to `OFF` (`:10`); `native/CMakeLists.txt:122-123`
forces `LAZER_ANDROID_BUILD_ENGINE` on for Android as soon as a usable FFmpeg SDK is found,
so the packaging path never enters that branch. `ci/build-android-audio.sh` builds only
`lazer-audio` and `lazer-audio-bridge` (`:25`) and copies only `liblazer-audio.so` and
`liblazer-audio-bridge.so` into `jniLibs` (`:29-30`). Nothing else references the
transport: `grep -rn "uac2\|UAC2" --include='*.kt' --include='*.dart' lib android` finds
nothing.

Build it locally by pointing CMake at `native/lazer-audio` itself, since the top-level
`native/` tree would force the engine on and skip this branch, with the same toolchain, ABI
and platform flags as the packaging script and `-DLAZER_ANDROID_BUILD_UAC2=ON`:

```sh
ndk="$ANDROID_HOME/ndk/28.2.13676358"
cmake -S native/lazer-audio -B build/uac2/arm64-v8a -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$ndk/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 -DANDROID_STL=c++_static \
  -DCMAKE_BUILD_TYPE=Release -DLAZER_ANDROID_BUILD_UAC2=ON
cmake --build build/uac2/arm64-v8a --target lazer-uac2
```

The NDK revision is pinned at `ci/build-android-audio.sh:6` and installed by
`.github/workflows/build.yml:446`; configuring downloads the pinned libusb tarball.

Shipping it would take `liblazer-uac2.so` and `libusb-1.0.so` staged into `jniLibs` beside
the existing two libraries, an `AndroidUac2NativeIsoBridge` Kotlin class that calls
`System.loadLibrary` and the exported methods, a Dart/FFI surface beside `lib/audio/native/`,
and matching staging and APK verification in `ci/`. None of that exists.

Until it is wired up, treat UAC2 as experimental source-only code.
