package dev.naominet.lazer

import android.content.Context

/** App-scoped preferences for Android presentation settings. */
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

    var lyricFollowDelayMillis: Long
        get() = normalizeLyricFollowDelayMillis(
            preferences.getLong(KEY_LYRIC_FOLLOW_DELAY, DEFAULT_LYRIC_FOLLOW_DELAY_MILLIS),
        )
        set(value) = preferences.edit()
            .putLong(KEY_LYRIC_FOLLOW_DELAY, normalizeLyricFollowDelayMillis(value))
            .apply()

    private companion object {
        const val PREFERENCES_NAME = "lazer.android.settings"
        const val KEY_DARK_THEME = "appearance.dark"
        const val KEY_SYSTEM_MONET = "appearance.system_monet"
        const val KEY_LYRIC_FOLLOW_DELAY = "lyrics.follow_delay_millis"
    }
}
