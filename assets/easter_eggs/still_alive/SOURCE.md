# Still Alive terminal credits provenance

This Flutter port now follows the user's corrected reference:
`F:/Portal_StillAlive_Python-master/still_alive_credit.py`. It replaces the
earlier Portal-StillAlive rendition and does not stretch its timeline to the
recording's length.

The supplied script identifies itself as **PORTAL--STILL ALIVE demo by
LHF (BD4SUP), September 2021**. Its complete original bytes are retained as
`source.py`, and that directory's README is retained unchanged as
`SOURCE_README.md`. The script declares the GNU General Public License,
version 3 or any later version, and its disclaimer is preserved in `source.py`.
`GPL-3.0.txt` contains the full GPL version 3 license text, obtained from the
SPDX license-list-data repository after the GNU server failed to respond.

The source credits personnel text to
<https://github.com/xBytez/aperturescience> and ASCII artwork to
<https://sites.google.com/site/gaddc11/Stillalive.rar?attredirects=0&d=1>.
It states that the song's copyright belongs to Jonathan Coulton and Valve
Software. The program's GPL notice does not grant additional rights to the
song or recording.

The Dart data preserves all **121 commands**, all **10 ASCII artworks**
(20 rows each), and all **2,825 personnel-text characters** across 198 rows.
No names, whitespace, source spelling or credit lines have been silently
corrected. Event times are absolute centiseconds: music starts at **7.1 s**,
the first sung lyric starts at **7.3 s**, personnel credits start at **9.3 s**,
the credits thread lasts **174 s**, and the END command occurs at **185 s**.

Mode 0 types text then starts a new row; mode 1 appends on the current row;
mode 2 draws artwork; mode 3 clears the lyric panel; mode 4 starts music;
mode 5 starts personnel credits; mode 9 ends the terminal sequence. Negative
typing intervals use the gap to the next scheduled event as the whole-line
duration. Nonnegative intervals specify that duration in seconds. Empty
strings still create a row without sleeping, as in the source loop. NUL
characters retain their original buffer-flush timing and empty row but are
never rendered. END and clear commands never become visible text.

Blocking text operations run serially: an overdue event begins at the later
of its timestamp and the previous operation's completion. Artwork rows use
the source's 10 ms per row (200 ms total). The table already includes its
documented 700 ms spacing; the port adds no further gap. Personnel text follows
its independent character clock and exposes a prefix for a scrolling panel.
Python thread scheduling, terminal transmission delays and the main loop's
10 ms polling overhead are not added as synthetic delays in Flutter.

The introduction runs before music starts. Thereafter the page evaluates the
absolute score at **7.1 s + the actual decoder position**; it never scales the
score to fit audio duration. Pause, seek, reverse seek and replay therefore
derive display content from the current position rather than accumulated
lyric timers.

`sa1.mp3` is byte-identical in both user-supplied directories and in this asset
directory. Its SHA256 is
`c0298d1f5e9430c6dabbff30295e21930ea7799fbeb427f67b2cbcc06f31af8b`.
The recording reports 176.404875 seconds, so its end corresponds to score time
183.504875 seconds: the personnel text is complete and the lyrics have already
cleared, while the reference END timestamp remains unchanged at 185 seconds.
