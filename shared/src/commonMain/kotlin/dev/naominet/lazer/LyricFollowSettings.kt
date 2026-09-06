package dev.naominet.lazer

/** Default pause after manual lyric scrolling before playback following resumes. */
const val DEFAULT_LYRIC_FOLLOW_DELAY_MILLIS: Long = 3_500L

/** Curated values shared by desktop and mobile settings. */
val LYRIC_FOLLOW_DELAY_OPTIONS_MILLIS: List<Long> = listOf(1_500L, 3_500L, 5_000L, 8_000L)

/** Keeps persisted or externally supplied values inside the supported range. */
fun normalizeLyricFollowDelayMillis(value: Long): Long {
    val boundedValue = value.coerceIn(
        LYRIC_FOLLOW_DELAY_OPTIONS_MILLIS.first(),
        LYRIC_FOLLOW_DELAY_OPTIONS_MILLIS.last(),
    )
    return LYRIC_FOLLOW_DELAY_OPTIONS_MILLIS.minBy { option ->
        kotlin.math.abs(option - boundedValue)
    }
}

/** Human-readable duration used by both settings surfaces. */
fun lyricFollowDelayLabel(value: Long): String = when {
    value % 1_000L == 0L -> "${value / 1_000L} 秒"
    else -> "${value / 1_000.0} 秒"
}
