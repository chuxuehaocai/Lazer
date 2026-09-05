package dev.naominet.lazer

/**
 * One timed lyric line. [timeMs] is the start offset within the track.
 */
data class TimedLyricLine(
    val timeMs: Long,
    val text: String,
)

private val LrcStampPattern = Regex("""\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?]""")

/**
 * Parses NetEase / standard LRC text into timed lines.
 * Supports multiple timestamps on one row: `[00:01.00][00:02.00]同一句`.
 */
internal fun parseLrc(lrc: String?): List<TimedLyricLine> {
    if (lrc.isNullOrBlank()) return emptyList()
    val lines = mutableListOf<TimedLyricLine>()
    for (raw in lrc.split('\n', '\r')) {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) continue
        val stamps = mutableListOf<Long>()
        var lastEnd = 0
        for (match in LrcStampPattern.findAll(trimmed)) {
            val min = match.groupValues[1].toIntOrNull() ?: continue
            val sec = match.groupValues[2].toIntOrNull() ?: continue
            val frac = match.groupValues[3]
            val ms = when {
                frac.isEmpty() -> 0
                frac.length == 1 -> frac.toInt() * 100
                frac.length == 2 -> frac.toInt() * 10
                else -> frac.take(3).padEnd(3, '0').take(3).toInt()
            }
            stamps += min * 60_000L + sec * 1_000L + ms
            lastEnd = match.range.last + 1
        }
        if (stamps.isEmpty()) continue
        val text = trimmed.substring(lastEnd).trim()
        if (text.isEmpty()) continue
        for (time in stamps) {
            lines += TimedLyricLine(time, text)
        }
    }
    return lines.sortedBy { it.timeMs }
}

/** Binary search: last line whose timeMs <= [positionMs], or -1. */
internal fun findCurrentLyricIndex(lines: List<TimedLyricLine>, positionMs: Long): Int {
    if (lines.isEmpty()) return -1
    var lo = 0
    var hi = lines.lastIndex
    var result = -1
    while (lo <= hi) {
        val mid = (lo + hi) ushr 1
        if (lines[mid].timeMs <= positionMs) {
            result = mid
            lo = mid + 1
        } else {
            hi = mid - 1
        }
    }
    return result
}
