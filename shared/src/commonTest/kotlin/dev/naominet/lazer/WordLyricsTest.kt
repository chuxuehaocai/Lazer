package dev.naominet.lazer

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class WordLyricsTest {
    @Test
    fun parsesYrcLineAndAbsoluteWordTimings() {
        val lines = parseWordLyrics(
            "[16210,3460](16210,670,0)还(16880,410,0)没 (17290,980,0)见",
        )

        assertEquals(1, lines.size)
        assertEquals(16_210L, lines.single().timeMillis)
        assertEquals("还没 见", lines.single().text)
        assertEquals(listOf(16_210L, 16_880L, 17_290L), lines.single().words.map { it.startTimeMillis })
    }

    @Test
    fun highlightAdvancesThroughCompletedAndActiveWords() {
        val words = listOf(
            TimedLyricWord(1_000L, 500L, "你"),
            TimedLyricWord(1_500L, 500L, "好呀"),
        )

        assertEquals(0, lyricHighlightCharacterCount(words, 999L, LyricAnimationSpeed.STANDARD))
        assertEquals(1, lyricHighlightCharacterCount(words, 1_500L, LyricAnimationSpeed.STANDARD))
        assertTrue(lyricHighlightCharacterCount(words, 1_800L, LyricAnimationSpeed.RESPONSIVE) >= 2)
        assertEquals(3, lyricHighlightCharacterCount(words, 2_000L, LyricAnimationSpeed.STANDARD))
    }

    @Test
    fun malformedMetadataAndEmptyRowsAreIgnored() {
        assertTrue(parseWordLyrics("{\"t\":0}\n[broken]\n[100,80]").isEmpty())
    }

    @Test
    fun animationSpeedKeepsPersistedNamesAndAddsFineGrainedChoices() {
        assertEquals(LyricAnimationSpeed.RELAXED, parseLyricAnimationSpeed("RELAXED"))
        assertEquals(LyricAnimationSpeed.STANDARD, parseLyricAnimationSpeed("STANDARD"))
        assertEquals(LyricAnimationSpeed.RESPONSIVE, parseLyricAnimationSpeed("RESPONSIVE"))
        assertEquals(7, LyricAnimationSpeed.entries.size)
    }
}
