package dev.naominet.lazer

import java.nio.file.Files
import java.util.Comparator
import java.util.ServiceLoader
import javax.sound.sampled.spi.AudioFileReader
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DesktopMediaAndCacheTest {
    @Test
    fun `playlist and track cache round trip unicode metadata`() {
        val directory = Files.createTempDirectory("lazer-playlist-cache-test")
        try {
            val cache = DesktopPlaylistCache(directory)
            val playlist = PlaylistItem(42, "夜晚散步", "18 首 · 初雪", "https://img.example/list.jpg", 18)
            val track = TrackItem(7, "晴天", "周杰伦", "叶惠美", 269_000, "https://img.example/song.jpg")

            cache.savePlaylists("user-9", listOf(playlist))
            cache.saveTracks(playlist.id, listOf(track), complete = true)

            assertEquals(playlist, cache.loadPlaylists("user-9").single())
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
    fun `MP3 decoder is discoverable through Java Sound`() {
        val readers = ServiceLoader.load(AudioFileReader::class.java).toList()
        assertTrue(readers.any { it.javaClass.name.contains("MpegAudioFileReader") })
    }

    @Test
    fun `artwork urls upgrade scheme and add size param once`() {
        assertEquals(
            "https://p1.music.126.net/cover.jpg?param=360y360",
            "http://p1.music.126.net/cover.jpg".toArtworkUrlForTest(),
        )
        assertEquals(
            "https://p1.music.126.net/cover.jpg?param=140y140",
            "https://p1.music.126.net/cover.jpg?param=140y140".toArtworkUrlForTest(),
        )
        assertEquals(
            "https://p1.music.126.net/cover.jpg?param=360y360",
            "//p1.music.126.net/cover.jpg".toArtworkUrlForTest(),
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
    return withScheme + if ('?' in withScheme) "&param=360y360" else "?param=360y360"
}
