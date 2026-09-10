package dev.naominet.lazer

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class LyricMotionTest {
    @Test
    fun longSyllablesHaveFractionalProgressAndSeekBackwards() {
        val word = TimedLyricWord(1_000L, 2_000L, "你")
        assertEquals(0f, lyricWordProgress(word, 900L))
        assertEquals(0.25f, lyricWordProgress(word, 1_500L))
        assertEquals(1f, lyricWordProgress(word, 3_500L))
        assertEquals(0.1f, lyricWordProgress(word, 1_200L))
        assertEquals(1f, lyricWordProgress(word.copy(durationMillis = 0), 1_001L))
    }

    @Test
    fun followConvergesWithoutOvershootAtDifferentFrameRates() {
        fun simulate(fps: Int): Float {
            var position = 0f
            repeat(fps) {
                val next = nextLyricScrollPosition(position, 112f, 1f / fps, LyricAnimationSpeed.STANDARD)
                assertTrue(next >= position && next <= 112f)
                position = next
            }
            return position
        }
        assertEquals(simulate(30), simulate(120), 0.001f)
        assertTrue(simulate(60) > 111f)
    }

    @Test
    fun followUsesANonlinearEaseCurve() {
        val firstFrame = nextLyricScrollPosition(0f, 100f, 0.05f, LyricAnimationSpeed.STANDARD)
        val secondFrame = nextLyricScrollPosition(firstFrame, 100f, 0.05f, LyricAnimationSpeed.STANDARD)
        val thirdFrame = nextLyricScrollPosition(secondFrame, 100f, 0.05f, LyricAnimationSpeed.STANDARD)
        assertTrue(firstFrame > secondFrame - firstFrame)
        assertTrue(secondFrame - firstFrame > thirdFrame - secondFrame)
    }

    @Test
    fun visualWordTimingStartsEarlyAndFinishesLate() {
        val word = TimedLyricWord(1_000L, 300L, "你")
        val nextWord = TimedLyricWord(1_300L, 300L, "好")
        assertTrue(lyricWordVisualProgress(word, 999L, LyricAnimationSpeed.STANDARD) > 0f)
        assertTrue(lyricWordVisualProgress(word, 1_301L, LyricAnimationSpeed.STANDARD) < 1f)
        assertTrue(lyricWordVisualProgress(word, 1_300L, LyricAnimationSpeed.STANDARD) < 1f)
        assertTrue(lyricWordVisualProgress(nextWord, 1_300L, LyricAnimationSpeed.STANDARD) > 0f)
        assertTrue(
            lyricWordSmoothingMillis(LyricAnimationSpeed.VERY_RELAXED) >
                lyricWordSmoothingMillis(LyricAnimationSpeed.VERY_RESPONSIVE),
        )
    }

    @Test
    fun amllMaskMovesOneHalfEmFadeBandAcrossTheMeasuredWord() {
        assertEquals(0f, lyricMaskForegroundAlpha(0f, 0f, 100f, 20f), 0.0001f)
        assertEquals(0.5f, lyricMaskForegroundAlpha(0.5f, 50f, 100f, 20f), 0.0001f)
        assertEquals(1f, lyricMaskForegroundAlpha(1f, 100f, 100f, 20f), 0.0001f)
    }

    @Test
    fun amllEmphasisIsBellShapedAndOnlyTargetsLongWords() {
        assertEquals(0f, amllEmphasisEasing(0f), 0.001f)
        assertTrue(amllEmphasisEasing(0.5f) > 0.99f)
        assertEquals(0f, amllEmphasisEasing(1f), 0.001f)
        assertTrue(shouldEmphasizeLyricWord(TimedLyricWord(0L, 1_100L, "长")))
        assertTrue(!shouldEmphasizeLyricWord(TimedLyricWord(0L, 500L, "短")))
    }

    @Test
    fun glyphMappingKeepsEmojiAndCombiningMarksTogether() {
        val text = "A👩‍🎤e\u0301好"
        val glyphs = buildTimedLyricGlyphs(text, listOf(TimedLyricWord(0L, 2_000L, text)))
        assertEquals(4, glyphs.size)
        assertEquals(listOf("A", "👩‍🎤", "e\u0301", "好"), glyphs.map {
            text.substring(it.startOffset, it.endOffset)
        })
        assertTrue(glyphs.all { it.characterCount == 4 })
    }

    @Test
    fun lineSpringsCascadeAndThenSettleAtTheSameTarget() {
        val field = LyricLineMotionField().apply { reset(lineCount = 8, position = 0f) }
        field.advance(
            target = 112f,
            activeIndex = 3,
            seconds = 1f / 60f,
            intervalMillis = 500L,
            speed = LyricAnimationSpeed.STANDARD,
        )
        assertTrue(field.positionFor(0) > field.positionFor(3))

        repeat(240) {
            field.advance(
                target = 112f,
                activeIndex = 3,
                seconds = 1f / 60f,
                intervalMillis = 500L,
                speed = LyricAnimationSpeed.STANDARD,
            )
        }
        repeat(8) { assertEquals(112f, field.positionFor(it), 0.05f) }
    }

}
