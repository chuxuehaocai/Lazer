package dev.naominet.lazer

import dev.nucleusframework.media.control.MediaControlEvent
import dev.nucleusframework.media.control.MediaControlService
import dev.nucleusframework.media.control.MediaMetadata
import dev.nucleusframework.media.control.MediaPlaybackState
import dev.nucleusframework.media.control.MediaPlaybackStatus
import java.io.Closeable

internal sealed interface SystemMediaCommand {
    data object Play : SystemMediaCommand
    data object Pause : SystemMediaCommand
    data object Toggle : SystemMediaCommand
    data object Next : SystemMediaCommand
    data object Previous : SystemMediaCommand
    data object Stop : SystemMediaCommand
    data class SeekBy(val offsetMillis: Long) : SystemMediaCommand
    data class SetPosition(val positionMillis: Long) : SystemMediaCommand
    data class SetVolume(val volume: Double) : SystemMediaCommand
}

internal enum class SystemMediaPlaybackStatus {
    STOPPED,
    PAUSED,
    PLAYING,
}

internal data class SystemMediaSnapshot(
    val trackId: Long?,
    val title: String?,
    val artist: String?,
    val album: String?,
    val coverUrl: String?,
    val durationMillis: Long,
    val playbackStatus: SystemMediaPlaybackStatus,
    val positionMillis: Long,
)

private data class PublishedMetadata(
    val trackId: Long?,
    val title: String?,
    val artist: String?,
    val album: String?,
    val coverUrl: String?,
    val durationMillis: Long,
)

/**
 * Publishes Lazer to the desktop operating system's media surface and routes its commands back to
 * the single player controller. Native integration is optional: a platform failure must never
 * interrupt audio playback.
 */
internal class DesktopSystemMediaSession(
    private val onCommand: (SystemMediaCommand) -> Unit,
) : Closeable {
    private var attached = false
    private var metadataPublished = false
    private var lastMetadata: PublishedMetadata? = null
    private var lastPlaybackStatus: SystemMediaPlaybackStatus? = null
    private var lastPositionSecond = Long.MIN_VALUE

    fun start() {
        if (attached) return
        runCatching {
            if (!MediaControlService.isAvailable()) {
                PlaybackDebugLog.event("system-media-unavailable")
                return
            }
            MediaControlService.configure(
                dbusName = "org.mpris.MediaPlayer2.Lazer",
                displayName = "Lazer",
            )
            MediaControlService.attach { event ->
                event.toSystemMediaCommand()?.let { command ->
                    PlaybackDebugLog.event("system-media-command", command.logName())
                    runCatching { onCommand(command) }
                        .onFailure { error ->
                            PlaybackDebugLog.event("system-media-command-error", error.playbackDebugSummary())
                        }
                }
            }
            attached = true
            PlaybackDebugLog.event("system-media-attached")
        }.onFailure { error ->
            PlaybackDebugLog.event("system-media-attach-error", error.playbackDebugSummary())
        }
    }

    fun publish(snapshot: SystemMediaSnapshot, forcePosition: Boolean = false) {
        if (!attached) return
        val metadata = PublishedMetadata(
            trackId = snapshot.trackId,
            title = snapshot.title,
            artist = snapshot.artist,
            album = snapshot.album,
            coverUrl = snapshot.coverUrl?.toSystemArtworkUrl(),
            durationMillis = snapshot.durationMillis.coerceAtLeast(0L),
        )
        if (!metadataPublished || metadata != lastMetadata) {
            runCatching {
                MediaControlService.setMetadata(
                    MediaMetadata(
                        title = metadata.title,
                        artist = metadata.artist,
                        album = metadata.album,
                        coverUrl = metadata.coverUrl,
                        duration = metadata.durationMillis.takeIf { it > 0L },
                    ),
                )
                metadataPublished = true
                lastMetadata = metadata
            }.onFailure { error ->
                PlaybackDebugLog.event("system-media-metadata-error", error.playbackDebugSummary())
            }
        }

        val safePosition = snapshot.positionMillis.coerceIn(0L, metadata.durationMillis.coerceAtLeast(0L))
        val positionSecond = safePosition / 1_000L
        if (
            forcePosition ||
            snapshot.playbackStatus != lastPlaybackStatus ||
            positionSecond != lastPositionSecond
        ) {
            runCatching {
                MediaControlService.setPlaybackState(
                    MediaPlaybackState(
                        status = snapshot.playbackStatus.toNucleusStatus(),
                        positionMs = safePosition,
                    ),
                )
                lastPlaybackStatus = snapshot.playbackStatus
                lastPositionSecond = positionSecond
            }.onFailure { error ->
                PlaybackDebugLog.event("system-media-state-error", error.playbackDebugSummary())
            }
        }
    }

    fun setVolume(volume: Float) {
        if (!attached) return
        runCatching {
            MediaControlService.setVolume(volume.coerceIn(0f, 1f).toDouble())
        }.onFailure { error ->
            PlaybackDebugLog.event("system-media-volume-error", error.playbackDebugSummary())
        }
    }

    override fun close() {
        if (!attached) return
        runCatching {
            MediaControlService.setPlaybackState(
                MediaPlaybackState(MediaPlaybackStatus.STOPPED, 0L),
            )
        }.onFailure { error ->
            PlaybackDebugLog.event("system-media-stop-error", error.playbackDebugSummary())
        }
        runCatching {
            MediaControlService.detach()
        }.onFailure { error ->
            PlaybackDebugLog.event("system-media-detach-error", error.playbackDebugSummary())
        }
        attached = false
    }
}

internal fun MediaControlEvent.toSystemMediaCommand(): SystemMediaCommand? = when (this) {
    MediaControlEvent.Play -> SystemMediaCommand.Play
    MediaControlEvent.Pause -> SystemMediaCommand.Pause
    MediaControlEvent.Toggle -> SystemMediaCommand.Toggle
    MediaControlEvent.Next -> SystemMediaCommand.Next
    MediaControlEvent.Previous -> SystemMediaCommand.Previous
    MediaControlEvent.Stop -> SystemMediaCommand.Stop
    is MediaControlEvent.SeekBy -> SystemMediaCommand.SeekBy(offsetMs)
    is MediaControlEvent.SetPosition -> SystemMediaCommand.SetPosition(positionMs)
    is MediaControlEvent.SetVolume -> SystemMediaCommand.SetVolume(volume)
    is MediaControlEvent.OpenUri,
    MediaControlEvent.Raise,
    MediaControlEvent.Quit,
    -> null
}

internal fun systemPositionProgress(positionMillis: Long, durationMillis: Long): Float {
    if (durationMillis <= 0L) return 0f
    val safePosition = positionMillis.coerceIn(0L, durationMillis)
    return playableSeekProgress(safePosition.toDouble().div(durationMillis).toFloat(), durationMillis)
}

internal fun systemSeekTargetMillis(positionMillis: Long, offsetMillis: Long, durationMillis: Long): Long {
    if (durationMillis <= 0L) return 0L
    val safePosition = positionMillis.coerceIn(0L, durationMillis)
    val safeOffset = offsetMillis.coerceIn(-durationMillis, durationMillis)
    if (safeOffset > 0L && safePosition > durationMillis - safeOffset) return durationMillis
    if (safeOffset < 0L && safePosition < -safeOffset) return 0L
    return safePosition + safeOffset
}

private fun SystemMediaPlaybackStatus.toNucleusStatus(): MediaPlaybackStatus = when (this) {
    SystemMediaPlaybackStatus.STOPPED -> MediaPlaybackStatus.STOPPED
    SystemMediaPlaybackStatus.PAUSED -> MediaPlaybackStatus.PAUSED
    SystemMediaPlaybackStatus.PLAYING -> MediaPlaybackStatus.PLAYING
}

private fun SystemMediaCommand.logName(): String = when (this) {
    SystemMediaCommand.Play -> "play"
    SystemMediaCommand.Pause -> "pause"
    SystemMediaCommand.Toggle -> "toggle"
    SystemMediaCommand.Next -> "next"
    SystemMediaCommand.Previous -> "previous"
    SystemMediaCommand.Stop -> "stop"
    is SystemMediaCommand.SeekBy -> "seek-by"
    is SystemMediaCommand.SetPosition -> "set-position"
    is SystemMediaCommand.SetVolume -> "set-volume"
}

private fun String.toSystemArtworkUrl(): String {
    val value = trim()
    return when {
        value.startsWith("//") -> "https:$value"
        value.startsWith("http://") -> "https://" + value.removePrefix("http://")
        else -> value
    }
}
