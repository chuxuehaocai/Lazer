# Android watch interface

`WatchShell` is a dedicated touch interface for ordinary Android watches. It
uses Flutter and the application's existing Android playback, files, accounts
and device-shape detection. It adds no Wear OS dependency or Wear OS-only API.
Detected watches retain the static background default.

## Layout and navigation

- The round player places the artwork, title, artist, progress and transport
  controls inside the physical display. Music and settings sit beside the
  artwork. The square player uses a wider artwork/title row, a top navigation
  strip and a separate transport row. Playback controls are available on the
  first screen at the tested default text size, without scrolling.
- Tap the artwork for the playback queue. Tap the song title for current lyrics
  and playback status; a playback error is also signalled beside the title.
  Music opens local/downloaded/cached tracks, recent plays, daily
  recommendations, playlists and search. Settings retains SMS sign-in, local
  import, volume, appearance and sign-out. Each secondary page has a fixed
  return control; Android Back also returns through the current page.
- A round display uses an ellipse chord calculated across the full height of
  each visible row, including its touch surface. Rows narrow near the poles
  and become available as they scroll into the central band. Square displays
  use their available width. Enlarged text switches the player to a scrollable
  layout instead of shrinking the listener's chosen font size.
- While an Android keyboard is present, list content moves into the remaining
  visible area. Bounds remain valid even for a keyboard covering the whole
  application. The keyboard's Back action first dismisses input, after which
  the page return control is available again.

## Resource use and verification

Song, queue and playlist rows are built lazily. A 1,200-song test mounts fewer
than 20 rows both at the start and end of the queue. Scroll-dependent round
insets update only mounted rows and use scalar geometry; they do not measure
text or run a ticker. Progress subscribes to the transport tick lane in its
own leaf: 10 position notifications rebuild no player page. Scrubbing sends a
single seek when released. There are no background blur passes, shadows or
continuous decorative animations in this interface.

`test/watch_shell_redesign_test.dart` covers 160×160 and 192×192 round/square
displays, 240×240 round and 240×280 square displays, button bounds and playback,
1.7× text, lazy queues, current lyrics, search, sign-in, delayed-navigation
races and simulated Android keyboard insets of 100/110/170/240 logical pixels.
`test/watch_and_tv_density_test.dart` also checks static defaults and the
existing sign-in path. Screenshot probes load MiSans, Material icons and a
real local PNG cover, and export at 3× resolution with:

```sh
flutter test --no-pub --dart-define=SAVE_WATCH_PROBES=true test/watch_shell_redesign_test.dart
```

Output is written to `diag/watch-redesign/`. The black corners in round probes
represent the part outside the physical display.

These are automated Flutter layout and interaction checks on Windows, not
Android watch hardware measurements. Manufacturer DPI, physical bezel/insets,
keyboard/fullscreen extraction mode, battery, thermal behaviour, file-picker
availability and prolonged playback still need validation on actual ordinary
Android round and square watches.
