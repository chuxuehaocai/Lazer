package dev.naominet.lazer

import kotlin.math.pow
import kotlin.math.roundToInt

/** One word (or syllable) inside a YRC lyric line. Times are absolute within the track. */
data class TimedLyricWord(
    val startTimeMillis: Long,
    val durationMillis: Long,
    val text: String,
)

data class ParsedWordLyricLine(
    val timeMillis: Long,
    val durationMillis: Long,
    val text: String,
    val words: List<TimedLyricWord>,
)

enum class LyricAnimationSpeed(
    private val labelKey: String,
    internal val scrollMultiplier: Double,
    internal val highlightExponent: Double,
) {
    VERY_RELAXED("lyric.speed.very_relaxed", 0.55, 1.45),
    RELAXED("lyric.speed.relaxed", 0.72, 1.25),
    GENTLE("lyric.speed.gentle", 0.86, 1.12),
    STANDARD("lyric.speed.standard", 1.0, 1.0),
    BRISK("lyric.speed.brisk", 1.18, 0.9),
    RESPONSIVE("lyric.speed.responsive", 1.38, 0.78),
    VERY_RESPONSIVE("lyric.speed.very_responsive", 1.65, 0.68);

    val label: String get() = tr(labelKey)
}

fun parseLyricAnimationSpeed(value: String?): LyricAnimationSpeed =
    LyricAnimationSpeed.entries.firstOrNull { it.name == value } ?: LyricAnimationSpeed.STANDARD

fun lyricScrollApproachCoefficient(speed: LyricAnimationSpeed): Double = 11.0 * speed.scrollMultiplier

private val YrcLinePattern = Regex("""^\[(\d+),(\d+)](.*)$""")
private val YrcWordPattern = Regex("""\((\d+),(\d+),(\d+)\)(.*?)(?=\(\d+,\d+,\d+\)|$)""")

/** Parses the documented `/lyric/new` YRC representation. Invalid metadata rows are ignored. */
fun parseWordLyrics(yrc: String?): List<ParsedWordLyricLine> {
    if (yrc.isNullOrBlank()) return emptyList()
    return buildList {
        yrc.lineSequence().forEach { rawLine ->
            val lineMatch = YrcLinePattern.matchEntire(rawLine.trim()) ?: return@forEach
            val lineStart = lineMatch.groupValues[1].toLongOrNull() ?: return@forEach
            val lineDuration = lineMatch.groupValues[2].toLongOrNull() ?: return@forEach
            val body = lineMatch.groupValues[3]
            val words = YrcWordPattern.findAll(body).mapNotNull { wordMatch ->
                val start = wordMatch.groupValues[1].toLongOrNull() ?: return@mapNotNull null
                val duration = wordMatch.groupValues[2].toLongOrNull() ?: return@mapNotNull null
                val text = wordMatch.groupValues[4]
                text.takeIf(String::isNotEmpty)?.let {
                    TimedLyricWord(start, duration.coerceAtLeast(1L), it)
                }
            }.toList()
            if (words.isNotEmpty()) {
                add(
                    ParsedWordLyricLine(
                        timeMillis = lineStart,
                        durationMillis = lineDuration,
                        text = words.joinToString(separator = "", transform = TimedLyricWord::text),
                        words = words,
                    ),
                )
            }
        }
    }.sortedBy(ParsedWordLyricLine::timeMillis)
}

/** Character offset used by Compose to paint the elapsed portion of the active lyric line. */
fun lyricHighlightCharacterCount(
    words: List<TimedLyricWord>,
    positionMillis: Long,
    speed: LyricAnimationSpeed,
): Int {
    var count = 0
    for (word in words) {
        when {
            positionMillis >= word.startTimeMillis + word.durationMillis -> count += word.text.length
            positionMillis <= word.startTimeMillis -> return count
            else -> {
                val rawProgress = (positionMillis - word.startTimeMillis).toDouble() / word.durationMillis
                val eased = rawProgress.coerceIn(0.0, 1.0).pow(speed.highlightExponent)
                return count + (word.text.length * eased).roundToInt().coerceIn(0, word.text.length)
            }
        }
    }
    return count
}
