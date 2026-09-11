package dev.naominet.lazer

import android.util.Log
import com.hchen.superlyricapi.SuperLyricData
import com.hchen.superlyricapi.SuperLyricHelper
import com.hchen.superlyricapi.SuperLyricLine
import com.hchen.superlyricapi.SuperLyricWord

/**
 * Publishes the current lyric line to the system-wide SuperLyric service so Xposed lyrics modules
 * (status bar, notification shade, dynamic island) can render it.
 *
 * The service controls playback position, the controller owns the parsed lyrics; both run in the
 * same process, so this object is the hand-off. A line is only published when the active line
 * changes, which keeps the Binder traffic to a few calls per minute.
 */
internal object SuperLyricPublisher {
    private const val TAG = "SuperLyricPublisher"

    @Volatile
    private var lines: List<AndroidTimedLyricLine> = emptyList()

    private var lastSentTrackId: Long? = null
    private var lastSentIndex = -1
    private var registered = false
    private var unavailable = false

    /** Registers as a publisher when the SuperLyric service is present. Idempotent. */
    @Synchronized
    fun ensureRegistered(): Boolean {
        if (registered) return true
        // Do not probe the service on every progress tick when it is not installed.
        if (unavailable) return false
        return runCatching {
            if (!SuperLyricHelper.isAvailable()) {
                unavailable = true
                return false
            }
            SuperLyricHelper.registerPublisher()
            // Lazer reports pause/stop itself, so the automatic MediaSession listener is disabled.
            SuperLyricHelper.setSystemPlayStateListenerEnabled(false)
            registered = SuperLyricHelper.isPublisherRegistered()
            registered
        }.onFailure { Log.w(TAG, "register failed", it) }.getOrDefault(false)
    }

    /** Replaces the lyric table. Call when a track's lyrics finish loading or are cleared. */
    fun updateLyrics(trackId: Long, newLines: List<AndroidTimedLyricLine>) {
        // Switching tracks clears the previous song's lyric from the system immediately, even
        // before the new track's lyrics have loaded.
        if (trackId != lastSentTrackId && lastSentIndex != -1) stop()
        lines = newLines
    }

    /**
     * Publishes the line active at [positionMillis] for [track] if it changed. Called from the
     * playback service's progress loop.
     */
    fun onPosition(track: AndroidTrack?, positionMillis: Long) {
        if (track == null || !ensureRegistered()) return
        val index = activeAndroidLyricIndex(lines, positionMillis)
        val line = lines.getOrNull(index)
        // Without a timed lyric line there is nothing to publish. Never fall back to the song
        // title, otherwise a track with no lyrics shows its name as if it were a lyric.
        if (line == null) {
            if (lastSentIndex != -1) stop()
            return
        }
        if (track.id == lastSentTrackId && index == lastSentIndex) return
        lastSentTrackId = track.id
        lastSentIndex = index

        runCatching {
            val end = lineEndMillis(index, track.durationMillis)
            val words = line.words
                .takeIf(List<TimedLyricWord>::isNotEmpty)
                ?.map { word ->
                    SuperLyricWord(word.text, word.startTimeMillis, word.startTimeMillis + word.durationMillis)
                }
                ?.toTypedArray()
            val data = SuperLyricData()
                .setTitle(track.title)
                .setArtist(track.artist)
                .setAlbum(track.album)
                .setLyric(
                    if (words != null) {
                        SuperLyricLine(line.text, words, line.timeMillis, end)
                    } else {
                        SuperLyricLine(line.text, line.timeMillis, end)
                    },
                )
            line.translation?.takeIf(String::isNotBlank)?.let { translation ->
                data.setTranslation(SuperLyricLine(translation, line.timeMillis, end))
            }
            SuperLyricHelper.sendLyric(data)
        }.onFailure { Log.w(TAG, "sendLyric failed", it) }
    }

    /** Tells the service playback paused or stopped so it can freeze the lyric. */
    fun stop() {
        if (!registered) return
        lastSentTrackId = null
        lastSentIndex = -1
        runCatching { SuperLyricHelper.sendStop(SuperLyricData()) }
            .onFailure { Log.w(TAG, "sendStop failed", it) }
    }

    @Synchronized
    fun release() {
        if (!registered) return
        runCatching { SuperLyricHelper.unregisterPublisher() }
        registered = false
        lines = emptyList()
        lastSentTrackId = null
        lastSentIndex = -1
    }

    private fun lineEndMillis(index: Int, trackDurationMillis: Long): Long {
        val current = lines[index]
        val next = lines.getOrNull(index + 1)
        val fromNext = next?.timeMillis
        val fromWords = current.words.maxOfOrNull { it.startTimeMillis + it.durationMillis }
        val end = fromNext ?: fromWords ?: (current.timeMillis + 5_000L)
        return when {
            trackDurationMillis > 0L -> end.coerceAtMost(trackDurationMillis)
            else -> end
        }
    }
}
