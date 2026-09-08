package dev.naominet.lazer

import android.media.AudioManager
import dev.naominet.lazer.gateway.AudioQuality
import kotlin.test.assertEquals
import kotlin.test.assertNull
import org.junit.Test

class AndroidPlaybackUrlTest {
    @Test
    fun exclusiveAudioUsesExclusiveTransientFocus() {
        assertEquals(AudioManager.AUDIOFOCUS_GAIN, androidAudioFocusGain(exclusiveAudio = false))
        assertEquals(
            AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE,
            androidAudioFocusGain(exclusiveAudio = true),
        )
    }

    @Test
    fun defaultsUnknownStoredAudioQualityToExHigh() {
        assertEquals(AudioQuality.EXHIGH, parseAndroidAudioQuality(null))
        assertEquals(AudioQuality.EXHIGH, parseAndroidAudioQuality("future-quality"))
        assertEquals(AudioQuality.LOSSLESS, parseAndroidAudioQuality(AudioQuality.LOSSLESS.name))
    }

    @Test
    fun fallsBackFromPreferredQualityWithoutUpgrading() {
        assertEquals(
            listOf(
                AudioQuality.LOSSLESS to false,
                AudioQuality.EXHIGH to false,
                AudioQuality.HIGHER to false,
                AudioQuality.STANDARD to false,
                AudioQuality.LOSSLESS to true,
            ),
            androidAudioQualityAttempts(AudioQuality.LOSSLESS),
        )
        assertEquals(
            listOf(
                AudioQuality.STANDARD to false,
                AudioQuality.STANDARD to true,
            ),
            androidAudioQualityAttempts(AudioQuality.STANDARD),
        )
    }

    @Test
    fun infersAUserOnlyWhenOneLegacyPlaylistCacheExists() {
        assertEquals(42L, cachedUserIdHint(setOf("featured.playlists", "user.playlists.42")))
        assertNull(cachedUserIdHint(setOf("user.playlists.42", "user.playlists.99")))
    }

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
