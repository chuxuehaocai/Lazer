package dev.naominet.lazer

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.drawscope.ContentDrawScope
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.kashif_e.backdrop.backdrops.LayerBackdrop
import com.kashif_e.backdrop.backdrops.layerBackdrop
import com.kashif_e.backdrop.backdrops.rememberLayerBackdrop
import com.kashif_e.backdrop.drawBackdrop
import com.kashif_e.backdrop.effects.blur
import com.kashif_e.backdrop.effects.lens
import com.kashif_e.backdrop.effects.vibrancy
import com.kashif_e.backdrop.highlight.Highlight
import com.kashif_e.backdrop.shadow.InnerShadow

const val DEFAULT_LIQUID_GLASS_BLUR_INTENSITY = 0.5f

fun normalizeLiquidGlassBlurIntensity(value: Float): Float = value.coerceIn(0f, 1f)

internal fun liquidGlassBlurScale(intensity: Float): Float =
    0.1f + normalizeLiquidGlassBlurIntensity(intensity) * 1.8f

/**
 * Holder for the optional liquid-glass backdrop. When disabled the surface modifiers below are
 * no-ops, so pages keep their existing flat construction without any graphics-layer overhead.
 */
@Immutable
class LazerLiquidGlass internal constructor(
    val backdrop: LayerBackdrop?,
    val blurIntensity: Float,
) {
    val isEnabled: Boolean get() = backdrop != null

    companion object {
        val Disabled = LazerLiquidGlass(null, DEFAULT_LIQUID_GLASS_BLUR_INTENSITY)
    }
}

/**
 * Creates a backdrop that captures the real content it is applied to, filling the app background
 * color everywhere else. This is the single source of truth for glass sampling: no fabricated
 * decorative content is ever injected as a backdrop.
 */
@Composable
fun rememberLazerLiquidGlass(
    enabled: Boolean,
    backgroundColor: Color,
    blurIntensity: Float = DEFAULT_LIQUID_GLASS_BLUR_INTENSITY,
): LazerLiquidGlass {
    val currentBackgroundColor = rememberUpdatedState(backgroundColor)
    // Keep this callback—and therefore the LayerBackdrop instance—stable across theme changes.
    // Replacing a positioned backdrop would briefly leave the new instance without coordinates,
    // so floating glass surfaces would have nothing to sample until another layout pass.
    val drawCapturedContent: ContentDrawScope.() -> Unit = remember {
        {
            drawRect(currentBackgroundColor.value)
            drawContent()
        }
    }
    val backdrop = rememberLayerBackdrop(drawCapturedContent)
    val normalizedBlurIntensity = normalizeLiquidGlassBlurIntensity(blurIntensity)
    return remember(enabled, normalizedBlurIntensity, backdrop) {
        LazerLiquidGlass(
            backdrop = if (enabled) backdrop else null,
            blurIntensity = normalizedBlurIntensity,
        )
    }
}

/** Scales an individual surface's tuned blur radius without flattening its visual hierarchy. */
fun LazerLiquidGlass.scaledBlurRadius(baseRadius: Dp): Dp =
    baseRadius * liquidGlassBlurScale(blurIntensity)

/** Captures this composable's rendered content into the glass backdrop for downstream sampling. */
fun Modifier.captureLiquidGlass(glass: LazerLiquidGlass): Modifier =
    glass.backdrop?.let { layerBackdrop(it) } ?: this

/**
 * Applies a liquid-glass surface that samples the captured content behind it: vibrancy, a light
 * blur, and lens refraction, finished with a neutral translucent surface for readability. No-op
 * when disabled.
 */
fun Modifier.liquidGlassSurface(
    glass: LazerLiquidGlass,
    shape: Shape,
    surfaceColor: Color,
    blurRadius: Dp = 8.dp,
): Modifier {
    if (!glass.isEnabled) return this
    val backdrop = glass.backdrop ?: return this
    val effectiveBlurRadius = glass.scaledBlurRadius(blurRadius)
    return drawBackdrop(
        backdrop = backdrop,
        shape = { shape },
        effects = {
            vibrancy()
            blur(effectiveBlurRadius.toPx())
            lens(
                refractionHeight = 22.dp.toPx(),
                refractionAmount = 44.dp.toPx(),
                depthEffect = true,
                chromaticAberration = true,
            )
        },
        highlight = { Highlight.Ambient },
        innerShadow = { InnerShadow(radius = 12.dp, color = Color.Black.copy(alpha = 0.10f)) },
        // Near-colourless: the material is the refraction, not a white fill.
        onDrawSurface = { drawRect(surfaceColor.copy(alpha = 0.08f)) },
    )
}
