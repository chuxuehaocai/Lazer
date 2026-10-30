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
frame-rate and mesh-detail settings. Browsing defaults to 30fps; now playing
defaults to the display's actual vsync rate, including displays above 240Hz.
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

| Platform | Engine library | Output |
| --- | --- | --- |
| Android 8.0+ (arm64-v8a, x86_64) | liblazer-audio.so | AAudio shared PCM |
| Windows | lazer-audio.dll | WASAPI |
| Linux | liblazer-audio.so | ALSA |
| macOS | liblazer-audio.dylib | CoreAudio |

Android uses the same FFmpeg decoder, gapless engine, DSP and Dart worker as the
desktop. Its AAudio backend negotiates the actual PCM format; Android does not
advertise desktop exclusive, bit-perfect or direct DSD output capabilities.
DSD sources use the engine's PCM conversion.

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
`ci/build-android-audio.sh`, builds both supported ABIs with NDK 28.2.13676358,
and checks the final APK for both native libraries in each ABI directory.

To build Android engines on Linux/macOS, set `ANDROID_HOME` and install the pinned
NDK, CMake, Ninja, pkg-config and NASM, then run:

```sh
bash ci/build-android-audio.sh
flutter build apk --release --target-platform android-arm64,android-x64
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
