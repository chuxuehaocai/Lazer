package dev.naominet.lazer

import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sqrt

private const val AMLL_BASE_MASK_ALPHA = 0.40f

/**
 * Stateless fallback retained for callers that only need a single eased value. Lyrics pages use
 * [LyricLineMotionField], which keeps velocity and gives each visible row its own delayed spring.
 */
fun nextLyricScrollPosition(
    position: Float,
    target: Float,
    seconds: Float,
    speed: LyricAnimationSpeed,
): Float {
    val distance = target - position
    if (abs(distance) <= 0.05f) return target
    val deltaSeconds = seconds.coerceIn(0f, 0.05f)
    val approach = (1.0 - exp(-lyricScrollApproachCoefficient(speed) * deltaSeconds)).toFloat()
    return position + distance * approach
}

internal data class LyricScrollSpringParameters(
    val mass: Float,
    val stiffness: Float,
    val damping: Float,
)

/** AMLL's vertical spring policy, including the interval-dependent stiffness curve. */
internal fun lyricScrollSpringParameters(
    intervalMillis: Long?,
    speed: LyricAnimationSpeed,
): LyricScrollSpringParameters {
    val baseStiffness = if (intervalMillis == null) {
        90f
    } else {
        val interval = intervalMillis.coerceIn(100L, 800L).toFloat()
        val ratio = (1f - (interval - 100f) / 700f).pow(0.2f)
        170f + ratio * 50f
    }
    val stiffness = baseStiffness * speed.scrollMultiplier.toFloat().pow(1.2f)
    return LyricScrollSpringParameters(
        mass = 0.9f,
        stiffness = stiffness,
        damping = sqrt(stiffness) * 2.2f,
    )
}

/**
 * One persistent spring per lyric row. A target change is released from top to bottom with AMLL's
 * roughly 50 ms stagger, so the lyrics no longer move as one rigid, linearly translated sheet.
 */
class LyricLineMotionField {
    private var positions = FloatArray(0)
    private var velocities = FloatArray(0)
    private var delays = FloatArray(0)
    private var targetPosition = 0f

    fun reset(lineCount: Int, position: Float) {
        positions = FloatArray(lineCount.coerceAtLeast(0)) { position }
        velocities = FloatArray(positions.size)
        delays = FloatArray(positions.size)
        targetPosition = position
    }

    fun snapTo(position: Float) {
        targetPosition = position
        positions.fill(position)
        velocities.fill(0f)
        delays.fill(0f)
    }

    fun positionFor(index: Int): Float = positions.getOrElse(index) { targetPosition }

    fun advance(
        target: Float,
        activeIndex: Int,
        seconds: Float,
        intervalMillis: Long?,
        speed: LyricAnimationSpeed,
    ): Boolean {
        if (positions.isEmpty()) return false
        if (abs(target - targetPosition) > 0.01f) {
            targetPosition = target
            scheduleCascade(activeIndex, speed)
        }

        val params = lyricScrollSpringParameters(intervalMillis, speed)
        val frameSeconds = seconds.coerceIn(0f, 0.05f)
        var moving = false
        for (index in positions.indices) {
            var availableSeconds = frameSeconds
            if (delays[index] > 0f) {
                val consumed = min(delays[index], availableSeconds)
                delays[index] -= consumed
                availableSeconds -= consumed
                moving = true
            }
            if (availableSeconds > 0f) {
                integrate(index, availableSeconds, params)
            }
            val distance = targetPosition - positions[index]
            if (abs(distance) < 0.02f && abs(velocities[index]) < 0.02f && delays[index] <= 0f) {
                positions[index] = targetPosition
                velocities[index] = 0f
            } else {
                moving = true
            }
        }
        return moving
    }

    private fun scheduleCascade(activeIndex: Int, speed: LyricAnimationSpeed) {
        val firstVisibleApproximation = (activeIndex - 3).coerceAtLeast(0)
        for (index in delays.indices) {
            val step = (index - firstVisibleApproximation).coerceIn(0, 7)
            var delay = 0f
            repeat(step) { delayStep ->
                val decayStep = (delayStep - 3).coerceAtLeast(0)
                delay += 0.05f / 1.05f.pow(decayStep)
            }
            delays[index] = delay / speed.scrollMultiplier.toFloat()
        }
    }

    private fun integrate(
        index: Int,
        seconds: Float,
        params: LyricScrollSpringParameters,
    ) {
        val steps = ceil(seconds / (1f / 120f)).toInt().coerceAtLeast(1)
        val stepSeconds = seconds / steps
        repeat(steps) {
            val displacement = targetPosition - positions[index]
            val acceleration =
                (params.stiffness * displacement - params.damping * velocities[index]) / params.mass
            velocities[index] += acceleration * stepSeconds
            positions[index] += velocities[index] * stepSeconds
        }
    }
}

/** Fractional progress keeps a long syllable moving throughout its source duration. */
fun lyricWordProgress(word: TimedLyricWord, positionMillis: Long): Float =
    ((positionMillis - word.startTimeMillis).toDouble() / word.durationMillis.coerceAtLeast(1L))
        .coerceIn(0.0, 1.0).toFloat()

/**
 * A forgiving visual clock around the source timestamp. Its overlap lets neighbouring syllables
 * share the moving fade edge without changing the lyric line selected by the playback clock.
 */
fun lyricWordVisualProgress(
    word: TimedLyricWord,
    positionMillis: Long,
    speed: LyricAnimationSpeed,
): Float {
    val leadMillis = 70.0 / speed.scrollMultiplier
    val tailMillis = 150.0 / speed.scrollMultiplier
    val visualStart = word.startTimeMillis.toDouble() - leadMillis
    val visualDuration = word.durationMillis.coerceAtLeast(1L) + leadMillis + tailMillis
    val rawProgress = ((positionMillis - visualStart) / visualDuration).coerceIn(0.0, 1.0)
    return rawProgress.pow(speed.highlightExponent).toFloat()
}

/** Exact AMLL mask geometry: the fade band is half a glyph-height wide. */
internal fun lyricMaskForegroundAlpha(
    wordProgress: Float,
    pointInWordPixels: Float,
    wordWidthPixels: Float,
    fadeWidthPixels: Float,
): Float {
    val fadeWidth = fadeWidthPixels.coerceAtLeast(0.01f)
    val transitionEnd =
        wordProgress.coerceIn(0f, 1f) * (wordWidthPixels.coerceAtLeast(0f) + fadeWidth)
    return ((transitionEnd - pointInWordPixels) / fadeWidth).coerceIn(0f, 1f)
}

internal fun lyricBaseMaskAlpha(): Float = AMLL_BASE_MASK_ALPHA

fun lyricWordSmoothingMillis(speed: LyricAnimationSpeed): Int =
    (96.0 / speed.scrollMultiplier).roundToInt().coerceIn(56, 180)

internal data class AmllCharacterMotion(
    val scale: Float,
    val offsetXEm: Float,
    val offsetYEm: Float,
    val glowAlpha: Float,
    val glowRadiusEm: Float,
)

/** AMLL's character emphasis: bell-shaped scale, outward spread, lift, and soft white glow. */
internal fun amllCharacterMotion(
    word: TimedLyricWord,
    positionMillis: Long,
    characterIndex: Int,
    characterCount: Int,
    isLastWord: Boolean,
    speed: LyricAnimationSpeed,
): AmllCharacterMotion {
    val count = characterCount.coerceAtLeast(1)
    var duration = max(1_000f, word.durationMillis.toFloat())
    var amount = duration / 2_000f
    amount = if (amount > 1f) sqrt(amount) else amount.pow(3)
    var blur = duration / 3_000f
    blur = if (blur > 1f) sqrt(blur) else blur.pow(3)
    amount *= 0.6f
    blur *= 0.5f
    if (isLastWord) {
        amount *= 1.6f
        blur *= 1.5f
        duration *= 1.2f
    }
    amount = min(1.2f, amount)
    blur = min(0.8f, blur)

    val rate = speed.scrollMultiplier.toFloat()
    val visualDuration = duration / rate
    val delay = word.startTimeMillis + (visualDuration / 2.5f / count) * characterIndex
    val phase = ((positionMillis - delay) / visualDuration).coerceIn(0f, 1f)
    val emphasis = amllEmphasisEasing(phase)

    return AmllCharacterMotion(
        scale = 1f + emphasis * 0.1f * amount,
        offsetXEm = -emphasis * 0.03f * amount * (count / 2f - characterIndex),
        offsetYEm = amllWordFloatOffsetEm(word, positionMillis, speed) - emphasis * 0.025f * amount,
        glowAlpha = emphasis * blur,
        glowRadiusEm = min(0.3f, blur * 0.3f),
    )
}

internal fun amllWordFloatOffsetEm(
    word: TimedLyricWord,
    positionMillis: Long,
    speed: LyricAnimationSpeed,
): Float {
    val floatDuration = max(1_000f, word.durationMillis.toFloat()) / speed.scrollMultiplier.toFloat()
    val floatPhase = ((positionMillis - word.startTimeMillis) / floatDuration).coerceIn(0f, 1f)
    return -(1f - (1f - floatPhase).pow(3)) * 0.05f
}

internal fun shouldEmphasizeLyricWord(word: TimedLyricWord): Boolean {
    if (word.durationMillis < 1_000L) return false
    val trimmed = word.text.trim()
    if (trimmed.isEmpty()) return false
    return if (trimmed.any(::isCjkCharacter)) true else trimmed.length in 2..7
}

internal fun amllEmphasisEasing(value: Float): Float {
    val x = value.coerceIn(0f, 1f)
    return if (x < 0.5f) {
        cubicBezierEasing(x / 0.5f, 0.2f, 0.4f, 0.58f, 1f)
    } else {
        1f - cubicBezierEasing((x - 0.5f) / 0.5f, 0.3f, 0f, 0.58f, 1f)
    }
}

private fun cubicBezierEasing(x: Float, x1: Float, y1: Float, x2: Float, y2: Float): Float {
    var low = 0f
    var high = 1f
    repeat(14) {
        val t = (low + high) / 2f
        if (cubicBezierCoordinate(t, x1, x2) < x) low = t else high = t
    }
    return cubicBezierCoordinate((low + high) / 2f, y1, y2)
}

private fun cubicBezierCoordinate(t: Float, first: Float, second: Float): Float {
    val oneMinusT = 1f - t
    return 3f * oneMinusT * oneMinusT * t * first +
        3f * oneMinusT * t * t * second +
        t * t * t
}

private fun isCjkCharacter(character: Char): Boolean =
    character.code in 0x3400..0x9FFF || character.code in 0xF900..0xFAFF

internal data class TimedLyricGlyph(
    val startOffset: Int,
    val endOffset: Int,
    val wordIndex: Int,
    val indexInWord: Int,
    val characterCount: Int,
    val isVisible: Boolean,
)

/** Maps stable text-layout offsets to timed words while preserving emoji and combining sequences. */
internal fun buildTimedLyricGlyphs(
    text: String,
    words: List<TimedLyricWord>,
): List<TimedLyricGlyph> {
    if (text.isEmpty()) return emptyList()
    val wordRanges = mutableListOf<IntRange>()
    var cursor = 0
    for (word in words) {
        val found = text.indexOf(word.text, startIndex = cursor).takeIf { it >= 0 } ?: cursor
        val endExclusive = (found + word.text.length).coerceAtMost(text.length)
        wordRanges += found until endExclusive
        cursor = endExclusive
    }

    data class RawGlyph(val start: Int, val end: Int, val wordIndex: Int, val visible: Boolean)
    val raw = splitGraphemes(text).map { range ->
        val wordIndex = wordRanges.indexOfFirst { range.first >= it.first && range.last <= it.last }
        RawGlyph(
            start = range.first,
            end = range.last + 1,
            wordIndex = wordIndex,
            visible = text.substring(range.first, range.last + 1).isNotBlank(),
        )
    }
    val counts = IntArray(words.size)
    raw.forEach { if (it.wordIndex >= 0 && it.visible) counts[it.wordIndex]++ }
    val indexes = IntArray(words.size)
    return raw.map { glyph ->
        val indexInWord = if (glyph.wordIndex >= 0 && glyph.visible) indexes[glyph.wordIndex]++ else 0
        TimedLyricGlyph(
            startOffset = glyph.start,
            endOffset = glyph.end,
            wordIndex = glyph.wordIndex,
            indexInWord = indexInWord,
            characterCount = counts.getOrElse(glyph.wordIndex) { 0 },
            isVisible = glyph.visible,
        )
    }
}

private fun splitGraphemes(text: String): List<IntRange> = buildList {
    var start = 0
    while (start < text.length) {
        var end = nextCodePointEnd(text, start)
        val firstCodePoint = codePointAt(text, start)
        if (firstCodePoint in 0x1F1E6..0x1F1FF && end < text.length &&
            codePointAt(text, end) in 0x1F1E6..0x1F1FF
        ) {
            end = nextCodePointEnd(text, end)
        }
        while (end < text.length) {
            val codePoint = codePointAt(text, end)
            when {
                isCombiningCodePoint(codePoint) -> end = nextCodePointEnd(text, end)
                codePoint == 0x200D -> {
                    end = nextCodePointEnd(text, end)
                    if (end < text.length) end = nextCodePointEnd(text, end)
                }
                else -> break
            }
        }
        add(start until end)
        start = end
    }
}

private fun nextCodePointEnd(text: String, offset: Int): Int =
    offset + if (text[offset].isHighSurrogate() && offset + 1 < text.length && text[offset + 1].isLowSurrogate()) 2 else 1

private fun codePointAt(text: String, offset: Int): Int {
    val first = text[offset]
    if (!first.isHighSurrogate() || offset + 1 >= text.length) return first.code
    val second = text[offset + 1]
    if (!second.isLowSurrogate()) return first.code
    return 0x10000 + ((first.code - 0xD800) shl 10) + (second.code - 0xDC00)
}

private fun isCombiningCodePoint(codePoint: Int): Boolean =
    codePoint in 0x0300..0x036F ||
        codePoint in 0x1AB0..0x1AFF ||
        codePoint in 0x1DC0..0x1DFF ||
        codePoint in 0x20D0..0x20FF ||
        codePoint in 0xFE00..0xFE0F ||
        codePoint in 0xFE20..0xFE2F ||
        codePoint in 0x1F3FB..0x1F3FF ||
        codePoint in 0xE0100..0xE01EF
