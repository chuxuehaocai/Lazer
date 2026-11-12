# Interface and audio customization

MiSans is the primary text family on every platform, including Material and
Cupertino surfaces. Settings → Font customization contains the shared text size and weight controls
for page headings, list/card titles, body text, secondary text, navigation,
player metadata and lyrics. Changes apply immediately and survive a restart.
Each group can be reset independently; the page also offers a complete reset.
Phones open font, shortcut and equalizer settings as separate pages. Desktop
keeps them inside the Settings view, with animated navigation and retained
overview scroll position.

Settings → Lyrics → Show artwork with lyrics keeps the artwork in the player.
Tapping the artwork moves it beside the song details without its shadow. Artwork,
details and transport hide together; a compact artwork/title/artist summary appears
at the top. Tapping the summary restores the controls; tapping the small artwork
restores the large artwork. This option applies only to the compact/mobile player;
portrait and landscape share the same animation state, including interrupted and
reversed transitions. Cover movement starts quickly and slows on arrival in
either direction.

Artwork-derived accents preserve their hue while adapting their lightness to the
active surface. Filled buttons choose a contrasting label. The open player's
playback state owns palette updates, including while either page is covered.
Late results for a previous song cannot overwrite the current song's accent.

Browsing and now-playing backgrounds have independent mode, image, color,
frame-rate and mesh-detail settings. On a fresh install the browse background
defaults to `不使用` (off) — only the theme surface is painted — while the
now-playing background keeps its flowing canvas default. Browsing defaults to
30fps; now playing defaults to the display's actual vsync rate, including
displays above 240Hz.
Manual rates can go down to 10fps. Background rendering uses vsync scheduling
and stops when hidden, paused or reduced motion is requested. Static mode keeps
one mesh frame, and solid-color mode uses a chosen or theme-generated color.

Transitions use nonlinear curves and temporary raster snapshots. Rapid page or
cover switching retains at most one outgoing rendered child. Snapshot images
are released when the motion ends. The player does not run lyric animation
during entrance/exit; desktop shader paths are warmed before interaction.

Playlist drops preserve the current card position while neighboring cards ease
into their new slots. Order writes are serialized, coalesced and restored after
restart. Discrete desktop wheels gain smooth momentum; small trackpad deltas
keep the system's own momentum, and Apple touch scrolling uses native bounce.

## Playback engines

Settings → HiFi playback → Audio engine selects the bundled/imported Audio Engine or the system
audio engine. Engine selection and imports apply on the next application launch.
An unavailable/incompatible native library falls back to the system engine.
New installations prefer the bundled native engine. An explicit system-engine
selection or imported-engine override is preserved across upgrades.

On Windows, `flutter run -d windows` also compiles the engine whenever a
DSD-capable FFmpeg SDK is available. CMake discovers `third_party/ffmpeg`,
`native/ffmpeg`, `build/native-ffmpeg/windows-x64` and the local
`build/windows-ffmpeg-local` cache; `LAZER_FFMPEG_ROOT` takes precedence.
Debug/Profile builds update `lazer-audio.dll` at the checkout root, with the
reader bridge and FFmpeg runtime in `build/native-audio`. Development checkouts
load that root engine before bundled copies. Release builds search their own
bundle and ignore repository artifacts.

For a standalone local Windows build, run
`dart run tool/build_native_audio.dart --project-root`. This discovers cached
SDKs and Visual Studio's CMake without requiring a developer command prompt.
The root DLL is a local build output: do not commit it or add an ignore rule.

| Platform | Engine library | Output |
| --- | --- | --- |
| Android 8.0+ (armeabi-v7a, arm64-v8a) | liblazer-audio.so | AAudio shared PCM |
| Windows | lazer-audio.dll | WASAPI |
| Linux | liblazer-audio.so | ALSA |
| macOS | liblazer-audio.dylib | CoreAudio |
| iOS | liblazer-audio.a linked into Runner | RemoteIO shared PCM |
| iOS | liblazer-audio.a linked into Runner | RemoteIO shared PCM |

Android uses the same FFmpeg decoder, gapless engine, DSP and Dart worker as the
desktop. Its AAudio backend negotiates the actual PCM format; Android does not
advertise desktop exclusive, bit-perfect or direct DSD output capabilities.
DSD sources use the engine's PCM conversion.

iOS uses the same decoder, DSP and Dart worker with the RemoteIO output backend.
Xcode prepares and links the static engine automatically for device and simulator
builds; iOS remains a shared mix and does not expose exclusive, bit-perfect or
direct DSD output.

iOS uses the same decoder, DSP and Dart worker with the RemoteIO output backend.
Xcode prepares and links the static engine automatically for device and simulator
builds; iOS remains a shared mix and does not expose exclusive, bit-perfect or
direct DSD output.

Import a library for the current platform and architecture using the app's C ABI
(`LAZER_AUDIO_ABI_VERSION` in `native/lazer-audio/include/lazer_audio_api.h`).
The importer checks the ABI and required exports and copies the files into the
application's support directory. Select dependency libraries together with the
engine when needed. Streaming uses the companion `lazer-audio-bridge` library;
the bundled bridge remains available when an import does not include one.
Restore bundled engine clears the override without changing the installation.

Settings → HiFi playback → Equalizer opens the ten-band editor, with presets,
preamp, limiter and reset. Native-engine adjustments apply live and persist;
bit-perfect mode bypasses EQ. System engines without DSP support can save a
curve for use after switching to Audio Engine and restarting.

Settings → 播放 → 切歌衔接 chooses how the end of one song reaches the next.
`专辑无缝播放` (the default) hands the following song to the engine only when it
belongs to the same album: adjacent tracks of an album run join to join without
a reload, while a different album starts with the normal cut. The album is the
one the catalogue reports; a file read from disk has no album id, so its album
name and performer stand in, and an untagged album never chains files together.
`自动混音` replaces that policy with AutoMix: the next song is prepared whatever
album it comes from, and an engine that can mix overlaps it before the current
song ends. Changing the mode rebuilds the queue hand-off — a prepared song from
another album is taken back — without interrupting the song unless the native
decoder has to reopen. An engine that refuses the mode falls back to album
gapless playback and the row says why.

Album gapless playback sounds different on the two families of engine, and both
are intended. The native engine queues the following song into the same playback
clock, so the join is sample to sample and nothing is overlapped. The system
engine runs one decoder per song and cannot make two of them share a clock: it
starts the following song inside the last 200 ms of the current one and crosses
the gains there, because waiting for the first decoder to stop and then opening
the second leaves the device dry and the join is heard as a click.

## Diagnostics

Settings → About → Export logs saves a bounded runtime log and playback report.
Android uses the system document creator, while desktop uses the file saver.
Credentials and URL queries are redacted. The report includes the running
engine, background configuration and accessibility transaction diagnostics.
The desktop semantics bridge retains connected updates and restores recently
detached nodes, preventing a stale animated descendant from invalidating AXTree.

## Builds

GitHub Actions stages the engine, reader bridge and required FFmpeg runtime/license
files into Windows, Linux and macOS runnable packages. Android additionally runs
`ci/build-android-audio.sh`, builds the supported ABIs with NDK 28.2.13676358,
and checks the final APK for both native libraries in each ABI directory.

To build Android engines on Linux/macOS, set `ANDROID_HOME` and install the pinned
NDK, CMake, Ninja, pkg-config and NASM, then run:

```sh
bash ci/build-android-audio.sh
flutter build apk --release --target-platform android-arm,android-arm64
```

Generated Android libraries and FFmpeg license files are ignored by Git. The
Android native libraries use 16 KiB maximum page alignment. Source checkouts
without staged libraries can still use the system audio engine.

See [Android Audio Engine](android-audio.md) for native output behavior, artifact
verification, device checks and the FFmpeg source/relinking archives that accompany
Android builds.

See [Rendering and resource validation](performance-validation.md) for measured
reductions in work, regression coverage and the limits of current frame-rate
measurements.
