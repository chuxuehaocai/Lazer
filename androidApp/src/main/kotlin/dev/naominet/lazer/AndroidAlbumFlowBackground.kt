package dev.naominet.lazer

import android.graphics.Bitmap
import android.graphics.BitmapFactory
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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.Dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URL
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

private const val FlowFrameIntervalNanos = 33_333_333L
private val FluidPaletteEasing = Easing { fraction ->
    ((1.0 - cos(PI * fraction.coerceIn(0f, 1f))) * 0.5).toFloat()
}
private val DefaultFlowPalette = listOf(
    Color(0xFFA9C8D8),
    Color(0xFFC5D5CE),
    Color(0xFFB88769),
    Color(0xFFE7ECEB),
    Color(0xFF5F91AC),
)

@Composable
internal fun AndroidAlbumFlowBackground(
    track: AndroidTrack?,
    modifier: Modifier = Modifier,
    cornerRadius: Dp,
    veil: Color,
) {
    var colors by remember { mutableStateOf(DefaultFlowPalette) }
    var phaseSeconds by remember { mutableFloatStateOf(0f) }

    LaunchedEffect(track?.id, track?.coverUrl) {
        colors = extractAndroidFlowPalette(track?.coverUrl)
    }
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

    val palette = remember(colors) { normalizeFlowPalette(colors) }
    Box(
        modifier
            .clip(RoundedCornerShape(cornerRadius))
            .background(palette[4]),
    ) {
        Crossfade(
            targetState = palette,
            animationSpec = tween(durationMillis = 650, easing = FluidPaletteEasing),
            label = "android-lyric-flow-palette",
        ) { activePalette ->
            Box(Modifier.fillMaxSize()) {
                FlowPaletteLayers(activePalette) { phaseSeconds }
            }
        }
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
private fun BoxScope.FlowPaletteLayers(palette: List<Color>, phaseSeconds: () -> Float) {
    FlowLayer(palette[0], phaseSeconds, 0.2f, 0.19f, 0.30f, 0.24f, 1.68f, 1.18f, 8f)
    FlowLayer(palette[1], phaseSeconds, 2.1f, 0.145f, 0.25f, 0.34f, 1.34f, 1.58f, -10f)
    FlowLayer(palette[2], phaseSeconds, 4.0f, 0.17f, 0.37f, 0.20f, 1.52f, 1.26f, 7f)
    FlowLayer(palette[3], phaseSeconds, 5.35f, 0.12f, 0.20f, 0.38f, 1.28f, 1.62f, -6f)
    FlowLayer(palette[4], phaseSeconds, 1.25f, 0.105f, 0.16f, 0.18f, 1.85f, 1.12f, 5f, 0.52f)
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

private suspend fun extractAndroidFlowPalette(coverUrl: String?): List<Color> = withContext(Dispatchers.IO) {
    if (coverUrl.isNullOrBlank()) return@withContext DefaultFlowPalette
    runCatching {
        val connection = URL(coverUrl.toAndroidPaletteArtworkUrl()).openConnection() as HttpURLConnection
        connection.connectTimeout = 8_000
        connection.readTimeout = 8_000
        connection.setRequestProperty("User-Agent", "Lazer/1.0")
        connection.inputStream.use(BitmapFactory::decodeStream)
            ?.let(::seedFromBitmap)
            ?.let(::flowColorsFromSeed)
            ?: DefaultFlowPalette
    }.getOrDefault(DefaultFlowPalette)
}

private fun seedFromBitmap(bitmap: Bitmap): Color {
    val width = bitmap.width
    val height = bitmap.height
    if (width <= 0 || height <= 0) return Color(0xFF5F91AC)
    val stepX = max(1, width / 48)
    val stepY = max(1, height / 48)
    val weightedRed = DoubleArray(24)
    val weightedGreen = DoubleArray(24)
    val weightedBlue = DoubleArray(24)
    val weights = DoubleArray(24)
    var averageRed = 0.0
    var averageGreen = 0.0
    var averageBlue = 0.0
    var averageCount = 0.0
    var y = 0
    while (y < height) {
        var x = 0
        while (x < width) {
            val pixel = bitmap.getPixel(x, y)
            if ((pixel ushr 24) and 0xFF >= 128) {
                val red = (pixel shr 16) and 0xFF
                val green = (pixel shr 8) and 0xFF
                val blue = pixel and 0xFF
                averageRed += red
                averageGreen += green
                averageBlue += blue
                averageCount++
                val hsl = rgbToHsl(red / 255f, green / 255f, blue / 255f)
                val saturation = hsl[1]
                val lightness = hsl[2]
                if (saturation >= 0.15f && lightness in 0.12f..0.92f) {
                    val weight = saturation * max(0.05, 1.0 - abs(lightness - 0.5) * 1.6)
                    val bucket = min(23, (hsl[0] / 360f * 24f).toInt())
                    weightedRed[bucket] += red * weight
                    weightedGreen[bucket] += green * weight
                    weightedBlue[bucket] += blue * weight
                    weights[bucket] += weight
                }
            }
            x += stepX
        }
        y += stepY
    }
    val best = weights.indices.maxByOrNull(weights::get) ?: -1
    if (best >= 0 && weights[best] > 0.5) {
        val seed = Color(
            (weightedRed[best] / weights[best]).roundToInt().coerceIn(0, 255) / 255f,
            (weightedGreen[best] / weights[best]).roundToInt().coerceIn(0, 255) / 255f,
            (weightedBlue[best] / weights[best]).roundToInt().coerceIn(0, 255) / 255f,
        )
        val hsl = rgbToHsl(seed.red, seed.green, seed.blue)
        return hslToColor(hsl[0], min(1f, hsl[1] * 1.25f), hsl[2])
    }
    return if (averageCount > 0) {
        Color(
            (averageRed / averageCount).roundToInt().coerceIn(0, 255) / 255f,
            (averageGreen / averageCount).roundToInt().coerceIn(0, 255) / 255f,
            (averageBlue / averageCount).roundToInt().coerceIn(0, 255) / 255f,
        )
    } else {
        Color(0xFF5F91AC)
    }
}

private fun flowColorsFromSeed(seed: Color): List<Color> {
    val hsl = rgbToHsl(seed.red, seed.green, seed.blue)
    val primaryChroma = (hsl[1] * 0.70f + 0.12f).coerceIn(0.22f, 0.55f)
    val tertiaryHue = (hsl[0] + 48f) % 360f
    val paperHue = lerpHue(hsl[0], 42f, 0.55f)
    return listOf(
        hslToColor(hsl[0], primaryChroma, 0.90f),
        hslToColor(hsl[0], 0.14f, 0.90f),
        hslToColor(tertiaryHue, 0.20f, 0.40f),
        hslToColor(paperHue, 0.045f, 0.86f),
        hslToColor(hsl[0], primaryChroma, 0.38f),
    )
}

private fun rgbToHsl(red: Float, green: Float, blue: Float): FloatArray {
    val maximum = max(red, max(green, blue))
    val minimum = min(red, min(green, blue))
    val lightness = (maximum + minimum) / 2f
    val delta = maximum - minimum
    if (delta <= 1e-4f) return floatArrayOf(0f, 0f, lightness)
    val saturation = if (lightness > 0.5f) delta / (2f - maximum - minimum) else delta / (maximum + minimum)
    val hue = when (maximum) {
        red -> (green - blue) / delta + if (green < blue) 6f else 0f
        green -> (blue - red) / delta + 2f
        else -> (red - green) / delta + 4f
    } * 60f
    return floatArrayOf(hue, saturation, lightness)
}

private fun hslToColor(hue: Float, saturation: Float, lightness: Float): Color {
    val normalizedHue = ((hue % 360f) + 360f) % 360f
    val safeSaturation = saturation.coerceIn(0f, 1f)
    val safeLightness = lightness.coerceIn(0f, 1f)
    val chroma = (1f - abs(2f * safeLightness - 1f)) * safeSaturation
    val huePart = normalizedHue / 60f
    val x = chroma * (1f - abs(huePart % 2f - 1f))
    val (red, green, blue) = when {
        huePart < 1f -> Triple(chroma, x, 0f)
        huePart < 2f -> Triple(x, chroma, 0f)
        huePart < 3f -> Triple(0f, chroma, x)
        huePart < 4f -> Triple(0f, x, chroma)
        huePart < 5f -> Triple(x, 0f, chroma)
        else -> Triple(chroma, 0f, x)
    }
    val match = safeLightness - chroma / 2f
    return Color(red + match, green + match, blue + match)
}

private fun lerpHue(start: Float, end: Float, fraction: Float): Float {
    val distance = ((end - start + 540f) % 360f) - 180f
    return ((start + distance * fraction) % 360f + 360f) % 360f
}

private fun normalizeFlowPalette(colors: List<Color>): List<Color> {
    val source = colors.ifEmpty { DefaultFlowPalette }
    return List(5) { index -> source[index % source.size] }
}

private val AndroidArtworkSizeParameter = Regex("([?&]param=)\\d+y\\d+", RegexOption.IGNORE_CASE)
private fun String.toAndroidPaletteArtworkUrl(): String {
    val secure = trim().replaceFirst("http://", "https://")
        .let { if (it.startsWith("//")) "https:$it" else it }
    if (AndroidArtworkSizeParameter.containsMatchIn(secure)) {
        return secure.replace(AndroidArtworkSizeParameter) { match -> match.groupValues[1] + "96y96" }
    }
    return secure + if ('?' in secure) "&param=96y96" else "?param=96y96"
}
