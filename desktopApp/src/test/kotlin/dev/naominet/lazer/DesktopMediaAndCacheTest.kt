package dev.naominet.lazer

import dev.nucleusframework.media.control.MediaControlEvent
import dev.naominet.lazer.gateway.model.UserProfile
import fr.delthas.javamp3.Sound
import java.awt.Insets
import java.awt.Rectangle
import java.io.IOException
import java.io.InputStream
import java.nio.file.Files
import java.util.Comparator
import javax.sound.sampled.AudioFormat
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DesktopMediaAndCacheTest {
    @Test
    fun `exclusive PCM volume is applied to every channel`() {
        val format = AudioFormat(
            AudioFormat.Encoding.PCM_SIGNED,
            48_000f,
            16,
            2,
            4,
            48_000f,
            false,
        )
        val pcm = byteArrayOf(0x10, 0x27, 0xF0.toByte(), 0xD8.toByte())

        applyPcm16Volume(pcm, pcm.size, format, 0.5f)

        assertArrayEquals(byteArrayOf(0x88.toByte(), 0x13, 0x78, 0xEC.toByte()), pcm)
    }

    @Test
    fun `WASAPI wave format matches decoded stereo PCM`() {
        val format = AudioFormat(
            AudioFormat.Encoding.PCM_SIGNED,
            44_100f,
            16,
            2,
            4,
            44_100f,
            false,
        )

        waveFormatEx(format).use { wave ->
            assertEquals(1, wave.getShort(0).toInt())
            assertEquals(2, wave.getShort(2).toInt())
            assertEquals(44_100, wave.getInt(4))
            assertEquals(176_400, wave.getInt(8))
            assertEquals(4, wave.getShort(12).toInt())
            assertEquals(16, wave.getShort(14).toInt())
        }
    }

    @Test
    fun `system media buttons map to the player commands`() {
        assertEquals(SystemMediaCommand.Play, MediaControlEvent.Play.toSystemMediaCommand())
        assertEquals(SystemMediaCommand.Pause, MediaControlEvent.Pause.toSystemMediaCommand())
        assertEquals(SystemMediaCommand.Toggle, MediaControlEvent.Toggle.toSystemMediaCommand())
        assertEquals(SystemMediaCommand.Next, MediaControlEvent.Next.toSystemMediaCommand())
        assertEquals(SystemMediaCommand.Previous, MediaControlEvent.Previous.toSystemMediaCommand())
        assertEquals(SystemMediaCommand.Stop, MediaControlEvent.Stop.toSystemMediaCommand())
        assertEquals(
            SystemMediaCommand.SeekBy(-10_000L),
            MediaControlEvent.SeekBy(-10_000L).toSystemMediaCommand(),
        )
        assertEquals(
            SystemMediaCommand.SetPosition(42_000L),
            MediaControlEvent.SetPosition(42_000L).toSystemMediaCommand(),
        )
        assertEquals(
            SystemMediaCommand.SetVolume(0.4),
            MediaControlEvent.SetVolume(0.4).toSystemMediaCommand(),
        )
        assertEquals(null, MediaControlEvent.Raise.toSystemMediaCommand())
    }

    @Test
    fun `system media seeks stay in the playable timeline`() {
        assertEquals(0f, systemPositionProgress(-1_000L, 240_000L), 0f)
        assertEquals(0.5f, systemPositionProgress(120_000L, 240_000L), 0.0001f)
        assertEquals(239f / 240f, systemPositionProgress(999_000L, 240_000L), 0.0001f)
        assertEquals(0L, systemSeekTargetMillis(5_000L, -10_000L, 240_000L))
        assertEquals(240_000L, systemSeekTargetMillis(235_000L, 10_000L, 240_000L))
        assertEquals(0L, systemSeekTargetMillis(Long.MAX_VALUE, Long.MAX_VALUE, 0L))
        assertEquals(
            Long.MAX_VALUE,
            systemSeekTargetMillis(Long.MAX_VALUE - 1L, Long.MAX_VALUE, Long.MAX_VALUE),
        )
    }

    @Test
    fun `global wheel motion keeps the lyric inertia curve`() {
        val motion = WheelInertiaMotion()

        assertEquals(36f, motion.impulse(1f), 0.0001f)
        assertEquals(28f, motion.advance(1f / 60f), 0.0001f)
        assertEquals(25.2f, motion.advance(1f / 60f), 0.0001f)

        // A second wheel tick adds to the existing tail instead of restarting it.
        assertEquals(36f, motion.impulse(1f), 0.0001f)
        assertEquals(50.68f, motion.advance(1f / 60f), 0.0001f)
    }

    @Test
    fun `playlist and track cache round trip unicode metadata`() {
        val directory = Files.createTempDirectory("lazer-playlist-cache-test")
        try {
            val cache = DesktopPlaylistCache(directory)
            val playlist = PlaylistItem(
                42,
                "夜晚散步",
                "18 首 · 初雪",
                "https://img.example/list.jpg",
                18,
                creatorName = "初雪",
            )
            val track = TrackItem(7, "晴天", "周杰伦", "叶惠美", 269_000, "https://img.example/song.jpg")

            cache.savePlaylists("user-9", listOf(playlist))
            cache.saveTracks(playlist.id, listOf(track), complete = true)
            cache.saveLikedTracks(9, listOf(track))

            assertEquals(playlist, cache.loadPlaylists("user-9").single())
            assertEquals(UserProfile(userId = 9, nickname = "初雪"), cache.loadCurrentUser())
            val profile = UserProfile(9, "初雪", "https://img.example/avatar.jpg", "慢慢听")
            cache.saveCurrentUser(profile)
            assertEquals(profile, cache.loadCurrentUser())
            assertEquals(listOf(track), cache.loadLikedTracks(9))
            val cachedTracks = cache.loadTracks(playlist.id)
            assertNotNull(cachedTracks)
            cachedTracks!!
            assertTrue(cachedTracks.complete)
            assertEquals(track, cachedTracks.tracks.single())
        } finally {
            Files.walk(directory).use { paths ->
                paths.sorted(Comparator.reverseOrder()).forEach(Files::deleteIfExists)
            }
        }
    }

    @Test
    fun `non MP3 streams request the compatible playback fallback`() {
        assertTrue(needsMp3PlaybackFallback("flac", "https://cdn.example/song.flac"))
        assertTrue(needsMp3PlaybackFallback("aac", "https://cdn.example/song"))
        assertFalse(needsMp3PlaybackFallback("mp3", "https://cdn.example/song.mp3"))
    }

    @Test
    fun `streaming MP3 decoder is available without JLayer`() {
        assertEquals("fr.delthas.javamp3.Sound", Sound::class.java.name)
        assertTrue(runCatching { Class.forName("javazoom.jl.decoder.Decoder") }.isFailure)
    }

    @Test
    fun `only a real tail EOF advances to the next track`() {
        assertFalse(shouldCompleteAfterEof(240_000, fromProgress = 0f, playedMillis = 90_000))
        assertFalse(shouldCompleteAfterEof(240_000, fromProgress = 0.5f, playedMillis = 70_000))
        assertTrue(shouldCompleteAfterEof(240_000, fromProgress = 0f, playedMillis = 236_000))
        assertTrue(shouldCompleteAfterEof(240_000, fromProgress = 0.75f, playedMillis = 58_000))
    }

    @Test
    fun `playlist cache clear preserves the signed in profile`() {
        val directory = Files.createTempDirectory("lazer-playlist-clear-test")
        try {
            val cache = DesktopPlaylistCache(directory)
            val profile = UserProfile(9, "初雪")
            val playlist = PlaylistItem(42, "夜晚散步", "18 首", null, 18)
            val track = TrackItem(7, "晴天", "周杰伦", "叶惠美", 269_000, null)
            cache.saveCurrentUser(profile)
            cache.savePlaylists("user-9", listOf(playlist))
            cache.saveTracks(playlist.id, listOf(track), complete = true)

            assertEquals(2, cache.clearPlaylistData())
            assertEquals(profile, cache.loadCurrentUser())
            assertTrue(cache.loadPlaylists("user-9").isEmpty())
            assertEquals(null, cache.loadTracks(playlist.id))
        } finally {
            Files.walk(directory).use { paths ->
                paths.sorted(Comparator.reverseOrder()).forEach(Files::deleteIfExists)
            }
        }
    }

    @Test
    fun `audio cache clear removes local media files`() = runBlocking {
        val directory = Files.createTempDirectory("lazer-audio-clear-test")
        try {
            Files.writeString(directory.resolve("7-test.audio"), "cached")
            Files.writeString(directory.resolve("7-test.audio.complete"), "6")
            val cache = DesktopAudioCache(directory) { _, _ -> }

            assertEquals(2, cache.clear())
            assertTrue(Files.list(directory).use { paths -> paths.findAny().isEmpty })
            cache.close()
        } finally {
            Files.walk(directory).use { paths ->
                paths.sorted(Comparator.reverseOrder()).forEach(Files::deleteIfExists)
            }
        }
    }

    @Test
    fun `audio output recovery handles errors closures and repeated zero writes`() {
        assertFalse(shouldRecoverAudioOutput(null, outputOpen = true, consecutiveZeroWrites = 7))
        assertTrue(shouldRecoverAudioOutput(null, outputOpen = true, consecutiveZeroWrites = 8))
        assertTrue(shouldRecoverAudioOutput(null, outputOpen = false, consecutiveZeroWrites = 1))
        assertTrue(
            shouldRecoverAudioOutput(
                IOException("device unavailable"),
                outputOpen = true,
                consecutiveZeroWrites = 1,
            ),
        )
    }

    @Test
    fun `playback clock does not reset when the output line is rebuilt`() {
        val timeline = OutputPlaybackTimeline(frameSize = 4, frameRate = 44_100f)
        timeline.onBytesSubmitted(176_400)

        assertEquals(500L, timeline.playedMillis(currentLineFrames = 22_050))
        timeline.onLineReplaced()
        assertEquals(1_000L, timeline.playedMillis(currentLineFrames = 0))
        assertEquals(1_100L, timeline.playedMillis(currentLineFrames = 4_410))
    }

    @Test
    fun `decoded seek preserves decoder state by reading instead of skipping`() = runBlocking {
        var skipCalled = false
        var emitted = 0
        val input = object : InputStream() {
            override fun read(): Int = if (emitted++ < 64) 0 else -1

            override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                if (emitted >= 64) return -1
                val count = minOf(length, 64 - emitted)
                repeat(count) { buffer[offset + it] = 0 }
                emitted += count
                return count
            }

            override fun skip(count: Long): Long {
                skipCalled = true
                throw ArrayIndexOutOfBoundsException("decoder state lost")
            }
        }

        assertTrue(discardDecodedBytes(input, byteCount = 64) { true })
        assertFalse(skipCalled)
    }

    @Test
    fun `decoded seek always lands on a whole PCM frame`() {
        val byteCount = decodedSeekByteCount(
            durationMillis = 377_045L,
            progress = 0.27103397f,
            frameRate = 48_000f,
            frameSize = 4,
        )

        assertEquals(19_620_864L, byteCount)
        assertEquals(0L, byteCount % 4L)
    }

    @Test
    fun `seek fade starts silent and reaches the original PCM level`() {
        val format = AudioFormat(
            AudioFormat.Encoding.PCM_SIGNED,
            4_000f,
            16,
            2,
            4,
            4_000f,
            false,
        )
        val pcm = ByteArray(4 * 4)
        repeat(8) { sample ->
            pcm[sample * 2] = 0x10
            pcm[sample * 2 + 1] = 0x27
        }
        PcmSeekFadeIn(format, durationMillis = 1).apply(pcm, pcm.size)

        fun sampleAt(index: Int): Int {
            val low = pcm[index * 2].toInt() and 0xFF
            val high = pcm[index * 2 + 1].toInt() and 0xFF
            return ((high shl 8) or low).toShort().toInt()
        }

        assertEquals(0, sampleAt(0))
        assertEquals(0, sampleAt(1))
        assertEquals(3_333, sampleAt(2))
        assertEquals(3_333, sampleAt(3))
        assertEquals(6_667, sampleAt(4))
        assertEquals(6_667, sampleAt(5))
        assertEquals(10_000, sampleAt(6))
        assertEquals(10_000, sampleAt(7))
    }

    @Test
    fun `lyric seeks cannot land exactly at or beyond EOF`() {
        assertEquals(0.5f, lyricSeekProgress(120_000, 240_000), 0.0001f)
        assertEquals(239f / 240f, lyricSeekProgress(999_000, 240_000), 0.0001f)
        assertEquals(0f, lyricSeekProgress(-1_000, 240_000), 0.0001f)
        assertEquals(239f / 240f, playableSeekProgress(1f, 240_000), 0.0001f)
    }

    @Test
    fun `audio cache keys are stable and progress is bounded`() {
        assertEquals("42-320000-mp3.audio", audioCacheFileName(42, "320000-mp3"))
        assertEquals("42-a_b.audio", audioCacheFileName(42, "a/b"))
        assertEquals("abcdef", audioCacheVariant(320_000, "ABCDEF", "mp3"))
        assertEquals("320000-mp3", audioCacheVariant(320_000, null, "MP3"))
        assertEquals(0f, bufferedFraction(1, 0), 0f)
        assertEquals(0.5f, bufferedFraction(50, 100), 0.0001f)
        assertEquals(1f, bufferedFraction(150, 100), 0f)
    }

    @Test
    fun `audio cache streams a growing file and survives a restart`() {
        val directory = Files.createTempDirectory("lazer-audio-cache-test")
        val source = directory.resolve("source.audio")
        val cacheDirectory = directory.resolve("cache")
        val payload = ByteArray(192 * 1024) { index -> (index * 31).toByte() }
        try {
            Files.write(source, payload)
            val firstCache = DesktopAudioCache(cacheDirectory) { _, _ -> }
            val firstRead = firstCache.open(
                trackId = 7,
                variantKey = "test",
                url = source.toUri().toString(),
                expectedBytes = payload.size.toLong(),
            ).use { it.readBytes() }
            firstCache.close()
            assertArrayEquals(payload, firstRead)

            Files.delete(source)
            val restartedCache = DesktopAudioCache(cacheDirectory) { _, _ -> }
            val cachedRead = restartedCache.open(
                trackId = 7,
                variantKey = "test",
                url = source.toUri().toString(),
                expectedBytes = payload.size.toLong(),
            ).use { it.readBytes() }
            restartedCache.close()
            assertArrayEquals(payload, cachedRead)
        } finally {
            Files.walk(directory).use { paths ->
                paths.sorted(Comparator.reverseOrder()).forEach(Files::deleteIfExists)
            }
        }
    }

    @Test
    fun `maximize uses the selected monitor work area`() {
        assertEquals(
            Rectangle(1920, 30, 1880, 1010),
            workAreaBounds(
                screen = Rectangle(1920, 0, 1920, 1080),
                insets = Insets(30, 0, 40, 40),
            ),
        )
    }

    @Test
    fun `artwork urls upgrade scheme and add size param once`() {
        assertEquals(
            "https://p1.music.126.net/cover.jpg?param=256y256",
            "http://p1.music.126.net/cover.jpg".toArtworkUrlForTest(),
        )
        assertEquals(
            "https://p1.music.126.net/cover.jpg?param=140y140",
            "https://p1.music.126.net/cover.jpg?param=140y140".toArtworkUrlForTest(),
        )
        assertEquals(
            "https://p1.music.126.net/cover.jpg?param=256y256",
            "//p1.music.126.net/cover.jpg".toArtworkUrlForTest(),
        )
        assertEquals(
            "https://p1.music.126.net/cover.jpg?param=96y96",
            "http://p1.music.126.net/cover.jpg?param=360y360".toPaletteArtworkUrl(),
        )
    }

    @Test
    fun `lrc parser keeps multi stamps and finds the active line`() {
        val lrc = """
            [00:00.00]作词 : Demo
            [00:12.50]第一句歌词
            [00:18.00][00:40.00]重复的一句
            [01:02.125]最后一句
        """.trimIndent()
        val lines = parseLrc(lrc)
        assertEquals(5, lines.size)
        assertEquals(0L, lines[0].timeMs)
        assertEquals(12_500L, lines[1].timeMs)
        assertEquals("第一句歌词", lines[1].text)
        assertEquals(18_000L, lines[2].timeMs)
        assertEquals("重复的一句", lines[2].text)
        assertEquals(40_000L, lines[3].timeMs)
        assertEquals("重复的一句", lines[3].text)
        assertEquals(62_125L, lines[4].timeMs)

        assertEquals(0, findCurrentLyricIndex(lines, 0))
        assertEquals(0, findCurrentLyricIndex(lines, 1))
        assertEquals(1, findCurrentLyricIndex(lines, 12_500))
        assertEquals(1, findCurrentLyricIndex(lines, 17_999))
        assertEquals(2, findCurrentLyricIndex(lines, 18_000))
        assertEquals(3, findCurrentLyricIndex(lines, 40_000))
        assertEquals(4, findCurrentLyricIndex(lines, 90_000))
        assertEquals(-1, findCurrentLyricIndex(emptyList(), 1_000))
    }
}

/** Mirrors DesktopPlayerApp.toArtworkUrl for JVM unit coverage without Compose. */
internal fun String.toArtworkUrlForTest(): String {
    val trimmed = trim()
    if (trimmed.isEmpty()) return trimmed
    val withScheme = when {
        trimmed.startsWith("//") -> "https:$trimmed"
        trimmed.startsWith("http://") -> "https://" + trimmed.removePrefix("http://")
        else -> trimmed
    }
    if ("param=" in withScheme) return withScheme
    return withScheme + if ('?' in withScheme) "&param=256y256" else "?param=256y256"
}
