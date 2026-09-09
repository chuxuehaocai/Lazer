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

    var themeEngine: LazerThemeEngine
        get() = parseLazerThemeEngine(preferences.getString(KEY_THEME_ENGINE, null))
        set(value) = preferences.edit().putString(KEY_THEME_ENGINE, value.name).apply()

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
        const val KEY_THEME_ENGINE = "appearance.theme_engine"
        const val KEY_LYRIC_FOLLOW_DELAY = "lyrics.follow_delay_millis"
        const val KEY_LYRIC_ANIMATION_SPEED = "lyrics.animation_speed"
        const val KEY_AUDIO_QUALITY = "playback.audio_quality"
        const val KEY_EXCLUSIVE_AUDIO = "playback.exclusive_audio"
        const val KEY_GATEWAY_BASE_URL = "gateway.base_url"
    }
}
