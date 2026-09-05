package dev.naominet.lazer

import androidx.compose.ui.graphics.Color
import java.awt.image.BufferedImage
import java.net.URI
import javax.imageio.ImageIO
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Album-art seed extraction and a small tonal ladder for the lyric color flow.
 * Ported from listclient's MonetColor.seedFromPixels + paperScheme accents.
 */
internal object CoverPalette {
    val defaultSeed: Color = Color(0xFF5F91AC)
    val defaultFlow: List<Color> = listOf(
        Color(0xFFA9C8D8),
        Color(0xFFC5D5CE),
        Color(0xFFB88769),
        Color(0xFFE7ECEB),
        Color(0xFF5F91AC),
    )

    fun extractSeedFromUrl(coverUrl: String?): Color {
        if (coverUrl.isNullOrBlank()) return defaultSeed
        return runCatching {
            val connection = URI(coverUrl.toPaletteArtworkUrl()).toURL().openConnection().apply {
                connectTimeout = 8_000
                readTimeout = 8_000
                setRequestProperty("User-Agent", "Lazer/1.0")
            }
            val image = connection.getInputStream().buffered(16 * 1024).use(ImageIO::read)
                ?: return defaultSeed
            try {
                seedFromImage(image)
            } finally {
                image.flush()
            }
        }.getOrDefault(defaultSeed)
    }

    fun flowColorsFromSeed(seed: Color): List<Color> {
        val (h, s, l) = rgbToHsl(seed)
        val cPrimary = (s * 0.70f + 0.12f).coerceIn(0.22f, 0.55f)
        val ht = (h + 48f) % 360f
        val hPaper = lerpHue(h, 42f, 0.55f)
        return listOf(
            hslToColor(h, cPrimary, 0.90f), // primary container
            hslToColor(h, 0.14f, 0.90f), // secondary container
            hslToColor(ht, 0.20f, 0.40f), // tertiary
            hslToColor(hPaper, 0.045f, 0.86f), // surface high
            hslToColor(h, cPrimary, 0.38f), // primary
        )
    }

    fun seedFromImage(image: BufferedImage): Color {
        val w = image.width
        val h = image.height
        if (w <= 0 || h <= 0) return defaultSeed
        val stepX = max(1, w / 48)
        val stepY = max(1, h / 48)
        val wr = DoubleArray(24)
        val wg = DoubleArray(24)
        val wb = DoubleArray(24)
        val ww = DoubleArray(24)
        var ar = 0.0
        var ag = 0.0
        var ab = 0.0
        var an = 0.0
        var y = 0
        while (y < h) {
            var x = 0
            while (x < w) {
                val p = image.getRGB(x, y)
                val a = (p ushr 24) and 0xFF
                if (a >= 128) {
                    val r = (p shr 16) and 0xFF
                    val g = (p shr 8) and 0xFF
                    val b = p and 0xFF
                    ar += r; ag += g; ab += b; an++
                    val rf = r / 255f
                    val gf = g / 255f
                    val bf = b / 255f
                    val maxc = max(rf, max(gf, bf))
                    val minc = min(rf, min(gf, bf))
                    val light = (maxc + minc) / 2f
                    val delta = maxc - minc
                    val sat = if (delta <= 1e-4f) {
                        0f
                    } else if (light > 0.5f) {
                        delta / (2f - maxc - minc)
                    } else {
                        delta / (maxc + minc)
                    }
                    val hue = if (delta <= 1e-4f) {
                        0f
                    } else {
                        when (maxc) {
                            rf -> (gf - bf) / delta + if (gf < bf) 6f else 0f
                            gf -> (bf - rf) / delta + 2f
                            else -> (rf - gf) / delta + 4f
                        } * 60f
                    }
                    if (sat >= 0.15f && light in 0.12f..0.92f) {
                        val midBias = 1.0 - abs(light - 0.5) * 1.6
                        val weight = sat * max(0.05, midBias)
                        val bucket = min(23, (hue / 360f * 24f).toInt())
                        wr[bucket] += r * weight
                        wg[bucket] += g * weight
                        wb[bucket] += b * weight
                        ww[bucket] += weight
                    }
                }
                x += stepX
            }
            y += stepY
        }
        var best = -1
        var bestW = 0.0
        for (i in 0 until 24) {
            if (ww[i] > bestW) {
                bestW = ww[i]
                best = i
            }
        }
        if (best >= 0 && bestW > 0.5) {
            val r = (wr[best] / ww[best]).roundToInt().coerceIn(0, 255)
            val g = (wg[best] / ww[best]).roundToInt().coerceIn(0, 255)
            val b = (wb[best] / ww[best]).roundToInt().coerceIn(0, 255)
            return boostChroma(Color(r / 255f, g / 255f, b / 255f), 1.25f)
        }
        if (an > 0) {
            return Color(
                (ar / an).roundToInt().coerceIn(0, 255) / 255f,
                (ag / an).roundToInt().coerceIn(0, 255) / 255f,
                (ab / an).roundToInt().coerceIn(0, 255) / 255f,
            )
        }
        return defaultSeed
    }

    private fun boostChroma(color: Color, mul: Float): Color {
        val (h, s, l) = rgbToHsl(color)
        return hslToColor(h, min(1f, s * mul), l)
    }

    private fun rgbToHsl(color: Color): FloatArray = rgbToHsl(color.red, color.green, color.blue)

    private fun rgbToHsl(r: Float, g: Float, b: Float): FloatArray {
        val maxc = max(r, max(g, b))
        val minc = min(r, min(g, b))
        val l = (maxc + minc) / 2f
        var hue = 0f
        var sat = 0f
        val d = maxc - minc
        if (d > 1e-4f) {
            sat = if (l > 0.5f) d / (2f - maxc - minc) else d / (maxc + minc)
            hue = when (maxc) {
                r -> (g - b) / d + if (g < b) 6f else 0f
                g -> (b - r) / d + 2f
                else -> (r - g) / d + 4f
            } * 60f
        }
        return floatArrayOf(hue, sat, l)
    }

    private fun hslToColor(hue: Float, sat: Float, light: Float): Color {
        var h = ((hue % 360f) + 360f) % 360f
        val s = sat.coerceIn(0f, 1f)
        val l = light.coerceIn(0f, 1f)
        val c = (1f - abs(2f * l - 1f)) * s
        val hp = h / 60f
        val x = c * (1f - abs(hp % 2f - 1f))
        val (r1, g1, b1) = when {
            hp < 1f -> Triple(c, x, 0f)
            hp < 2f -> Triple(x, c, 0f)
            hp < 3f -> Triple(0f, c, x)
            hp < 4f -> Triple(0f, x, c)
            hp < 5f -> Triple(x, 0f, c)
            else -> Triple(c, 0f, x)
        }
        val m = l - c / 2f
        return Color((r1 + m).coerceIn(0f, 1f), (g1 + m).coerceIn(0f, 1f), (b1 + m).coerceIn(0f, 1f))
    }

    private fun lerpHue(a: Float, b: Float, t: Float): Float {
        val d = ((b - a + 540f) % 360f) - 180f
        return ((a + d * t) % 360f + 360f) % 360f
    }
}

private val ArtworkSizeParameter = Regex("([?&]param=)\\d+y\\d+", RegexOption.IGNORE_CASE)

/** Palette sampling never needs the full album image resident in memory. */
internal fun String.toPaletteArtworkUrl(): String {
    val secure = trim().replaceFirst("http://", "https://")
        .let { if (it.startsWith("//")) "https:$it" else it }
    if (ArtworkSizeParameter.containsMatchIn(secure)) {
        return secure.replace(ArtworkSizeParameter) { match -> match.groupValues[1] + "96y96" }
    }
    return secure + if ('?' in secure) "&param=96y96" else "?param=96y96"
}
