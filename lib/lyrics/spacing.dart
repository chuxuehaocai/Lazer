/// Shared vertical gap added after each lyric row.
///
/// The full player and the desktop/floating lyric overlay read the same value
/// so changing the setting does not make the two lyric surfaces drift apart.
const double kLyricsLineSpacingDefault = 20;
const double kLyricsLineSpacingMin = 0;
const double kLyricsLineSpacingMax = 48;
