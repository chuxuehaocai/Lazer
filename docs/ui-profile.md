# UI profile benchmark

`tool/ui_profile.dart` runs a synthetic, account-free Windows UI workload in
Flutter profile mode. It shows 200 timed lyric lines, lets their position
springs settle, measures five seconds of the active word animation, then
animates a 5,000-track queue through four 4,000-pixel scrolls. The lyrics use a
fixed playhead; this tests rendering, not the audio backend or network.

```powershell
flutter run --profile -d windows -t tool/ui_profile.dart --dart-define=PROFILE_OUTPUT=C:/temp/lazer-ui-profile.json
```

The program exits after the run and writes frame counts plus median and 95th
percentile engine build and raster durations in milliseconds. Use the same
machine, window size, Flutter version, rendering backend and idle conditions
for comparisons; repeat runs before treating small differences as meaningful.
The results are frame costs, not end-to-end interaction latency or proof of a
particular frame rate. Device thermals, refresh rate and other activity affect
results. The normal app and its persisted settings are not used.

One paired run on Windows, Flutter 3.47.8 and Impeller OpenGL, 1280 × 720:

| Workload | Measure | Branch base | Working tree |
| --- | --- | ---: | ---: |
| Settled word lyrics | UI build p95 | 0.214 ms | 0.196 ms |
| Settled word lyrics | raster p95 | 1.229 ms | 1.237 ms |
| Queue scroll | UI build p95 | 0.373 ms | 0.330 ms |
| Queue scroll | raster p95 | 0.599 ms | 0.593 ms |

This is a single synthetic comparison, not a representative device survey.
It does not measure startup, artwork, actual audio playback, networking, page
navigation, or long comment/local-library lists.

A later unpaired working-tree run recorded 834 lyric frames and 784 queue-scroll
frames. Lyrics measured 0.193 ms build p95 and 1.209 ms raster p95; queue scroll
measured 0.326 ms build p95 and 0.592 ms raster p95. These values are close to
the earlier working-tree sample and do not establish a causal change.

## Large-queue track switching

`tool/queue_switch_profile.dart` renders the real browse shell with a fake
player, catalogue, lyrics and in-memory preferences. It creates 5,000 tracks,
warms up, then selects 40 tracks at 125 ms intervals while a ticker keeps frames
scheduled. The program records frame build and raster p95, frame-to-frame vsync
intervals, the synchronous duration of `playTrackAt`, and the final persisted
queue/index. It runs without the user's music, credentials or settings:

```powershell
flutter run --profile -d windows -t tool/queue_switch_profile.dart --dart-define=PROFILE_OUTPUT=C:/temp/lazer-switch-profile.json
```

To include the default dynamic album backdrop in the same workload, add
`--dart-define=PROFILE_DYNAMIC_BACKDROP=true`. The default profile keeps the
backdrop off so queue changes can be compared without mesh animation cost.

A single paired run under the same Windows/Flutter/backend setup above:

| Measure | Branch base | Working tree |
| --- | ---: | ---: |
| Frame build p95 | 1.366 ms | 0.570 ms |
| Raster p95 | 1.453 ms | 1.437 ms |
| Vsync interval p99 | 12.134 ms | 6.067 ms |
| Intervals over 16.7 ms | 1 | 0 |
| Synchronous `playTrackAt` p95 | 0.031 ms | 0.174 ms |
| Final saved index / track count | 40 / 5000 | 40 / 5000 |

This sample suggests fewer long frame intervals, while the synchronous part of
`playTrackAt` increased by 0.143 ms. Results vary between runs; they are not an
end-to-end measure of actual disk, audio, network, artwork or cold startup.
`playTrackAt` timing excludes asynchronous work. On web, `compute` runs on the
same thread rather than a separate isolate.

A later single working-tree run after filtering player-bar rebuilds reported
0.475 ms build p95, 1.432 ms raster p95 and 6.067 ms vsync interval p99;
the final index and 5,000 tracks were still present. This is another unpaired
sample and should not be read as a causal or statistically significant change.

A follow-up run after caching queue snapshots and sidebar playlist entries
recorded 836 frames: 0.455 ms build p95, 1.477 ms raster p95, 0.149 ms
synchronous `playTrackAt` p95 and 6.067 ms vsync interval p99, with no
intervals over 16.7 ms. The saved queue still contained 5,000 tracks at index
40. This is another single synthetic run; the small build-time difference
does not establish a general improvement, and raster time was slightly higher
than in the prior unpaired run.

A separate run with `PROFILE_DYNAMIC_BACKDROP=true` kept the default mesh
animation active during the same shell and queue workload. It recorded 835
frames, 0.559 ms build p95, 1.485 ms raster p95 and 6.067 ms vsync interval
p99, with no intervals over 16.7 ms; the saved queue was still 5,000 tracks at
index 40. The preceding backdrop-off sample measured 0.455 / 1.477 ms build /
raster p95. These separate runs are not paired evidence; on this Windows
profile they do not point to the mesh as the main source of frame stalls.

## Large gateway responses

`tool/gateway_profile.dart` feeds the transport 20 in-memory 703,378-byte
responses containing 5,000 synthetic tracks, with frames continuously
scheduled. It checks the decoded result but performs no network requests:

```powershell
flutter run --profile -d windows -t tool/gateway_profile.dart --dart-define=PROFILE_OUTPUT=C:/temp/lazer-gateway-profile.json
```

One paired run on the Windows setup above:

| Measure | Branch base | Working tree |
| --- | ---: | ---: |
| Frame interval p99 | 12.134 ms | 6.067 ms |
| Intervals over 16.7 ms | 0 | 0 |
| Response processing p50 | 8.911 ms | 11.011 ms |
| Response processing p95 | 11.493 ms | 12.934 ms |

The sample suggests improved scheduling responsiveness at the cost of extra
processing latency. It excludes network, real catalogue mapping and UI layout;
repeat on target devices before drawing a general conclusion. Large response
parsing uses `compute`, which does not create a background isolate on web.

## Large cache writes

`tool/cache_write_profile.dart` serializes 5,000 synthetic track records 20
times while scheduling frames. Its in-memory `put` receiver isolates encoding
and scheduling costs; it does not access disk or user data:

```powershell
flutter run --profile -d windows -t tool/cache_write_profile.dart --dart-define=PROFILE_OUTPUT=C:/temp/lazer-cache-profile.json
```

One paired run on the Windows setup above, producing 763,385 bytes per write:

| Measure | Branch base | Working tree |
| --- | ---: | ---: |
| Synchronous write call p95 | 5.895 ms | 4.128 ms |
| Complete write p95 | 12.927 ms | 20.999 ms |
| Vsync interval p99 | 12.134 ms | 12.134 ms |
| Intervals over 16.7 ms | 4 | 0 |

The sample shows less synchronous work and a longer overall completion time;
a single run does not establish a general frame-rate improvement. Copying the
snapshot and isolate transfer still cost UI time. Disk performance, catalogue
object conversion and web execution are outside this test; `compute` does not
create a separate isolate on web.

## Catalogue track conversion experiment

`tool/catalog_profile.dart` loads 5,000 synthetic tracks through an in-memory
cache and a fake gateway, scheduling frames throughout. Each case runs 12 times
and verifies the resulting tracks; it does not use user data, disk or network.

```powershell
flutter run --profile -d windows -t tool/catalog_profile.dart --dart-define=PROFILE_OUTPUT=C:/temp/lazer-catalog-profile.json
```

One paired run compared the branch base with an experimental background-isolate
conversion. The experiment was reverted because this sample showed no frame
interval improvement and increased latency:

| Measure | Branch base | Experimental conversion (reverted) |
| --- | ---: | ---: |
| Cold in-memory cache latency p95 | 0.764 ms | 4.269 ms |
| Fake network latency p95 | 5.066 ms | 8.202 ms |
| Frame interval p99, both cases | 6.067 ms | 6.067 ms |
| Intervals over 16.7 ms, both cases | 0 | 0 |

These are single-run synthetic measurements, not a measure of actual storage,
network, track-list rendering or performance on other devices.

## Local manifest loading

`tool/local_library_profile.dart` loads a 1,929,489-byte manifest with 5,000
synthetic records 12 times from a temporary directory, scheduling frames while
loading. File-existence checks are faked; no user music or settings are read.

```powershell
flutter run --profile -d windows -t tool/local_library_profile.dart --dart-define=PROFILE_OUTPUT=C:/temp/lazer-local-profile.json
```

One paired run on the Windows setup above:

| Measure | Before | Background parsing |
| --- | ---: | ---: |
| Load latency p95 | 43.252 ms | 47.869 ms |
| Frame interval p99 | 42.468 ms | 6.067 ms |
| Intervals over 16.7 ms | 12 | 0 |

The test suggests fewer long frame intervals with a small latency increase,
but is a single synthetic run. It excludes real filesystem checks, audio,
rendering the local library page, and device differences. On web, `compute`
does not create a separate isolate.

## Local manifest writing

`tool/local_library_write_profile.dart` starts with 5,000 synthetic records in a
private temporary directory and adds 12 scan-root records, writing the actual
manifest each time while scheduling frames. Existence checks are faked and no
user music or settings are read.

```powershell
flutter run --profile -d windows -t tool/local_library_write_profile.dart --dart-define=PROFILE_OUTPUT=C:/temp/lazer-local-write-profile.json
```

One paired run on the Windows setup above:

| Measure | Before | Background encoding |
| --- | ---: | ---: |
| Complete write p95 | 26.819 ms | 34.075 ms |
| Frame interval p99 | 18.201 ms | 6.067 ms |
| Intervals over 16.7 ms | 12 | 0 |

This single synthetic run suggests fewer long frame intervals with longer write
completion. Results depend on storage and device; the benchmark does not cover
scanning or real music. On web, `compute` runs on the calling thread.

## Local library page rebuilds

`tool/local_page_profile.dart` renders the local music page with 5,000 synthetic
records and sends 40 library notifications without changing the records. A
continuous ticker schedules frames. It uses no user music or settings:

```powershell
flutter run --profile -d windows -t tool/local_page_profile.dart --dart-define=PROFILE_OUTPUT=C:/temp/lazer-local-page-profile.json
```

One paired run on the Windows setup above:

| Measure | Branch base | Working tree |
| --- | ---: | ---: |
| Build duration p95 | 0.217 ms | 0.260 ms |
| Build duration p99 | 1.601 ms | 0.592 ms |
| Frame interval p99 | 6.067 ms | 6.067 ms |
| Intervals over 16.7 ms | 0 | 0 |

The p99 sample suggests less build work during this synthetic notification
pattern, without a measured frame-interval change. The comparison includes all
branch changes, not only the local-page cache, and measures idle frames as well
as notification frames. Real scanning, playback, disk, large missing-file lists,
other devices and user interaction are outside its scope.

## Current branch frame sample (2026-10-29)

The profile workloads were rerun on Windows against the current working tree.
The application ran in Flutter profile mode with the Impeller OpenGL renderer.
These are independent synthetic workloads, not a before/after comparison or a
measurement of the user's normal session:

| Workload | Frames | Build p95 | Raster p95 | Vsync interval p99 | Intervals over 16.7 ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Timed lyric animation | 840 | 0.209 ms | 1.238 ms | Not recorded | Not recorded |
| 5,000-track queue scroll | 782 | 0.340 ms | 0.606 ms | Not recorded | Not recorded |
| 40 switches in a 5,000-track queue | 833 | 0.477 ms | 1.473 ms | 6.067 ms | 0 |
| 5,000-track local-library notifications | 834 | 0.153 ms | Not recorded | 6.067 ms | 0 |

The queue switch call itself measured 0.149 ms at p95; the final persisted queue
contained 5,000 tracks at index 40. The local-library build p99 was 0.534 ms.
The two workloads that recorded vsync intervals had no interval above the
16.7 ms 60 Hz frame budget in these samples. The lyric and queue-scroll runner
does not count missed-frame intervals. Results vary with display refresh,
device load, thermals, Flutter version and rendering backend; profile timings
should not be treated as a device-wide FPS guarantee.
