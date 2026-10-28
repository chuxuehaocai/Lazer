# Native audio engine

The playback path inherited from the `master` branch: FFmpeg decodes, the
platform backend (WASAPI / ALSA / CoreAudio HAL) outputs, and one C++ engine owns
the clock, the gapless queue, DSD/DoP and the EQ/limiter chain. On `nextgen` it
runs behind the same `AudioEngine` interface the Flutter app already used, so
everything above the engine — queue, lyrics, media session, seek rail — is
unchanged.

`just_audio`/media_kit is still the fallback. The native engine is used only when
its shared library is next to the app and reports the ABI version this build
expects; otherwise the app plays exactly as it did before. That keeps Android,
iOS, and any desktop build without a DSD-capable FFmpeg working.

```
AppState ──► AudioEngine ──► NativeAudioEngine ──► LazerAudioWorker (isolate)
                │                   │                      │
                │                   ├── AudioStreamCache ──┤ blocking C ABI calls
                │                   │   (HTTP → cache file)│
                │                   └── events ◄───────────┴── lazer-audio(.dll/.so/.dylib)
                └──► just_audio (fallback)                        ▲
                                                                  │
                                              lazer-audio-bridge ─┘ (growing-file reader)
```

The engine's own design history — format policy, what each platform backend does
and does not prove, the offline probe suite — is still documented on the `master`
branch in `docs/HIFI_PLAYER_DEVELOPMENT.md` and `docs/HIFI_PLAYER_HANDOFF.md`; this
file only covers what the Flutter port adds and what it does not yet do.

## Local changes to the vendored engine

`native/lazer-audio/` is the master branch's tree, with one deliberate addition:
the **crossfeed** stage, ported from the Twilight Echo engine (Apache-2.0, see
`THIRD-PARTY-NOTICES.md`). It is an interleaved float stage between the EQ and the
limiter, so the limiter still protects the summed signal, and it is exercised by
`lazer-audio-crossfeed-probe` (CTest `lazer-audio-crossfeed`).

That change appends fields to `LazerAudioDspConfig` and bumps
`LAZER_AUDIO_ABI_VERSION` to **24** — the header's own rule for additive changes. The
Dart mirror, the layout expectations and the worker message were updated together, so
`dart tool/native_abi_check.dart` fails loudly if they ever drift.

Everything else in the tree is the master branch's, including its probes.

## Layout

| Path | What it is |
| --- | --- |
| `native/lazer-audio/` | The engine from `master`, unmodified: `include/lazer_audio_api.h` (ABI v23), FFmpeg decode, WASAPI/ALSA/CoreAudio output, DSD/DoP, DSP chain, offline probes. |
| `native/lazer-audio-bridge/` | Growing-file reader over a cache file, plus the ABI layout probe. |
| `native/CMakeLists.txt` | Builds both for the host when an FFmpeg prefix is available. |
| `lib/audio/native/lazer_audio_abi.dart` | Dart mirror of the C ABI (structs, enums, constants). |
| `lib/audio/native/lazer_audio_library.dart` | Library resolution, ABI check, typed function pointers. |
| `lib/audio/native/lazer_audio_worker.dart` | Isolate that owns the blocking engine calls. |
| `lib/audio/native/lazer_audio_reader.dart` | Dart handle for one bridge reader. |
| `lib/audio/native/audio_stream_cache.dart` | HTTP → growing cache file download. |
| `lib/audio/native/lazer_audio_engine.dart` | `AudioEngine` / `QueueAudioEngine` / `BufferedAudioEngine` / `FailureReportingAudioEngine`. |
| `lib/audio/engine_factory.dart` | Picks the native engine or `just_audio` for this launch. |
| `lib/audio/native/lazer_audio_devices.dart` | Output-device catalogs (Windows endpoints vs. UTF-8 Linux/macOS), the exclusive PCM format probe and endpoint volume. |
| `lib/state/hifi_settings.dart` | The HiFi settings model: band layout, presets, DSD mode/rate policy, normalisation modes, crossfeed and their encodings. |
| `lib/audio/hifi_controller.dart` | Applies those settings to the engine and reports what it negotiated. |
| `lib/widgets/hifi_settings_section.dart` | The 高保真播放 / 均衡器 / 信号路径 groups on the Settings page. |

## Three things the port had to solve

**Blocking calls can't run on the UI isolate.** `lazer_audio_open_reader` reads —
and waits for — the source; `queue_reader` decodes a successor; `stop`,
`clear_queued_reader` and `destroy` join engine threads. The master branch ran
those on `Dispatchers.IO`. Here they run in `LazerAudioWorker`, a dedicated
isolate, which also serialises them: one isolate, one event loop, so a device
change can never overtake the open it was meant for. Calls that do not block
(`snapshot`, `stream_info`, `last_error`) are made from the UI isolate so
`AudioEngine.position` stays synchronous.

**Dart cannot service a blocking native callback.** The engine pulls bytes
through `LazerAudioReader` callbacks on its own decode thread and expects a
synchronous return value (`> 0` bytes, `0` = not yet, `-1` = EOF, `-2` = error).
`dart:ffi` offers only `NativeCallable.isolateLocal` (illegal from a foreign
thread) or `NativeCallable.listener` (asynchronous, no return value). So the byte
source lives in `native/lazer-audio-bridge`: it opens the cache file, blocks on a
condition variable until the download appends, and exposes the five callbacks as
plain C function pointers that Dart writes into the reader struct. Dart keeps the
lifecycle (`create`, `notify`, `finish`, `destroy`) and never enters the read
path.

**Reader lifetime is a real hazard.** The engine may keep reading a reader until
it stops or replaces the source, so a reader is freed only after a *serialised*
worker call that guarantees the engine dropped it — a later
`clear_queued_reader`, a finished `open`, or `stop`/`destroy`. Freeing on the Dart
side alone would let the decoder read freed memory.

Network playback follows the master design: the app downloads into a cache file
while the engine reads it, so a read for a range that has not landed yet waits
for the download instead of looking like a short file. Local files are opened
directly with `lazer_audio_open_file_utf8`.

## Building

The engine needs a **DSD-capable** FFmpeg (`AV_SAMPLE_FMT_DSD`, `AVChannelLayout`,
`swr_alloc_set_opts2`). Distro packages usually are not; build one with
`native/lazer-audio/tools/build_dsd_ffmpeg.sh`. A prebuilt Windows bundle such as
`ffmpeg-master-latest-win64-gpl-shared` has the APIs and the MSVC import libraries;
unpack it anywhere and point `LAZER_FFMPEG_ROOT` at it.

On Windows the engine must be built with **MSVC**. Its WASAPI backend links GUID
symbols (`KSDATAFORMAT_SUBTYPE_PCM`, `PKEY_Device_FriendlyName`) that MinGW only
declares, so a MinGW link fails with undefined references;
`tool/build_native_audio.dart` therefore selects the Visual Studio generator when it
can find one.

Windows and Linux are wired into the Flutter build:

```bash
LAZER_FFMPEG_ROOT=/path/to/ffmpeg flutter build windows --release
LAZER_FFMPEG_ROOT=/path/to/ffmpeg flutter build linux --release
```

`windows/CMakeLists.txt` and `linux/CMakeLists.txt` add `native/` and install
`lazer-audio`, `lazer-audio-bridge` and (on Windows) FFmpeg's DLLs next to the
executable. Without `LAZER_FFMPEG_ROOT` (or `third_party/ffmpeg`) the engine is
skipped with a status message and the app builds against `just_audio`.

For `flutter run` during development, and for macOS (whose Xcode build has no
CMake step), stage the libraries into `build/native-audio/`, which the loader also
searches:

```bash
dart run tool/build_native_audio.dart --ffmpeg-root /path/to/ffmpeg
```

`LAZER_AUDIO_LIBRARY` and `LAZER_AUDIO_BRIDGE_LIBRARY` override the resolved paths
for one process.

## Verification

### Engine regression suite

With `-DLAZER_AUDIO_NATIVE_PROBES=ON` the engine's own offline probes are built and
registered with CTest. They drive fake platform-output backends, so no audio device is
needed, and they cover PCM matrix byte-exactness across the advertised rate/depth grid,
gapless A→B seams, DoP carrier framing, Native DSD packing, CUE segments, ReplayGain
transitions, the DSP/limiter chain and the platform format policies:

```bash
cmake -S native -B build/native-probes -DLAZER_FFMPEG_ROOT=/path/to/ffmpeg -DLAZER_AUDIO_NATIVE_PROBES=ON
cmake --build build/native-probes --config Release
ctest --test-dir build/native-probes -C Release --output-on-failure
```

### Checks that need no engine binary

```bash
dart tool/native_abi_check.dart     # Dart struct mirror vs. the C compiler
dart tool/native_cache_check.dart   # HTTP → cache → resume/fail/evict
dart tool/native_engine_check.dart  # worker messages + format summaries
dart tool/native_hifi_check.dart    # settings encodings, presets, engine mapping
flutter test test/audio/            # the same, under flutter test
```

### Live check on a machine with the engine and an output device

```bash
dart run tool/build_native_audio.dart --ffmpeg-root /path/to/ffmpeg
dart tool/native_bridge_check.dart   # the reader bridge against the real library
dart tool/native_engine_smoke.dart   # real playback, seek, gapless, exclusive
```

`native_engine_smoke.dart` walks the device catalog, plays a generated tone, samples the
clock, seeks, crosses a gapless boundary, applies the EQ through the settings layer, and
— if the endpoint allows it — opens an exclusive bit-perfect session and checks that the
engine reports the source format unchanged. It reads a WAV/FLAC under
`build/native-audio/testdata` (or `--file`), which FFmpeg can generate:

```bash
ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=3" -ac 2 -c:a pcm_s16le build/native-audio/testdata/tone441.wav
```

* **ABI layout.** `native/lazer-audio-bridge/tools/abi_layout_probe.cpp` prints
  `sizeof`/`offsetof` for every struct the Dart side builds or reads; the Dart
  side asserts the same numbers. A wrong offset is silent corruption (the engine
  copies structs byte-for-byte), so this is the check that keeps the mirror
  honest. Rerun the probe after any header change.
* **Reader bridge.** The check drives the real `lazer-audio-bridge` library: a
  read blocks until bytes are appended, `seek` waits for an undownloaded offset,
  the announced length is reported while the file grows, `finish` yields a clean
  EOF, a failed download becomes a terminal error, and `cancel` wakes a blocked
  read.
* **Streaming cache.** Whole download, range resume after an interrupted
  download, a server that ignores `Range` (truncate, no duplication), a failed
  download reported as failure, and bounded eviction.
* **Crossfeed.** `lazer-audio-crossfeed-probe` measures cross-channel leakage, its delay,
  the strength scaling, bit-transparency when off, the mono bypass, that the named
  algorithms differ from the custom default, and that the limiter still catches the
  summed signal.
* **Settings layer.** The master branch's equaliser encoding still parses (including
  its Kotlin enum names — that check found a real incompatibility, now fixed), a
  malformed value falls back to a flat curve, every preset round-trips, and
  bit-perfect sends no bands at all.
* **Live engine on this machine** (Windows, Realtek USB endpoint): the endpoint
  catalog, the endpoint master-volume read/write round-trip, the exclusive PCM format
  probe, shared-mode playback at the endpoint's own mix format, seeking, `pause`/`stop`
  states, the reader bridge feeding a live FLAC decode, a gapless `TrackChanged` →
  `Ended` crossing, EQ/limiter telemetry that moves with the preamp, and an exclusive
  bit-perfect session for a `44100 Hz/16-bit` source that reported
  `44100 Hz/16-bit`, `exclusive`, `selection = ExclusiveSource`. A shared-only
  endpoint refuses the same request instead of silently converting.

Status of this port:

| Item | State |
| --- | --- |
| Engine sources, ABI and probes | Ported unmodified from `master`. |
| ABI mirror in Dart | Verified against the C compiler (14 structs). |
| Reader bridge | Built and exercised end to end. |
| Streaming cache | Exercised end to end. |
| `AudioEngine` transport, gapless queue, buffered position, failure reporting | Implemented and verified live. |
| Windows bundle integration | Built with MSVC against a DSD-capable FFmpeg; **CTest 16/16** under both the Ninja and Visual Studio generators. |
| Linux bundle integration | Written; not built or run here. |
| macOS bundle integration | Manual staging only; not run. |
| Real playback through WASAPI | **Verified on one Windows host**: shared and exclusive, seek, pause/stop, gapless crossing, reader-bridge streaming, EQ. |
| DSD/DoP/Native DSD | Bound and reachable from the settings page; **no DSD source and no DoP-capable DAC were available**, so none of it is device-verified. |
| Exclusive mode + bit-perfect | Verified: the session reported the source format unchanged; a shared-only endpoint is rejected rather than downgraded. |
| EQ/limiter | Verified end to end (telemetry moves with the preamp) and reachable from the settings page. |
| Crossfeed (ported from Twilight Echo) | Verified by its own CTest probe and live through the settings layer (a Bauer preset reaches the engine and playback still runs). |
| DSD `auto` policy | Implemented in this layer as a Native → DoP → PCM retry chain, since the engine accepts one explicit policy per open. Not device-verified: no DSD source or DoP DAC was available. |
| Normalisation modes | `off`/`track`/`album` map onto the engine's per-source ReplayGain; `loudnorm` needs an EBU R128 measurement stage the engine does not have, so it is offered and reported as unavailable. |
| Settings page (device, exclusive, bit-perfect, DSD, buffer, EQ + presets, live format) | Written; **not run**, because this machine cannot build the Flutter app (see below). |
| ReplayGain | Supported per source by the ABI; the app does not compute or pass it yet. |
| Linux/macOS playback | Not run. The code is the master branch's, unchanged, but ALSA/CoreAudio device behaviour is unverified here. |
| Android/iOS | Not wired. Those need the JNI path from the master branch (`android_dsd_jni.cpp`, UAC2 transport); this port targets desktop. The app keeps `just_audio` there. |

Nothing here is evidence of bit-perfect output: the engine reports what the
platform endpoint accepted, which is necessary but not sufficient, and no digital
loopback has been captured for any device. The exclusive/bit-perfect result above
means the endpoint accepted the exact format and the engine reported no processing —
not that a DAC received those bits unaltered.

This machine cannot build the Flutter app itself: `flutter build` and `flutter test`
need Windows Developer Mode for plugin symlinks, which requires administrator rights
this account does not have. Everything under `lib/` is therefore covered by
`flutter analyze` plus the plain-Dart checks that share its logic — not by a running
app.

## Settings surface

Ported from Twilight Echo's HiFi settings, in this app's own visual language:

| Group | Rows |
| --- | --- |
| 高保真播放 | 引擎状态, 输出设备 (with refresh), 独占输出, Bit-perfect, DSD 输出 (auto/PCM/DoP/native), DSD 倍率策略, 响度归一, 输出缓冲 |
| 耳机串扰 | crossfeed 开关, 强度, 算法 (custom/Bauer/BS2B/Meier) |
| 均衡器 | 开关, 预设, 前级, 限幅器, 10 段滑杆, 重置 |
| 信号路径 | 解码格式, 源, 输出会话, 格式选择, 独占/bit-perfect, 遥测 |

The page enforces the honest combinations rather than letting the engine refuse later:
bit-perfect greys out the EQ and crossfeed (both are bypassed by that promise), a
non-unity software volume is called out, and policies the engine cannot implement are
labelled as such instead of silently behaving like the fallback.

## Next steps

1. Run the app (`flutter run -d windows`) with the engine staged and check the settings
   page against real hardware: device switching, exclusive mode, a DSD/DoP file on a
   DoP-capable DAC, and the EQ while playing.
2. Capture a digital loopback for one endpoint, which turns "the endpoint accepted the
   format" into a bit-exactness result.
3. Feed ReplayGain from the local-library metadata into `LazerOpenSettings`.
4. Verify on Linux (ALSA `hw:`) and macOS (CoreAudio HAL, Hog Mode).
5. Port the mobile JNI path if Android/iOS should get the same engine.
