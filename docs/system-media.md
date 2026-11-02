# System media integration

The app has one queue and one audio engine. `LazerMediaHandler` adapts the existing
`AppState` to system controls, rather than creating another player.

| Platform | Integration |
| --- | --- |
| Android | `audio_service`, foreground media playback service, MediaSession and notification |
| iOS | `audio_service`, MPNowPlayingInfoCenter and MPRemoteCommandCenter; background audio enabled |
| macOS | `audio_service`, MediaPlayer framework |
| Linux | `audio_service_mpris`, session D-Bus / MPRIS |
| Windows | App-owned C++/WinRT SMTC bridge, with timeline and seek support |

Android resolves the media notification's small icon and audio_service's transport
action icons by resource name at runtime, so `android/app/src/main/res/raw/keep.xml`
pins them against the release resource shrinker. A stripped small icon makes
`startForeground` post an invalid notification, which Android 12+ rejects by
killing the process, and stripped action icons leave the notification buttons blank.

Playback position is sampled every **100 ms**. The media handler also publishes
every **100 ms**, and immediately after a structural change. Screens consume the
position notifier without rebuilding the app or the navigation tree.

The exposed transport is previous track, play/pause, next track and absolute
seek. In particular, iOS receives track commands, not the podcast-style 30-second
skip controls. System commands share the same playlist, repeat and shuffle state
as the Flutter UI. Artwork is cached locally using the CDN's required headers.

On Android, the first foreground playback transition starts the media service
from the visible activity before publishing the playing state. This keeps the
`mediaPlayback` foreground service eligible for Android 17 background audio
hardening, so Control Center commands continue through the same Dart queue and
audio engine after the activity is hidden.

Windows events are posted to the window thread before using Flutter's method
channel. Shutdown revokes the WinRT event handlers and drains pending events.

Completion uses the player's terminal event, with a fallback based on the native
duration and position. Catalogue durations and estimated clocks never advance an
unavailable or buffering song. A source generation guard discards errors from
superseded play requests.

## Lyrics on the phone controls

Neither Android's `MediaMetadata` nor iOS's `MPNowPlayingInfoCenter` has a lyrics
key, and Apple renders the now-playing card — lock screen, Control Center and the
Dynamic Island — from exactly the documented `MPMediaItem` subset, which does not
include lyrics. What both platforms do render as the control's second line is the
item's **artist**, so that is where the line being sung goes:

- `LazerMediaHandler` publishes `MediaItem.artist` (plus `displayTitle` /
  `displaySubtitle` / `displayDescription`, which Android 12 and older read from
  the notification the app posts itself) as the current lyric line.
- The line is read from `AppState.currentLyricLine`, which uses the same binary
  search as the lyric viewport and falls back to the last line with words when a
  line is instrumental.
- It is refreshed by the handler's one-second clock and only pushed to the
  platform when the line actually changed.
- Queue entries keep the plain artist, so a controller listing the queue —
  Android Auto, CarPlay — shows songs rather than lyrics.
- The desktop controls (SMTC, MPRIS) keep the artist: MPRIS is read by other
  applications, and their flyouts sit next to an app that shows the whole sheet.
- **Settings → 歌词 → 系统媒体控件显示歌词** turns it off; `AppState.systemMediaLyrics`
  persists the choice as `lazer_system_media_lyrics` (default on).

Apple reserves richer lyrics presentation (styled text in the Dynamic Island) for
a Live Activity, which needs a widget extension in the Xcode project; that is not
part of this integration.

## Verification

`test/system_media_test.dart` covers completion, the fallback, repeat-one,
interrupted requests, media commands, position cadence, stale artwork and the
Windows channel contract. `test/system_media_lyrics_test.dart` covers the lyric
line following playback, its fallback across instrumental lines, the setting and
the desktop exception. Responsive and accessibility tests cover the visible
controls and route changes. Apple and Linux native builds require their own OS
toolchains; they cannot be compiled or exercised by the Windows build host.

References: [audio_service](https://pub.dev/packages/audio_service),
[MPRIS adapter](https://pub.dev/packages/audio_service_mpris),
[Microsoft SMTC timeline](https://learn.microsoft.com/en-us/uwp/api/windows.media.systemmediatransportcontrols.updatetimelineproperties).
