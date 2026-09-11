package dev.naominet.lazer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.MediaPlayer
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.annotation.RequiresApi
import dev.naominet.lazer.gateway.AudioQuality
import dev.naominet.lazer.gateway.GatewayConfig
import dev.naominet.lazer.gateway.NeteaseMusicGateway
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URL
import kotlin.math.roundToInt

data class AndroidPlaybackSnapshot(
    val track: AndroidTrack? = null,
    val isPreparing: Boolean = false,
    val isPlaying: Boolean = false,
    val positionMillis: Long = 0L,
    val durationMillis: Long = 0L,
    val bufferedFraction: Float = 0f,
    val message: String? = null,
)

private object AndroidPlaybackStateStore {
    private val mutableSnapshot = MutableStateFlow(AndroidPlaybackSnapshot())
    val snapshot: StateFlow<AndroidPlaybackSnapshot> = mutableSnapshot.asStateFlow()

    fun update(value: AndroidPlaybackSnapshot) {
        mutableSnapshot.value = value
    }
}

/**
 * Holds the current queue in the same app process. The foreground service owns playback; this is
 * only the hand-off from a list tap to that service and lets system next/previous work while it is
 * alive. The active item itself is always mirrored in [AndroidPlaybackStateStore].
 */
private object AndroidPlaybackQueue {
    var tracks: List<AndroidTrack> = emptyList()
    var index: Int = -1

    fun replace(queue: List<AndroidTrack>, track: AndroidTrack) {
        val distinct = queue.distinctBy(AndroidTrack::id)
        tracks = if (distinct.any { it.id == track.id }) {
            distinct
        } else {
            listOf(track) + distinct
        }
        index = tracks.indexOfFirst { it.id == track.id }
    }

    fun current(): AndroidTrack? = tracks.getOrNull(index)

    fun next(): AndroidTrack? {
        if (tracks.isEmpty()) return null
        index = (index + 1) % tracks.size
        return current()
    }

    fun previous(): AndroidTrack? {
        if (tracks.isEmpty()) return null
        index = (index - 1 + tracks.size) % tracks.size
        return current()
    }

    fun adjacent(): List<AndroidTrack> {
        if (tracks.size < 2 || index !in tracks.indices) return emptyList()
        return listOf(
            tracks[(index + 1) % tracks.size],
            tracks[(index - 1 + tracks.size) % tracks.size],
        ).distinctBy(AndroidTrack::id)
    }
}

/** Entry point used by Compose controls. Android's media session calls back into the same service. */
object AndroidPlaybackConnection {
    val snapshot: StateFlow<AndroidPlaybackSnapshot> = AndroidPlaybackStateStore.snapshot

    fun play(context: Context, queue: List<AndroidTrack>, track: AndroidTrack) {
        AndroidPlaybackQueue.replace(queue.ifEmpty { listOf(track) }, track)
        AndroidPlaybackStateStore.update(
            AndroidPlaybackSnapshot(track = track, isPreparing = true, durationMillis = track.durationMillis),
        )
        dispatch(context, AndroidPlaybackService.ACTION_PLAY_TRACK)
    }

    fun toggle(context: Context) = dispatch(context, AndroidPlaybackService.ACTION_TOGGLE)

    fun next(context: Context) = dispatch(context, AndroidPlaybackService.ACTION_NEXT)

    fun previous(context: Context) = dispatch(context, AndroidPlaybackService.ACTION_PREVIOUS)

    fun seekTo(context: Context, positionMillis: Long) = dispatch(
        context,
        AndroidPlaybackService.ACTION_SEEK,
        AndroidPlaybackService.EXTRA_POSITION to positionMillis.coerceAtLeast(0L),
    )

    fun updateExclusiveAudio(context: Context) = dispatch(
        context,
        AndroidPlaybackService.ACTION_EXCLUSIVE_AUDIO_CHANGED,
    )

    fun stopAndClearSession(context: Context) = dispatch(context, AndroidPlaybackService.ACTION_STOP_AND_CLEAR_SESSION)

    private fun dispatch(context: Context, action: String, extra: Pair<String, Long>? = null) {
        val intent = Intent(context, AndroidPlaybackService::class.java).setAction(action)
        extra?.let { intent.putExtra(it.first, it.second) }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent)
        } else {
            context.startService(intent)
        }
    }
}

class AndroidPlaybackService : Service(), AudioManager.OnAudioFocusChangeListener {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val handler = Handler(Looper.getMainLooper())
    private lateinit var mediaSession: MediaSession
    private lateinit var audioManager: AudioManager
    private var audioFocusRequest: AudioFocusRequest? = null
    private lateinit var gatewaySettings: AndroidSettingsStore
    private lateinit var gatewaySessionStore: AndroidGatewaySessionStore
    private lateinit var gateway: NeteaseMusicGateway
    private var player: MediaPlayer? = null
    private var loadingGeneration = 0L
    private var artworkGeneration = 0L
    private var artworkTrackId: Long? = null
    private var artworkBitmap: Bitmap? = null
    private var wasPlayingBeforeFocusLoss = false
    private var foregroundStarted = false
    private val streamUrls = object : LinkedHashMap<AndroidStreamCacheKey, AndroidCachedStreamUrl>(
        STREAM_URL_CACHE_SIZE,
        0.75f,
        true,
    ) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<AndroidStreamCacheKey, AndroidCachedStreamUrl>?): Boolean =
            size > STREAM_URL_CACHE_SIZE
    }
    private val streamUrlPrefetches = mutableSetOf<AndroidStreamCacheKey>()
    private val mediaRequestHeaders = mapOf(
        "User-Agent" to "Mozilla/5.0 (Linux; Android ${Build.VERSION.RELEASE}) Lazer/1.0",
        "Referer" to "https://music.163.com/",
    )

    private val progressReporter = object : Runnable {
        override fun run() {
            val currentPlayer = player ?: return
            val playing = runCatching { currentPlayer.isPlaying }.getOrDefault(false)
            if (playing) {
                publishCurrentState(isPreparing = false, isPlaying = true)
                handler.postDelayed(this, PROGRESS_UPDATE_MILLIS)
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        gatewaySettings = AndroidSettingsStore(applicationContext)
        gatewaySessionStore = AndroidGatewaySessionStore(applicationContext)
        gateway = createGateway(gatewaySettings.gatewayBaseUrl)
        audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) createNotificationChannel()
        mediaSession = MediaSession(this, "Lazer playback").apply {
            setFlags(
                MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or
                    MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS,
            )
            setCallback(
                object : MediaSession.Callback() {
                    override fun onPlay() = resumeCurrent()
                    override fun onPause() = pauseCurrent()
                    override fun onSkipToNext() = playNext()
                    override fun onSkipToPrevious() = playPrevious()
                    override fun onSeekTo(position: Long) = seekTo(position)
                    override fun onStop() = stopPlayback()
                },
            )
            setSessionActivity(contentIntent())
            isActive = true
        }
        SuperLyricPublisher.ensureRegistered()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PLAY_TRACK -> {
                AndroidPlaybackQueue.current()?.let(::resolveAndPlay)
                    ?: publishError(tr("status.audio_queue_end"))
            }
            ACTION_TOGGLE -> if (player?.isPlaying == true) pauseCurrent() else resumeCurrent()
            ACTION_NEXT -> playNext()
            ACTION_PREVIOUS -> playPrevious()
            ACTION_SEEK -> seekTo(intent.getLongExtra(EXTRA_POSITION, 0L))
            ACTION_EXCLUSIVE_AUDIO_CHANGED -> refreshAudioFocusMode()
            ACTION_STOP -> stopPlayback()
            ACTION_STOP_AND_CLEAR_SESSION -> stopPlayback(clearSession = true)
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onAudioFocusChange(focusChange: Int) {
        when (focusChange) {
            AudioManager.AUDIOFOCUS_GAIN -> if (wasPlayingBeforeFocusLoss) {
                wasPlayingBeforeFocusLoss = false
                resumeCurrent(requestFocus = false)
            }
            AudioManager.AUDIOFOCUS_LOSS,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                wasPlayingBeforeFocusLoss = player?.isPlaying == true
                pauseCurrent(abandonExclusiveFocus = false)
            }
        }
    }

    private fun resolveAndPlay(track: AndroidTrack) {
        val generation = ++loadingGeneration
        releasePlayer()
        abandonAudioFocus()
        requestArtwork(track)
        ensureForeground(track, preparing = true)
        AndroidPlaybackStateStore.update(
            AndroidPlaybackSnapshot(
                track = track,
                isPreparing = true,
                durationMillis = track.durationMillis,
            ),
        )
        updateSession(track, isPlaying = false, positionMillis = 0L, isPreparing = true)
        scope.launch {
            val url = runCatching {
                resolveStreamUrl(track.id)
            }.onFailure { error ->
                Log.e(TAG, "Gateway failed to resolve audio URL for ${track.id}", error)
            }.getOrNull()
            if (generation != loadingGeneration) return@launch
            if (url.isNullOrBlank()) {
                publishError(tr("status.track_unplayable"))
                return@launch
            }
            preparePlayer(track, url, generation)
            prefetchAdjacentStreamUrls()
        }
    }

    private fun preparePlayer(track: AndroidTrack, url: String, generation: Long) {
        val newPlayer = MediaPlayer().apply {
            setAudioAttributes(playbackAudioAttributes())
            setOnPreparedListener { readyPlayer ->
                if (generation != loadingGeneration) {
                    readyPlayer.release()
                    return@setOnPreparedListener
                }
                if (!requestAudioFocus()) {
                    publishError(audioFocusFailureMessage())
                    return@setOnPreparedListener
                }
                readyPlayer.start()
                publishCurrentState(isPreparing = false, isPlaying = true)
                ensureForeground(track, preparing = false)
                handler.removeCallbacks(progressReporter)
                handler.post(progressReporter)
            }
            setOnCompletionListener { playNext() }
            setOnBufferingUpdateListener { _, percent ->
                val snapshot = AndroidPlaybackStateStore.snapshot.value
                AndroidPlaybackStateStore.update(
                    snapshot.copy(bufferedFraction = (percent / 100f).coerceIn(0f, 1f)),
                )
            }
            setOnErrorListener { _, what, extra ->
                Log.e(TAG, "MediaPlayer failed for ${track.id}: what=$what extra=$extra")
                if (generation == loadingGeneration) publishError(tr("status.track_unplayable"))
                true
            }
        }
        player = newPlayer
        runCatching {
            newPlayer.setDataSource(
                this@AndroidPlaybackService,
                Uri.parse(url),
                mediaRequestHeaders,
            )
            newPlayer.prepareAsync()
        }.onFailure { error ->
            Log.e(TAG, "MediaPlayer could not open stream for ${track.id}", error)
            if (generation == loadingGeneration) publishError(tr("status.track_unplayable"))
        }
    }

    private suspend fun resolveStreamUrl(
        trackId: Long,
        preferredQuality: AudioQuality = gatewaySettings.audioQuality,
    ): String? {
        refreshGatewayProvider()
        val cacheKey = AndroidStreamCacheKey(trackId, preferredQuality)
        val now = System.currentTimeMillis()
        streamUrls[cacheKey]
            ?.takeIf { it.expiresAtMillis > now }
            ?.let { return it.url }
        streamUrls.remove(cacheKey)

        val attempts = androidAudioQualityAttempts(cacheKey.quality)
        attempts.forEach { (quality, unblock) ->
            val rawUrl = withContext(Dispatchers.IO) {
                runCatching {
                    val streams = gateway.songUrls(listOf(trackId), quality = quality, unblock = unblock).data
                    (streams.firstOrNull { it.id == trackId } ?: streams.firstOrNull())?.url
                }.onFailure { error ->
                    Log.w(TAG, "Audio URL attempt failed for $trackId at ${quality.label}", error)
                }.getOrNull()
            }
            normalizedPlaybackUrl(rawUrl)?.let { url ->
                streamUrls[cacheKey] = AndroidCachedStreamUrl(
                    url = url,
                    expiresAtMillis = now + STREAM_URL_CACHE_TTL_MILLIS,
                )
                return url
            }
        }
        return null
    }

    /** Resolve nearby URLs while the current player is buffering, so next/previous skips avoid a round trip. */
    private fun prefetchAdjacentStreamUrls() {
        val preferredQuality = gatewaySettings.audioQuality
        AndroidPlaybackQueue.adjacent().forEach { track ->
            val cacheKey = AndroidStreamCacheKey(track.id, preferredQuality)
            val usableCachedUrl = streamUrls[cacheKey]?.expiresAtMillis ?: 0L
            if (usableCachedUrl > System.currentTimeMillis() || !streamUrlPrefetches.add(cacheKey)) return@forEach
            scope.launch {
                try {
                    resolveStreamUrl(track.id, preferredQuality)
                } finally {
                    streamUrlPrefetches.remove(cacheKey)
                }
            }
        }
    }

    private fun refreshGatewayProvider() {
        val configuredBaseUrl = gatewaySettings.gatewayBaseUrl
        if (gateway.config.baseUrl == configuredBaseUrl) return
        gateway.close()
        gateway = createGateway(configuredBaseUrl)
    }

    private fun createGateway(baseUrl: String): NeteaseMusicGateway = NeteaseMusicGateway(
        config = GatewayConfig(baseUrl = baseUrl),
        sessionStore = gatewaySessionStore,
    )

    private fun resumeCurrent(requestFocus: Boolean = true) {
        val currentPlayer = player
        if (currentPlayer == null) {
            AndroidPlaybackQueue.current()?.let(::resolveAndPlay)
            return
        }
        if (requestFocus && !requestAudioFocus()) {
            publishError(audioFocusFailureMessage())
            return
        }
        runCatching { currentPlayer.start() }.onSuccess {
            publishCurrentState(isPreparing = false, isPlaying = true)
            AndroidPlaybackStateStore.snapshot.value.track?.let { ensureForeground(it, preparing = false) }
            handler.removeCallbacks(progressReporter)
            handler.post(progressReporter)
        }
    }

    private fun pauseCurrent(abandonExclusiveFocus: Boolean = true) {
        player?.let { currentPlayer ->
            runCatching { if (currentPlayer.isPlaying) currentPlayer.pause() }
            publishCurrentState(isPreparing = false, isPlaying = false)
            AndroidPlaybackStateStore.snapshot.value.track?.let { ensureForeground(it, preparing = false) }
        }
        SuperLyricPublisher.stop()
        if (gatewaySettings.exclusiveAudio && abandonExclusiveFocus) abandonAudioFocus()
    }

    private fun seekTo(positionMillis: Long) {
        player?.let { currentPlayer ->
            val bounded = positionMillis.coerceIn(0L, currentPlayer.duration.coerceAtLeast(0).toLong())
            runCatching { currentPlayer.seekTo(bounded.toInt()) }
            publishCurrentState(isPreparing = false, isPlaying = currentPlayer.isPlaying)
        }
    }

    private fun playNext() {
        AndroidPlaybackQueue.next()?.let(::resolveAndPlay)
    }

    private fun playPrevious() {
        AndroidPlaybackQueue.previous()?.let(::resolveAndPlay)
    }

    private fun stopPlayback(clearSession: Boolean = false) {
        ++loadingGeneration
        ++artworkGeneration
        releasePlayer()
        artworkTrackId = null
        artworkBitmap = null
        streamUrls.clear()
        streamUrlPrefetches.clear()
        abandonAudioFocus()
        SuperLyricPublisher.stop()
        if (clearSession) gateway.clearSession()
        AndroidPlaybackStateStore.update(AndroidPlaybackSnapshot())
        mediaSession.setPlaybackState(
            PlaybackState.Builder().setState(PlaybackState.STATE_STOPPED, 0L, 0f).build(),
        )
        stopForeground(STOP_FOREGROUND_REMOVE)
        foregroundStarted = false
        stopSelf()
    }

    private fun publishCurrentState(isPreparing: Boolean, isPlaying: Boolean) {
        val track = AndroidPlaybackStateStore.snapshot.value.track ?: return
        val currentPlayer = player
        val duration = runCatching { currentPlayer?.duration?.toLong() }.getOrNull()
            ?.takeIf { it > 0L }
            ?: track.durationMillis
        val position = runCatching { currentPlayer?.currentPosition?.toLong() }.getOrNull() ?: 0L
        AndroidPlaybackStateStore.update(
            AndroidPlaybackStateStore.snapshot.value.copy(
                track = track,
                isPreparing = isPreparing,
                isPlaying = isPlaying,
                positionMillis = position.coerceAtLeast(0L),
                durationMillis = duration,
                message = null,
            ),
        )
        updateSession(track, isPlaying, position)
        if (isPlaying) SuperLyricPublisher.onPosition(track, position.coerceAtLeast(0L))
    }

    private fun publishError(message: String) {
        ++loadingGeneration
        releasePlayer()
        abandonAudioFocus()
        val previous = AndroidPlaybackStateStore.snapshot.value
        AndroidPlaybackStateStore.update(previous.copy(isPreparing = false, isPlaying = false, message = message))
        previous.track?.let {
            updateSession(it, isPlaying = false, positionMillis = previous.positionMillis)
            ensureForeground(it, preparing = false)
        }
    }

    private fun updateSession(
        track: AndroidTrack,
        isPlaying: Boolean,
        positionMillis: Long,
        isPreparing: Boolean = false,
    ) {
        val metadata = MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, track.title)
            .putString(MediaMetadata.METADATA_KEY_DISPLAY_TITLE, track.title)
            .putString(MediaMetadata.METADATA_KEY_ARTIST, track.artist)
            .putString(MediaMetadata.METADATA_KEY_DISPLAY_SUBTITLE, track.artist)
            .putString(MediaMetadata.METADATA_KEY_ALBUM, track.album)
            .putString(MediaMetadata.METADATA_KEY_ALBUM_ART_URI, track.coverUrl)
            .putLong(MediaMetadata.METADATA_KEY_DURATION, track.durationMillis)
        artworkBitmap.takeIf { artworkTrackId == track.id }?.let { bitmap ->
            metadata.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, bitmap)
            metadata.putBitmap(MediaMetadata.METADATA_KEY_ART, bitmap)
        }
        mediaSession.setMetadata(metadata.build())
        val state = when {
            isPreparing -> PlaybackState.STATE_BUFFERING
            isPlaying -> PlaybackState.STATE_PLAYING
            else -> PlaybackState.STATE_PAUSED
        }
        mediaSession.setPlaybackState(
            PlaybackState.Builder()
                .setActions(
                    PlaybackState.ACTION_PLAY or
                        PlaybackState.ACTION_PAUSE or
                        PlaybackState.ACTION_PLAY_PAUSE or
                        PlaybackState.ACTION_SKIP_TO_NEXT or
                        PlaybackState.ACTION_SKIP_TO_PREVIOUS or
                        PlaybackState.ACTION_SEEK_TO or
                        PlaybackState.ACTION_STOP,
                )
                .setState(state, positionMillis.coerceAtLeast(0L), if (isPlaying) 1f else 0f)
                .build(),
        )
    }

    private fun requestArtwork(track: AndroidTrack) {
        if (artworkTrackId == track.id && artworkBitmap != null) return
        val url = notificationArtworkUrl(track.coverUrl) ?: return
        val generation = ++artworkGeneration
        artworkTrackId = track.id
        artworkBitmap = null
        scope.launch(Dispatchers.IO) {
            val bitmap = runCatching { downloadArtwork(url) }
                .onFailure { error -> Log.w(TAG, "Artwork failed for ${track.id}", error) }
                .getOrNull()
            withContext(Dispatchers.Main.immediate) {
                val snapshot = AndroidPlaybackStateStore.snapshot.value
                if (generation != artworkGeneration || snapshot.track?.id != track.id || bitmap == null) {
                    return@withContext
                }
                artworkBitmap = bitmap
                updateSession(
                    track = track,
                    isPlaying = snapshot.isPlaying,
                    positionMillis = snapshot.positionMillis,
                    isPreparing = snapshot.isPreparing,
                )
                ensureForeground(track, preparing = snapshot.isPreparing)
            }
        }
    }

    private fun downloadArtwork(url: String): Bitmap? {
        val connection = URL(url).openConnection() as HttpURLConnection
        return try {
            connection.connectTimeout = NETWORK_TIMEOUT_MILLIS
            connection.readTimeout = NETWORK_TIMEOUT_MILLIS
            connection.instanceFollowRedirects = true
            mediaRequestHeaders.forEach(connection::setRequestProperty)
            connection.connect()
            if (connection.responseCode !in 200..299) return null
            val decoded = connection.inputStream.use { input -> BitmapFactory.decodeStream(input) }
                ?: return null
            decoded.fitInsideNotificationArtwork()
        } finally {
            connection.disconnect()
        }
    }

    private fun ensureForeground(track: AndroidTrack, preparing: Boolean) {
        val notification = notification(track, preparing)
        if (!foregroundStarted) {
            startForeground(NOTIFICATION_ID, notification)
            foregroundStarted = true
        } else {
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIFICATION_ID, notification)
        }
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            tr("notification.playing"),
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = tr("notification.controls")
            setShowBadge(false)
        }
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(channel)
    }

    private fun notification(track: AndroidTrack, preparing: Boolean): Notification {
        val isPlaying = AndroidPlaybackStateStore.snapshot.value.isPlaying
        val playAction = if (isPlaying) ACTION_TOGGLE else ACTION_TOGGLE
        val playIcon = if (isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play
        val playLabel = if (isPlaying) tr("player.pause") else tr("player.play")
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
            .setSmallIcon(if (isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play)
            .setContentTitle(track.title)
            .setContentText(if (preparing) tr("notification.preparing") else track.artist)
            .setOnlyAlertOnce(true)
            .setOngoing(isPlaying || preparing)
            .setCategory(Notification.CATEGORY_TRANSPORT)
            .setContentIntent(contentIntent())
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .addAction(notificationAction(android.R.drawable.ic_media_previous, tr("player.previous"), ACTION_PREVIOUS))
            .addAction(notificationAction(playIcon, playLabel, playAction))
            .addAction(notificationAction(android.R.drawable.ic_media_next, tr("player.next"), ACTION_NEXT))
            .setStyle(
                Notification.MediaStyle()
                    .setMediaSession(mediaSession.sessionToken)
                    .setShowActionsInCompactView(0, 1, 2),
            )
        artworkBitmap.takeIf { artworkTrackId == track.id }?.let(builder::setLargeIcon)
        return builder.build()
    }

    private fun notificationAction(icon: Int, label: String, action: String): Notification.Action =
        Notification.Action.Builder(icon, label, actionIntent(action)).build()

    private fun actionIntent(action: String): PendingIntent = PendingIntent.getService(
        this,
        action.hashCode(),
        Intent(this, AndroidPlaybackService::class.java).setAction(action),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun contentIntent(): PendingIntent = PendingIntent.getActivity(
        this,
        0,
        Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun requestAudioFocus(): Boolean {
        abandonAudioFocus()
        val focusGain = androidAudioFocusGain(gatewaySettings.exclusiveAudio)
        val result = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(focusGain)
                .setAudioAttributes(playbackAudioAttributes())
                .setOnAudioFocusChangeListener(this, handler)
                .setWillPauseWhenDucked(true)
                .build()
            audioFocusRequest = request
            audioManager.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(this, AudioManager.STREAM_MUSIC, focusGain)
        }
        return result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    private fun abandonAudioFocus() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocusRequest?.let(audioManager::abandonAudioFocusRequest)
            audioFocusRequest = null
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(this)
        }
    }

    private fun refreshAudioFocusMode() {
        val isPlaying = player?.isPlaying == true
        abandonAudioFocus()
        if (isPlaying && !requestAudioFocus()) publishError(audioFocusFailureMessage())
    }

    private fun playbackAudioAttributes(): AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
        .build()

    private fun audioFocusFailureMessage(): String = if (gatewaySettings.exclusiveAudio) {
        tr("status.exclusive_fail")
    } else {
        tr("status.audio_fail")
    }

    private fun releasePlayer() {
        handler.removeCallbacks(progressReporter)
        player?.let { currentPlayer ->
            runCatching { currentPlayer.reset() }
            runCatching { currentPlayer.release() }
        }
        player = null
    }

    override fun onDestroy() {
        ++artworkGeneration
        artworkTrackId = null
        artworkBitmap = null
        releasePlayer()
        abandonAudioFocus()
        mediaSession.isActive = false
        mediaSession.release()
        SuperLyricPublisher.release()
        scope.cancel()
        gateway.close()
        super.onDestroy()
    }

    companion object {
        const val ACTION_PLAY_TRACK = "dev.naominet.lazer.action.PLAY_TRACK"
        const val ACTION_TOGGLE = "dev.naominet.lazer.action.TOGGLE"
        const val ACTION_NEXT = "dev.naominet.lazer.action.NEXT"
        const val ACTION_PREVIOUS = "dev.naominet.lazer.action.PREVIOUS"
        const val ACTION_SEEK = "dev.naominet.lazer.action.SEEK"
        const val ACTION_EXCLUSIVE_AUDIO_CHANGED = "dev.naominet.lazer.action.EXCLUSIVE_AUDIO_CHANGED"
        const val ACTION_STOP = "dev.naominet.lazer.action.STOP"
        const val ACTION_STOP_AND_CLEAR_SESSION = "dev.naominet.lazer.action.STOP_AND_CLEAR_SESSION"
        const val EXTRA_POSITION = "position_millis"

        private const val CHANNEL_ID = "lazer.playback"
        private const val NOTIFICATION_ID = 2036
        private const val PROGRESS_UPDATE_MILLIS = 100L
        private const val NETWORK_TIMEOUT_MILLIS = 10_000
        private const val STREAM_URL_CACHE_SIZE = 6
        private const val STREAM_URL_CACHE_TTL_MILLIS = 4 * 60_000L
        private const val TAG = "LazerPlayback"
    }
}

private data class AndroidStreamCacheKey(
    val trackId: Long,
    val quality: AudioQuality,
)

private data class AndroidCachedStreamUrl(
    val url: String,
    val expiresAtMillis: Long,
)

internal fun androidAudioFocusGain(exclusiveAudio: Boolean): Int = if (exclusiveAudio) {
    AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE
} else {
    AudioManager.AUDIOFOCUS_GAIN
}

internal fun androidAudioQualityAttempts(preferred: AudioQuality): List<Pair<AudioQuality, Boolean>> {
    val preferredIndex = ANDROID_AUDIO_QUALITY_OPTIONS.indexOf(preferred)
        .takeIf { it >= 0 }
        ?: ANDROID_AUDIO_QUALITY_OPTIONS.indexOf(AudioQuality.EXHIGH)
    val normalAttempts = ANDROID_AUDIO_QUALITY_OPTIONS
        .subList(0, preferredIndex + 1)
        .asReversed()
        .map { it to false }
    return normalAttempts + (preferred to true)
}

internal fun normalizedPlaybackUrl(raw: String?): String? {
    val value = raw?.trim()?.takeIf(String::isNotBlank) ?: return null
    return when {
        value.startsWith("//") -> "https:$value"
        value.startsWith("http://", ignoreCase = true) -> "https://${value.substringAfter("://")}"
        value.startsWith("https://", ignoreCase = true) -> value
        else -> null
    }
}

private fun notificationArtworkUrl(raw: String?): String? = normalizedArtworkUrl(raw)?.let { url ->
    if (url.contains("music.126.net") && !url.contains("param=")) {
        "$url${if (url.contains('?')) '&' else '?'}param=320y320"
    } else {
        url
    }
}

private fun Bitmap.fitInsideNotificationArtwork(maxSide: Int = 320): Bitmap {
    val longestSide = maxOf(width, height)
    if (longestSide <= maxSide) return this
    val scale = maxSide.toFloat() / longestSide.toFloat()
    val targetWidth = (width * scale).roundToInt().coerceAtLeast(1)
    val targetHeight = (height * scale).roundToInt().coerceAtLeast(1)
    return Bitmap.createScaledBitmap(this, targetWidth, targetHeight, true).also { scaled ->
        if (scaled !== this) recycle()
    }
}
