package dev.naominet.lazer

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.BlurEffect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlin.math.min
import kotlin.math.roundToLong

private val LyricShaderShadowRadius = 12.dp

@Composable
fun animatedLyricFocus(active: Boolean, speed: LyricAnimationSpeed): Float {
    val focus by animateFloatAsState(
        if (active) 1f else 0f,
        spring(dampingRatio = 1f, stiffness = (150 * speed.scrollMultiplier).toFloat()),
        label = "lyric focus",
    )
    return focus
}

/**
 * AMLL-style lyric renderer.
 *
 * BasicText performs shaping and line breaking once. The timed mask, character transforms, and
 * glow are then painted over that immutable layout, so animation can never change row height.
 */
@Composable
fun AmllLyricText(
    text: String,
    words: List<TimedLyricWord>,
    positionMillis: Long,
    active: Boolean,
    currentLine: Boolean = active,
    color: Color,
    shadowColor: Color = Color.Black,
    speed: LyricAnimationSpeed,
    modifier: Modifier = Modifier,
    style: TextStyle = TextStyle.Default,
    textAlign: TextAlign? = null,
    maxLines: Int = Int.MAX_VALUE,
    overflow: TextOverflow = TextOverflow.Clip,
) {
    var layoutResult by remember(text, style, textAlign, maxLines, overflow) {
        mutableStateOf<TextLayoutResult?>(null)
    }
    val glyphs = remember(text, words) { buildTimedLyricGlyphs(text, words) }
    val animatedPosition by animateFloatAsState(
        targetValue = positionMillis.toFloat(),
        animationSpec = tween(
            durationMillis = lyricWordSmoothingMillis(speed),
            easing = LinearEasing,
        ),
        label = "AMLL lyric clock",
    )
    val effectStrength by animateFloatAsState(
        targetValue = if (active) 1f else 0f,
        animationSpec = tween(durationMillis = 300, easing = FastOutSlowInEasing),
        label = "AMLL lyric effect",
    )
    val lineFocus by animateFloatAsState(
        targetValue = if (currentLine) 1f else 0f,
        animationSpec = tween(durationMillis = 300, easing = FastOutSlowInEasing),
        label = "AMLL lyric shadow",
    )
    val alignedStyle = style.merge(
        TextStyle(textAlign = textAlign ?: TextAlign.Unspecified),
    )
    val layoutStyle = alignedStyle.merge(TextStyle(color = Color.Transparent))
    val laidOutGlyphs = remember(layoutResult, glyphs, words) {
        layoutResult?.let { buildLaidOutGlyphs(it, glyphs, words.size) }.orEmpty()
    }

    Box(modifier) {
        Box(
            Modifier
                .matchParentSize()
                .graphicsLayer {
                    val radius = LyricShaderShadowRadius.toPx()
                    compositingStrategy = CompositingStrategy.Offscreen
                    clip = false
                    alpha = 0.5f * lineFocus
                    renderEffect = if (lineFocus > 0.001f) {
                        BlurEffect(radius, radius, TileMode.Decal)
                    } else {
                        null
                    }
                }
                .drawBehind {
                    if (lineFocus <= 0.001f) return@drawBehind
                    val measured = layoutResult ?: return@drawBehind
                    drawLyricShaderShadow(
                        layout = measured,
                        glyphs = laidOutGlyphs,
                        words = words,
                        positionMillis = animatedPosition.roundToLong(),
                        speed = speed,
                        shadowColor = shadowColor,
                    )
                }
                .clearAndSetSemantics { },
        )
        BasicText(
            text = text,
            modifier = Modifier.fillMaxWidth().drawWithContent {
                val measured = layoutResult
                if (measured == null) {
                    drawContent()
                } else if (words.isEmpty() || laidOutGlyphs.none { it.timing.wordIndex >= 0 }) {
                    drawText(measured, color = color)
                } else if (!active && effectStrength <= 0.001f) {
                    drawText(measured, color = color)
                } else {
                    drawAmllGlyphs(
                        layout = measured,
                        glyphs = laidOutGlyphs,
                        words = words,
                        positionMillis = animatedPosition.roundToLong(),
                        color = color,
                        speed = speed,
                        effectStrength = effectStrength,
                    )
                }
            },
            style = layoutStyle,
            overflow = overflow,
            maxLines = maxLines,
            onTextLayout = { result ->
                if (layoutResult != result) layoutResult = result
            },
        )
    }
}

private data class LaidOutLyricGlyph(
    val timing: TimedLyricGlyph,
    val bounds: Rect,
    val startInWord: Float,
    val wordWidth: Float,
)

private fun buildLaidOutGlyphs(
    layout: TextLayoutResult,
    glyphs: List<TimedLyricGlyph>,
    wordCount: Int,
): List<LaidOutLyricGlyph> {
    data class Partial(val timing: TimedLyricGlyph, val bounds: Rect, val start: Float)

    val wordWidths = FloatArray(wordCount)
    val partials = buildList {
        for (glyph in glyphs) {
            if (!glyph.isVisible || glyph.startOffset >= layout.layoutInput.text.length) continue
            val bounds = layout.getBoundingBox(glyph.startOffset)
            if (bounds.width <= 0.01f || bounds.height <= 0.01f) continue
            val startInWord = if (glyph.wordIndex >= 0) wordWidths[glyph.wordIndex] else 0f
            if (glyph.wordIndex >= 0) wordWidths[glyph.wordIndex] += bounds.width
            add(Partial(timing = glyph, bounds = bounds, start = startInWord))
        }
    }
    return partials.map { partial ->
        LaidOutLyricGlyph(
            timing = partial.timing,
            bounds = partial.bounds,
            startInWord = partial.start,
            wordWidth = wordWidths.getOrElse(partial.timing.wordIndex) { 0f },
        )
    }
}

private fun DrawScope.drawLyricShaderShadow(
    layout: TextLayoutResult,
    glyphs: List<LaidOutLyricGlyph>,
    words: List<TimedLyricWord>,
    positionMillis: Long,
    speed: LyricAnimationSpeed,
    shadowColor: Color,
) {
    drawRect(color = Color.Transparent, blendMode = BlendMode.Clear)
    if (words.isEmpty() || glyphs.none { it.timing.wordIndex >= 0 }) {
        drawText(textLayoutResult = layout, color = shadowColor)
        return
    }
    for (clip in lineScanClips(layout, glyphs, words, positionMillis, speed)) {
        clipRect(clip.left, clip.top, clip.right, clip.bottom) {
            drawText(textLayoutResult = layout, color = shadowColor)
        }
    }
}

private fun lineScanClips(
    layout: TextLayoutResult,
    glyphs: List<LaidOutLyricGlyph>,
    words: List<TimedLyricWord>,
    positionMillis: Long,
    speed: LyricAnimationSpeed,
): List<Rect> {
    val timed = glyphs.filter { it.timing.wordIndex >= 0 }.sortedBy { it.timing.startOffset }
    if (timed.isEmpty()) return emptyList()
    val current = currentLyricWordIndex(words, positionMillis)
    if (current < 0) return emptyList()
    val progress = lyricWordVisualProgress(words[current], positionMillis, speed).coerceIn(0f, 1f)
    val wordWidths = FloatArray(words.size)
    for (glyph in timed) {
        val index = glyph.timing.wordIndex
        if (index in wordWidths.indices) wordWidths[index] = glyph.wordWidth
    }
    var target = 0f
    for (index in 0 until current) target += wordWidths[index]
    target += wordWidths.getOrElse(current) { 0f } * progress

    val clips = ArrayList<Rect>(timed.size)
    var traveled = 0f
    for (glyph in timed) {
        val clip = glyphLineClip(layout, glyph)
        val width = clip.width
        if (width <= 0.01f) continue
        when {
            traveled + width <= target + 0.01f -> {
                clips += clip
                traveled += width
            }
            traveled < target -> {
                clips += Rect(clip.left, clip.top, min(clip.left + (target - traveled), clip.right), clip.bottom)
                break
            }
            else -> break
        }
    }
    return clips
}

private fun glyphLineClip(layout: TextLayoutResult, glyph: LaidOutLyricGlyph): Rect {
    val line = layout.getLineForOffset(glyph.timing.startOffset)
    return Rect(
        left = glyph.bounds.left,
        top = layout.getLineTop(line),
        right = glyph.bounds.right,
        bottom = layout.getLineBottom(line),
    )
}

private fun DrawScope.drawAmllGlyphs(
    layout: TextLayoutResult,
    glyphs: List<LaidOutLyricGlyph>,
    words: List<TimedLyricWord>,
    positionMillis: Long,
    color: Color,
    speed: LyricAnimationSpeed,
    effectStrength: Float,
) {
    val effect = effectStrength.coerceIn(0f, 1f)
    val dimColor = color.copy(alpha = color.alpha * (1f - effect * (1f - lyricBaseMaskAlpha())))
    drawText(textLayoutResult = layout, color = dimColor)
    for (clip in lineScanClips(layout, glyphs, words, positionMillis, speed)) {
        clipRect(clip.left, clip.top, clip.right, clip.bottom) {
            drawText(textLayoutResult = layout, color = color)
        }
    }
}
