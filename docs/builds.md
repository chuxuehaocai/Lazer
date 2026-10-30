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
| `Lazer-Windows-x86_64` | ZIP with EXE, native audio engine, FFmpeg, resources and the MSVC runtime |
| `Lazer-macOS-universal` | ZIP with an Intel / Apple Silicon App and native audio engine |
| `Lazer-macOS-x86_64` | ZIP with a native Intel App and native audio engine |
| `Lazer-Linux-x86_64` | x86_64 AppImage with GTK, libmpv and the native audio engine |
| `Lazer-Linux-aarch64` | ARM64 AppImage with GTK, libmpv and the native audio engine |
| `Lazer-Android-universal` | Universal release APK signed with the release key from repository secrets |
| `Lazer-iOS-aarch64` | Unsigned device IPA containing `Payload/Runner.app` |

All artifact names follow `Lazer-<OS>-<Arch>`. `universal` denotes a multi-architecture
package. The macOS archives preserve executable permissions and framework symlinks.
Architecture checks run before packaging. IPA builds explicitly disable code signing.

## Native audio engine

The desktop playback engine ported from `master` (FFmpeg + WASAPI/ALSA/CoreAudio,
DSD/DoP, gapless, EQ/limiter) is built into all Windows, macOS and Linux cloud
artifacts together with the matching DSD-capable FFmpeg runtime and its LGPL
notice. Packaging checks fail if any required engine, bridge or FFmpeg library is
missing. Android packages the native AAudio engine for arm64-v8a and x86_64;
iOS uses `just_audio`. On Windows the engine and FFmpeg are built with MSVC so
their import libraries match the app toolchain. See
[audio-engine.md](audio-engine.md) for local build variables and the settings page.

## Android release signing

The Android job signs the release APK with a dedicated upload key. The keystore and
`android/key.properties` are git-ignored; CI recreates both from repository secrets
before building, and `android/app/build.gradle.kts` reads `key.properties`
(`storeFile`, `storePassword`, `keyAlias`, `keyPassword`) when it exists.

Create the key once per repository with:

```powershell
./ci/generate-android-keystore.ps1
```

The script writes `android/app/upload-keystore.jks`, `android/key.properties`, and an
export bundle in `dist/android-signing/` holding `upload-keystore.jks`, the base64
copy, and `github-secrets.txt`. Add these four repository secrets
(**Settings → Secrets and variables → Actions**):

| Secret | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | Full content of `upload-keystore.jks.base64.txt` |
| `ANDROID_KEYSTORE_PASSWORD` | `storePassword` from `key.properties` |
| `ANDROID_KEY_ALIAS` | `keyAlias` from `key.properties` |
| `ANDROID_KEY_PASSWORD` | `keyPassword` from `key.properties` |

Behaviour:

- With the secrets present, every Android build — branch, PR, or tag — is signed with
  the release key.
- On a `v*` tag the build fails if the secrets are missing, so a release can never be
  debug-signed.
- Pull requests from forks cannot read secrets; they fall back to the debug key so the
  job still turns green.
- After the build the job compares the APK signer's SHA-256 certificate digest with the
  keystore's and fails on a mismatch.

The key is the root of trust for every future update: an APK signed by a different key
cannot upgrade an installed build, so keep `dist/android-signing/` in offline storage.
Losing it forces a new application id or an uninstall/reinstall for every user. Builds
published before this key existed were debug-signed and need one manual uninstall to
move onto release-keyed updates.

`flutter run --release` and local release builds keep working without a keystore: the
release build type then falls back to the debug signing configuration. To make a local
build insist on the real key, run Gradle with `-PlazerRequireReleaseSigning=true`.

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
