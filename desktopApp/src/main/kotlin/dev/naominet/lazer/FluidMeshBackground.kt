package dev.naominet.lazer

import androidx.compose.foundation.Canvas
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.PI
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * Compose port of listclient [GlShapes.fluidMesh]: a low-frequency animated mesh
 * gradient for lyric backgrounds. Full-bleed by default (no rounded cutout).
 */
@Composable
fun FluidMeshBackground(
    colors: List<Color>,
    modifier: Modifier = Modifier,
    cornerRadius: Dp = 0.dp,
    veil: Color = Color.Transparent,
) {
    var timeSec by remember { mutableFloatStateOf(0f) }
    LaunchedEffect(Unit) {
        val start = withFrameNanos { it }
        while (true) {
            withFrameNanos { now ->
                timeSec = ((now - start) / 1_000_000_000.0).toFloat()
            }
        }
    }
    val meshColors = if (colors.size >= 2) colors else CoverPalette.defaultMesh
    Canvas(
        modifier
            .fillMaxSize()
            .then(if (cornerRadius > 0.dp) Modifier.clip(RoundedCornerShape(cornerRadius)) else Modifier),
    ) {
        // Solid base so corners never flash empty.
        drawRect(meshColors.first().copy(alpha = 0.55f))
        drawFluidMesh(timeSec, meshColors)
        if (veil.alpha > 0.001f) {
            drawRect(veil)
        }
    }
}

private fun DrawScope.drawFluidMesh(time: Float, colors: List<Color>) {
    val w = size.width
    val h = size.height
    if (w <= 1f || h <= 1f) return
    // Full-window mesh: no rounded inset, cover every pixel.
    val cols = max(10, min(28, ceil(w / 12f).toInt()))
    val rows = max(12, min(32, ceil(h / 5f).toInt()))
    val points = (cols + 1) * (rows + 1)
    val px = FloatArray(points)
    val py = FloatArray(points)
    val pc = Array(points) { Color.Transparent }

    for (row in 0..rows) {
        val v = row / rows.toFloat()
        for (col in 0..cols) {
            val u = col / cols.toFloat()
            val index = row * (cols + 1) + col
            val edge = (sin(PI * u) * sin(PI * v)).toFloat()
            val du = (
                sin(v * 8.1 + time * 0.31) +
                    cos((u + v) * 5.3 - time * 0.17)
                ).toFloat() * 0.035f * edge
            val dv = (
                cos(u * 7.4 - time * 0.27) +
                    sin((u - v) * 6.2 + time * 0.13)
                ).toFloat() * 0.035f * edge
            val warpedV = (v + dv).coerceIn(0f, 1f)
            val warpedU = (u + du).coerceIn(0f, 1f)
            px[index] = warpedU * w
            py[index] = warpedV * h
            pc[index] = fluidColor(u, v, time, colors)
        }
    }

    val path = Path()
    for (row in 0 until rows) {
        for (col in 0 until cols) {
            val a = row * (cols + 1) + col
            val b = a + 1
            val d = (row + 1) * (cols + 1) + col
            val c = d + 1
            path.reset()
            path.moveTo(px[a], py[a])
            path.lineTo(px[b], py[b])
            path.lineTo(px[c], py[c])
            path.close()
            drawPath(path, color = averageColor(pc[a], pc[b], pc[c]))
            path.reset()
            path.moveTo(px[a], py[a])
            path.lineTo(px[c], py[c])
            path.lineTo(px[d], py[d])
            path.close()
            drawPath(path, color = averageColor(pc[a], pc[c], pc[d]))
        }
    }
}

private fun averageColor(a: Color, b: Color, c: Color): Color = Color(
    red = (a.red + b.red + c.red) / 3f,
    green = (a.green + b.green + c.green) / 3f,
    blue = (a.blue + b.blue + c.blue) / 3f,
    alpha = (a.alpha + b.alpha + c.alpha) / 3f,
)

private fun fluidColor(u: Float, v: Float, time: Float, colors: List<Color>): Color {
    var wr = 0.0
    var wg = 0.0
    var wb = 0.0
    var total = 0.0
    for (i in colors.indices) {
        val phase = PI * 2.0 * i / colors.size
        val speed = 0.075 + i * 0.014
        val cx = 0.5 + sin(time * speed + phase) * (0.34 - (i and 1) * 0.05)
        val cy = 0.5 + cos(time * (speed * 0.83) + phase * 1.37) * 0.32
        val dx = u - cx
        val dy = v - cy
        val weight = 1.0 / (0.035 + dx * dx + dy * dy)
        val c = colors[i]
        wr += c.red * weight
        wg += c.green * weight
        wb += c.blue * weight
        total += weight
    }
    return Color(
        red = (wr / total).toFloat().coerceIn(0f, 1f),
        green = (wg / total).toFloat().coerceIn(0f, 1f),
        blue = (wb / total).toFloat().coerceIn(0f, 1f),
        alpha = 0.90f,
    )
}
