package dev.naominet.lazer

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import kotlin.math.max
import kotlin.math.min

/** A curated set of seed colours offered next to the free hue strip. */
val LazerSeedSwatches: List<Color> = listOf(
    Color(0xFF5F91AC), Color(0xFFB88769), Color(0xFF7C9A6B), Color(0xFF9B6B9E),
    Color(0xFFC05B5B), Color(0xFF4F7C6B), Color(0xFF8A7BB0), Color(0xFFB08A4F),
    Color(0xFF6B8FB5), Color(0xFFB55B8A), Color(0xFF5B8C8C), Color(0xFF8C7A5B),
)

private fun hueColor(hue: Float): Color = hslToColor(hue, 0.55f, 0.50f)

/**
 * Seed colour picker: a continuous hue strip plus preset swatches. Shared by Android and desktop
 * so both platforms expose the same "custom Monet seed" control.
 */
@Composable
fun SeedColorPicker(
    seed: Color,
    onSeedChange: (Color) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = MaterialTheme.colorScheme
    val current = rememberUpdatedState(onSeedChange)
    Column(modifier) {
        Text(
            tr("settings.palette.seed"),
            style = MaterialTheme.typography.bodySmall,
            color = colors.onSurfaceVariant,
        )
        Spacer(Modifier.height(8.dp))
        Canvas(
            Modifier
                .fillMaxWidth()
                .height(28.dp)
                .clip(RoundedCornerShape(14.dp))
                .pointerInput(Unit) {
                    awaitEachGesture {
                        val down = awaitFirstDown(requireUnconsumed = false)
                        fun emit(x: Float) {
                            val fraction = (x / size.width.toFloat()).coerceIn(0f, 1f)
                            current.value(hueColor(fraction * 360f))
                        }
                        emit(down.position.x)
                        down.consume()
                        while (true) {
                            val change = awaitPointerEvent().changes.firstOrNull { it.id == down.id } ?: break
                            if (!change.pressed) break
                            emit(change.position.x)
                            change.consume()
                        }
                    }
                },
        ) {
            drawRect(
                brush = Brush.horizontalGradient(
                    List(13) { hueColor(it * 30f) },
                ),
            )
            // Thumb marking the current hue.
            val fraction = hueOf(seed) / 360f
            val x = size.width * fraction
            drawCircle(Color.White, radius = size.height * 0.36f, center = Offset(x, size.height / 2f))
            drawCircle(seed, radius = size.height * 0.24f, center = Offset(x, size.height / 2f))
        }
        Spacer(Modifier.height(10.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            LazerSeedSwatches.forEach { swatch ->
                val selected = swatch.toArgb() == seed.toArgb()
                Box(
                    Modifier
                        .size(26.dp)
                        .clip(CircleShape)
                        .background(swatch)
                        .border(
                            width = if (selected) 2.dp else 0.dp,
                            color = if (selected) colors.primary else Color.Transparent,
                            shape = CircleShape,
                        )
                        .clickable { onSeedChange(swatch) },
                )
            }
        }
    }
}

private fun hueOf(color: Color): Float {
    val maximum = max(color.red, max(color.green, color.blue))
    val minimum = min(color.red, min(color.green, color.blue))
    val delta = maximum - minimum
    if (delta <= 1e-4f) return 0f
    return when (maximum) {
        color.red -> (color.green - color.blue) / delta + if (color.green < color.blue) 6f else 0f
        color.green -> (color.blue - color.red) / delta + 2f
        else -> (color.red - color.green) / delta + 4f
    } * 60f
}
