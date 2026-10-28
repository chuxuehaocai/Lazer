# Automated builds

[Build nextgen](https://github.com/chuxuehaocai/Lazer/actions/workflows/build.yml)
runs for pushes and pull requests targeting `nextgen`, manual
`workflow_dispatch` runs, and `v*` version tags. Flutter is pinned to
**3.47.0 stable**. A successful run for a `v*` tag creates a GitHub Release
with all platform binaries and SHA-256 files. A tag containing a hyphen, such
as `v2.0.0-beta.1`, is published as a pre-release. Set the matching app version
in `pubspec.yaml` before pushing the tag so the binaries report the same version.

Analysis and tests run first. Seven independent platform/architecture builds then
upload the following **Artifacts**. Each binary/archive has its own SHA-256 file.

| Artifact / filename stem | Format and contents |
| --- | --- |
| `Lazer-Windows-x86_64` | ZIP with EXE, DLLs, resources and the MSVC runtime |
| `Lazer-macOS-universal` | ZIP with an Intel / Apple Silicon App |
| `Lazer-macOS-x86_64` | ZIP with a native Intel App |
| `Lazer-Linux-x86_64` | x86_64 AppImage with GTK and libmpv |
| `Lazer-Linux-aarch64` | ARM64 AppImage with GTK and libmpv |
| `Lazer-Android-universal` | Universal release APK using the development signing configuration |
| `Lazer-iOS-aarch64` | Unsigned device IPA containing `Payload/Runner.app` |

All artifact names follow `Lazer-<OS>-<Arch>`. `universal` denotes a multi-architecture
package. The macOS archives preserve executable permissions and framework symlinks.
Architecture checks run before packaging. IPA builds explicitly disable code signing.

## Native audio engine

The desktop playback engine ported from `master` (FFmpeg + WASAPI/ALSA/CoreAudio,
DSD/DoP, gapless, EQ/limiter) is opt-in: it is built into the bundle only when a
DSD-capable FFmpeg is available, and the app otherwise plays through `just_audio`.
The CI workflow does not set `LAZER_FFMPEG_ROOT`, so released binaries currently use
`just_audio`. On Windows the engine must be built with MSVC (its WASAPI backend
cannot be linked by MinGW). See [audio-engine.md](audio-engine.md) for the build
variables, the settings page and the checks that cover the port.

## Build stamp

Every platform build receives the commit it was cut from through
`--dart-define=LAZER_COMMIT=<sha>`, and **Settings → About** shows its short
form. Tag builds also receive `--dart-define=LAZER_VERSION=<tag>`; the update
checker compares that version with GitHub Releases, so the tag and
`pubspec.yaml` must agree. A local `flutter run` that omits the defines falls
back to the checked-in values in `lib/diagnostics/build_info.dart`.

## Publishing an update

1. Set `version:` in `pubspec.yaml` to the tag without its `v` prefix and bump
   the build number (for example `2.0.0-beta.3+3`).
2. Commit, then push an annotated tag with the same version (`v2.0.0-beta.3`).
3. The build workflow runs every platform job. Only when all of them pass does
   the release job attach the artifacts; a tag containing `-` becomes a
   pre-release.
4. An installed build checks `api.github.com` at most once a day, and offers
   the newest release newer than its own `LAZER_VERSION`. Stable builds ignore
   pre-releases; a beta build sees later betas.

See [updates.md](updates.md) for the client-side rules.


## Runners and SDKs

- Windows uses `windows-2022`.
- macOS universal uses `macos-15`; Intel uses `macos-15-intel`.
- Linux uses native `ubuntu-22.04` / `ubuntu-22.04-arm` runners. Both AppImages have
  a glibc 2.35 baseline. The ARM runner bootstraps the SDK from the official Flutter
  3.47.0 tag and verifies its commit, since the official archive only provides an
  x64 Linux SDK. It does not cross-compile or use a third-party SDK.
- Android uses `ubuntu-24.04` with Java 21; iOS uses `macos-15`.

Linux packaging pins linuxdeploy and its GTK helper, checks the packaging tool's
SHA-256, and explicitly bundles libmpv because it is loaded through FFI. Each
AppImage must start under Xvfb and a session D-Bus before it is uploaded.

## Downloading

Open a completed branch run and download from **Artifacts** while signed in to
GitHub. These artifacts are retained for 30 days. Version-tag runs also attach
the artifacts to their GitHub Release; the release job has write access only to
download its workflow artifacts and publish that release.

Extract the whole Windows ZIP before launching the EXE. Downloaded AppImages need
`chmod +x`. macOS Apps are ad-hoc signed, not Developer ID signed/notarized. The
unsigned IPA needs your own signing before installation.
