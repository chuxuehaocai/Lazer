# Scheduled pause

Settings → Playback → Scheduled pause supports multiple daily local-time points.
Mobile opens a separate settings page; desktop keeps the editor in a settings
subview. Add, edit, delete or individually disable points, then enable the
master switch. Settings persist across application restarts.

Each entry contains one 24-hour time, such as 23:00 or 12:30. At that time,
playback pauses once and retains the current queue and position. The listener
can resume manually immediately afterwards; there is no blocked interval and no
automatic resume. Entries at the same time coalesce into one pause. Editing or
enabling a schedule does not retroactively pause for earlier times in the day.
Existing range settings migrate to their start times; their end times are
discarded and the saved settings use the point format from then on.

A foreground check catches points crossed while the process was suspended and
coalesces missed events into one pause. Pending stream loads, buffer waits, and
native play requests also recheck the schedule, so an earlier play request cannot
resume audio after the point. An explicit new play request remains available.

A single timer targets the next point, with a wall-clock check at most every
30 seconds while enabled. Points use local calendar dates, rather than adding
24 hours, to follow daylight-saving boundaries. A skipped local time follows
the platform's calendar normalization; a repeated local minute does not deliver
the same pause twice. A bounded history retains 32 delivered local dates to
prevent repeats after a clock rollback. Timezone changes update upcoming local
times at the next check.

Execution requires the application to be running. An operating system that
suspends the process can defer the pause until the app resumes. The feature
pauses music; it does not close the app, shut down the device, or control another
application's audio. The editor is available in Simplified Chinese, Traditional
Chinese, English, and Japanese.
