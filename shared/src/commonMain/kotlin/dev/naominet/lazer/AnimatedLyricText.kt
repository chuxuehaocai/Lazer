package dev.naominet.lazer

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToLong

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
    color: Color,
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
    val layoutStyle = style.merge(
        TextStyle(
            color = Color.Transparent,
            textAlign = textAlign ?: TextAlign.Unspecified,
        ),
    )
    val laidOutGlyphs = remember(layoutResult, glyphs, words) {
        layoutResult?.let { buildLaidOutGlyphs(it, glyphs, words.size) }.orEmpty()
    }

    BasicText(
        text = text,
        modifier = modifier.drawWithContent {
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

private data class LaidOutLyricGlyph(
    val timing: TimedLyricGlyph,
    val bounds: Rect,
    val path: Path,
    val startInWord: Float,
    val wordWidth: Float,
)

private fun buildLaidOutGlyphs(
    layout: TextLayoutResult,
    glyphs: List<TimedLyricGlyph>,
    wordCount: Int,
): List<LaidOutLyricGlyph> {
    data class Partial(val timing: TimedLyricGlyph, val bounds: Rect, val path: Path, val start: Float)

    val wordWidths = FloatArray(wordCount)
    val partials = buildList {
        for (glyph in glyphs) {
            if (!glyph.isVisible || glyph.startOffset >= layout.layoutInput.text.length) continue
            val bounds = layout.getBoundingBox(glyph.startOffset)
            if (bounds.width <= 0.01f || bounds.height <= 0.01f) continue
            val startInWord = if (glyph.wordIndex >= 0) wordWidths[glyph.wordIndex] else 0f
            if (glyph.wordIndex >= 0) wordWidths[glyph.wordIndex] += bounds.width
            add(
                Partial(
                    timing = glyph,
                    bounds = bounds,
                    path = layout.getPathForRange(glyph.startOffset, glyph.endOffset),
                    start = startInWord,
                ),
            )
        }
    }
    return partials.map { partial ->
        LaidOutLyricGlyph(
            timing = partial.timing,
            bounds = partial.bounds,
            path = partial.path,
            startInWord = partial.start,
            wordWidth = wordWidths.getOrElse(partial.timing.wordIndex) { 0f },
        )
    }
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
    for (laidOutGlyph in glyphs) {
        val glyph = laidOutGlyph.timing
        val bounds = laidOutGlyph.bounds
        val path = laidOutGlyph.path
        val word = words.getOrNull(glyph.wordIndex)
        val shouldEmphasize = word?.let(::shouldEmphasizeLyricWord) == true
        val motion = when {
            word == null -> AmllCharacterMotion(1f, 0f, 0f, 0f, 0f)
            shouldEmphasize -> amllCharacterMotion(
                word = word,
                positionMillis = positionMillis,
                characterIndex = glyph.indexInWord,
                characterCount = glyph.characterCount,
                isLastWord = glyph.wordIndex == words.lastIndex,
                speed = speed,
            )
            else -> AmllCharacterMotion(
                scale = 1f,
                offsetXEm = 0f,
                offsetYEm = amllWordFloatOffsetEm(word, positionMillis, speed),
                glowAlpha = 0f,
                glowRadiusEm = 0f,
            )
        }
        val emPixels = max(bounds.height, 1f)
        val scale = 1f + (motion.scale - 1f) * effect
        val offsetX = motion.offsetXEm * emPixels * effect
        val offsetY = motion.offsetYEm * emPixels * effect
        val pivot = bounds.center

        if (motion.glowAlpha * effect > 0.001f && motion.glowRadiusEm > 0f) {
            val blurPixels = motion.glowRadiusEm * emPixels
            withTransform({
                translate(offsetX, offsetY)
                scale(scale, scale, pivot)
            }) {
                clipRect(
                    left = bounds.left - blurPixels * 2f,
                    top = bounds.top - blurPixels * 2f,
                    right = bounds.right + blurPixels * 2f,
                    bottom = bounds.bottom + blurPixels * 2f,
                ) {
                    drawText(
                        textLayoutResult = layout,
                        color = Color.Transparent,
                        shadow = Shadow(
                            color = color.copy(alpha = color.alpha * motion.glowAlpha * effect),
                            offset = Offset.Zero,
                            blurRadius = blurPixels,
                        ),
                    )
                }
            }
        }

        withTransform({
            translate(offsetX, offsetY)
            scale(scale, scale, pivot)
        }) {
            clipPath(path) {
                if (word != null && glyph.characterCount > 0) {
                    val progress = lyricWordVisualProgress(word, positionMillis, speed)
                    val fadeWidth = bounds.height * 0.5f
                    val leftMask = lyricMaskForegroundAlpha(
                        wordProgress = progress,
                        pointInWordPixels = laidOutGlyph.startInWord,
                        wordWidthPixels = laidOutGlyph.wordWidth,
                        fadeWidthPixels = fadeWidth,
                    )
                    val rightMask = lyricMaskForegroundAlpha(
                        wordProgress = progress,
                        pointInWordPixels = laidOutGlyph.startInWord + bounds.width,
                        wordWidthPixels = laidOutGlyph.wordWidth,
                        fadeWidthPixels = fadeWidth,
                    )
                    val base = lyricBaseMaskAlpha()
                    val leftAlpha = 1f - effect * (1f - (base + (1f - base) * leftMask))
                    val rightAlpha = 1f - effect * (1f - (base + (1f - base) * rightMask))
                    val foreground: Brush = if (abs(leftAlpha - rightAlpha) < 0.001f) {
                        SolidColor(color.copy(alpha = color.alpha * leftAlpha))
                    } else {
                        Brush.horizontalGradient(
                            colors = listOf(
                                color.copy(alpha = color.alpha * leftAlpha),
                                color.copy(alpha = color.alpha * rightAlpha),
                            ),
                            startX = bounds.left,
                            endX = bounds.right,
                        )
                    }
                    drawText(textLayoutResult = layout, brush = foreground)
                } else {
                    drawText(textLayoutResult = layout, color = color)
                }
            }
        }
    }
}
