# Android Audio Engine

The full native engine supports Android API 26 and newer on `armeabi-v7a` and
`arm64-v8a`. It uses the same decoder, gapless queue, DSP and public C ABI as the
desktop engines. There are two distinct output paths:

- **System output:** AAudio shared PCM. This does not establish exclusive or
  bit-perfect playback. FFmpeg converts to the negotiated AAudio format; the
  Android audio service still controls routing and mixing.
- **USB DAC direct output:** the application requests Android USB permission,
  opens the device, and passes its connection FD to the native engine. libusb
  claims the USB AudioControl/AudioStreaming interfaces, verifies the device
  clock and sends isochronous PCM packets directly. AAudio and AudioTrack are
  absent from this PCM path. Selecting USB never silently falls back to system
  output when permission, format negotiation or USB transfers fail.

USB direct output is implemented and covered by host contract tests. **There is
currently no Android phone/DAC hardware verification for this change.** A NICEHCK
DAC detected by Windows does not validate Android USB permission, kernel-driver
detachment, OTG power, device-specific control transfers or physical output.

For AAudio, float PCM is preferred; 16-bit PCM is the fallback. Pause preserves
the output queue. Seek pauses and flushes it before continuing. Start is
asynchronous because some Android AudioTrack implementations complete a resume
only after the next PCM write.

## USB direct PCM contract

The actual call chain is:

```text
HiFi device choice (android-usb:<deviceName>)
  -> AndroidUsbAudio.resolveDeviceId / AndroidUsbAudioPlugin
  -> UsbManager permission + UsbDeviceConnection
  -> transient android-usb-fd:<fd> in native device settings
  -> routed AudioOutput -> android_uac2_output.cpp
  -> android_uac2_control.cpp (claims + RANGE/SET_CUR/GET_CUR)
  -> IsoTransportSession -> libusb usbfs isochronous OUT + feedback IN -> DAC
```

The persistent preference names the Android USB device path, not a reusable FD.
A reconnect can change that path and require selecting the DAC again. The native
transport duplicates the FD, and closes its duplicate only after callbacks have
quiesced. The plugin retains the Android connection until device release, engine
shutdown or detach. A timed-out native shutdown quarantines transfer state to
avoid callbacks using freed memory.

Supported devices must expose USB Audio Class 2, Type-I signed integer PCM,
mono or stereo, a directly referenced Clock Source, and full/high-speed USB 2.0.
Formats are 16-in-16, 24-in-24, 24-in-32 and 32-in-32. For PCM sources the chosen
rate is the source rate (8–768 kHz, subject to the DAC and endpoint bandwidth);
the backend will not choose a substitute rate. Conflicting explicit PCM target
rates, channels, precision or container widths fail instead of being ignored.
The Clock Source RANGE must include that rate; a writable clock receives SET_CUR, and GET_CUR must read the exact rate
back. Clock-validity is checked when the descriptor exposes that control.
Asynchronous outputs require an explicit feedback endpoint; adaptive/synchronous
outputs use exact rational packet scheduling. Unsupported clock selectors,
clock multipliers, implicit feedback, UAC1/UAC3, SuperSpeed, channel layouts and
native DSD/DoP are rejected explicitly.

DSD sources may use the engine's existing DSD-to-PCM conversion when direct DSD
and bit-perfect modes are not required. The USB backend requests 24-bit PCM,
starting at 176.4 kHz for DSD64, 352.8 kHz for DSD128, or 705.6 kHz for higher
rates, then tries lower 44.1-family rates down to 44.1 kHz if unsupported. Each
candidate must pass the same clock verification; device/transfer errors stop
negotiation. Session facts label this as converted PCM, never native DSD or
bit-perfect DSD. This also avoids treating a DSD byte clock as a PCM sample rate.

USB interface ownership and bypassing Android's mixer do not, by themselves,
prove bit-perfect PCM. The existing engine separately checks integer source
precision/layout, the target format and sample-changing DSP/volume. The USB
backend reports only the format and ownership it actually negotiated. Hardware
bit transparency still needs a digital capture or suitable DAC verification.

The optional `lazer_audio_android_usb_backend_version()` export returns 1 for
engines with this route. The Dart integration must check it before passing a USB
token: older imported engines may otherwise treat an unknown device token as
system output. This does not change the existing C ABI structure layout.

`AndroidUsbAudioPlugin` belongs to the Flutter engine, so an activity recreation
does not discard its connections. USB detach closes the Android connection and
notifies Dart; libusb transfer errors also report device loss on the native path.
Permission denial and unsupported device topology are errors, not successful
HiFi sessions.

Permission replies carry a per-request nonce: a delayed reply for a cancelled
request cannot complete a newer request for the same device. Each engine uses
its own permission action. The plugin allows at most 8 pending device requests,
32 waiters per device, and 8 open connections; additional requests return
`usb_busy` without evicting a connection in use. Invalid FDs are closed before
they can enter the connection cache. Detach, cancellation and engine shutdown
release pending results and connections, including when an individual close
throws. These lifecycle and capacity rules have a device-free Kotlin contract
runner at `tool/usb_audio_session_check.ps1`; they do not replace USB hardware
tests.

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
ORG_GRADLE_PROJECT_lazerRequireNativeAudio=true flutter build apk --release --no-pub --target-platform android-arm,android-arm64
python3 ci/verify-android-audio.py --apk build/app/outputs/flutter-apk/app-release.apk
```

The helper stages `liblazer-audio.so` and `liblazer-audio-bridge.so` for each ABI
under Android's `jniLibs` directory. The APK verifier checks ELF architecture,
required C exports (including the USB backend capability for bundled engines),
runtime dependencies, absence of private FFmpeg exports,
16 KiB load alignment and uncompressed ZIP-entry alignment. Release packaging
also rejects bundled FFmpeg source archives, license files and build metadata.

`lazerRequireNativeAudio=true` is the publication policy used by CI: both ARM
engine/bridge pairs must be staged, and `androidComponents.finalizeDsl` limits
the final APK ABI configuration to ARM64 and ARMv7. Flutter 3.47 otherwise adds
x86_64 to its default filters even when only ARM targets were requested; an
x86_64 plugin library could then advertise an incomplete app architecture.
For fat APKs the policy sets NDK filters; for `--split-per-abi` it clears NDK
filters and restricts the split list instead, avoiding AGP's conflicting-filter
error. Ordinary builds without the publication flag keep Flutter's normal
emulator/debug behavior. No global `disable-abi-filtering` override is required.

The APK verifier checks **every** architecture present under `lib/<abi>/`, not
only the two expected ARM directories. Each must contain nonempty
`libflutter.so`, `libapp.so`, engine and bridge libraries. Fat release APKs must
contain both ARM ABIs by default; pass `--apk <split.apk> --abi arm64-v8a` or
`--abi armeabi-v7a` to verify the corresponding single-ABI split. Extra incomplete
plugin-only architectures are rejected in either mode.

FFmpeg is built from a pinned LGPL revision with the file protocol and audio
decoders enabled. The profile stamp prevents an older DSD-only SDK from silently
being reused. The engine uses a version script to keep FFmpeg and static C++
runtime symbols local to its shared library.

Static FFmpeg and libusb linkage produces a relinking archive for each ABI in
`dist/`. These archives contain both libraries' static archives, engine object
files, the export map and a relink script. The script links libusb alongside
FFmpeg in the archive group. They also include libusb's corresponding source,
LGPL license, pinned revision/hash and the exact CMake recipe to rebuild it with
NDK 28.2.13676358. CMake records the actual built archive and source location,
including source overrides, so packaging cannot accidentally omit libusb.
The included FFmpeg build script records its pinned revision and build options
(the repository copy is `native/lazer-audio/tools/build_android_dsd_ffmpeg.sh`).
Follow the archive's README to replace either library and run `bash relink.sh`
to produce a replacement engine. The app's Audio Engine importer accepts compatible
replacement libraries without requiring the original library's signature.

## Verification

The dated evidence and phone/DAC acceptance matrix are in
[HiFi acceptance, 2026-11-18](hifi-acceptance-2026-11-18.md). The isolated
2026-11-17 HiFi test APK passed its complete ARM package checks, but no Android
phone or DAC was attached. That historical artifact does not establish a build
or a hardware result for the current branch.

The USB host contracts compile the production output, clock-control code,
packetizer and transport against a fake libusb device. They verify exact payload
bytes at 44.1/48/96/192 kHz, integer subslot layouts, permission-FD duplication,
clock RANGE/SET_CUR/readback, interface release, pause/flush/drain and failure
without AAudio fallback. They also reject conflicting explicit PCM targets,
preserve claim/control I/O errors, and exercise DSD64/128/256 converted-PCM clock
negotiation while rejecting required native DSD, DoP and bit-perfect DSD. The existing transport cases also cover cancellation,
feedback and quarantined shutdown. These are software contracts, not a USB bus
capture or a listening test.

```sh
cmake -S native/lazer-audio/tools/uac2_transport_probe -B build/uac2-contract
cmake --build build/uac2-contract --config Release
ctest --test-dir build/uac2-contract -C Release --output-on-failure
cmake -S native/lazer-audio/tools/uac2_packetizer_probe -B build/uac2-packetizer-contract
cmake --build build/uac2-packetizer-contract --config Release
ctest --test-dir build/uac2-packetizer-contract -C Release --output-on-failure
flutter test --no-pub test/android_usb_audio_test.dart test/hifi_android_devices_test.dart
python3 -m unittest discover -s ci/tests -p test_android_audio_acceptance.py -v
```

A separate NDK link check builds the actual AAudio/USB routed backend without the
FFmpeg SDK. Run it for both packaged ARM ABIs:

```sh
cmake -S native/lazer-audio/tools/uac2_android_compile_probe \
  -B build/uac2-output-android-arm64-v8a -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 -DANDROID_STL=c++_static
cmake --build build/uac2-output-android-arm64-v8a
```

Historical verification in the 2026-11-17 snapshot: USB output/transport (2 tests), USB packetizer
(1 test), and AAudio/log contracts (2 tests) passed on the Windows host. The
standalone UAC2 JNI target and the routed backend link check both compiled with
NDK 28.2.13676358 for `arm64-v8a` and `armeabi-v7a`. The latter's ELF files have
16 KiB LOAD alignment, export the optional USB backend version function, and
require only Android system libraries (libusb and the C++ runtime are static).
A relink-package smoke check also extracted the corresponding libusb source,
verified every manifest hash, rebuilt libusb with the NDK, and relinked the real
routed backend objects with `-z defs` for both ARM ABIs. That fixture uses empty
FFmpeg archives because the backend probe does not reference FFmpeg; it verifies
packaging/relinking plumbing, not a full engine. The link-check DSO is not an
installable playback engine. The later isolated HiFi APK did include the complete
FFmpeg engine and passed packaging checks; see the dated report above. A fresh
APK and USB behavior on Android hardware require separate verification. The
2026-11-18 integration subsequently rebuilt the full engines, real relinking
archives and APK; its results are in [the current acceptance record](hifi-acceptance-2026-11-18.md).

In that historical snapshot, `AndroidUsbAudioPlugin.kt` also compiled to JVM 17
bytecode against the official Android 36 API jar and Flutter 3.47.0's Android
embedding jar using standalone Kotlin 2.2.20. This is an isolated source/API
compile, not the repository's Gradle/Kotlin 2.4.0 build. This isolated check alone
does not establish MainActivity or full APK integration: those also require
AndroidX, audio_service and generated Android resources. No stub APIs were
substituted for those dependencies. The later historical APK's Gradle build is
recorded separately in the dated acceptance report.

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
