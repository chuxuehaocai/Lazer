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
  <img alt="platforms" src="https://img.shields.io/badge/Windows%20%C2%B7%20Linux%20%C2%B7%20Android-7FB6A4">
  <a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-AGPL--3.0-4C9A7A"></a>
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
- Popular and latest comments with pagination, likes and unlikes. Guests can read; sign in to react.
- System media controls on Windows, Linux and Android; the notification and lock screen carry the line being sung.

**The lyric part**

- LRC / YRC parsing, per-grapheme emphasized springs, a 35% focus band, progressive masks and distance blur.
- Font size and weight adjust with a live preview; copy several lines or export them as a PNG.
- Lyrics follow the music, and glide back to following after you scroll away by hand.

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

## Automated builds

Pushes to `nextgen` trigger [GitHub Actions](https://github.com/chuxuehaocai/Lazer/actions/workflows/build.yml).
Checks run before platform builds. Pushing a `v*` version tag creates a GitHub
Release after every build succeeds; tags with a suffix such as `-beta.1` are
marked as pre-releases. Output filenames follow `Lazer-<OS>-<Arch>`.

| Output | Contents |
| --- | --- |
| `Lazer-Windows-x86_64.zip` | EXE, DLLs, resources and Visual C++ runtime |
| `Lazer-Linux-x86_64.AppImage` | Linux x86_64, including GTK and libmpv |
| `Lazer-Linux-aarch64.AppImage` | Linux ARM64 built on a native ARM runner |
| `Lazer-Android-universal.apk` | Universal APK signed with the release key from repository secrets (see [build details](docs/builds.md#android-release-signing)) |

Download from a completed run's **Artifacts** section while signed in to GitHub;
artifacts are retained for 30 days. Extract the complete Windows ZIP before
launching its EXE, and run `chmod +x` on a downloaded AppImage.

More documentation: [build details](docs/builds.md) · [system media](docs/system-media.md) · [now playing](docs/now-playing.md) · [scheduled pause](docs/scheduled-pause.md) · [car head unit](docs/car-head-unit.md) · [large screen mode (Android TV)](docs/android-tv.md) · [QR sign-in](docs/login-qr.md) · [SMS sign-in](docs/login-sms.md) · [unified interface](docs/ui.md)

## References and thanks

- The protocol implementation references [API Enhanced](https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced).
- The now-playing composition references [AMLL Player](https://github.com/amll-dev/amll-player).
- Lyric animation references [Apple Music Like Lyrics](https://github.com/amll-dev/applemusic-like-lyrics).
- Third-party components and their licences: [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
- The interface uses **MiSans** by Xiaomi. Thank you, MiSans.
- And you, reading this: downloading it and finishing one song is already plenty.

<p align="center">
  <img src="docs/images/mark.png" width="44" alt="Lazer">
  <br>
  <sub>AGPL-3.0 License · made with Flutter and a little patience</sub>
</p>
