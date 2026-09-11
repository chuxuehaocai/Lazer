package dev.naominet.lazer

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
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

/**
 * Holder for the optional liquid-glass backdrop. When disabled the surface modifiers below are
 * no-ops, so pages keep their existing flat construction without any graphics-layer overhead.
 */
@Immutable
class LazerLiquidGlass internal constructor(val backdrop: LayerBackdrop?) {
    val isEnabled: Boolean get() = backdrop != null

    companion object {
        val Disabled = LazerLiquidGlass(null)
    }
}

/**
 * Creates a backdrop that captures the real content it is applied to, filling the app background
 * color everywhere else. This is the single source of truth for glass sampling: no fabricated
 * decorative content is ever injected as a backdrop.
 */
@Composable
fun rememberLazerLiquidGlass(enabled: Boolean, backgroundColor: Color): LazerLiquidGlass {
    val backdrop = rememberLayerBackdrop {
        drawRect(backgroundColor)
        drawContent()
    }
    return remember(enabled) { LazerLiquidGlass(if (enabled) backdrop else null) }
}

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
    return drawBackdrop(
        backdrop = backdrop,
        shape = { shape },
        effects = {
            vibrancy()
            blur(blurRadius.toPx())
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
