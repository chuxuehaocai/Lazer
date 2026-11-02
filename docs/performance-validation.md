# Rendering and resource validation

The changes reduce repeated work in lyrics, artwork loading, cache maintenance
and page transitions. They preserve word timing, layout and access to controls.
The measurements below come from local Windows comparisons; they establish
specific reductions in work, rather than a guaranteed frame rate on all devices.

| Check | Previous implementation | Updated implementation |
| --- | --- | --- |
| Directory scans for 80 artwork writes | 80 | 1 in the recorded run; at most 2 in the burst test |
| File metadata reads for those writes | approximately 2,584 | 80 in the recorded run |
| Layout of 16 lyric rows, median | 45.016 ms | 16.225 ms |
| Painting 300 lyric frames, median | 63.743 ms | 37.762 ms |
| Active lyric row save layers | 3 | 2 |

These are focused workloads, not application-wide frame-time measurements.
Alternating old and new native-window runs showed variable raster times and
display scheduling. They do not support a claim of a consistent overall FPS
increase. Initial player presentation still needs profiling on target devices.

Lyrics retain paragraph layout until text, width, typography or scaling changes.
Off-focus rows defer per-word geometry, settled words share paint groups and
repeated lines reuse height measurements. Pixel comparisons across 84 cases
covered wrapping, emoji, focus changes and reverse playback: the maximum channel
difference was 2/255, with approximately 0.22% of channels differing.

Cached artwork uses file-backed immutable buffers, avoiding an additional Dart
byte array and native copy. Cache cleanup coalesces bursts while checking writes
that arrive during an active scan. Its capacity and concurrent-write behavior
are covered by `test/cache_maintenance_performance_test.dart` and
`test/disk_cache_test.dart`.

Page transitions keep the active navigation ancestors (at most eight), pause
hidden animation work, exclude hidden focus/semantics, and release snapshots
after motion. Returning reuses the shelf's state and scroll position. Background density and cadence are
independent. Browsing defaults to 30 fps; the player follows display vsync unless
a manual rate is selected. Static and hidden backgrounds do not keep the flow
ticker running.

The embedded view switcher reuses the animation owned by `AnimatedSwitcher`.
Previously, rebuilding its transition ten times left ten additional status
listeners attached after the widgets were removed. The lifecycle regression in
`test/page_switch_motion_test.dart` now verifies that no listeners remain.

Cover flights use an independent overlay ticker and a paint transform. The
incoming page's paused tickers therefore cannot freeze the flight. Forward and
return flights use the same 420 ms curve, `Cubic(.22, 1, .36, 1)`, which moves
most of the distance early and slows on arrival. Regression tests check actual
transformed bounds, moving return targets, rapid cancellation and re-entry, and
that intermediate frames do not rebuild or lay out the artwork.

Startup restores the local library, bounded playback cache, audio volume,
saved playback queue, and account/home data in parallel where they are
independent. Account restoration still precedes an authenticated home request;
bootstrap completion still waits for every lane. Window setup overlaps
preferences, device detection and audio initialization.

A controlled five-run benchmark injected a 400 ms local-library delay. Before
the change, the home request started at 403–471 ms and the saved queue was ready
at 402–412 ms. Afterwards, those values were 2–3 ms and 1 ms respectively; full
bootstrap still completed around 400–402 ms. This measures removal of a known
serialization bottleneck, not a promise about total cold-start time on a device.

## Animation work reduced on 2026-11-02

The following focused comparisons reduce repeated work without reducing mesh
density, background cadence or displayed artwork resolution:

| Workload | Before | After |
| --- | --- | --- |
| Hide or restore one artwork source in a 120-card shelf | 120 source wrapper rebuilds | 1 affected wrapper rebuild |
| 7 hidden navigation ancestors during 6 transition frames | 42 slide rebuilds | 0 |
| Hidden ancestor wrapper during 6 unrelated parent reports | 6 rebuilds | 0 |
| 100 unrelated AppState reports while browsing | Background subtree regenerated on each report | 0 background regenerations |
| 120 mesh frames with a settled cover palette | Palette interpolation/HSL treatment on each paint | One cached palette treatment |
| Analyse a 2048×1024 cover | 8,388,608 bytes of decoded RGBA; image retained in the display cache | 96×48 analysis image, 18,432 bytes of RGBA; no analysis image in the display cache |
| Ordinary long word after its soft highlight clears | 24 paragraph draws per frame | 2 (dim and bright) |
| Synthetic active lyric row | 33 paragraph draws per frame | 13 |
| Native position reads during 10 lyric animation frames | 20 | 10 |
| Record 300 focused lyric paint frames | 34.4–37.7 ms | 17.2–19.0 ms |

The small analysis image only supplies background colours. The visible cover
keeps its original rendering path. Codecs, descriptors and encoded buffers are
released after analysis. The byte comparison measures decoded pixel size and
display-cache retention; it does not measure total process peak memory or the
decoder's internal temporary allocations.

Ordinary floating words share a clip and paragraph draw once their soft mask
has passed every glyph. Emphasized glyph animation and mask timing are retained.
A 656-frame comparison covered CJK, emoji, right-to-left text, wrapping, focus
changes, rewinds and highlight boundaries within one microsecond. It changed
0.0171% of pixel channels, with a maximum difference of 123/255. Every difference
greater than 2 was within 1.5 pixels of an original per-glyph clip edge: merging
the clips removes their antialias seams. The comparison is not pixel-identical.
Paint timings measure synthetic paragraph recording, not whole-app device FPS.

Parked navigation pages use stationary animations and reuse inactive wrappers,
so they no longer subscribe to the next page's transition controller. Inherited
theme and window changes still update their dependent elements. Cover visibility
notifications are local to the selected source, and pending updates coalesce
before the next frame. Recycled sources release their visibility state.

The independent real-catalogue BGA check also passed with six CDN covers: cold
loads, warm loads without further downloads, distinct painted pixels and three
out-of-order cover requests. This checks the new analysis decoder against the
actual disk/network path; `build/reports/bga-real-catalog.json` records the run.

## Motion and compact screens

Artwork dissolves keep the previous opaque composition above the new artwork,
avoiding the dark dip caused by fading both plates over the page background.
Rapid next/previous changes start from that visible composition. Reduced motion
replaces the artwork immediately. Player artwork/lyrics and compact metadata
use the same decelerating curve as cover flights, with whole-element opacity.

Route returns ease from their current visible position, including when Back
interrupts an entrance. The player controller now represents the displayed
position itself, and timed simulations apply easing once. Releasing a 10% or
40% pull therefore retains that exact offset on the first released frame;
previously the extra curve mapping jumped to approximately 0.34% or 7.16%.
Full player presentation/dismissal remains 300 ms, scaled to the remaining
distance on interruption. Rebuild/disposal tests cover listener cleanup and
opening another player while the previous route exits.

Large-screen components use an 84% design baseline, 20% larger than the previous
70%; automatic/manual DPI still applies. The 1280×720 regression uses the real
scale with remote navigation across home, collections, library, settings and
search. See `docs/android-tv.md` for the controls and size setting.

The ordinary Android watch interface now has separate round/square player
layouts, ellipse-safe lazy lists and a leaf transport subscription. The
1,200-song queue mounts fewer than 20 rows; ten position reports rebuild no
player page. Tests cover 160–240 logical-pixel screens, enlarged text, keyboard
insets and late network responses. The background remains static by default.
See `docs/android-watch.md` for interaction details and hardware limitations.

Run focused regression checks with:

```sh
flutter test --no-pub test/lyric_render_performance_test.dart test/lyric_motion_test.dart test/artwork_memory_test.dart test/cache_maintenance_performance_test.dart test/background_preferences_test.dart test/settings_subview_transition_test.dart test/accessible_player_transitions_test.dart
flutter test --no-pub test/background_resource_performance_test.dart test/cover_transition_ticker_test.dart test/retained_content_switcher_test.dart test/animated_track_cover_test.dart
flutter test --no-pub test/route_motion_test.dart test/player_pull_down_test.dart test/large_screen_test.dart test/watch_and_tv_density_test.dart
```

For native frame measurements, build and run `tool/rendering_profile.dart` and
`tool/player_lifecycle_profile.dart` in profile mode. Compare repeated runs on the
same display and hardware, keeping viewport size, refresh rate, engine backend,
lyric fixture and settings fixed. Inspect both build and raster distributions,
including presentation and dismissal, before drawing a frame-rate conclusion.
