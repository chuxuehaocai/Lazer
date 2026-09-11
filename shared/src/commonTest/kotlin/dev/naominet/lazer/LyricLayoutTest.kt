package dev.naominet.lazer

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class LyricLayoutTest {
    @Test
    fun `wrapped neighboring rows create proportionally more space`() {
        val compact = lyricLineCenters(listOf(48f, 48f, 48f), minimumGapPx = 12f, maximumGapPx = 40f)
        val wrapped = lyricLineCenters(listOf(48f, 132f, 48f), minimumGapPx = 12f, maximumGapPx = 40f)

        assertEquals(60f, compact[1])
        assertTrue(wrapped[1] > compact[1])
        assertTrue(wrapped[2] - wrapped[1] > compact[2] - compact[1])
    }

    @Test
    fun `translation gap follows measured main lyric height`() {
        val oneLine = lyricTranslationGapPx(48f, minimumGapPx = 8f, maximumGapPx = 24f)
        val twoLines = lyricTranslationGapPx(96f, minimumGapPx = 8f, maximumGapPx = 24f)

        assertTrue(twoLines > oneLine)
        assertEquals(24f, lyricTranslationGapPx(400f, minimumGapPx = 8f, maximumGapPx = 24f))
    }

    @Test
    fun `visual index interpolates across non uniform centers`() {
        val centers = floatArrayOf(0f, 60f, 180f)

        assertEquals(0.5f, lyricVisualIndex(centers, 30f), 0.0001f)
        assertEquals(1.5f, lyricVisualIndex(centers, 120f), 0.0001f)
    }

    @Test
    fun `font size preference snaps to supported values`() {
        assertEquals(MIN_LYRIC_FONT_SIZE_SP, normalizeLyricFontSizeSp(Int.MIN_VALUE))
        assertEquals(34, normalizeLyricFontSizeSp(35))
        assertEquals(MAX_LYRIC_FONT_SIZE_SP, normalizeLyricFontSizeSp(Int.MAX_VALUE))
    }
}
