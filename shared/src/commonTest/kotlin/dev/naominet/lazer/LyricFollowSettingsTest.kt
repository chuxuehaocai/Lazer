package dev.naominet.lazer

import kotlin.test.Test
import kotlin.test.assertEquals

class LyricFollowSettingsTest {
    @Test
    fun normalizesPersistedDelayToNearestSupportedOption() {
        assertEquals(1_500L, normalizeLyricFollowDelayMillis(Long.MIN_VALUE))
        assertEquals(1_500L, normalizeLyricFollowDelayMillis(900L))
        assertEquals(3_500L, normalizeLyricFollowDelayMillis(3_900L))
        assertEquals(8_000L, normalizeLyricFollowDelayMillis(60_000L))
        assertEquals(8_000L, normalizeLyricFollowDelayMillis(Long.MAX_VALUE))
    }

    @Test
    fun formatsWholeAndFractionalSeconds() {
        assertEquals("1.5 秒", lyricFollowDelayLabel(1_500L))
        assertEquals("5 秒", lyricFollowDelayLabel(5_000L))
    }
}
