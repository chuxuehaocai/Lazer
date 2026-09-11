package dev.naominet.lazer

import androidx.compose.material3.ColorScheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.ui.graphics.Color
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Where the app takes its colour from.
 *  - [Default] uses the built-in paper/lake-blue scheme.
 *  - [System] uses the platform Monet palette (Android 12+); falls back to [Default] elsewhere.
 *  - [Custom] derives every role from a user-picked seed colour, on every platform.
 */
sealed interface LazerPalette {
    data object Default : LazerPalette
    data object System : LazerPalette
    data class Custom(val seed: Color) : LazerPalette

    companion object {
        fun parse(value: String?): LazerPalette = when {
            value == null -> Default
            value.equals("SYSTEM", ignoreCase = true) -> System
            value.startsWith("CUSTOM:", ignoreCase = true) ->
                value.substringAfter(':').toLongOrNull()?.let { Custom(Color(it.toInt())) } ?: Default
            else -> Default
        }
    }

    fun serialize(): String = when (this) {
        Default -> "DEFAULT"
        System -> "SYSTEM"
        is Custom -> "CUSTOM:${seed.value.toLong()}"
    }
}

/**
 * A compact Material-3-style tonal scheme generated from one seed colour.
 *
 * The seed's hue drives primary/secondary/tertiary (spaced 60°/120° apart); fixed light/dark
 * tones keep contrast predictable. This is not byte-identical to Material You, but it is
 * dependency-free, identical on every platform, and keeps the paper hierarchy of the app.
 */
fun seedColorScheme(seed: Color, isDark: Boolean): ColorScheme {
    val hsl = seed.toHsl()
    val hue = hsl[0]
    val chroma = 0.55f

    fun tone(lightness: Float, secondary: Boolean = false, chromaScale: Float = 1f): Color =
        hslToColor(
            hue = if (secondary) (hue + 60f) % 360f else hue,
            saturation = (chroma * chromaScale).coerceIn(0f, 1f),
            lightness = lightness,
        )

    return if (isDark) {
        darkColorScheme(
            primary = tone(0.80f),
            onPrimary = tone(0.20f),
            primaryContainer = tone(0.30f),
            onPrimaryContainer = tone(0.90f),
            secondary = tone(0.80f, secondary = true, chromaScale = 0.6f),
            onSecondary = tone(0.20f, secondary = true),
            secondaryContainer = tone(0.30f, secondary = true, chromaScale = 0.6f),
            onSecondaryContainer = tone(0.90f, secondary = true),
            tertiary = tone(0.80f, secondary = true),
            onTertiary = tone(0.20f, secondary = true),
            tertiaryContainer = tone(0.30f, secondary = true),
            onTertiaryContainer = tone(0.90f, secondary = true),
            background = tone(0.10f, chromaScale = 0.25f),
            onBackground = tone(0.90f, chromaScale = 0.15f),
            surface = tone(0.13f, chromaScale = 0.25f),
            onSurface = tone(0.90f, chromaScale = 0.15f),
            surfaceVariant = tone(0.30f, chromaScale = 0.3f),
            onSurfaceVariant = tone(0.80f, chromaScale = 0.2f),
            outline = tone(0.60f, chromaScale = 0.3f),
            outlineVariant = tone(0.32f, chromaScale = 0.3f),
            error = Color(0xFFFFB4AB),
        )
    } else {
        lightColorScheme(
            primary = tone(0.40f),
            onPrimary = Color.White,
            primaryContainer = tone(0.88f),
            onPrimaryContainer = tone(0.20f),
            secondary = tone(0.45f, secondary = true, chromaScale = 0.6f),
            onSecondary = Color.White,
            secondaryContainer = tone(0.90f, secondary = true, chromaScale = 0.6f),
            onSecondaryContainer = tone(0.22f, secondary = true),
            tertiary = tone(0.42f, secondary = true),
            onTertiary = Color.White,
            tertiaryContainer = tone(0.90f, secondary = true),
            onTertiaryContainer = tone(0.22f, secondary = true),
            background = tone(0.97f, chromaScale = 0.25f),
            onBackground = tone(0.18f, chromaScale = 0.2f),
            surface = tone(0.99f, chromaScale = 0.2f),
            onSurface = tone(0.18f, chromaScale = 0.2f),
            surfaceVariant = tone(0.92f, chromaScale = 0.3f),
            onSurfaceVariant = tone(0.38f, chromaScale = 0.3f),
            outline = tone(0.55f, chromaScale = 0.3f),
            outlineVariant = tone(0.84f, chromaScale = 0.3f),
            error = Color(0xFFA94C4C),
        )
    }
}

private fun Color.toHsl(): FloatArray {
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

internal fun hslToColor(hue: Float, saturation: Float, lightness: Float): Color {
    val normalizedHue = ((hue % 360f) + 360f) % 360f
    val safeSaturation = saturation.coerceIn(0f, 1f)
    val safeLightness = lightness.coerceIn(0f, 1f)
    val chroma = (1f - abs(2f * safeLightness - 1f)) * safeSaturation
    val huePart = normalizedHue / 60f
    val x = chroma * (1f - abs(huePart % 2f - 1f))
    val (r, g, b) = when {
        huePart < 1f -> Triple(chroma, x, 0f)
        huePart < 2f -> Triple(x, chroma, 0f)
        huePart < 3f -> Triple(0f, chroma, x)
        huePart < 4f -> Triple(0f, x, chroma)
        huePart < 5f -> Triple(x, 0f, chroma)
        else -> Triple(chroma, 0f, x)
    }
    val match = safeLightness - chroma / 2f
    return Color(r + match, g + match, b + match)
}
