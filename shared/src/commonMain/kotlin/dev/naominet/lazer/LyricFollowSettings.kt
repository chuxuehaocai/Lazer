package dev.naominet.lazer

/** Default pause after manual lyric scrolling before playback following resumes. */
const val DEFAULT_LYRIC_FOLLOW_DELAY_MILLIS: Long = 3_500L

const val MIN_LYRIC_FOLLOW_DELAY_MILLIS: Long = 500L
const val MAX_LYRIC_FOLLOW_DELAY_MILLIS: Long = 5_000L
const val LYRIC_FOLLOW_DELAY_STEP_MILLIS: Long = 500L

/** Half-second choices shared by desktop and mobile settings. */
val LYRIC_FOLLOW_DELAY_OPTIONS_MILLIS: List<Long> =
    (MIN_LYRIC_FOLLOW_DELAY_MILLIS..MAX_LYRIC_FOLLOW_DELAY_MILLIS step LYRIC_FOLLOW_DELAY_STEP_MILLIS).toList()

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
    value % 1_000L == 0L -> tr("lyric.follow.seconds", value / 1_000L)
    else -> tr("lyric.follow.seconds", value / 1_000.0)
}
