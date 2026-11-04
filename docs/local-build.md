# Local builds

[Automated builds](builds.md) are the reference: CI pins the SDK, installs the
Linux packages and produces every distributed artifact. Everything except
packaging runs the same way on a local checkout — the same SDK version, the
same lockfile, the same analysis and tests. This page covers a Linux/WSL setup;
Windows and macOS use their own SDK installations, still on Flutter 3.47.0.

## Pinned SDK

CI pins **Flutter 3.47.0 stable** (`.github/workflows/build.yml`), and
`pubspec.lock` requires Dart `>=3.13.0` and Flutter `>=3.47.0`, so
`--enforce-lockfile` refuses a different SDK. On Linux/WSL use the official
archive:

- URL: `https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.47.0-stable.tar.xz`
- Size: `1572146400` bytes (~1.5 GiB)
- SHA-256: `26cd99d3d94b1367e6b50535a18aeef0282c10a535bbe3ec493534dcdab75296`

## Quick start (Linux/WSL)

Download, verify and unpack the SDK outside the repository:

```bash
mkdir -p ~/toolchains
cd ~/toolchains
curl -fLO https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.47.0-stable.tar.xz
echo "26cd99d3d94b1367e6b50535a18aeef0282c10a535bbe3ec493534dcdab75296  flutter_linux_3.47.0-stable.tar.xz" | sha256sum -c -
tar xf flutter_linux_3.47.0-stable.tar.xz
mv flutter ~/toolchains/flutter-3.47.0
```

Put that SDK first on `PATH` in the shell that does the work. Keep the export
command-scoped; only add it to `~/.bashrc` if every new terminal should pick up
this SDK rather than whichever Flutter is already installed:

```bash
export PATH="$HOME/toolchains/flutter-3.47.0/bin:$PATH"
tool/check_toolchain.sh
```

`tool/check_toolchain.sh` reports the Flutter and Dart versions, the `git`,
`tar` and `xz` it resolves on `PATH`, plus the checkout revision, and exits
non-zero when a hard requirement is missing or too old. Then, from the
repository root:

```bash
flutter config --no-analytics
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub --reporter expanded
```

### Expected baseline

Measured on WSL Debian 13 with this SDK:

- `flutter pub get --enforce-lockfile` completes in about 42 s.
- `flutter analyze --no-pub` prints `No issues found!` (0 issues).
- `flutter test --no-pub` runs 1056 tests, all passing, in about 3 min 24 s.

The suite runs headless and needs no display, so it works the same over SSH,
in WSL without WSLg, and in CI. Treat a different issue or test count as a
change in the tree, not in the setup.

## Optional: Linux desktop build

`flutter analyze` and `flutter test` need none of this; `flutter run -d linux`
does. Install the packages CI installs:

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev \
  libmpv-dev libayatana-appindicator3-dev libgdk-pixbuf2.0-dev \
  librsvg2-dev patchelf file desktop-file-utils fuse libfuse2 nasm \
  libasound2-dev \
  xvfb dbus-x11
flutter config --enable-linux-desktop
tool/check_toolchain.sh --build
flutter run -d linux
```

`--build` checks `clang`, `cmake`, `ninja`, `pkg-config`, GTK 3, libmpv and
liblzma, but reports them as warnings: a missing desktop toolchain never fails
the version check.

The native Hi-Fi engine needs the DSD-capable FFmpeg SDK built by
`native/lazer-audio/tools/build_dsd_ffmpeg.sh`; point `LAZER_FFMPEG_ROOT` at its
install prefix when building. This dependency is optional for development:
without it the engine is skipped with a status line and playback falls back to
`just_audio`, so a plain `flutter run -d linux` still works. See
[audio-engine.md](audio-engine.md) for the engine and its build variables.

AppImage packaging is CI-only — linuxdeploy, its pinned GTK helper and the Xvfb
smoke test stay in the workflow. A local `flutter build linux` produces the
bundle but not a distributable AppImage.

## Troubleshooting

### The lockfile rejects the SDK

`flutter pub get --enforce-lockfile` fails with a constraint error naming Dart
or Flutter when another SDK is first on `PATH`. Run `tool/check_toolchain.sh`,
compare `flutter --version` with 3.47.0, and fix `PATH` (or the SDK install)
instead of editing `pubspec.lock`.

### `unzip` is missing

The Flutter tool shells out to `unzip` whenever it has to unpack downloaded
engine artifacts. A complete release tarball already contains them, so the
default check only warns; install `unzip` if Flutter starts fetching artifacts
and the unpack step fails.

### No display on WSL

`flutter analyze` and `flutter test` are headless and need no `DISPLAY`.
`flutter run -d linux` does: WSLg exports `DISPLAY` for GUI applications, a
plain SSH shell does not. Start an X server and export `DISPLAY`, or use WSLg,
for desktop runs. CI installs `xvfb` and `dbus-x11` only for the AppImage smoke
test.

### The app falls back to just_audio

Expected without the FFmpeg SDK. The engine prints the reason it was skipped and
the app plays through `just_audio`; it is a notice, not a build failure. Build
the FFmpeg SDK as described above to exercise the native engine.

## See also

- [builds.md](builds.md) — CI workflow, artifact matrix, signing and publishing.
- `tool/check_toolchain.sh` — the version checks to run before reporting a
  toolchain problem.
