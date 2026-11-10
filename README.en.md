<p align="center">
  <img src="docs/images/mascot.png" width="220" alt="The Lazer mascot">
</p>

<h1 align="center">Lazer</h1>

<h3 align="center">
  Community: <a href="https://qm.qq.com/q/JJJfE0QV00">神秘交流群 (QQ group) · 1063238023</a>
</h3>

<p align="center">
  <a href="https://qm.qq.com/q/JJJfE0QV00"><img alt="QQ group: 1063238023" src="https://img.shields.io/badge/QQ%E7%BE%A4-1063238023-12B7F5?style=for-the-badge&logo=tencentqq&logoColor=white"></a>
</p>

<p align="center">
  <a href="https://github.com/chuxuehaocai/Lazer/actions/workflows/build.yml"><img alt="build" src="https://img.shields.io/badge/build-GitHub%20Actions-6C8EBF"></a>
  <img alt="Flutter" src="https://img.shields.io/badge/Flutter-3.47.0-54C5F8?logo=flutter&logoColor=white">
  <img alt="version" src="https://img.shields.io/badge/Lazer-v2.0.0-8E7CC3">
  <img alt="platforms" src="https://img.shields.io/badge/Windows%20%C2%B7%20macOS%20%C2%B7%20Linux%20%C2%B7%20Android%20%C2%B7%20iOS-7FB6A4">
  <img alt="web demo" src="https://img.shields.io/badge/Web%20Demo-Vercel-000000">
  <a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-AGPL--3.0--or--later-4C9A7A"></a>
</p>

<p align="center">
  <b>A NetEase Cloud Music client written by hand in Flutter.</b><br>
  WEAPI / EAPI live inside the app — no third-party gateway —<br>
  and the catalogue, lyrics, comments and daily picks come straight from the service.
</p>

<p align="center"><a href="README.md">简体中文</a> | English</p>

## What it does

**The listening part**

- A real catalogue, search, recommended playlists, personal radar, accounts and favourites.
- Artist pages with popular tracks and paged albums; album pages carry the description and the full track list — tap a name and you are there.
- Saved albums get their own page in the library: a cover wall that pages as you scroll, filtered by album or artist so the record you feel like hearing is a keystroke away.
- Popular and latest comments with pagination, likes and unlikes. Guests can read; sign in to react.
- Network sources: WebDAV, SMB, SFTP and FTP reach the NAS directly — browse it, play a folder, scan it into the library. Internet radio and RSS podcast subscriptions live on the same page, and podcasts remember where each episode stopped.
- System media controls on Windows, macOS, Linux, Android and iOS; the notification, lock screen and Dynamic Island carry the line being sung.

**The lyric part**

- LRC / YRC parsing, per-grapheme emphasized springs, a 35% focus band, progressive masks and distance blur.
- Font size and weight adjust with a live preview; copy several lines or export them as a PNG.
- Lyrics follow the music, and glide back to following after you scroll away by hand.
- Desktop lyrics: on Windows the lyrics live in explorer's desktop layer (above the wallpaper,
  below normal windows, click-through); every desktop also gets a draggable floating lyric window.
  Three lines by default, configurable from one to five, rendered by the same spring engine.
- The desktop lyric's left handle drags it and remembers the position; playback progress syncs
  every 50 ms, and interludes show breathing dots.

**The interface part**

- One Apple-style interface, theme and spring-motion system across platforms: semantic colours and type, translucent navigation, grouped lists and tints pulled from the cover art.
- Desktop gets a sidebar and the full transport; phones get a tab bar and a mini-player — one page tree and one state, just a different posture.
- Layout override (desktop / mobile), DPI 80–175%, and a car head-unit profile that starts at 135%.
- Large screen mode: TVs and projectors start in it, and the D-pad moves by position across shelves, the library grid and the transport.
- Simplified Chinese, Traditional Chinese, Japanese and English.

**The fussy part**

- Adjustable scroll inertia and acceleration; haptic detents on the seek bar.
- An uncached song gathers ten seconds of stream before it starts, so the opening bars no longer stutter; downloaded and cached tracks still start instantly.
- Pages, dialogs and controls use interruptible springs. Drags track the pointer directly, release preserves the current velocity, and reduced motion is supported.
- Browse backgrounds default to 30 fps; the player follows the display refresh rate. Frame rate and mesh precision are separate settings, and hidden pages and static backgrounds stop continuous drawing. Settings can show a live frame-time overlay.
- The now-playing page brings an AMLL mesh backdrop, cover/lyrics switching, queue and comment panels, and the M / L / Q / C / F shortcuts.
- Scheduled pause supports multiple repeating daily times. Each time pauses once, preserves the queue and position, and allows an immediate manual resume.

## A look at it

<table>
  <tr>
    <td align="center" width="50%"><img src="docs/images/shot-home.jpg" width="100%" alt="Home"></td>
    <td align="center" width="50%"><img src="docs/images/shot-library.jpg" width="100%" alt="Library"></td>
  </tr>
  <tr>
    <td align="center"><b>Listen now</b><br><sub>Recommended playlists, personal radar and daily picks, right on the first screen.</sub></td>
    <td align="center"><b>A real library</b><br><sub>Search, artists, albums and favourites, all read from the service itself.</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/images/shot-playing.jpg" width="100%" alt="Now playing"></td>
    <td align="center"><img src="docs/images/shot-adaptive.jpg" width="100%" alt="Adaptive layout"></td>
  </tr>
  <tr>
    <td align="center"><b>Immersive playback</b><br><sub>AMLL word-by-word lyrics, a 35% focus band and spring-follow scrolling.</sub></td>
    <td align="center"><b>One set of pages</b><br><sub>A desktop sidebar and a mobile tab bar sharing the same pages and state.</sub></td>
  </tr>
</table>

## A tidy little cache

Playback caching keeps up to 50 completed songs by default, with a configurable limit. Recent mode evicts the songs not played for the longest time; smart mode favours songs heard more often in the last 30 days. Manually downloaded and imported files are retained. Artwork and catalogue caches have their own bounds, and a failed network request can fall back to an earlier snapshot. Fully cached tracks play locally while new streams cache in the background.

## Build it yourself

Use **Flutter 3.47.0 stable**.

```sh
flutter pub get
flutter analyze
flutter test
flutter run
```

### Web build and Vercel deployment

The web build is compiled from this repository's `lib/main.dart` and shares the same Dart UI, plugin runtime and state layer as the desktop and mobile apps. The deployed site is [player.naominet.dev](https://player.naominet.dev).

> Mainland China: Flutter Web loads CanvasKit from `www.gstatic.com` by default, which is unreachable there and leaves the page stuck on the loading screen. Always build with `--no-web-resources-cdn` so CanvasKit ships inside `build/web/canvaskit/`.

```sh
# 1. Build the static site in this repository
flutter pub get
flutter build web --release --no-web-resources-cdn

# 2. Pack the Vercel Build Output with the lazer_demo wrapper
#    (it provides the same-origin /api/plugin-http function)
cd ../lazer_ncm/lazer_demo
node tool/prepare-vercel-output.js

# 3. Deploy with the Vercel CLI
vercel deploy --prebuilt --prod --project lazer_demo
```

On a fresh account, create the project and disable SSO protection first; otherwise the public domain shows a login wall:

```sh
vercel project create lazer_demo --non-interactive
vercel project protection disable lazer_demo --sso --yes
```

Notes:

- The static output comes from this repository's `build/web`; `lazer_demo` only holds the Vercel Function and packing script. The packer content-hashes the CanvasKit directory and `main.dart.js` and serves them with an immutable cache, so return visits do not download those megabytes again.
- The packer also replaces the full MiSans files with the subsets in `web/assets/assets/fonts/` (about 2.3 MB per weight, covering GB2312, Big5 level 1, JIS level 1 and the UI strings; the full files are about 8 MB per weight). Flutter copies the `web/` overlay over the generated bundle last, so a plain `flutter build web` ships them too; rerun `python tool/subset_web_fonts.py` to rebuild them. Native builds keep the full fonts.
- `api/plugin-http.js` only accepts HTTPS hosts declared by the calling plugin manifest and rejects loopback, private, link-local and metadata addresses. Forwarded requests carry `X-Real-IP` / `X-Forwarded-For` generated from api-enhanced's mainland China ranges; browsers cannot override those headers.
- Uploaded Lua is untrusted. A production deployment should still keep a domain allowlist, rate limits, and redacted logs.

## Automated builds

Pushes to `nextgen` trigger [GitHub Actions](https://github.com/chuxuehaocai/Lazer/actions/workflows/build.yml).
Checks run before platform builds. Pushing a `v*` version tag creates a GitHub
Release after every build succeeds; tags with a suffix such as `-beta.1` are
marked as pre-releases. Output filenames follow `Lazer-<OS>-<Arch>`.

| Output | Contents |
| --- | --- |
| `Lazer-Windows-x86_64.zip` | EXE, DLLs, resources and Visual C++ runtime |
| `Lazer-macOS-universal.zip` | Universal Intel / Apple Silicon App |
| `Lazer-macOS-x86_64.zip` | Intel App built on a native Intel runner |
| `Lazer-Linux-x86_64.AppImage` | Linux x86_64, including GTK and libmpv |
| `Lazer-Linux-aarch64.AppImage` | Linux ARM64 built on a native ARM runner |
| `Lazer-Android-universal.apk` | Universal APK signed with the release key from repository secrets (see [build details](docs/builds.md#android-release-signing)) |
| `Lazer-iOS-aarch64.ipa` | Unsigned device IPA |

Download from a completed run's **Artifacts** section while signed in to GitHub;
artifacts are retained for 30 days. Extract the complete Windows ZIP before
launching its EXE, run `chmod +x` on a downloaded AppImage, and note that macOS
Apps are ad-hoc signed while the IPA needs your own signing.

More documentation: [build details](docs/builds.md) · [system media](docs/system-media.md) · [now playing](docs/now-playing.md) · [scheduled pause](docs/scheduled-pause.md) · [car head unit](docs/car-head-unit.md) · [large screen mode (Android TV)](docs/android-tv.md) · [QR sign-in](docs/login-qr.md) · [SMS sign-in](docs/login-sms.md) · [password sign-in](docs/login-password.md) · [unified interface](docs/ui.md) · [network sources](docs/network-sources.md) · [third-party notices](THIRD-PARTY-NOTICES.md)

## References and thanks

- The protocol implementation references [API Enhanced](https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced).
- The now-playing composition references [AMLL Player](https://github.com/amll-dev/amll-player).
- Lyric animation references [Apple Music Like Lyrics](https://github.com/amll-dev/applemusic-like-lyrics).
- The interface uses **MiSans** by Xiaomi. Thank you, MiSans.
- And you, reading this: downloading it and finishing one song is already plenty.

<p align="center">
  <img src="docs/images/mark.png" width="44" alt="Lazer">
  <br>
  <sub>AGPL-3.0-or-later · see THIRD-PARTY-NOTICES.md for separate components and assets</sub>
</p>
