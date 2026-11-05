# Listening statistics and mobile back navigation

Open **Library → Listening statistics**. The page follows the app's semantic
colours and grouped cards, supports light/dark themes, and adapts to phone and
desktop widths. Today, the last 7/30 calendar days, and all time use the device's
local dates. Tap or drag the hourly chart to inspect an hour; keyboard arrows and
screen-reader adjustment actions provide the same control.

Statistics start with playback after this feature is installed. They are local
to this installation, include local files and streamed music, and are separate
from a provider's account listening history.

- Listening time follows advancing audio-engine positions. Pausing, buffering,
  loading, and seeking do not add listening time.
- A session counts as one play after one second of actual audio. Pause/resume
  and audio-quality changes preserve that session. Natural repeats start a new
  session.
- A manual change to a different song after audio has played counts as a skip.
  Natural advancement, failed playback, and restarting the same song do not.
- Hourly totals split playback at local hour and date boundaries. Song rankings
  show the five most played or most skipped songs in the selected period.

The controller aggregates daily/hourly totals and stores song metadata once in
`listening_statistics_v1.json` in the application support directory. Writes are
coalesced, use a temporary file followed by rename, and flush at playback
boundaries. Loading the statistics store does not block playback.

Mobile back navigation covers both Navigator routes and the shell's embedded
detail/player views. A cancelled gesture keeps the current view and navigation
history. A committed gesture returns once to the previewed destination. Dialogs
and sheets take priority over the shell. The player's existing downward drag
remains available.

## Device verification

Widget tests exercise system gesture progress, cancellation and commit. Before
shipping, also check on an iPhone and an Android device with predictive back:

1. Open a playlist, then an artist or album. Slowly drag back, cancel, and then
   complete the gesture. Check the previous page and its scroll position.
2. Open the player. Cancel and complete an edge-back gesture, then try the
   existing downward dismissal. Open a queue sheet and verify back closes it
   before the player.
3. Open Listening statistics from Library. Check its back gesture, theme,
   accessibility text size, and the hourly chart's touch/keyboard controls.
4. Play, pause, seek, manually change songs, and let a song end. Verify the
   corresponding totals, then restart the app and check persistence.
