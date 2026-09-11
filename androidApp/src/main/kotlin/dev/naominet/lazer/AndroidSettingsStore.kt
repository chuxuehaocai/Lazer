package dev.naominet.lazer

import android.content.Context
import dev.naominet.lazer.gateway.AudioQuality
import dev.naominet.lazer.gateway.DEFAULT_GATEWAY_BASE_URL
import dev.naominet.lazer.gateway.normalizeGatewayBaseUrl

internal val ANDROID_AUDIO_QUALITY_OPTIONS = listOf(
    AudioQuality.STANDARD,
    AudioQuality.HIGHER,
    AudioQuality.EXHIGH,
    AudioQuality.LOSSLESS,
    AudioQuality.HI_RES,
    AudioQuality.JYMASTER,
)

internal fun parseAndroidAudioQuality(value: String?): AudioQuality =
    ANDROID_AUDIO_QUALITY_OPTIONS.firstOrNull { it.name == value } ?: AudioQuality.EXHIGH

/** App-scoped preferences for Android appearance, playback, and service settings. */
internal class AndroidSettingsStore(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences(
        PREFERENCES_NAME,
        Context.MODE_PRIVATE,
    )

    var isDark: Boolean
        get() = preferences.getBoolean(KEY_DARK_THEME, false)
        set(value) = preferences.edit().putBoolean(KEY_DARK_THEME, value).apply()

    var useSystemMonetColors: Boolean
        get() = preferences.getBoolean(KEY_SYSTEM_MONET, false)
        set(value) = preferences.edit().putBoolean(KEY_SYSTEM_MONET, value).apply()

    /** Colour source. Migrates the legacy system-monet toggle on first read. */
    var palette: LazerPalette
        get() {
            preferences.getString(KEY_PALETTE, null)?.let { return LazerPalette.parse(it) }
            return if (preferences.getBoolean(KEY_SYSTEM_MONET, false)) LazerPalette.System else LazerPalette.Default
        }
        set(value) = preferences.edit().putString(KEY_PALETTE, value.serialize()).apply()

    /** Absolute path of the user's custom background image, or null. */
    var backgroundImagePath: String?
        get() = preferences.getString(KEY_BACKGROUND_IMAGE, null)
        set(value) = preferences.edit().putString(KEY_BACKGROUND_IMAGE, value).apply()

    var backgroundAlpha: Float
        get() = preferences.getFloat(KEY_BACKGROUND_ALPHA, 0.82f).coerceIn(0f, 1f)
        set(value) = preferences.edit().putFloat(KEY_BACKGROUND_ALPHA, value.coerceIn(0f, 1f)).apply()

    /** Single appearance style. Migrates the legacy separate engine/glass keys on first read. */
    var style: LazerStyle
        get() {
            preferences.getString(KEY_STYLE, null)?.let { return parseLazerStyle(it) }
            val legacyEngine = parseLazerThemeEngine(preferences.getString(KEY_THEME_ENGINE, null))
            val legacyGlass = preferences.getBoolean(KEY_LIQUID_GLASS_ENABLED, false)
            return when {
                legacyGlass -> LazerStyle.LIQUID_GLASS
                legacyEngine == LazerThemeEngine.MIUIX -> LazerStyle.MIUIX
                else -> LazerStyle.MATERIAL
            }
        }
        set(value) = preferences.edit().putString(KEY_STYLE, value.name).apply()

    var language: LazerLanguage
        get() = parseLazerLanguage(preferences.getString(KEY_LANGUAGE, null))
        set(value) = preferences.edit().putString(KEY_LANGUAGE, value.name).apply()

    var lyricFollowDelayMillis: Long
        get() = normalizeLyricFollowDelayMillis(
            preferences.getLong(KEY_LYRIC_FOLLOW_DELAY, DEFAULT_LYRIC_FOLLOW_DELAY_MILLIS),
        )
        set(value) = preferences.edit()
            .putLong(KEY_LYRIC_FOLLOW_DELAY, normalizeLyricFollowDelayMillis(value))
            .apply()

    var lyricAnimationSpeed: LyricAnimationSpeed
        get() = parseLyricAnimationSpeed(preferences.getString(KEY_LYRIC_ANIMATION_SPEED, null))
        set(value) = preferences.edit().putString(KEY_LYRIC_ANIMATION_SPEED, value.name).apply()

    var wordLyricsEnabled: Boolean
        get() = preferences.getBoolean(KEY_WORD_LYRICS_ENABLED, true)
        set(value) = preferences.edit().putBoolean(KEY_WORD_LYRICS_ENABLED, value).apply()

    var lyricGlowEnabled: Boolean
        get() = preferences.getBoolean(KEY_LYRIC_GLOW_ENABLED, true)
        set(value) = preferences.edit().putBoolean(KEY_LYRIC_GLOW_ENABLED, value).apply()

    var lyricFontSizeSp: Int
        get() = normalizeLyricFontSizeSp(
            preferences.getInt(KEY_LYRIC_FONT_SIZE_SP, DEFAULT_ANDROID_LYRIC_FONT_SIZE_SP),
        )
        set(value) = preferences.edit()
            .putInt(KEY_LYRIC_FONT_SIZE_SP, normalizeLyricFontSizeSp(value))
            .apply()

    var showFullLyrics: Boolean
        get() = preferences.getBoolean(KEY_SHOW_FULL_LYRICS, false)
        set(value) = preferences.edit().putBoolean(KEY_SHOW_FULL_LYRICS, value).apply()

    var audioQuality: AudioQuality
        get() = parseAndroidAudioQuality(preferences.getString(KEY_AUDIO_QUALITY, null))
        set(value) = preferences.edit().putString(KEY_AUDIO_QUALITY, value.name).apply()

    var exclusiveAudio: Boolean
        get() = preferences.getBoolean(KEY_EXCLUSIVE_AUDIO, false)
        set(value) = preferences.edit().putBoolean(KEY_EXCLUSIVE_AUDIO, value).apply()

    var gatewayBaseUrl: String
        get() = normalizeGatewayBaseUrl(
            preferences.getString(KEY_GATEWAY_BASE_URL, DEFAULT_GATEWAY_BASE_URL).orEmpty(),
        ) ?: DEFAULT_GATEWAY_BASE_URL
        set(value) = preferences.edit()
            .putString(KEY_GATEWAY_BASE_URL, normalizeGatewayBaseUrl(value) ?: DEFAULT_GATEWAY_BASE_URL)
            .apply()

    private companion object {
        const val PREFERENCES_NAME = "lazer.android.settings"
        const val KEY_DARK_THEME = "appearance.dark"
        const val KEY_SYSTEM_MONET = "appearance.system_monet"
        const val KEY_STYLE = "appearance.style"
        const val KEY_PALETTE = "appearance.palette"
        const val KEY_BACKGROUND_IMAGE = "appearance.background_image"
        const val KEY_BACKGROUND_ALPHA = "appearance.background_alpha"
        const val KEY_THEME_ENGINE = "appearance.theme_engine"
        const val KEY_LIQUID_GLASS_ENABLED = "appearance.liquid_glass"
        const val KEY_LANGUAGE = "appearance.language"
        const val KEY_LYRIC_FOLLOW_DELAY = "lyrics.follow_delay_millis"
        const val KEY_LYRIC_ANIMATION_SPEED = "lyrics.animation_speed"
        const val KEY_WORD_LYRICS_ENABLED = "lyrics.word_animation_enabled"
        const val KEY_LYRIC_GLOW_ENABLED = "lyrics.glow_enabled"
        const val KEY_LYRIC_FONT_SIZE_SP = "lyrics.font_size_sp"
        const val KEY_SHOW_FULL_LYRICS = "lyrics.show_full_lines"
        const val KEY_AUDIO_QUALITY = "playback.audio_quality"
        const val KEY_EXCLUSIVE_AUDIO = "playback.exclusive_audio"
        const val KEY_GATEWAY_BASE_URL = "gateway.base_url"
    }
}
