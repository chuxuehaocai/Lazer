# Third-party notices

The original Lazer source in this repository is licensed under the GNU Affero
General Public License, version 3 or any later version. See [LICENSE](LICENSE).
The works listed below keep their own copyright and licensing terms. A notice
here does not grant permission to redistribute material whose copyright holder
has not granted that permission.

## Apple Music Like Lyrics

The lyric animation adaptation in the following files is licensed under
AGPL-3.0-or-later:

- `lib/lyrics/viewport.dart`
- `lib/lyrics/spring.dart`
- `lib/lyrics/word_motion.dart`
- `lib/lyrics/timed_line.dart`

Source project: <https://github.com/amll-dev/applemusic-like-lyrics>
Reference commit: `86200dead453bb067e554e989110cbadca8d4756`
The full license text and attribution are in
`licenses/lyric_animation/AGPL-3.0.txt`.

## Still Alive terminal credits

The terminal-credit program and the adapted Dart score/data are licensed under
GPL-3.0-or-later. The original source, README, and license text are retained in
`assets/easter_eggs/still_alive/`; the adapted files are:

- `lib/easter_egg/still_alive_data.dart`
- `lib/easter_egg/still_alive_score.dart`

The original source credits personnel text to
<https://github.com/xBytez/aperturescience> and ASCII art to
<https://sites.google.com/site/gaddc11/Stillalive.rar?attredirects=0&d=1>.
Those upstream works may have separate terms.

The bundled `sa1.mp3`, the song recording, the lyrics, and Portal-related
names and artwork are separate copyrighted material. The GPL license of the
terminal-credit program does not grant rights to that recording or those works.
Do not publish a build containing them unless the applicable rights have been
obtained or the assets have been removed.

## MiSans

`assets/fonts/MiSans-*.ttf` contains MiSans by Xiaomi. It is governed by the
MiSans Fonts Intellectual Property License Agreement, not by this repository's
AGPL license:

<https://hyperos.mi.com/font/en/download/>

## Roboto Mono

`assets/fonts/RobotoMono-Regular.ttf` contains Roboto Mono, Copyright 2015 The
Roboto Mono Project Authors, used under the Apache License 2.0:

<https://github.com/googlefonts/RobotoMono>

## Twilight Echo crossfeed

The crossfeed algorithms and related settings are ported from the Twilight Echo
audio engine:

- `native/lazer-audio/src/dsp_chain.h`
- `native/lazer-audio/src/dsp_chain.cpp`
- `lib/state/hifi_settings.dart`
- `tool/native_hifi_check.dart`

Upstream project: <https://github.com/Px-asen/Twilight_Echo>
The component is used under Apache-2.0. A copy of that license is included at
`licenses/twilight_echo/Apache-2.0.txt`; retain the attribution and license
when distributing builds containing this code.

## Network source clients

The NAS, radio and podcast features use four pure-Dart packages. Their
licenses are retained in the packages themselves and are listed by Flutter's
own licence page:

- `dartssh2` (SFTP/SSH) — MIT, <https://github.com/TerminalStudio/dartssh2>
- `smb_connect` (SMB2) — Apache-2.0, <https://github.com/vadia/smb_connect>
- `xml` (DAV and RSS/Atom parsing) — MIT, <https://github.com/renggli/dart-xml>
- `pointycastle` (AES-GCM for stored credentials, and the crypto underneath the
  two protocol clients) — MIT (Bouncy Castle), <https://github.com/bcgit/pc-dart>

`smb_connect` declares the pointycastle 3.x line while `dartssh2` 4.x requires
4.x; the repository pins 4.x through `dependency_overrides` because the
pointycastle API surface both packages use is unchanged. Both copies would
otherwise be linked.

## FFmpeg

The DSD-capable FFmpeg builds produced by
`native/lazer-audio/tools/build_*_dsd_ffmpeg.sh` are configured under
LGPL-2.1-or-later for the profiles used by this project. The build scripts
stage `COPYING.LGPLv2.1` and exact build information under
`share/lazer-ffmpeg/`.

- Windows bundles the notice beside the native DLLs.
- Linux bundles it under `lib/licenses/lazer-ffmpeg/`.
- Android relink archives include the corresponding FFmpeg source, static
  archives, engine objects, and build profile.
- iOS static-link distributions must provide the corresponding FFmpeg source,
  license, and relinking materials alongside the final IPA or through an
  equivalent written offer.

FFmpeg source: <https://github.com/FFmpeg/FFmpeg>

## libmpv and its media libraries

Windows builds fetch `libmpv-2.dll` through
`media_kit_libs_windows_audio`; the Linux AppImage bundles a `libmpv.so`
discovered from the build host. mpv is GPLv2-or-later by default and can be
LGPLv2.1-or-later when built without GPL-only files. The exact license of a
binary depends on the upstream build profile and linked libraries, so the
binary's upstream license files and build configuration must accompany any
redistributed package.

- mpv license details: <https://github.com/mpv-player/mpv/blob/master/Copyright>
- Windows binary build: <https://github.com/media-kit/libmpv-win32-audio-build>
- Flutter wrapper: <https://github.com/media-kit/media-kit>

The MIT license of the Flutter wrapper does not relicense the downloaded
libmpv or FFmpeg binaries.

## mimalloc

`media_kit_libs_linux` downloads and statically links mimalloc 2.1.2 into the
Linux plugin. mimalloc is distributed under the MIT license:

<https://github.com/microsoft/mimalloc>

Its copyright and license notice must remain available in Linux distributions.

## libusb (optional Android UAC2 target)

The optional `LAZER_ANDROID_BUILD_UAC2` target fetches libusb at the pinned
revision in `native/lazer-audio/CMakeLists.txt`. libusb is LGPL-2.1-or-later:

<https://github.com/libusb/libusb>

This target is not part of the normal Android HiFi release path. If it is
enabled in a distributed build, include the libusb license and corresponding
source or source offer.

## Chart logos and external chart data

The chart-logo preparation script downloads and transforms logos from the
following sources:

- <https://biliboard.uk/logo_black.svg>
- <https://upload.wikimedia.org/wikipedia/commons/9/95/Billboard_logo.svg>
- <https://www.officialcharts.com/>
- <https://support.beatport.com/>
- <https://upload.wikimedia.org/wikipedia/commons/0/01/Oricon_Logo_2017.svg>
- <https://upload.wikimedia.org/wikipedia/commons/3/3c/Logo_NRJ_new.png>

These logos may be trademarks or copyrighted artwork. The source URLs do not
by themselves grant a redistribution license. Verify the applicable terms or
replace the assets before commercial or public distribution.

The generated Biliboard song metadata is collected from
<https://biliboard.uk/> and
<https://github.com/VincentZyuApps/billboard-data>. Preserve any upstream
database or content terms that apply to a redistribution.

## Dart, Flutter, and pub dependencies

Flutter emits the dependency notices used by the application in
`flutter_assets/NOTICES.Z`. That generated notice bundle covers the pub
packages, including the Flutter packages, `dbus` (MPL-2.0), Pointy Castle,
and the MIT/BSD/Apache-licensed packages in `pubspec.lock`. Those package
licenses remain separate from the Lazer license above.

## LuaDardo Plus

`third_party/lua_dardo_plus` vendors the published LuaDardo Plus 0.3.1 pure Dart
Lua VM under Apache-2.0. The full upstream license is retained at
`third_party/lua_dardo_plus/LICENSE`; local changes are listed in
`third_party/lua_dardo_plus/LAZER_PATCHES.md`.

Upstream: <https://gitlab.com/aa22396584/LuaDardo>.
