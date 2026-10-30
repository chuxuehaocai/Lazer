# Scheduled pause

Settings → Playback → Scheduled pause supports multiple daily local-time ranges.
Mobile opens a separate settings page; desktop keeps the editor in a settings
subview. Add, edit, delete or individually disable ranges, then enable the
master switch. Settings persist across application restarts.

The start is inclusive and the end exclusive. For example, 23:00–07:00 pauses
from 23:00 through the following morning, while 12:00–13:00 adds a lunch break.
Overlapping ranges remain active until every covering range has ended. Equal
start/end times are rejected so a mistaken entry cannot disable playback all day.

Entering an enabled range pauses the current track and retains its queue and
position. Playback requests are held while a range is active. Leaving the range,
disabling the feature or deleting the range never starts playback automatically.
The listener can resume manually afterwards. The feature pauses music; it does
not close the application or shut down the device.

A single timer targets the next boundary, with a wall-clock check at most every
30 seconds while enabled. Resume events trigger an immediate recheck. Boundaries
use local calendar dates, including overnight ranges. Timezone/system-clock
changes are picked up by the recheck. Execution requires the application to be
running; an operating system that suspends the process can defer the check until
the app resumes. The app cannot pause another application's audio.
