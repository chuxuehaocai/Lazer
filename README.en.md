<p align="center">
  <img src="docs/images/mascot.png" width="220" alt="The Lazer mascot">
</p>

<h1 align="center">Lazer</h1>

<h3 align="center">
  Community: <a href="https://qm.qq.com/q/FR8H7OzrCQ">Join the Take lazer QQ group · 1137280545</a>
</h3>

<p align="center">
  <a href="https://qm.qq.com/q/FR8H7OzrCQ"><img alt="QQ group: 1137280545" src="https://img.shields.io/badge/QQ%E7%BE%A4-1137280545-12B7F5?style=for-the-badge&logo=tencentqq&logoColor=white"></a>
</p>

<p align="center">
  <a href="https://github.com/chuxuehaocai/Lazer/actions/workflows/build.yml"><img alt="build" src="https://img.shields.io/badge/build-GitHub%20Actions-6C8EBF"></a>
  <img alt="Flutter" src="https://img.shields.io/badge/Flutter-3.47.0-54C5F8?logo=flutter&logoColor=white">
  <img alt="version" src="https://img.shields.io/badge/Lazer-v2.0.300-8E7CC3">
  <img alt="platforms" src="https://img.shields.io/badge/Windows%20%C2%B7%20macOS%20%C2%B7%20Linux%20%C2%B7%20Android%20%C2%B7%20iOS-7FB6A4">
  <img alt="web demo" src="https://img.shields.io/badge/Web%20Demo-Vercel-000000">
  <a href="https://lazer.naominet.dev/docs"><img alt="Lua plugin docs" src="https://img.shields.io/badge/Lua%20plugin%20docs-lazer.naominet.dev%2Fdocs-F04450"></a>
  <a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-AGPL--3.0--or--later-4C9A7A"></a>
</p>

<p align="center">
  <b>A NetEase Cloud Music client written by hand in Flutter.</b><br>
  WEAPI / EAPI live inside the app with no third-party gateway;<br>
  the catalogue, lyrics, comments and daily picks come straight from the service.
</p>

<p align="center"><a href="README.md">简体中文</a> | English</p>

## What it does

**Listening**

- A real catalogue, search, recommended playlists, personal radar, accounts and favourites.
- Artist pages with popular tracks and paged albums; album pages carry the description and the full track list — tap a name and you are there.
- Saved albums get their own page in the library: a cover wall that pages as you scroll, filtered by album or artist so the record you feel like hearing is a keystroke away.
- Popular and latest comments with pagination, likes and unlikes. Guests can read; sign in to react.
- Network sources: WebDAV, SMB, SFTP and FTP reach the NAS directly — browse it, play a folder, scan it into the library. Internet radio and RSS podcast subscriptions live on the same page, and podcasts remember where each episode stopped.
- System media controls on Windows, macOS, Linux, Android and iOS; the notification, lock screen and Dynamic Island carry the line being sung.

**Lyrics**

- LRC / YRC parsing, per-grapheme emphasized springs, a 35% focus band, progressive masks and distance blur.
- Font size and weight adjust with a live preview; copy several lines or export them as a PNG.
- Lyrics follow the music, and glide back to following after you scroll away by hand.
- Desktop lyrics: on Windows the lyrics live in explorer's desktop layer (above the wallpaper,
  below normal windows, click-through); every desktop also gets a draggable floating lyric window.
  Three lines by default, configurable from one to five, rendered by the same spring engine.
- The desktop lyric's left handle drags it and remembers the position; playback progress syncs
  every 50 ms, and interludes show breathing dots.

**Interface**

- One Apple-style interface, theme and spring-motion system across platforms: semantic colours and type, translucent navigation, grouped lists and tints pulled from the cover art.
- Desktop gets a sidebar and the full transport; phones get a tab bar and a mini-player, over the same page tree and state.
- Layout override (desktop / mobile), DPI 80–175%, and a car head-unit profile that starts at 135%.
- Large screen mode: TVs and projectors start in it, and the D-pad moves by position across shelves, the library grid and the transport.
- Simplified Chinese, Traditional Chinese, Japanese and English.

**Detail**

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

## Write a plugin

Lazer ships without a streaming gateway: which platform you listen to is decided by a Lua plugin. The full contract lives at **[lazer.naominet.dev/docs](https://lazer.naominet.dev/docs)** — manifest fields, the `call()` operation table, the `host.*` API, the permission model, and how a release reaches the market. Installing plugins and browsing what others built is at [lazer.naominet.dev/plugin](https://lazer.naominet.dev/plugin).

## Build it yourself

Use **Flutter 3.47.0 stable**.

`lua_dardo_plus` is fetched from pub.dev. Run the patch script after resolving dependencies to keep Lua plugin async calls working:

```sh
flutter pub get
dart tool/patch_lua_dardo_plus.dart
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
dart tool/patch_lua_dardo_plus.dart
flutter build web --release --no-web-resources-cdn

# 2. Pack and verify the static site and same-origin /api/plugin-http function
node ci/vercel-web/prepare-output.js
node ci/vercel-web/verify-output.js

# 3. Deploy with the Vercel CLI
export VERCEL_ORG_ID=team_38TeUJcXlno06LvmAuureTRh
export VERCEL_PROJECT_ID=prj_4G5sAItdYPHxXo6DX0Dfjy2bvr7v
vercel deploy --prebuilt --prod
```

On a fresh account, create the project and disable SSO protection first; otherwise the public domain shows a login wall:

```sh
vercel project create lazer_demo --non-interactive
vercel project protection disable lazer_demo --sso --yes
```

Notes:

- Both local deployments and CI use this repository's packer and `ci/vercel-web/api/`. CanvasKit, entrypoint, fonts and other assets have separate content hashes and one-year immutable caching. HTML revalidates, the bootstrap is inline, and fonts load in parallel with the entrypoint. Updating translations or images does not invalidate engine or font caches.
- Web MiSans subsets cover GB2312, Big5 level 1, JIS level 1 and UI strings. Vercel serves WOFF2: approximately 5.25 MB for all four weights, down from 9.79 MB of TTF. Install `fonttools` and `brotli`, then run `python tool/subset_web_fonts.py` to regenerate both formats. Native builds keep full fonts. Startup resources are same-origin, without a Google font/engine CDN dependency.
- The HTTP bridge runs in Hong Kong (`hkg1`) to stay close to mainland music services. Requests have a deadline and bounded payloads; responses are never cached. Cross-border connectivity still affects mainland loading, and Vercel has no mainland compute region.
- Web Settings → Network proxy → Web client IP saves a separate country/region, defaulting to mainland China. The other 15 choices cover all 19 Vercel compute regions and apply to the next plugin request. This selects synthetic `X-Real-IP` / `X-Forwarded-For` headers for upstreams that honor them; **it does not change the real network exit or allocate a dedicated IP**. CN retains the api-enhanced ranges; other choices use an attributed RIR registration snapshot, which may differ from an upstream's GeoIP database. Real mainland egress requires a separate mainland proxy. [Vercel regions](https://vercel.com/docs/regions) · [Outbound IPs](https://vercel.com/docs/networking/static-ips)
- `api/plugin-http.js` accepts only HTTPS hosts declared by the calling plugin manifest and rejects loopback, private, link-local and metadata addresses. Browsers and plugins cannot override its generated client-IP headers. Regenerate the non-CN snapshot with `node ci/vercel-web/update-forwarded-ip-ranges.js`.
- Uploaded Lua is untrusted. A production deployment should still keep a domain allowlist, rate limits, and redacted logs.

## Automated builds

Pushes to `nextgen` trigger [GitHub Actions](https://github.com/chuxuehaocai/Lazer/actions/workflows/build.yml).
Checks run before platform builds. Pushing a `v*` version tag creates a GitHub
Release after every build succeeds; tags with a suffix such as `-beta.1` are
marked as pre-releases. Output filenames follow `Lazer-<OS>-<Arch>`.

| Output | Contents |
| --- | --- |
| `Lazer-Windows-x86_64.zip` | EXE, DLLs, resources and Visual C++ runtime |
| `Lazer-macOS-aarch64.zip` | Apple Silicon App |
| `Lazer-Linux-x86_64.AppImage` | Linux x86_64, including GTK and libmpv |
| `Lazer-Linux-aarch64.AppImage` | Linux ARM64 built on a native ARM runner |
| `Lazer-Android-universal.apk` | Universal APK signed with the release key from repository secrets (see [build details](docs/builds.md#android-release-signing)) |
| `Lazer-iOS-aarch64.ipa` | Unsigned device IPA |

Download from a completed run's **Artifacts** section while signed in to GitHub;
artifacts are retained for 30 days. Extract the complete Windows ZIP before
launching its EXE, run `chmod +x` on a downloaded AppImage, and note that macOS
Apps are ad-hoc signed while the IPA needs your own signing.

More documentation: [build details](docs/builds.md) · [system media](docs/system-media.md) · [now playing](docs/now-playing.md) · [scheduled pause](docs/scheduled-pause.md) · [car head unit](docs/car-head-unit.md) · [large screen mode (Android TV)](docs/android-tv.md) · [plugin development](https://lazer.naominet.dev/docs) ([runtime notes](docs/lua-plugins.md)) · [QR sign-in](docs/login-qr.md) · [SMS sign-in](docs/login-sms.md) · [password sign-in](docs/login-password.md) · [unified interface](docs/ui.md) · [network sources](docs/network-sources.md) · [third-party notices](THIRD-PARTY-NOTICES.md)

## References and thanks

- ESP32 port: [Lazer for ESP](https://github.com/sanmingsaxian/lazer-for-esp).
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
