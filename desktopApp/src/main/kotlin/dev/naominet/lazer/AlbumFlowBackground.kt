package dev.naominet.lazer

import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.Easing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.Dp
import kotlinx.coroutines.isActive
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

private const val FlowFrameIntervalNanos = 33_333_333L

private val FluidPaletteEasing = Easing { fraction ->
    ((1.0 - cos(PI * fraction.coerceIn(0f, 1f))) * 0.5).toFloat()
}

/**
 * Album-art color flow for the full lyric page.
 *
 * It keeps the useful renderer ideas from applemusic-like-lyrics (one time axis,
 * low-resolution album-derived color state, capped refresh rate and eased state
 * crossfades) without constructing or redrawing a triangle mesh. The continuous
 * motion only updates retained layer transforms, keeping lyric scrolling cheap.
 */
@Composable
internal fun AlbumFlowBackground(
    colors: List<Color>,
    modifier: Modifier = Modifier,
    cornerRadius: Dp,
    veil: Color,
) {
    val palette = remember(colors) { normalizeFlowPalette(colors) }
    var phaseSeconds by remember { mutableFloatStateOf(0f) }

    LaunchedEffect(Unit) {
        var lastPublishedNs = 0L
        while (isActive) {
            withFrameNanos { now ->
                if (lastPublishedNs == 0L) {
                    lastPublishedNs = now
                } else if (now - lastPublishedNs >= FlowFrameIntervalNanos) {
                    val elapsedSeconds = ((now - lastPublishedNs) / 1_000_000_000.0)
                        .toFloat()
                        .coerceAtMost(0.1f)
                    lastPublishedNs = now
                    phaseSeconds = (phaseSeconds + elapsedSeconds) % 10_000f
                }
            }
        }
    }

    Box(
        modifier
            .clip(RoundedCornerShape(cornerRadius))
            .background(palette[4]),
    ) {
        // Like the reference renderer's album-state stack, retain the outgoing palette
        // briefly and blend the incoming one with a non-linear curve when a song changes.
        Crossfade(
            targetState = palette,
            animationSpec = tween(durationMillis = 650, easing = FluidPaletteEasing),
            label = "lyric-flow-palette",
        ) { activePalette ->
            Box(Modifier.fillMaxSize()) {
                FlowPaletteLayers(activePalette) { phaseSeconds }
            }
        }

        // The reference renderer finishes with a vignette. Here it also keeps light album
        // colors behind the lyric text readable in both themes.
        Box(
            Modifier
                .fillMaxSize()
                .background(
                    Brush.radialGradient(
                        colors = listOf(
                            Color.Transparent,
                            veil.copy(alpha = veil.alpha * 0.28f),
                            veil.copy(alpha = veil.alpha * 0.72f),
                        ),
                    ),
                ),
        )
        Box(Modifier.fillMaxSize().background(veil.copy(alpha = veil.alpha * 0.72f)))
    }
}

@Composable
private fun BoxScope.FlowPaletteLayers(
    palette: List<Color>,
    phaseSeconds: () -> Float,
) {
    FlowLayer(
        color = palette[0],
        phaseSeconds = phaseSeconds,
        phaseOffset = 0.2f,
        speed = 0.19f,
        orbitX = 0.30f,
        orbitY = 0.24f,
        scaleX = 1.68f,
        scaleY = 1.18f,
        rotationRange = 8f,
    )
    FlowLayer(
        color = palette[1],
        phaseSeconds = phaseSeconds,
        phaseOffset = 2.1f,
        speed = 0.145f,
        orbitX = 0.25f,
        orbitY = 0.34f,
        scaleX = 1.34f,
        scaleY = 1.58f,
        rotationRange = -10f,
    )
    FlowLayer(
        color = palette[2],
        phaseSeconds = phaseSeconds,
        phaseOffset = 4.0f,
        speed = 0.17f,
        orbitX = 0.37f,
        orbitY = 0.20f,
        scaleX = 1.52f,
        scaleY = 1.26f,
        rotationRange = 7f,
    )
    FlowLayer(
        color = palette[3],
        phaseSeconds = phaseSeconds,
        phaseOffset = 5.35f,
        speed = 0.12f,
        orbitX = 0.20f,
        orbitY = 0.38f,
        scaleX = 1.28f,
        scaleY = 1.62f,
        rotationRange = -6f,
    )
    FlowLayer(
        color = palette[4],
        phaseSeconds = phaseSeconds,
        phaseOffset = 1.25f,
        speed = 0.105f,
        orbitX = 0.16f,
        orbitY = 0.18f,
        scaleX = 1.85f,
        scaleY = 1.12f,
        rotationRange = 5f,
        colorAlpha = 0.52f,
    )
}

@Composable
private fun BoxScope.FlowLayer(
    color: Color,
    phaseSeconds: () -> Float,
    phaseOffset: Float,
    speed: Float,
    orbitX: Float,
    orbitY: Float,
    scaleX: Float,
    scaleY: Float,
    rotationRange: Float,
    colorAlpha: Float = 0.68f,
) {
    val brush = remember(color, colorAlpha) {
        Brush.radialGradient(
            colors = listOf(
                color.copy(alpha = colorAlpha),
                color.copy(alpha = colorAlpha * 0.56f),
                color.copy(alpha = colorAlpha * 0.16f),
                Color.Transparent,
            ),
        )
    }
    Box(
        Modifier
            .fillMaxSize()
            .graphicsLayer {
                val time = phaseSeconds() * speed + phaseOffset
                val secondaryTime = phaseSeconds() * speed * 0.73f + phaseOffset * 1.37f
                translationX = sin(time.toDouble()).toFloat() * size.width * orbitX
                translationY = cos(secondaryTime.toDouble()).toFloat() * size.height * orbitY
                val pulse = sin((time * 0.61f).toDouble()).toFloat() * 0.075f
                this.scaleX = scaleX + pulse
                this.scaleY = scaleY - pulse * 0.72f
                rotationZ = sin((time * 0.43f).toDouble()).toFloat() * rotationRange
            }
            .background(brush),
    )
}

private fun normalizeFlowPalette(colors: List<Color>): List<Color> {
    val source = colors.ifEmpty { CoverPalette.defaultFlow }
    return List(5) { index -> source[index % source.size] }
}
