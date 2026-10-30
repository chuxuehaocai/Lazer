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

Page transitions retain at most one outgoing page, pause covered animation work
and release temporary snapshots after motion. Background density and cadence are
independent. Browsing defaults to 30 fps; the player follows display vsync unless
a manual rate is selected. Static and hidden backgrounds do not keep the flow
ticker running.

The shared page switcher also reuses the animation owned by `AnimatedSwitcher`.
Previously, rebuilding its transition ten times left ten additional status
listeners attached after the widgets were removed. The lifecycle regression in
`test/page_switch_motion_test.dart` now verifies that no listeners remain.

Run focused regression checks with:

```sh
flutter test --no-pub test/lyric_render_performance_test.dart test/lyric_motion_test.dart test/artwork_memory_test.dart test/cache_maintenance_performance_test.dart test/background_preferences_test.dart test/settings_subview_transition_test.dart test/accessible_player_transitions_test.dart
```

For native frame measurements, build and run `tool/rendering_profile.dart` and
`tool/player_lifecycle_profile.dart` in profile mode. Compare repeated runs on the
same display and hardware, keeping viewport size, refresh rate, engine backend,
lyric fixture and settings fixed. Inspect both build and raster distributions,
including presentation and dismissal, before drawing a frame-rate conclusion.
