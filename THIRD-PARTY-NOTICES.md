# Third-party notices

Lazer as a whole is licensed under the GNU Affero General Public License,
version 3 or later (see [LICENSE](LICENSE)). The components listed below keep
their own licences and are used under those terms; where this repository does
not state a licence, follow the upstream project.

| Component | Licence | Where it appears | Upstream |
| --- | --- | --- | --- |
| Apple Music Like Lyrics (amll-dev) | AGPL-3.0-or-later | Dart lyric-animation ports `lib/lyrics/viewport.dart`, `lib/lyrics/spring.dart`, `lib/lyrics/word_motion.dart`, `lib/lyrics/timed_line.dart` (each carries an `SPDX-License-Identifier: AGPL-3.0-or-later` header); the attribution and full licence copy stay at `licenses/lyric_animation/AGPL-3.0.txt` | https://github.com/amll-dev/applemusic-like-lyrics |
| LHF (BD4SUP) "Still Alive" terminal credits | GPL-3.0-or-later | `lib/easter_egg/still_alive_score.dart`, `lib/easter_egg/still_alive_data.dart`; licence text bundled at `assets/easter_eggs/still_alive/GPL-3.0.txt` | LHF (BD4SUP), "PORTAL--STILL ALIVE demo", September 2021, as named in the comment in `lib/main.dart` and in `assets/easter_eggs/still_alive/SOURCE.md`; no canonical URL is recorded in this repository |
| MiSans (Xiaomi) | MiSans Fonts Intellectual Property License Agreement | `assets/fonts/MiSans-*.ttf` | https://hyperos.mi.com/font/en/download/ |
| Twilight Echo crossfeed stage | Apache-2.0 | the crossfeed stage added to `native/lazer-audio/`, documented in `docs/audio-engine.md` | the Twilight Echo audio engine, cited in `native/lazer-audio/src/dsp_chain.h` as `audio-engine/dsp/CrossfeedProcessor.cpp`; no repository URL is stated, see upstream |
| FFmpeg (DSD-capable LGPL build) | LGPL-2.1-or-later | built by `native/lazer-audio/tools/build_dsd_ffmpeg.sh`, which stages `COPYING.LGPLv2.1` and `BUILDINFO.txt` under `share/lazer-ffmpeg/` in the SDK; `.github/workflows/build.yml` ships them at `licenses/lazer-ffmpeg/` on Windows, `lib/licenses/lazer-ffmpeg/` in the Linux AppImage and `Contents/Resources/licenses/lazer-ffmpeg/` on macOS, and `ci/build-android-audio.sh` copies them to `android/app/src/main/assets/licenses/lazer-ffmpeg/<abi>/` on Android | https://ffmpeg.org/ |
| libmpv | see upstream | bundled into the Linux AppImage by `ci/package-appimage.sh`, which takes the system `libmpv.so.1`/`.so.2` found through `ldconfig`; the script states no licence for it | see upstream |

Project licence text: see [LICENSE](LICENSE).
