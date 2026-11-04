# Apple-style adaptive interface

The app ships one Apple Music-inspired interface across platforms. Desktop,
mobile, TV and watch layouts share a theme and motion vocabulary while adapting
their input, available space and density. Playback, catalogue, lyrics, queues
and comments use the same state and services. There is no separate old/new UI
selection or parallel theme factory.

## Design system

`buildAppleTheme` in `lib/theme/apple_design.dart` builds the app theme,
including dialogs and settings. `lib/ui/` contains the shared browse pages and
shell; `lib/player/` contains the adaptive player and desktop composition.

- **Semantic colours** — `AppleSemanticColors` provides `background`,
  `secondaryGroupedBackground`, `label`, `secondaryLabel`, `separator`,
  `fill`, `glass`, and the accent. Light and dark palettes are explicit, with no
  Material elevation tinting.
- **Accent** — Apple Music red `#FA2D48` is the default. When Settings →
  配色 is set to 跟随当前歌曲, the dominant cover colour is used as the accent;
  自定义 opens an HSV swatch picker that seeds the accent with the listener's
  own colour. Neutral surfaces remain stable either way.
- **Typography** — the HIG ramp (large title 34, title 20, body 17, footnote
  13, caption 11) with tight tracking and semibold display weights. Bundled
  MiSans is the default on every platform. Settings can select the system
  font or import an OTF/TTF face, and adjust text categories and lyrics.
- **Surfaces** — real grouped backgrounds, hairline separators, 8–20 pt
  corner radii, no drop shadows on lists, and subtle album shadows on artwork.
- **Motion** — shared duration/bounce springs in
  `lib/animation/apple_spring.dart`. Page, player, sheet and control movement
  retargets from its presented value and velocity when interrupted. Bounded
  properties such as colour and opacity use `AppleSpringCurve`; direct
  manipulation follows the pointer before a spring settles the release.
  Reduced motion removes decorative travel and stops ambient flow.

`lib/widgets/apple_ui.dart` holds the reusable primitives: large-title page
headers, section headers, grouped cards, list tiles, icon tiles, empty states,
capsule search fields, and `AppleGlass` (blur + semantic tint + hairline) for
navigation chrome and transient panels.

## Browse backdrop

Settings → 背景 picks how the browse shell paints its canvas: the flowing
album-colour mesh, a flat album tone, the listener's own picture, or none.
A custom picture is copied into the application support directory on import,
so the backdrop keeps working after the source file moves or is deleted.
With no backdrop, dark mode paints the deep warm `AppleColors.darkCanvas`
rather than pure black, so the window still reads as a surface. Fresh installs
default to `不使用` (no backdrop); the mode is stored once the listener picks
one.

The immersive player owns separately persisted background settings. Both browse
and player backgrounds support dynamic flow, a static frame, a solid colour or
a custom image. Frame rate and mesh precision are separate controls. Browsing
defaults to 30 fps; the player follows the display unless a manual rate is set.

## Adaptive layouts

### Desktop / large window

- 236 dp translucent source-list sidebar with a persistent search field,
  browse/likes/library destinations, synced playlists, settings and account.
- Transparent content toolbar with back navigation, search, appearance toggle
  and profile menu.
- Centred large-title content area capped at 1180 dp for readability.
- Full 84 dp transport with now-playing tile, centre transport controls, thin
  seek rail, volume popover and queue/comments actions.
- The immersive now-playing overlay follows the AMLL Player/Apple Music
  composition: a separately configured album-colour canvas, a
  large shadowed cover, metadata and actions on the left, a borderless lyric
  column on the right, and a dark Apple transport shelf. Queue and comments
  open as docked glass panels. Keyboard shortcuts (Space, arrows, M, L, Q, C,
  F, Esc) remain.

### Phone / compact window

- 50 dp inline navigation bar, collapsible search, large page titles and the
  iOS tab bar (`主页 / 音乐库 / 我喜欢 / 设置`).
- 60 dp translucent mini-player above the tab bar; tapping it opens the
  immersive player.
- Content is inset at 16 dp with edge-to-edge artwork where appropriate.
  Settings uses a single-column grouped list.
- The now-playing overlay is portrait/landscape adaptive: a borderless lyric
  column floats directly on the blurred artwork, with a cover view toggle,
  glass bottom transport and bottom-sheet queue/comments. The landscape split
  keeps a compact information card beside the lyrics. Queue and comment
  controls stay reachable at every height.
- Login is an Apple-sheet card with QR sign-in and a Cookie escape hatch.

### 大屏幕模式 (television)

Android TV gets its own composition rather than the desktop shell at ten feet.
`设置 → 界面 → 设备形态` can force `大屏幕模式`; otherwise a Leanback or
touch-less Android device selects it automatically and boots into it. The
large-screen mode draws a floating destination capsule, shelves of captioned
artwork (为你打造 and 排行榜 reuse the desktop/mobile cards), a rail-and-grid
library and a rounded transport card that floats over the page, keeps the
standard interface scale, insets chrome for overscan, and turns every card,
row and transport glyph into a D-pad focus stop with a white-on-black focus
ring. Settings rows wash and ring around whichever Material control the remote
is on.
Directional traversal follows the card geometry and bumps a shelf or page when
the next card has not been built yet. Back closes the queue or volume panel
first, then the player, then detail pages. See
[android-tv.md](android-tv.md) for the manifest, detection, layout and
navigation details.

Breakpoints: mobile below 720 dp, immersive desktop player from 840 dp,
compact desktop transport below 1000 dp. Settings and artwork grids reflow
independently of those thresholds.

## Pages

| Page | Apple composition |
| --- | --- |
| 现在就听 | Large title, edge-to-edge featured playlist hero, horizontal recommendation shelf, grouped quick-pick track rows |
| 资料库 | Large title, owned playlists, recommendation grid with 2–6 adaptive columns |
| 我喜欢 | Playlist hero and grouped track list, guest sign-in state; the shared playlist page's floating locate-current button |
| 歌单详情 | Album-style hero, metadata and play/shuffle controls, grouped track list, floating locate-current-track button |
| 搜索 | Capsule search field, artist/search result sections, track rows and playlist grid |
| 设置 | iOS inset grouped cards: interface, appearance, playback, interaction, lyrics, scrolling, performance, account, about |
| 登录 | Apple sheet card, QR code, status messaging, Cookie mode |
| 正在播放 | AMLL/Apple Music-style blurred-artwork canvas, large cover, borderless animated lyrics, adaptive transport; shared lyric engine |

## Preserved functionality

Everything above the pixels remains shared with the existing app:

- `AppState`, NetEase gateway, catalogue cache, artwork loading, playback,
  queueing, likes, comments and lyrics.
- The shared `LyricViewport` with word-level sweep, selection, copy and image
  export, plus all persisted lyric preferences.
- Queue (`PlaybackQueueView`) and comments (`SongCommentsView`) are reused in
  modal glass panels/sheets rather than forked.
- DPI scaling, car-display mode, the large-screen profile, safe areas,
  window frame, system media integration and localisation continue to work.

## Settings and persistence

Settings exposes accent,
device profile, layout mode, DPI scale (manual + automatic), album backdrop,
content opacity and dynamic-background render precision, theme, language,
independent playback, haptics, lyric timing, size, weight, blur, follow
delay, scroll inertia/acceleration, frame overlay, account and catalogue
refresh. Existing preferences migrate in place. Daily scheduled pauses are
single time points, with a master switch and individual switches; previous
ranges migrate to their start times. See [scheduled-pause.md](scheduled-pause.md).

## Performance

The redesign keeps the existing performance constraints:

- `CustomPaint` album flow, no per-frame widget transforms in the background.
  Its render precision changes mesh density independently of frame rate.
  Static and hidden backgrounds stop continuous ticking; settled palettes
  reuse their processed colours.
- Lyric rows repaint on the playback tick lane only; inactive rows stay cached.
- Track lists use `SliverList.builder` where they can grow.
- Artwork requests the smallest CDN rendition covering its painted size.
- Blur is limited to navigation chrome and overlays; content surfaces are
  opaque/semantically filled so text contrast does not depend on artwork.
- Shell rebuilds remain structural only; transport/seek widgets own the
  100 ms tick lane.

### Switching pages

Two pages can be visible during navigation while the incoming one builds for
the first time. The retained switcher owns the shared spring and lets the shell
stand down ambient work for the actual transition:

- the album mesh is parked under a `TickerMode` for the length of the switch;
- playback, download and lyric reports that arrive mid-switch are held back and
  folded into the single rebuild that ends the switch. Rebuilding the incoming
  page ten times a second while it fades is what makes the animation stutter;
  nothing is lost, because that rebuild reads the newest state;
- a state report that arrives outside a switch still rebuilds the shell exactly
  as before, so pages keep following playback while nothing is animating;
- `AppleGlass` bounds backdrop blur for both square chrome and rounded panels,
  so it cannot filter the
  whole window. Nearly opaque materials skip the invisible blur pass.

Playlist cover flights use a separate overlay ticker, retain the visible
source composition and hand off to the detail artwork without exposing a
placeholder frame. Back can interrupt an entrance, and another destination can
retarget a moving flight. Navigation ancestors retain their state and scroll
position but do not keep hidden tickers running.

Playlist names and count lines share the cover flight's clock. Their measured
card/header bounds and text styles interpolate in both directions; faster
movement lightens the weight by up to 120 before returning to the configured
weight at rest. Interrupted flights preserve text position and velocity.
Scrolling after Back immediately returns the cover and text to the live card.

## Verification

`flutter analyze` and the full widget/unit suite cover the desktop layout at
800–1920 px, compact layout down to 320 px, the Apple player theme, lyric
interaction, queue/comments sheets, sign-in and persistence.
