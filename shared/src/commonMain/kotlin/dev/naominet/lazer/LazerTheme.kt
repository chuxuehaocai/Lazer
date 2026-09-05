package dev.naominet.lazer

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.LocalRippleConfiguration
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.RippleConfiguration
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/** Shared paper-and-blue tokens. All platform UIs inherit this theme. */
object LazerTokens {
    val Paper = Color(0xFFF7F5EF)
    val PaperRaised = Color(0xFFFCFAF5)
    val MistBlue = Color(0xFFA9C8D8)
    val LakeBlue = Color(0xFF5F91AC)
    val DeepBlue = Color(0xFF365F73)
    val Ink = Color(0xFF26363D)
    val QuietInk = Color(0xFF627279)
    val WarmClay = Color(0xFFB88769)
    val NightPaper = Color(0xFF1D282D)
    val NightRaised = Color(0xFF253238)
    val NightInk = Color(0xFFE7ECEB)
    val NightQuietInk = Color(0xFFAAB8BC)
    val NightBlue = Color(0xFF91BED3)
}

private val LightColors = lightColorScheme(
    primary = LazerTokens.LakeBlue,
    onPrimary = Color.White,
    primaryContainer = Color(0xFFDDECF3),
    onPrimaryContainer = Color(0xFF244B5E),
    secondary = Color(0xFF6E858F),
    onSecondary = Color.White,
    secondaryContainer = Color(0xFFE5ECEE),
    onSecondaryContainer = LazerTokens.Ink,
    tertiary = LazerTokens.WarmClay,
    onTertiary = Color.White,
    tertiaryContainer = Color(0xFFF1E3D8),
    onTertiaryContainer = Color(0xFF60442F),
    background = LazerTokens.Paper,
    onBackground = LazerTokens.Ink,
    surface = LazerTokens.PaperRaised,
    onSurface = LazerTokens.Ink,
    surfaceVariant = Color(0xFFE9EEED),
    onSurfaceVariant = LazerTokens.QuietInk,
    outline = Color(0xFFA8B5B8),
    outlineVariant = Color(0xFFD7DEDD),
    error = Color(0xFFA94C4C),
)

private val DarkColors = darkColorScheme(
    primary = LazerTokens.NightBlue,
    onPrimary = Color(0xFF153844),
    primaryContainer = Color(0xFF294B5A),
    onPrimaryContainer = Color(0xFFDCEFF7),
    secondary = Color(0xFFB2C6CE),
    onSecondary = Color(0xFF20343C),
    secondaryContainer = Color(0xFF304047),
    onSecondaryContainer = LazerTokens.NightInk,
    tertiary = Color(0xFFD2A388),
    onTertiary = Color(0xFF482A1B),
    tertiaryContainer = Color(0xFF563C2F),
    onTertiaryContainer = Color(0xFFF5DED0),
    background = LazerTokens.NightPaper,
    onBackground = LazerTokens.NightInk,
    surface = LazerTokens.NightRaised,
    onSurface = LazerTokens.NightInk,
    surfaceVariant = Color(0xFF314047),
    onSurfaceVariant = LazerTokens.NightQuietInk,
    outline = Color(0xFF687A81),
    outlineVariant = Color(0xFF3B4B51),
    error = Color(0xFFFFB4AB),
)

private val LazerTypography = Typography(
    displaySmall = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.SemiBold,
        fontSize = 34.sp,
        lineHeight = 42.sp,
        letterSpacing = (-0.6).sp,
    ),
    headlineMedium = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.SemiBold,
        fontSize = 25.sp,
        lineHeight = 33.sp,
        letterSpacing = (-0.25).sp,
    ),
    headlineSmall = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.SemiBold,
        fontSize = 21.sp,
        lineHeight = 29.sp,
    ),
    titleLarge = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.SemiBold, fontSize = 18.sp, lineHeight = 25.sp),
    titleMedium = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Medium, fontSize = 15.sp, lineHeight = 22.sp),
    titleSmall = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Medium, fontSize = 13.sp, lineHeight = 20.sp),
    bodyLarge = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Normal, fontSize = 15.sp, lineHeight = 24.sp),
    bodyMedium = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Normal, fontSize = 14.sp, lineHeight = 22.sp),
    bodySmall = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Normal, fontSize = 12.sp, lineHeight = 19.sp),
    labelLarge = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Medium, fontSize = 14.sp, lineHeight = 20.sp),
    labelMedium = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Medium, fontSize = 12.sp, lineHeight = 18.sp),
    labelSmall = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Normal, fontSize = 11.sp, lineHeight = 16.sp),
)

@Composable
fun LazerTheme(isDark: Boolean, content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = if (isDark) DarkColors else LightColors,
        typography = LazerTypography,
    ) {
        CompositionLocalProvider(
            LocalContentColor provides if (isDark) LazerTokens.NightInk else LazerTokens.Ink,
            LocalRippleConfiguration provides RippleConfiguration(
                color = if (isDark) Color(0xFFEAF4F7) else LazerTokens.DeepBlue,
            ),
            content = content,
        )
    }
}
