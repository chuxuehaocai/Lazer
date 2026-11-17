# Player entry rendering benchmark

Run `flutter run -d windows --profile -t tool/benchmarks/player_open.dart` from
the repository root. Keep the app visible and avoid interacting with other
windows until it closes itself (about 45 seconds after launch).

The executable opens the production `LazerApp`, including its window frame,
navigation, player transition and native Windows backdrop. It uses generated
local artwork, 48 tracks and 120 word-timed lyric lines. Preferences and queue
storage are isolated; it does not require an account or play audio.

`build/benchmarks/player-open.json` contains four samples each for dynamic,
static and Windows Mica backgrounds. Each sample captures entry plus a 1.6-second
tail, with build/raster P95, worst duration and frames exceeding the display's
refresh budget. The first opening for each material is marked cold; it is not
a fresh process or shader-cache reset. Frame counts vary with background mode
and activity. These are engine timings, not an end-to-end display latency test.

Use profile/release builds for comparisons, on the same display and with the
same window size. Network artwork, real audio decoding, other GPUs and TV
devices need separate measurements. A good P95 does not rule out isolated long
frames; inspect the worst duration and over-budget count as well.
