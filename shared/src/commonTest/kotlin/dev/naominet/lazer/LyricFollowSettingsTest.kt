package dev.naominet.lazer

import kotlin.test.Test
import kotlin.test.assertEquals

class LyricFollowSettingsTest {
    @Test
    fun normalizesPersistedDelayToNearestSupportedOption() {
        assertEquals(500L, normalizeLyricFollowDelayMillis(Long.MIN_VALUE))
        assertEquals(1_000L, normalizeLyricFollowDelayMillis(900L))
        assertEquals(4_000L, normalizeLyricFollowDelayMillis(3_900L))
        assertEquals(5_000L, normalizeLyricFollowDelayMillis(60_000L))
        assertEquals(5_000L, normalizeLyricFollowDelayMillis(Long.MAX_VALUE))
    }

    @Test
    fun formatsWholeAndFractionalSeconds() {
        LazerI18n.install(
            LazerLanguage.entries.associateWith { language ->
                mapOf(
                    "lyric.follow.seconds" to
                        if (language == LazerLanguage.ENGLISH) "{0} sec" else "{0} 秒",
                )
            },
        )
        LazerI18n.switchLanguage(LazerLanguage.SIMPLIFIED_CHINESE)
        assertEquals("0.5 秒", lyricFollowDelayLabel(500L))
        assertEquals("5 秒", lyricFollowDelayLabel(5_000L))
        LazerI18n.switchLanguage(LazerLanguage.ENGLISH)
        assertEquals("0.5 sec", lyricFollowDelayLabel(500L))
        assertEquals("5 sec", lyricFollowDelayLabel(5_000L))
        LazerI18n.switchLanguage(LazerLanguage.SIMPLIFIED_CHINESE)
    }
}
