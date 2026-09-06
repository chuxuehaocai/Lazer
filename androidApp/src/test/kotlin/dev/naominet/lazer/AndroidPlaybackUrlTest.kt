package dev.naominet.lazer

import kotlin.test.assertEquals
import kotlin.test.assertNull
import org.junit.Test

class AndroidPlaybackUrlTest {
    @Test
    fun upgradesClearTextCdnUrlForModernAndroid() {
        assertEquals(
            "https://m801.music.126.net/song.mp3?token=1",
            normalizedPlaybackUrl("http://m801.music.126.net/song.mp3?token=1"),
        )
    }

    @Test
    fun fillsProtocolRelativeUrl() {
        assertEquals(
            "https://m801.music.126.net/song.mp3",
            normalizedPlaybackUrl("//m801.music.126.net/song.mp3"),
        )
    }

    @Test
    fun rejectsNonNetworkPlaybackSource() {
        assertNull(normalizedPlaybackUrl("file:///storage/emulated/0/song.mp3"))
    }
}
