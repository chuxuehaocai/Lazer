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
return flights now share a critically damped spring. Each rectangle edge
retains its presented position and velocity when the destination changes;
the perceived response parameter is not a fixed completion time.
Regression tests check actual
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

## Native-window scheduling comparison on 2026-11-02

`tool/resource_usage_profile.dart` measures an offline background in a native
Windows window. It does not play audio, restore an account or load the user's
library. Each isolated stage starts a fresh process, warms up for two seconds,
then samples for five seconds. CPU time includes all process threads and is
reported as a percentage of one CPU core, not of the whole machine. RSS is
sampled every 250 ms. Flutter frame timings are drained for another second and
filtered to the sampled vsync interval.

The local comparison uses the same current probe harness for two renderers:
`frozen-renderer-current-harness` and `unified-current`. The frozen copy retains
the previous shared clock, which requests every display vsync even when its
consumers discard frames for a manual cap. The current clock sleeps until a
requested background frame is due. This isolates that scheduling change; it
is not a comparison of the complete beta.4 and beta.5 applications. All accepted
reports below recorded a 100 Hz display, a requested 1280x720 window, a
1264x681 logical content area and device pixel ratio 1.0. A different reported
refresh rate must be compared separately.

Reports are accepted only when `samples_complete` and the report/stage `valid`
fields are true, the window remains visible and not minimized, and an animated
stage delivers frames. The accepted runs report no lifecycle changes. Windows
did not report an initial Flutter lifecycle state, which the JSON records as a
warning; the native visibility checks and an external window monitor remain
available. The external monitor did not identify these windows as the foreground
window, so these results do not establish foreground scheduling behavior.
Earlier `before-*`, `frozen-repeat-*`, `baseline-valid-1.json` and
`current-valid-1/2.json` attempts are excluded: they either lack these validity
fields or contain hidden, minimized or inactive samples. In particular,
zero frames from a hidden animated window are not a performance improvement.

Values are shown as frozen renderer -> current renderer. RSS is the process
working set at the end of the sample, in MiB (1,048,576 bytes). The table
preserves each pair instead of pooling runs with different display scheduling.

| Stage / isolated pair | Scheduled callbacks/s | CPU, one core % | Build p95, ms | Raster p95, ms | Ending RSS, MiB |
| --- | --- | --- | --- | --- | --- |
| 10 fps / 1 | 76.98 -> 9.99 | 9.37 -> 1.56 | 0.265 -> 0.420 | 37.490 -> 5.092 | 52.75 -> 52.38 |
| 10 fps / 2 | 40.99 -> 9.99 | 4.69 -> 1.25 | 0.232 -> 0.263 | 108.357 -> 118.214 | 53.40 -> 52.72 |
| 10 fps / 3 | 101.37 -> 10.00 | 7.81 -> 1.25 | 0.200 -> 0.227 | 0.729 -> 0.622 | 52.98 -> 52.25 |
| 30 fps / 1 | 80.79 -> 29.90 | 5.62 -> 1.87 | 0.248 -> 0.283 | 40.566 -> 24.056 | 53.51 -> 52.50 |
| 30 fps / 2 | 56.39 -> 25.60 | 5.31 -> 2.50 | 0.222 -> 0.247 | 85.923 -> 89.935 | 52.68 -> 53.51 |
| Display vsync / 1 | 62.58 -> 69.79 | 6.87 -> 17.18 | 0.348 -> 0.341 | 67.479 -> 54.633 | 52.26 -> 54.60 |
| Display vsync / 2 | 52.59 -> 42.39 | 7.81 -> 4.69 | 0.325 -> 0.385 | 86.969 -> 90.195 | 53.30 -> 52.63 |
| Static / 1 | 0 -> 0 | 0.94 -> 0.31 | no frames | no frames | 52.22 -> 52.38 |
| Static / 2 | 0 -> 0 | 0 -> 0 | no frames | no frames | 52.51 -> 52.21 |
| Static / 3 | 0 -> 0 | 0 -> 0.31 | no frames | no frames | 56.30 -> 54.16 |

Only two complete paired samples exist for 30 fps and display-vsync mode in
this captured set. The third baseline files for those stages have no matching
current report and are excluded from paired conclusions.

At the manual 10 fps cap, all three current runs request approximately ten
callbacks per second and use less CPU than their paired frozen runs. Both
complete 30 fps pairs also request fewer callbacks and use less CPU; one
delivers 25.60 callbacks/s under the measured scheduling conditions, so the cap
does not guarantee 30 delivered frames/s. Static mode schedules no frames in
either renderer. The simulation regressions in
`test/background_frame_schedule_test.dart` additionally cover 10/30 fps
deadlines on 60/120/165 Hz displays, faster shared consumers and cancellation
while inactive.

The uncapped CPU pairs disagree about direction, and raster p95 changes from
sub-millisecond values to more than 100 ms between runs. Ending RSS also moves
in both directions. These measurements support reduced unnecessary wakeups
at manual caps, but do not establish an uncapped CPU improvement, a consistent
raster-time reduction, a total-process memory reduction or a whole-app FPS
increase. Older 144 Hz attempts cannot be averaged with these 100 Hz pairs.
The probe's CPU counter is coarse for five-second near-idle samples; static
values from 0 to 0.94% are not evidence of a repeatable idle CPU difference.

GPU busy time and GPU memory residency were not measured:
`gpu_busy_measured` is false. Scheduled Flutter callbacks and raster-thread
duration are not GPU utilization. The separate artwork regressions establish
a narrower memory budget: two nearby thumbnail sizes share one 96x96 decoded
cache entry (36,864 RGBA bytes), instead of retaining a 2048x2048 decode
(16,777,216 RGBA bytes) for that fixture. Extreme panoramas cannot exceed four
times the target on their longest edge. This reduces the nominal uncompressed
pixel/texture payload for those images; it does not quantify driver allocation,
texture residency, mipmaps, decoder temporary storage or application-wide VRAM.
The palette-only 96x48 decode and its non-retention in the display cache are
covered separately above.

Raw local reports use
`build/reports/resource-usage/{baseline,current}-valid-isolated{1,2,3}-<stage>.json`.
They include process IDs, sample times, view size, validity checks and local
application hashes. They do not record the Flutter SDK revision, so they cannot
prove that revision by themselves. These generated reports and frozen binaries
remain local and are not release assets. The maintained probe and regression
tests are the reproducible method; a future comparison should also retain the
build commands and SDK revision, keep the display configuration fixed, reject
invalid samples and publish all complete pairs.

## Motion and compact screens

Artwork dissolves keep the previous opaque composition above the new artwork,
avoiding the dark dip caused by fading both plates over the page background.
Rapid next/previous changes start from that visible composition. Reduced motion
replaces the artwork immediately. Player artwork/lyrics and compact metadata
use the shared spring model, with whole-element opacity. Desktop track-cover
changes use the slower smooth response, while compact layouts use the responsive
response. Both use spring settlement rather than a fixed dissolve deadline.

Composite home cards (daily recommendations and charts) capture their last
painted mosaic, logo and caption once before navigation. Their spring flight
now blends those pixels into the detail artwork, and reverses that blend on
return. Rectangle-to-square motion crops both images proportionally and eases
the corner radius; it does not stretch the cover. Interrupted returns preserve
both current geometry and current colour composition.

Only these composite cards capture an image. Its longest edge is bounded to
1024 pixels at no more than 2× logical resolution. The detail's retained origin
keeps that texture available for returning; pending, page and flight references
release it when no longer needed, including deferred overlay removal. Animating
the blend only repaints and never rebuilds or lays out the cover again. The
pixel regressions in `test/home_cover_morph_test.dart` check the first/middle/
last frames, image proportions, interrupted journeys, DPI and resource cleanup.
Detail artwork that arrives after the flight uses a separate 200 ms reveal
over its placeholder. Synchronously cached images and reduced motion show
immediately; browse thumbnails keep their existing rendering path.

Route returns ease from their current visible position, including when Back
interrupts an entrance. The player controller now represents the displayed
position itself, and its simulation applies motion once. Releasing a 10% or
40% pull therefore retains that exact offset on the first released frame;
previously the extra curve mapping jumped to approximately 0.34% or 7.16%.
Player presentation/dismissal uses the shared smooth spring and retains the
presented position and velocity on interruption. The route's nominal duration
does not force a spring to stop before it settles. Rebuild/disposal tests cover listener cleanup and
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

## Resource and spring validation for beta.5

`tool/resource_usage_profile.dart` measures one background mode at a time in a
fresh Windows release process. It records visibility, lifecycle changes,
scheduled Flutter frames, process CPU time, RSS samples and engine raster
timings. A minimized or suspended run is invalid rather than a zero-cost result.
The frozen original renderer and current renderer use the same probe.

In the third valid isolated 10 fps pair, both windows reported a 100 Hz display
and a 1264 by 681 logical viewport. Over five seconds the original renderer
scheduled 101.37 Flutter frames per second and consumed 7.81% of one CPU core;
the current renderer scheduled 10.00 frames per second and consumed 1.25%.
The setting still requested ten background paints per second: the reduction is
in unnecessary frame callbacks. Static runs scheduled no frames in both
implementations. These short synthetic samples do not establish an
application-wide CPU percentage or GPU utilization. Other pairs varied in
delivered display cadence, so their full-vsync timings are not treated as a
causal speed improvement. RSS stayed close to 53 MiB in this background-only
workload and does not demonstrate a process-wide memory reduction.

Image-cache tests separately verify the memory improvement for displayed
artwork. A 2048 by 2048 local cover shown at the 96-pixel rendition retains
36,864 decoded RGBA bytes instead of 16,777,216. Nearby thumbnail sizes share a
cache key. Normal covers retain enough pixels for proportional cropping and
small images are never upscaled. Exceptionally elongated images have their
longest edge capped at four times the selected rendition: their cropped
resolution may be lower in exchange for a bounded texture. Unsized original
image export retains full resolution.

Navigation and cover geometry now run physical duration/bounce springs and
inherit presented position and velocity when retargeted. Duration is a
perceptual response parameter, not a fixed removal deadline. Regression tests
wait for the actual simulation to finish, check canceled/regrabbed gestures and
verify that tickers, source snapshots and temporary overlay layers are released.
Cover pixel tests include the first returning frame and immediate reopening;
the old layer stays visible until its replacement has painted.

The system media clock sleeps when playback is paused or absent. Paused seek
notifications still update the OS timeline immediately through the tick lane;
playing ticks do not increase the one-second publication cadence. These work
counts and decoded-byte budgets are the regression gates. GPU busy time,
whole-session peak RSS and hardware-specific power consumption require device
profiling and are not claimed by these checks.
