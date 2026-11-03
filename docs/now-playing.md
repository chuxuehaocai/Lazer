# Now playing and lyric engine

The player uses one adaptive entry point on every platform. Desktop, phone and
television presentations share playback state, lyrics, artwork, queue and
comment services; each layout adapts the same controls to its available space.
The browse shell and settings live in `lib/ui/` and use `buildAppleTheme` from
`lib/theme/apple_design.dart`. There is no separate old/new player wrapper.

## Player modules

| Module | Responsibility |
| --- | --- |
| `lib/player/now_playing_page.dart` | Adaptive page, artwork, lyrics, transport, queue and comments |
| `lib/player/desktop_now_playing.dart` | Desktop split composition and collapsible transport dock |
| `lib/player/artwork_lyrics_layout.dart` | Compact portrait/landscape artwork, lyrics and metadata layout |
| `lib/player/now_playing_route.dart` | Standalone player presentation and pull-down dismissal |
| `lib/player/player_page_motion.dart` | Finite desktop page slides and shared presentation policy |
| `lib/player/player_backdrop.dart` | Separately configured player background and album-colour vignette |
| `lib/animation/apple_spring.dart` | Shared duration/bounce springs and bounded spring curve |

The desktop composition is an artwork-led split view with a borderless lyric
canvas. The phone composition keeps artwork and lyrics in one adaptive layout;
queue and comments use the shared panels/sheets. The desktop header's download
action opens the shared quality and destination dialog, shows active progress
and opens the download queue after a track is queued or saved. Local files keep
that action disabled.

On desktop, clicking reveals the auto-hidden transport dock. Mouse movement,
window re-entry and scrolling do not reveal it or extend its idle timer.
Keyboard input does not wake the dock; media shortcuts still work while it is
hidden. Holding a pointer during a seek keeps the controls visible until release.
Television remotes retain their key-driven wake behavior.

Opening the player reads an already decoded artwork palette synchronously for
its first frame. If extraction is still running, its result invalidates the
entrance snapshot immediately, so the visible background updates during the
slide. Generation checks prevent an older track's extraction from replacing
the current background.

## Lyric motion and layout

The lyric canvas follows the AMLL/Apple Music reading rhythm:

- Focus band sits at 35% of the available height, matching the reference
  `LyricViewport` rather than centering every line in the middle of the screen.
- Rows measure their real wrapped text height and share the Apple lyric gutter.
  The translation is held as a smaller secondary row directly underneath.
  Line positions therefore follow the reference implementation instead of a
  fixed `itemExtent`.
- The active line reaches 100% scale while every inactive line settles to the
  reference 97%. Scale is a real `mass=2, stiffness=100, damping=25` spring per
  line, with the AMLL `lyricStaggerDelays` schedule applied around the focus.
  The focus row itself starts on the activation frame, so its upward float
  begins with the brightness/blur change instead of trailing it by a stagger
  step.
- Scroll following ports AMLL's `getPosYSpringPolicy`: normal playback uses
  interval-dependent stiffness/damping, seeks use the slow pair, rapid
  delivery stays responsive, and the end of the song uses the medium pair.
  Retargeting preserves spring velocity instead of restarting a duration
  animation.
- The render range follows AMLL exactly: rows are prebuilt inside a motion
  buffer equal to 40% of the viewport plus a small overscan, while visibility
  is driven by spring positions and the `LineBrightness` active window.
- `LyricEdgeFade` is restored as a final viewport mask: it dissolves the
  raster at the top and bottom, plus the left/right in compact mode. It is a
  visual mask only and does not replace AMLL's bright/dim line transition.
- Blur is derived from each row's live spring position: the row centre's
  distance from the 35% focus band, divided by the average row height, scaled
  by `1.55` and capped at the reference 5 px filter. Because it reads the same
  spring that drives the upward float, a row sharpens exactly as it arrives
  instead of clearing ahead of the motion. Manual browsing fades the whole
  mask through its own gate.
- Word rendering ports both AMLL Web Animations. Every word, including short
  syllables that AMLL treats as ordinary, runs the long emphasis float with
  its scale and x spread; there is no bare vertical-translation fallback. The
  white blurred glow stays reserved for AMLL's emphasized subset (long
  syllables / short words), so ordinary words float without lighting up and
  settle at the float target instead of rising past it and dropping back.
  Scale, x/y float, the `empEasing` two-bezier envelope, the 32-frame glow
  table and the last-word intensity multiplier all match the reference. Glow
  is drawn per grapheme from the character's `motion.glow` and
  `motion.glowRadiusEm`, not as one fixed line-wide shadow. The karaoke sweep
  is a soft half-glyph-height gradient, completed words paint directly into a
  clip (no per-glyph `saveLayer`), and word repaints are pumped once per vsync
  by a `Ticker`. There is no longer a 5 ms follow timer: the ticker drives
  follow while playing and the 100 ms transport lane catches everything else.
- `LineBrightness` is ported as a real two-layer line: an unmasked dim clone
  at 0.2 opacity plus the bright animated layer. Activation cross-fades over
  300 ms and deactivation over 450 ms, both ease-out, matching
  `.lyricMainLineBright` / `.lyricMainLineDim` and `.gradientMask`. The
  translation follows `.lyricSubLine` at 0.3 opacity.
- Manual drag/wheel browsing fades blur to zero, keeps momentum, and resumes
  following after the configured timeout. Movement is clamped to the
  first/last lyric focus bounds, so it cannot expose empty lyric space above
  the first line or below the last one. Blur is calculated from distance to
  the focus band, not from line index alone.
- Inactive rows are cached rasters behind `RepaintBoundary`; only the active
  word row (and a row whose scale is still easing) repaints per frame. The
  edge mask is built once per layout, not once per frame, and blur sigmas are
  quantized to 1/8 px so frames reuse one filter object. A transport tick
  repaints nothing unless a paused seek changes the word mask. The wide
  desktop canvas keeps only the vertical mask pass; its 18 px gutter already
  contains the blur halo, while compact layouts retain the left/right pass.
- The animated lyric rows are intentionally excluded from the platform
  semantics tree. One stable, keyed live-region node exposes the current lyric
  and translation, so scrolling, scale/blur transitions and line lifecycle are
  invisible to UIA and cannot leave pending lyric nodes in the AXTree.

## Lyric engine

| Module | Responsibility |
| --- | --- |
| `lib/lyrics/lyric_document.dart` | LRC/YRC parser and translation matching |
| `lib/lyrics/selection.dart` | Immutable multi-line selection model |
| `lib/lyrics/spring.dart` | Closed-form spring and adaptive position policy |
| `lib/lyrics/word_motion.dart` | Word emphasis/float motion envelopes |
| `lib/lyrics/timed_line.dart` | Grapheme-aware progressive glyph painting |
| `lib/ui/background.dart` | AMLL mesh-gradient cover flow + multi-hue cover palette extraction |
| `lib/lyrics/hit_region.dart` | Hit testing limited to actual glyph boxes |
| `lib/lyrics/selection_bar.dart` | Apple-style floating selection actions |
| `lib/lyrics/edge_fade.dart` | Four-edge soft viewport mask for the lyric raster |
| `lib/lyrics/image_export.dart` | Preview, PNG capture and save flow |
| `lib/lyrics/viewport.dart` | Lazy line mounting, follow/manual scrolling, blur, selection and export orchestration |

The viewport mounts only visible rows, polls the engine clock for word
painting, suspends follow during manual scrolling and resumes after the
configured delay. Selection tools copy original + translation in order and
export exactly the selected lines. Long-press selects with a plain bright
white highlight; selected rows (main text and translation) paint at full
alpha while every unselected row keeps the brightness it had before selection
began.

## Artwork and compact metadata

Tapping compact artwork switches between the large cover and the lyric layout.
The artwork shrinks beside the metadata while controls remain visible. When
controls hide, the top summary shows the small cover, title and artist. It enters
from above and moves downward; hiding it moves upward from its presented
position while fading. Reversing the action retargets the current spring instead
of resetting its position. Long-pressing artwork offers to save the current cover.

`AnimatedTrackCover` dissolves the outgoing visible composition above an opaque
incoming cover, avoiding a dark dip. A rapid return to a still-visible track
reuses that plate and its current spring velocity. Desktop artwork uses the
slower `AppleSpring.smooth` response; compact artwork uses
`AppleSpring.responsive`. Metadata refreshes do not replay a track change, and
reduced motion replaces the artwork immediately.

### Desktop cover resizing

The desktop cover changes size as the transport dock reveals or hides. One
retargetable layout spring drives the dock's reserved height, so the cover and
metadata follow the same motion without a second size animation. Revealing the
dock uses a 600 ms perceptual duration and `bounce: 0.15`; hiding uses the same
duration with no bounce. A reversal keeps the presented position and velocity.
The arrival overshoot stays below 2% of the resize distance.

Opacity uses a separate 220 ms cubic fade. The dock retains one control tree
through reversals, excludes hidden controls from input, focus and semantics, and
pauses their tickers. Reduced motion snaps both layout and opacity immediately,
including when enabled during a resize.

This follows the duration/bounce and velocity-continuity guidance in
[WWDC23: Animate with springs](https://developer.apple.com/cn/videos/play/wwdc2023/10158/)
and the continuously interruptible transitions in
[WWDC24: Enhance your UI animations and transitions](https://developer.apple.com/cn/videos/play/wwdc2024/10145/?time=233).

## Presentation and direct manipulation

The shell mounts the player over its existing root. Direct callers can use
`NowPlayingRoute`. Both hosts use a 460 ms cubic ease-in/out for ordinary desktop
opening and closing: no bounce and no almost-stationary spring tail. Compact
presentation and the release of a direct pull retain their spring response.

The controller value is the displayed openness. Closing during entrance or
opening during exit starts from the current position and velocity. A desktop
reversal briefly brakes the existing movement before changing direction; its
travel stays within the screen edges. The same page remains mounted throughout.
No extra easing is applied to a finger-driven coordinate. This applies the
WWDC23 continuity guidance and WWDC24 continuously interactive transitions to
both player hosts without giving the full-screen slide a decorative bounce.

A downward drag in the upper part of the page pulls it one-to-one with the
pointer. The player closes after 22% travel, or a downward release faster than
900 px/s after a small minimum travel; otherwise it springs back. An upward
release can cancel dismissal. Release velocity is normalized into the same
coordinate used by the animation, so there is no first-frame jump. Pointer
cancellation settles the visible player back into place. Mouse drags share this
path; wheel and trackpad scroll signals remain available to scroll content.

Reduced motion removes decorative travel and disables ambient background flow.
It does not force a long animated path through an accessibility preference.

## Background and resource handling

The player has independent dynamic, static, solid-colour and custom-image
settings. Browsing defaults to 30 fps; player flow follows the display refresh
rate unless a manual limit is chosen. Mesh precision changes density separately
from frame cadence. Static and hidden backgrounds do not keep continuous tickers
running. Custom images are copied into app storage so the selected file can move.

Album colours are extracted from a small analysis image, with generations that
prevent an older request overwriting the current track's palette. Displayed
artwork still uses the rendition appropriate for its painted size. Settled
palettes reuse processed colours instead of rebuilding them on every paint.

During player travel, ambient work is suspended and the backdrop uses a cheap
palette ramp. Large stable subtrees are repaint boundaries or captured motion
surfaces, so presentation moves a composed layer. The covered browse page stays
mounted with its state and scroll position; hidden tickers, focus and semantics
are gated until the page is visible again. See
[performance-validation.md](performance-validation.md) for focused measurements
and their limits.

## Accessibility and verification

The same-route player preserves the Windows accessibility root. Browse
semantics are excluded while the player is open; player semantics become active
after entrance. Lyrics contribute one stable live-region node, rather than one
changing node per animated row. Transport and seek controls keep stable labelled
semantics outside structural page rebuilds.

Tests cover compact/desktop layouts, portrait/landscape changes, enlarged text,
artwork blending, rapid reverse transitions, interrupted drag releases,
queue/comments, lyric timing, resource cleanup and reduced motion. Relevant
focused suites include `test/player_pull_down_test.dart`,
`test/apple_player_route_test.dart`, `test/animated_track_cover_test.dart`,
`test/mobile_artwork_player_test.dart`,
`test/accessible_player_transitions_test.dart` and
`test/player_open_cost_test.dart`. These checks do not substitute for frame-time
and input testing on each physical platform.
