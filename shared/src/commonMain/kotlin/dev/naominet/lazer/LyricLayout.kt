package dev.naominet.lazer

/** User-facing lyric size range shared by desktop and Android settings. */
const val MIN_LYRIC_FONT_SIZE_SP: Int = 22
const val MAX_LYRIC_FONT_SIZE_SP: Int = 44
const val LYRIC_FONT_SIZE_STEP_SP: Int = 2
const val DEFAULT_DESKTOP_LYRIC_FONT_SIZE_SP: Int = 34
const val DEFAULT_ANDROID_LYRIC_FONT_SIZE_SP: Int = 28

val LYRIC_FONT_SIZE_OPTIONS_SP: List<Int> =
    (MIN_LYRIC_FONT_SIZE_SP..MAX_LYRIC_FONT_SIZE_SP step LYRIC_FONT_SIZE_STEP_SP).toList()

fun normalizeLyricFontSizeSp(value: Int): Int {
    val boundedValue = value.coerceIn(MIN_LYRIC_FONT_SIZE_SP, MAX_LYRIC_FONT_SIZE_SP)
    return LYRIC_FONT_SIZE_OPTIONS_SP.minBy { option -> kotlin.math.abs(option - boundedValue) }
}

fun lyricFontSizeLabel(value: Int): String = tr("lyric.font.size", normalizeLyricFontSizeSp(value))

/**
 * Calculates the center of every lyric row from the actual measured height of adjacent rows.
 *
 * The first center is the scroll origin. Every following center includes half of the previous
 * row, a proportional breathing gap, and half of the next row. Tall wrapped or translated lines
 * therefore make room for themselves without imposing a fixed pitch on short lines.
 */
fun lyricLineCenters(
    rowHeightsPx: List<Float>,
    minimumGapPx: Float,
    maximumGapPx: Float,
    gapRatio: Float = 0.10f,
): FloatArray {
    if (rowHeightsPx.isEmpty()) return FloatArray(0)
    require(minimumGapPx >= 0f) { "minimumGapPx must not be negative" }
    require(maximumGapPx >= minimumGapPx) { "maximumGapPx must be at least minimumGapPx" }
    require(gapRatio >= 0f) { "gapRatio must not be negative" }

    val heights = rowHeightsPx.map { it.takeIf(Float::isFinite)?.coerceAtLeast(1f) ?: 1f }
    return FloatArray(heights.size).also { centers ->
        for (index in 1 until heights.size) {
            val previousHeight = heights[index - 1]
            val currentHeight = heights[index]
            val gap = ((previousHeight + currentHeight) * gapRatio)
                .coerceIn(minimumGapPx, maximumGapPx)
            centers[index] = centers[index - 1] + previousHeight / 2f + gap + currentHeight / 2f
        }
    }
}

/** A translation moves farther from the original as the original wraps onto more lines. */
fun lyricTranslationGapPx(
    mainLyricHeightPx: Float,
    minimumGapPx: Float,
    maximumGapPx: Float,
): Float = (mainLyricHeightPx.coerceAtLeast(1f) * 0.18f)
    .coerceIn(minimumGapPx, maximumGapPx)

/**
 * Vertical rhythm for the lyric page, derived from the rendered main line height instead of fixed
 * dp. Enlarging the lyric font therefore widens the breathing room between rows and translations
 * proportionally, and shrinking it tightens the page the same way.
 */
data class LyricSpacing(
    val minimumRowGapPx: Float,
    val maximumRowGapPx: Float,
    val minimumTranslationGapPx: Float,
    val maximumTranslationGapPx: Float,
)

fun lyricSpacing(mainLineHeightPx: Float): LyricSpacing {
    val height = mainLineHeightPx.takeIf(Float::isFinite)?.coerceAtLeast(1f) ?: 1f
    return LyricSpacing(
        minimumRowGapPx = height * 0.32f,
        maximumRowGapPx = height * 0.95f,
        minimumTranslationGapPx = height * 0.18f,
        maximumTranslationGapPx = height * 0.55f,
    )
}

/** Fractional row index nearest to [scrollPx], used for quiet distance-based fading. */
fun lyricVisualIndex(centersPx: FloatArray, scrollPx: Float): Float {
    if (centersPx.isEmpty()) return 0f
    if (scrollPx <= centersPx.first()) return 0f
    if (scrollPx >= centersPx.last()) return centersPx.lastIndex.toFloat()

    var lower = 0
    var upper = centersPx.lastIndex
    while (lower + 1 < upper) {
        val middle = (lower + upper) ushr 1
        if (centersPx[middle] <= scrollPx) lower = middle else upper = middle
    }
    val span = (centersPx[upper] - centersPx[lower]).coerceAtLeast(1f)
    return lower + (scrollPx - centersPx[lower]) / span
}
