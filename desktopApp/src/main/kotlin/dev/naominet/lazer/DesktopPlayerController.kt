package dev.naominet.lazer

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import dev.naominet.lazer.gateway.AudioQuality
import dev.naominet.lazer.gateway.GatewayConfig
import dev.naominet.lazer.gateway.NeteaseMusicGateway
import dev.naominet.lazer.gateway.normalizeGatewayBaseUrl
import dev.naominet.lazer.gateway.model.Playlist
import dev.naominet.lazer.gateway.model.QrCheckResponse
import dev.naominet.lazer.gateway.model.Song
import dev.naominet.lazer.gateway.model.SongUrl
import dev.naominet.lazer.gateway.model.UserProfile
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.swing.Swing
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.roundToInt

data class TrackItem(
    val id: Long,
    val title: String,
    val artist: String,
    val album: String,
    val durationMillis: Long,
    val coverUrl: String?,
) {
    val durationLabel: String
        get() = formatDuration(durationMillis)
}

data class PlaylistItem(
    val id: Long,
    val title: String,
    val subtitle: String,
    val coverUrl: String?,
    val trackCount: Int,
    val creatorName: String? = null,
    /** True for the account's private "liked songs" collection (sidebar 我喜欢). */
    val isLikedCollection: Boolean = false,
)

internal fun visiblePlaylistTracks(
    activePlaylist: PlaylistItem?,
    activePlaylistTracks: List<TrackItem>,
    refreshedHomeTracks: List<TrackItem>,
): List<TrackItem> = if (activePlaylist == null) refreshedHomeTracks else activePlaylistTracks

enum class LoginMethod { QR_CODE, PASSWORD }

enum class QrLoginState {
    IDLE,
    CREATING,
    WAITING_FOR_SCAN,
    WAITING_FOR_CONFIRMATION,
    EXPIRED,
    AUTHORIZED,
    ERROR,
}

private data class PlaybackProgress(val token: Long, val value: Float)
private data class CacheProgress(val trackId: Long, val value: Float)
private data class DesktopStreamCacheKey(val trackId: Long, val quality: AudioQuality)
private data class CachedDesktopSongUrl(val songUrl: SongUrl, val expiresAtMillis: Long)
private data class DesktopCachedLibrary(
    val playlists: List<PlaylistItem>,
    val likedTracks: List<TrackItem>,
)

private data class DesktopCachedBootstrap(
    val hasSavedSession: Boolean,
    val profile: UserProfile?,
    val featuredPlaylists: List<PlaylistItem>,
    val recentTracks: List<TrackItem>,
    val library: DesktopCachedLibrary?,
)

class DesktopPlayerController(
    private var gateway: NeteaseMusicGateway = createDesktopGateway(),
) {
    private val controllerJob = SupervisorJob()
    private val scope = CoroutineScope(controllerJob + Dispatchers.Swing)
    private val playlistCache = DesktopPlaylistCache()
    private val systemMediaSession = DesktopSystemMediaSession(::handleSystemMediaCommand)
    private var searchJob: Job? = null
    private var playJob: Job? = null
    private var playlistJob: Job? = null
    private var lyricsJob: Job? = null
    private var paletteJob: Job? = null
    private var qrLoginJob: Job? = null
    private var bootstrapJob: Job? = null
    private var maintenanceJob: Job? = null
    private var playlistRequestGeneration = 0L
    private val streamUrls = object : LinkedHashMap<DesktopStreamCacheKey, CachedDesktopSongUrl>(
        STREAM_URL_CACHE_SIZE,
        0.75f,
        true,
    ) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<DesktopStreamCacheKey, CachedDesktopSongUrl>?): Boolean =
            size > STREAM_URL_CACHE_SIZE
    }
    private val streamUrlPrefetches = mutableSetOf<DesktopStreamCacheKey>()
    private var started = false
    private val activePlaybackToken = AtomicLong(0L)
    private val progressEvents = Channel<PlaybackProgress>(Channel.CONFLATED)
    private val cacheProgressEvents = Channel<CacheProgress>(Channel.CONFLATED)
    private val progressCollectorJob = scope.launch {
        for (event in progressEvents) {
            if (event.token == activePlaybackToken.get() && !isSeeking) {
                progress = event.value
                publishSystemMedia()
            }
        }
    }
    private val cacheProgressCollectorJob = scope.launch {
        for (event in cacheProgressEvents) {
            if (nowPlaying?.id == event.trackId) {
                bufferedProgress = event.value.coerceIn(0f, 1f)
            }
        }
    }
    private val audioPlayer = DesktopAudioPlayer(
        // A conflated channel keeps at most one pending UI update. This prevents a busy Swing
        // thread from accumulating one coroutine and captured object for every audio tick.
        onProgress = { token, value -> progressEvents.trySend(PlaybackProgress(token, value)) },
        onBuffered = { trackId, value -> cacheProgressEvents.trySend(CacheProgress(trackId, value)) },
        onCompleted = { token ->
            scope.launch {
                if (!activePlaybackToken.compareAndSet(token, 0L)) {
                    PlaybackDebugLog.event("playback-complete-ignored", "token=$token active=${activePlaybackToken.get()}")
                    return@launch
                }
                PlaybackDebugLog.event("playback-complete", "token=$token track=${nowPlaying?.id}")
                progress = 1f
                when {
                    repeat -> {
                        nowPlaying?.let { resolveAndPlay(it) } ?: run { isPlaying = false }
                        publishSystemMedia(forcePosition = true)
                    }
                    effectiveQueue().isEmpty() -> {
                        isPlaying = false
                        publishSystemMedia(forcePosition = true)
                    }
                    else -> playNext()
                }
            }
        },
        onError = { token, error ->
            scope.launch {
                if (!activePlaybackToken.compareAndSet(token, 0L)) {
                    PlaybackDebugLog.event(
                        "playback-error-ignored",
                        "token=$token active=${activePlaybackToken.get()} error=${error.playbackDebugSummary()}",
                    )
                    return@launch
                }
                PlaybackDebugLog.event(
                    "playback-error",
                    "token=$token track=${nowPlaying?.id} seeking=$isSeeking progress=$progress error=${error.playbackDebugSummary()}",
                )
                isPlaying = false
                isSeeking = false
                streamUrl = null
                statusMessage = error.toFriendlyMessage(tr("status.audio_fail"))
                publishSystemMedia(
                    statusOverride = SystemMediaPlaybackStatus.STOPPED,
                    forcePosition = true,
                )
            }
        },
        initialExclusiveAudio = DesktopSettings.exclusiveAudio,
    )

    var isDark by mutableStateOf(DesktopSettings.isDark)
        private set
    var themeEngine by mutableStateOf(DesktopSettings.themeEngine)
        private set
    var language by mutableStateOf(DesktopSettings.language)
        private set
    var lyricFollowDelayMillis by mutableStateOf(DesktopSettings.lyricFollowDelayMillis)
        private set
    var lyricAnimationSpeed by mutableStateOf(DesktopSettings.lyricAnimationSpeed)
        private set
    var wordLyricsEnabled by mutableStateOf(DesktopSettings.wordLyricsEnabled)
        private set
    var lyricGlowEnabled by mutableStateOf(DesktopSettings.lyricGlowEnabled)
        private set
    var lyricFontSizeSp by mutableIntStateOf(DesktopSettings.lyricFontSizeSp)
        private set
    var showFullLyrics by mutableStateOf(DesktopSettings.showFullLyrics)
        private set
    var gatewayBaseUrl by mutableStateOf(gateway.config.baseUrl)
        private set
    var isLoading by mutableStateOf(false)
        private set
    var statusMessage by mutableStateOf<String?>(null)
        private set
    var searchQuery by mutableStateOf("")
        private set
    var featuredPlaylists by mutableStateOf<List<PlaylistItem>>(emptyList())
        private set
    var userPlaylists by mutableStateOf<List<PlaylistItem>>(emptyList())
        private set
    var recentTracks by mutableStateOf<List<TrackItem>>(emptyList())
        private set
    var likedTracks by mutableStateOf<List<TrackItem>>(emptyList())
        private set
    var searchResults by mutableStateOf<List<TrackItem>>(emptyList())
        private set
    var activePlaylist by mutableStateOf<PlaylistItem?>(null)
        private set
    var activePlaylistTracks by mutableStateOf<List<TrackItem>>(emptyList())
        private set
    val activePlaylistTitle: String?
        get() = activePlaylist?.title
    var nowPlaying by mutableStateOf<TrackItem?>(null)
        private set
    var isPlaying by mutableStateOf(false)
        private set
    var progress by mutableFloatStateOf(0f)
        private set
    /** Fraction of the current encoded audio already available in the persistent local cache. */
    var bufferedProgress by mutableFloatStateOf(0f)
        private set
    /** True while the user is dragging the seek bar — freezes display smoothing. */
    var isSeeking by mutableStateOf(false)
        private set
    var volume by mutableFloatStateOf(0.72f)
        private set
    var audioQuality by mutableStateOf(AudioQuality.EXHIGH)
        private set
    var exclusiveAudio by mutableStateOf(DesktopSettings.exclusiveAudio && isWindowsDesktop())
        private set
    var streamUrl by mutableStateOf<String?>(null)
        private set
    var streamBitrate by mutableStateOf<Int?>(null)
        private set
    private var streamCacheVariant = "default"
    private var streamExpectedBytes: Long? = null
    var isLiked by mutableStateOf(false)
        private set
    var shuffle by mutableStateOf(false)
        private set
    var repeat by mutableStateOf(false)
        private set

    var lyrics by mutableStateOf<List<TimedLyricLine>>(emptyList())
        private set
    var lyricsLoading by mutableStateOf(false)
        private set
    var lyricsError by mutableStateOf<String?>(null)
        private set
    var isLyricsVisible by mutableStateOf(false)
        private set
    /** Album-art-derived colors driving the continuous lyric background. */
    var lyricFlowColors by mutableStateOf(CoverPalette.defaultFlow)
        private set

    /** Playback position derived from progress and the current track duration. */
    val positionMillis: Long
        get() {
            val duration = nowPlaying?.durationMillis ?: return 0L
            return (duration * progress.toDouble()).toLong().coerceIn(0L, duration)
        }

    val currentLyricIndex: Int
        get() = findCurrentLyricIndex(lyrics, positionMillis)

    var currentUser by mutableStateOf<UserProfile?>(null)
        private set
    val isSignedIn: Boolean
        get() = currentUser != null

    var isLoginVisible by mutableStateOf(false)
        private set
    var loginMethod by mutableStateOf(LoginMethod.QR_CODE)
        private set
    var qrLoginState by mutableStateOf(QrLoginState.IDLE)
        private set
    var qrImageData by mutableStateOf<String?>(null)
        private set
    var qrFallbackUrl by mutableStateOf<String?>(null)
        private set
    var loginIdentifier by mutableStateOf("")
        private set
    var loginPassword by mutableStateOf("")
        private set
    var loginError by mutableStateOf<String?>(null)
        private set
    var isSubmittingLogin by mutableStateOf(false)
        private set
    private var activeRequests by mutableIntStateOf(0)

    fun start() {
        if (started) return
        started = true
        LazerI18n.switchLanguage(language)
        systemMediaSession.start()
        systemMediaSession.setVolume(volume)
        scope.launch {
            loadLazerTranslations()
            connectMusicService()
        }
    }

    private fun connectMusicService() {
        bootstrapJob?.cancel()
        val gatewayAtStart = gateway
        bootstrapJob = scope.launch {
            val cached = withContext(Dispatchers.IO) {
                val hasSavedSession = !gatewayAtStart.sessionCookie.isNullOrBlank()
                val profile = playlistCache.loadCurrentUser().takeIf { hasSavedSession }
                val library = profile?.let {
                    DesktopCachedLibrary(
                        playlists = playlistCache.loadPlaylists(userPlaylistCacheKey(it.userId)),
                        likedTracks = playlistCache.loadLikedTracks(it.userId),
                    )
                }
                DesktopCachedBootstrap(
                    hasSavedSession = hasSavedSession,
                    profile = profile,
                    // Older builds cached `/recommend/resource` entries before `picUrl` was mapped.
                    featuredPlaylists = playlistCache.loadPlaylists(FEATURED_CACHE_KEY)
                        .filter { !it.coverUrl.isNullOrBlank() },
                    recentTracks = playlistCache.loadTracks(RECENT_TRACKS_CACHE_ID)?.tracks.orEmpty(),
                    library = library,
                )
            }
            if (gatewayAtStart !== gateway) return@launch
            featuredPlaylists = cached.featuredPlaylists
            recentTracks = cached.recentTracks
            if (nowPlaying == null) nowPlaying = recentTracks.firstOrNull()
            nowPlaying?.let { track ->
                loadCoverPalette(track.coverUrl, track.id)
                if (lyrics.isEmpty()) loadLyrics(track.id)
            }
            if (cached.profile != null && cached.library != null) {
                currentUser = cached.profile
                userPlaylists = cached.library.playlists
                likedTracks = cached.library.likedTracks
                isLiked = nowPlaying?.let { track -> likedTracks.any { it.id == track.id } } ?: false
            } else {
                currentUser = null
                userPlaylists = emptyList()
                likedTracks = emptyList()
                isLiked = false
            }
            publishSystemMedia(forcePosition = true)
            beginRequest(if (cached.profile != null) tr("status.syncing_music") else tr("status.connecting"))
            try {
                if (!cached.hasSavedSession) {
                    loadPublicLibrary()
                } else {
                    val freshProfile = resolveStoredProfile()
                    if (freshProfile == null) {
                        gateway.clearSession()
                        playlistCache.clearCurrentUser()
                        currentUser = null
                        userPlaylists = emptyList()
                        likedTracks = emptyList()
                        isLiked = false
                        loadPublicLibrary()
                    } else {
                        currentUser = freshProfile
                        playlistCache.saveCurrentUser(freshProfile)
                        restoreCachedUserLibrary(freshProfile)
                        syncUserLibrary(freshProfile)
                    }
                }
                statusMessage = null
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                statusMessage = if (currentUser != null) {
                    tr("status.local_only")
                } else {
                    error.toFriendlyMessage(tr("status.connect_fail"))
                }
            } finally {
                endRequest()
            }
        }
    }

    fun dispose() {
        bootstrapJob?.cancel()
        searchJob?.cancel()
        playJob?.cancel()
        playlistJob?.cancel()
        lyricsJob?.cancel()
        paletteJob?.cancel()
        qrLoginJob?.cancel()
        maintenanceJob?.cancel()
        activePlaybackToken.set(0L)
        progressEvents.close()
        progressCollectorJob.cancel()
        cacheProgressEvents.close()
        cacheProgressCollectorJob.cancel()
        systemMediaSession.close()
        audioPlayer.close()
        controllerJob.cancel()
        gateway.close()
    }

    fun toggleTheme() {
        isDark = !isDark
        DesktopSettings.isDark = isDark
    }

    fun updateThemeEngine(value: LazerThemeEngine) {
        themeEngine = value
        DesktopSettings.themeEngine = value
    }

    fun updateLanguage(value: LazerLanguage) {
        if (language == value) return
        language = value
        LazerI18n.switchLanguage(value)
        DesktopSettings.language = value
        statusMessage = null
        loginError = null
    }

    fun updateLyricFollowDelay(value: Long) {
        lyricFollowDelayMillis = normalizeLyricFollowDelayMillis(value)
        DesktopSettings.lyricFollowDelayMillis = lyricFollowDelayMillis
    }

    fun updateLyricAnimationSpeed(value: LyricAnimationSpeed) {
        lyricAnimationSpeed = value
        DesktopSettings.lyricAnimationSpeed = value
    }

    fun updateWordLyricsEnabled(enabled: Boolean) {
        wordLyricsEnabled = enabled
        DesktopSettings.wordLyricsEnabled = enabled
    }

    fun updateLyricGlowEnabled(enabled: Boolean) {
        lyricGlowEnabled = enabled
        DesktopSettings.lyricGlowEnabled = enabled
    }

    fun updateLyricFontSizeSp(value: Int) {
        lyricFontSizeSp = normalizeLyricFontSizeSp(value)
        DesktopSettings.lyricFontSizeSp = lyricFontSizeSp
    }

    fun updateShowFullLyrics(enabled: Boolean) {
        showFullLyrics = enabled
        DesktopSettings.showFullLyrics = enabled
    }

    fun updateGatewayBaseUrl(value: String): Boolean {
        val normalized = normalizeGatewayBaseUrl(value) ?: return false
        if (normalized == gatewayBaseUrl) return true

        bootstrapJob?.cancel()
        searchJob?.cancel()
        playlistJob?.cancel()
        playlistRequestGeneration += 1
        lyricsJob?.cancel()
        qrLoginJob?.cancel()
        gateway.close()
        streamUrls.clear()
        streamUrlPrefetches.clear()

        DesktopSettings.gatewayBaseUrl = normalized
        gatewayBaseUrl = normalized
        gateway = createDesktopGateway(normalized)
        searchResults = emptyList()
        isLoginVisible = false
        qrLoginState = QrLoginState.IDLE
        qrImageData = null
        qrFallbackUrl = null
        connectMusicService()
        return true
    }

    fun updateSearchQuery(query: String) {
        searchQuery = query
        searchJob?.cancel()
        if (query.isBlank()) {
            searchResults = emptyList()
            return
        }
        searchJob = scope.launch {
            delay(320)
            beginRequest(tr("status.understanding"))
            try {
                val response = gateway.search(query, limit = 24, useCloudSearch = true)
                searchResults = response.result?.songs.orEmpty().map { it.toTrackItem() }
                statusMessage = if (searchResults.isEmpty()) tr("status.try_again") else null
            } catch (error: Throwable) {
                statusMessage = error.toFriendlyMessage(tr("status.search_fail"))
            } finally {
                endRequest()
            }
        }
    }

    fun useIntentSuggestion(suggestion: String) {
        updateSearchQuery(suggestion)
    }

    fun playTrack(track: TrackItem) {
        nowPlaying = track
        progress = 0f
        bufferedProgress = 0f
        streamUrl = null
        streamBitrate = null
        streamCacheVariant = "default"
        streamExpectedBytes = null
        isLiked = likedTracks.any { it.id == track.id }
        if (recentTracks.none { it.id == track.id }) {
            recentTracks = listOf(track) + recentTracks.take(39)
        }
        loadLyrics(track.id)
        loadCoverPalette(track.coverUrl, track.id)
        publishSystemMedia(
            statusOverride = SystemMediaPlaybackStatus.STOPPED,
            forcePosition = true,
        )
        resolveAndPlay(track)
    }

    fun openLyrics() {
        isLyricsVisible = true
        val track = nowPlaying ?: return
        if (lyrics.isEmpty() && !lyricsLoading) {
            loadLyrics(track.id)
        }
    }

    fun closeLyrics() {
        isLyricsVisible = false
    }

    /** Jump playback to the start of a lyric line. */
    fun seekToLyric(index: Int) {
        val line = lyrics.getOrNull(index) ?: return
        val track = nowPlaying ?: return
        if (track.durationMillis <= 0L) return
        val url = streamUrl
        val playWhenReady = isPlaying
        isSeeking = true
        progress = lyricSeekProgress(line.timeMs, track.durationMillis)
        PlaybackDebugLog.event(
            "lyric-seek",
            "track=${track.id} line=$index target=$progress playing=$playWhenReady hasStream=${!url.isNullOrBlank()}",
        )
        if (url.isNullOrBlank()) {
            isSeeking = false
            resolveAndPlay(track, resumeProgress = progress, playWhenReady = playWhenReady)
        } else {
            startAudioPlayback(
                url = url,
                track = track,
                fromProgress = progress,
                playWhenReady = playWhenReady,
            )
            isSeeking = false
        }
        publishSystemMedia(forcePosition = true)
    }

    private fun loadLyrics(songId: Long) {
        lyricsJob?.cancel()
        lyrics = emptyList()
        lyricsError = null
        lyricsLoading = true
        lyricsJob = scope.launch {
            try {
                val response = gateway.preferredLyrics(songId)
                val timedLyrics = parseDesktopWordLyrics(response.yrc?.lyric)
                    .ifEmpty { parseLrc(response.lrc?.lyric) }
                val parsed = mergeLyrics(
                    lyrics = timedLyrics,
                    translatedLyrics = parseLrc(response.tlyric?.lyric),
                )
                if (nowPlaying?.id != songId) return@launch
                lyrics = parsed
                lyricsLoading = false
                lyricsError = if (parsed.isEmpty()) tr("status.no_lyrics") else null
            } catch (error: Throwable) {
                if (nowPlaying?.id != songId) return@launch
                lyrics = emptyList()
                lyricsLoading = false
                lyricsError = error.toFriendlyMessage(tr("status.lyrics_fail"))
            }
        }
    }

    private fun loadCoverPalette(coverUrl: String?, trackId: Long) {
        paletteJob?.cancel()
        paletteJob = scope.launch {
            val seed = runInterruptible(Dispatchers.IO) {
                CoverPalette.extractSeedFromUrl(coverUrl)
            }
            val flow = CoverPalette.flowColorsFromSeed(seed)
            if (nowPlaying?.id == trackId) {
                lyricFlowColors = flow
            }
        }
    }

    fun togglePlayPause() {
        val track = nowPlaying ?: recentTracks.firstOrNull() ?: return
        if (nowPlaying == null) {
            playTrack(track)
            return
        }
        if (isPlaying) {
            isPlaying = false
            audioPlayer.pause()
            publishSystemMedia(forcePosition = true)
        } else if (streamUrl == null) {
            // Playback errors deliberately clear the stale URL, but the UI keeps the last
            // confirmed position. Resume from that position instead of silently starting the
            // audio at zero while lyrics and the seek bar remain further ahead.
            val resumeProgress = progress.coerceIn(0f, 0.999f)
            PlaybackDebugLog.event(
                "playback-retry",
                "track=${track.id} from=$resumeProgress reason=missing-stream",
            )
            resolveAndPlay(track, resumeProgress = resumeProgress, playWhenReady = true)
        } else {
            isPlaying = true
            audioPlayer.resume()
            publishSystemMedia(forcePosition = true)
        }
    }

    private fun handleSystemMediaCommand(command: SystemMediaCommand) {
        when (command) {
            SystemMediaCommand.Play -> if (!isPlaying) togglePlayPause()
            SystemMediaCommand.Pause -> if (isPlaying) togglePlayPause()
            SystemMediaCommand.Toggle -> togglePlayPause()
            SystemMediaCommand.Next -> playNext()
            SystemMediaCommand.Previous -> playPrevious()
            SystemMediaCommand.Stop -> stopFromSystemMedia()
            is SystemMediaCommand.SeekBy -> seekFromSystemMedia(
                systemSeekTargetMillis(positionMillis, command.offsetMillis, nowPlaying?.durationMillis ?: 0L),
            )
            is SystemMediaCommand.SetPosition -> seekFromSystemMedia(command.positionMillis)
            is SystemMediaCommand.SetVolume -> updateVolume(command.volume.toFloat())
        }
    }

    private fun stopFromSystemMedia() {
        playJob?.cancel()
        activePlaybackToken.set(0L)
        audioPlayer.stop()
        isPlaying = false
        isSeeking = false
        progress = 0f
        streamUrl = null
        streamBitrate = null
        publishSystemMedia(
            statusOverride = SystemMediaPlaybackStatus.STOPPED,
            forcePosition = true,
        )
    }

    private fun seekFromSystemMedia(positionMillis: Long) {
        val durationMillis = nowPlaying?.durationMillis ?: return
        if (durationMillis <= 0L) return
        seekTo(systemPositionProgress(positionMillis, durationMillis))
        commitSeek()
    }

    fun playPrevious() {
        val list = effectiveQueue()
        if (list.isEmpty()) return
        val currentId = nowPlaying?.id
        val index = list.indexOfFirst { it.id == currentId }.let { if (it < 0) 0 else it }
        playTrack(list[(index - 1 + list.size) % list.size])
    }

    fun playNext() {
        val list = effectiveQueue()
        if (list.isEmpty()) return
        val currentId = nowPlaying?.id
        val index = list.indexOfFirst { it.id == currentId }.let { if (it < 0) 0 else it }
        playTrack(list[(index + 1) % list.size])
    }

    fun seekTo(value: Float) {
        isSeeking = true
        progress = playableSeekProgress(value, nowPlaying?.durationMillis ?: 0L)
    }

    fun commitSeek() {
        // Tap and drag recognizers may both finish one pointer sequence. Only the first commit is
        // allowed to rebuild the audio pipeline.
        if (!isSeeking) {
            PlaybackDebugLog.event("seek-commit-ignored", "track=${nowPlaying?.id} reason=no-active-seek")
            return
        }
        val track = nowPlaying
        val url = streamUrl
        val targetProgress = playableSeekProgress(progress, track?.durationMillis ?: 0L)
        val playWhenReady = isPlaying
        isSeeking = false
        PlaybackDebugLog.event(
            "seek-commit",
            "track=${track?.id} target=$targetProgress playing=$playWhenReady hasStream=${!url.isNullOrBlank()}",
        )
        if (track == null) return
        if (url.isNullOrBlank()) {
            resolveAndPlay(track, resumeProgress = targetProgress, playWhenReady = playWhenReady)
        } else {
            startAudioPlayback(url, track, targetProgress, playWhenReady = playWhenReady)
        }
        publishSystemMedia(forcePosition = true)
    }

    /** Browse playlists shown in the library strip / sidebar, without the dedicated liked entry. */
    fun browsePlaylists(): List<PlaylistItem> = userPlaylists.filterNot { it.isLikedCollection }

    fun likedPlaylist(): PlaylistItem? =
        userPlaylists.firstOrNull { it.isLikedCollection }
            ?: userPlaylists.firstOrNull { it.title.endsWith("喜欢的音乐") }

    /** Sidebar 「我喜欢」— open the private liked collection so track order matches NetEase. */
    fun openLikedCollection() {
        val profile = currentUser
        if (profile == null) {
            openLogin()
            return
        }
        val liked = likedPlaylist()
        if (liked != null) {
            openPlaylist(liked)
            return
        }
        // Fallback: rebuild from /likelist while preserving the returned id order.
        playlistJob?.cancel()
        playlistRequestGeneration += 1
        playlistJob = scope.launch {
            beginRequest(tr("liked.open"))
            try {
                val likedIds = gateway.likedSongIds(profile.userId).ids
                val details = if (likedIds.isEmpty()) {
                    emptyList()
                } else {
                    gateway.songDetails(likedIds).songs
                        .associateBy { it.id }
                        .let { byId -> likedIds.mapNotNull { id -> byId[id]?.toTrackItem() } }
                }
                likedTracks = details
                val synthetic = PlaylistItem(
                    id = LIKED_FALLBACK_PLAYLIST_ID,
                    title = tr("liked.title"),
                    subtitle = "${tr("playlist.tracks", details.size)} · ${profile.nickname}",
                    coverUrl = details.firstOrNull()?.coverUrl,
                    trackCount = details.size,
                    creatorName = profile.nickname,
                    isLikedCollection = true,
                )
                showPlaylist(synthetic, details)
                statusMessage = if (details.isEmpty()) tr("status.quiet") else null
            } catch (error: Throwable) {
                statusMessage = error.toFriendlyMessage(tr("status.liked_sync_fail"))
            } finally {
                endRequest()
            }
        }
    }

    fun updateVolume(value: Float) {
        volume = value.coerceIn(0f, 1f)
        audioPlayer.setVolume(volume)
        systemMediaSession.setVolume(volume)
    }

    fun updateAudioQuality(quality: AudioQuality) {
        if (audioQuality == quality) return
        audioQuality = quality
        val track = nowPlaying ?: return
        if (isPlaying || streamUrl != null) {
            bufferedProgress = 0f
            resolveAndPlay(track, resumeProgress = progress, playWhenReady = isPlaying)
        }
    }

    fun updateExclusiveAudio(enabled: Boolean) {
        if (!isWindowsDesktop() || exclusiveAudio == enabled) return
        exclusiveAudio = enabled
        DesktopSettings.exclusiveAudio = enabled
        audioPlayer.setExclusiveAudio(enabled)
        val track = nowPlaying ?: return
        if (isPlaying || streamUrl != null) {
            bufferedProgress = 0f
            resolveAndPlay(track, resumeProgress = progress, playWhenReady = isPlaying)
        }
    }

    fun toggleLiked() {
        val track = nowPlaying ?: return
        val user = currentUser
        if (user == null) {
            openLogin()
            return
        }
        val next = !isLiked
        val previousLikedTracks = likedTracks
        isLiked = next
        likedTracks = if (next) {
            listOf(track) + likedTracks.filterNot { it.id == track.id }
        } else {
            likedTracks.filterNot { it.id == track.id }
        }
        playlistCache.saveLikedTracks(user.userId, likedTracks)
        scope.launch {
            runCatching { gateway.updateSongLiked(track.id, user.userId, next) }
                .onFailure {
                    isLiked = !next
                    likedTracks = previousLikedTracks
                    playlistCache.saveLikedTracks(user.userId, previousLikedTracks)
                    statusMessage = tr("status.like_fail")
                }
        }
    }

    fun toggleShuffle() {
        shuffle = !shuffle
    }

    fun toggleRepeat() {
        repeat = !repeat
    }

    fun openPlaylist(playlist: PlaylistItem) {
        val requestGeneration = ++playlistRequestGeneration
        playlistJob?.cancel()
        // Publish the header immediately so the detail sheet doesn't flash empty.
        activePlaylist = playlist
        activePlaylistTracks = emptyList()
        playlistJob = scope.launch {
            val cached = withContext(Dispatchers.IO) { playlistCache.loadTracks(playlist.id) }
            if (!isCurrentPlaylistRequest(playlist.id, requestGeneration)) return@launch
            if (cached != null && cached.tracks.isNotEmpty()) {
                showPlaylist(playlist, cached.tracks)
                statusMessage = if (cached.complete) {
                    tr("status.opening_local")
                } else {
                    tr("status.opening_local_partial", cached.tracks.size)
                }
            }
            beginRequest(tr("status.opening_playlist", playlist.title))
            try {
                val tracks = loadCompletePlaylist(playlist, requestGeneration)
                if (isCurrentPlaylistRequest(playlist.id, requestGeneration) && tracks.isNotEmpty()) {
                    showPlaylist(playlist, tracks)
                    if (playlist.isLikedCollection) {
                        likedTracks = tracks
                    }
                }
                if (isCurrentPlaylistRequest(playlist.id, requestGeneration)) {
                    statusMessage = if (tracks.isEmpty()) tr("status.playlist_empty") else null
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (isCurrentPlaylistRequest(playlist.id, requestGeneration)) {
                    statusMessage = error.toFriendlyMessage(tr("status.playlist_sync_fail"))
                }
            } finally {
                endRequest()
            }
        }
    }

    fun syncLibrary() {
        val profile = currentUser ?: run {
            openLogin()
            return
        }
        scope.launch {
            beginRequest(tr("status.syncing_playlists"))
            try {
                syncUserLibrary(profile)
                val syncedMessage = tr("status.synced")
                statusMessage = syncedMessage
                delay(1_600)
                if (statusMessage == syncedMessage) statusMessage = null
            } catch (error: Throwable) {
                statusMessage = error.toFriendlyMessage(tr("status.playlist_sync_fail"))
            } finally {
                endRequest()
            }
        }
    }

    fun clearSongCache() {
        maintenanceJob?.cancel()
        maintenanceJob = scope.launch {
            playJob?.cancel()
            activePlaybackToken.set(0L)
            isPlaying = false
            isSeeking = false
            streamUrl = null
            streamBitrate = null
            streamUrls.clear()
            streamUrlPrefetches.clear()
            bufferedProgress = 0f
            val removed = withContext(Dispatchers.IO) { audioPlayer.clearCache() }
            publishSystemMedia(
                statusOverride = SystemMediaPlaybackStatus.STOPPED,
                forcePosition = true,
            )
            statusMessage = if (removed > 0) tr("status.songs_cleared") else tr("status.songs_empty")
        }
    }

    fun clearPlaylistCache() {
        val removed = playlistCache.clearPlaylistData()
        statusMessage = if (removed > 0) tr("status.playlists_cleared") else tr("status.playlists_empty")
    }

    fun forceResync() {
        maintenanceJob?.cancel()
        bootstrapJob?.cancel()
        maintenanceJob = scope.launch {
            beginRequest(tr("status.resyncing"))
            try {
                currentUser?.let { syncUserLibrary(it, forceRefresh = true) }
                    ?: loadPublicLibrary(forceRefresh = true)
                statusMessage = tr("status.resynced")
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                statusMessage = error.toFriendlyMessage(tr("status.resync_fail"))
            } finally {
                endRequest()
            }
        }
    }

    fun openLogin() {
        isLoginVisible = true
        loginMethod = LoginMethod.QR_CODE
        loginError = null
        if (qrLoginState !in setOf(QrLoginState.CREATING, QrLoginState.WAITING_FOR_SCAN, QrLoginState.WAITING_FOR_CONFIRMATION)) {
            startQrLogin()
        }
    }

    fun closeLogin() {
        isLoginVisible = false
        qrLoginJob?.cancel()
        qrLoginState = QrLoginState.IDLE
    }

    fun selectLoginMethod(method: LoginMethod) {
        loginMethod = method
        loginError = null
        if (method == LoginMethod.PASSWORD) {
            qrLoginJob?.cancel()
            qrLoginState = QrLoginState.IDLE
        }
        if (method == LoginMethod.QR_CODE && qrLoginState !in setOf(
                QrLoginState.CREATING,
                QrLoginState.WAITING_FOR_SCAN,
                QrLoginState.WAITING_FOR_CONFIRMATION,
            )
        ) {
            startQrLogin()
        }
    }

    fun updateLoginIdentifier(value: String) {
        loginIdentifier = value
        loginError = null
    }

    fun updateLoginPassword(value: String) {
        loginPassword = value
        loginError = null
    }

    fun startQrLogin() {
        qrLoginJob?.cancel()
        qrLoginJob = scope.launch {
            qrLoginState = QrLoginState.CREATING
            qrImageData = null
            qrFallbackUrl = null
            loginError = null
            try {
                val key = gateway.createQrKey(platform = "web").data?.unikey.orEmpty()
                check(key.isNotBlank()) { tr("login.qr_key_empty") }
                val code = gateway.createQrCode(key, includeImage = true, platform = "web").data
                qrImageData = code?.qrimg
                qrFallbackUrl = code?.qrurl?.let(::normalizeGatewayQrLoginUrl)
                check(!qrImageData.isNullOrBlank() || !qrFallbackUrl.isNullOrBlank()) { tr("login.qr_empty") }
                qrLoginState = QrLoginState.WAITING_FOR_SCAN

                while (isActive) {
                    delay(1_800)
                    val result = gateway.checkQrCode(key, platform = "web")
                    when (result.code) {
                        QrCheckResponse.EXPIRED_CODE -> {
                            qrLoginState = QrLoginState.EXPIRED
                            return@launch
                        }
                        QrCheckResponse.WAITING_FOR_SCAN_CODE -> qrLoginState = QrLoginState.WAITING_FOR_SCAN
                        QrCheckResponse.WAITING_FOR_CONFIRMATION_CODE -> qrLoginState = QrLoginState.WAITING_FOR_CONFIRMATION
                        QrCheckResponse.AUTHORIZED_CODE -> {
                            qrLoginState = QrLoginState.AUTHORIZED
                            // Close the sheet immediately; library sync continues in the background.
                            finishSignInAndClose()
                            return@launch
                        }
                        else -> {
                            loginError = if (language == LazerLanguage.SIMPLIFIED_CHINESE) {
                                result.message ?: result.msg ?: tr("login.qr_code_fail", result.code)
                            } else {
                                tr("login.qr_code_fail", result.code)
                            }
                            qrLoginState = QrLoginState.ERROR
                            return@launch
                        }
                    }
                }
            } catch (error: Throwable) {
                qrLoginState = QrLoginState.ERROR
                loginError = error.toFriendlyMessage(tr("login.qr_gen_fail_retry"))
            }
        }
    }

    fun submitPasswordLogin() {
        val identifier = loginIdentifier.trim()
        if (identifier.isBlank() || loginPassword.isBlank()) {
            loginError = tr("login.enter_credentials")
            return
        }
        scope.launch {
            isSubmittingLogin = true
            loginError = null
            try {
                val response = if ('@' in identifier) {
                    gateway.loginWithEmail(identifier, loginPassword)
                } else {
                    gateway.loginWithPhonePassword(
                        phone = identifier.removePrefix("+86").replace(" ", ""),
                        password = loginPassword,
                        countryCode = "86",
                    )
                }
                if (response.code !in 200..299 || gateway.sessionCookie.isNullOrBlank()) {
                    error(response.failureMessage ?: tr("login.wrong_credentials"))
                }
                finishSignInAndClose(response.profile)
            } catch (error: Throwable) {
                loginError = error.toFriendlyMessage(tr("login.fail_check"))
            } finally {
                isSubmittingLogin = false
            }
        }
    }

    fun logout() {
        playlistJob?.cancel()
        playlistRequestGeneration += 1
        scope.launch {
            beginRequest(tr("status.signing_out"))
            try {
                runCatching { gateway.logoutSession() }
            } finally {
                gateway.clearSession()
                currentUser = null
                playlistCache.clearCurrentUser()
                userPlaylists = emptyList()
                likedTracks = emptyList()
                isLiked = false
                activePlaylist = null
                activePlaylistTracks = emptyList()
                runCatching { gateway.anonymousLogin() }
                runCatching { loadPublicLibrary() }
                gateway.clearSession()
                statusMessage = null
                endRequest()
            }
        }
    }

    /**
     * Resolves the signed-in profile, closes the login UI immediately, then syncs
     * the library in the background so the sheet never waits on playlist fetches.
     */
    private suspend fun finishSignInAndClose(profileHint: UserProfile? = null) {
        val profile = resolveSignedInProfile(profileHint)
        currentUser = profile
        playlistCache.saveCurrentUser(profile)
        restoreCachedUserLibrary(profile)
        loginPassword = ""
        loginError = null
        isLoginVisible = false
        qrLoginState = QrLoginState.IDLE
        qrLoginJob?.cancel()

        scope.launch {
            beginRequest(tr("status.syncing_music"))
            try {
                runCatching { syncUserLibrary(profile) }
                    .onSuccess {
                        val syncedMessage = tr("status.synced")
                        statusMessage = syncedMessage
                        delay(1_600)
                        if (statusMessage == syncedMessage) statusMessage = null
                    }
                    .onFailure { statusMessage = tr("status.login_success_sync_later") }
            } finally {
                endRequest()
            }
        }
    }

    private suspend fun resolveSignedInProfile(profileHint: UserProfile? = null): UserProfile {
        val profile = profileHint?.takeIf { it.userId > 0 }
            ?: resolveStoredProfile()
        check(profile != null && profile.userId > 0) { tr("login.no_profile") }
        return profile
    }

    private suspend fun resolveStoredProfile(): UserProfile? {
        val loginStatus = gateway.loginStatus().data
        return loginStatus?.profile?.takeIf { it.userId > 0 }
            ?: loginStatus?.account?.id
                ?.takeIf { it > 0 }
                ?.let { gateway.userDetail(it).profile }
    }

    private suspend fun loadPublicLibrary(forceRefresh: Boolean = false) {
        val playlists = ensurePlaylistCovers(
            gateway.topPlaylists(limit = 12, forceRefresh = forceRefresh).playlists.map { it.toPlaylistItem() },
            forceRefresh = forceRefresh,
        )
        featuredPlaylists = playlists
        playlistCache.savePlaylists(FEATURED_CACHE_KEY, playlists)
        if (recentTracks.isEmpty() && playlists.isNotEmpty()) {
            val tracks = runCatching {
                gateway.playlistTracks(
                    playlists.first().id,
                    limit = 18,
                    forceRefresh = forceRefresh,
                ).songs.map { it.toTrackItem() }
            }.getOrDefault(emptyList())
            recentTracks = tracks
            playlistCache.saveTracks(RECENT_TRACKS_CACHE_ID, tracks, complete = false)
            if (nowPlaying == null) nowPlaying = tracks.firstOrNull()
        }
        if (recentTracks.isEmpty()) {
            val fmTracks = runCatching { gateway.personalFm().data.map { it.toTrackItem() } }
                .getOrDefault(emptyList())
            recentTracks = fmTracks
            playlistCache.saveTracks(RECENT_TRACKS_CACHE_ID, fmTracks, complete = false)
            if (nowPlaying == null) nowPlaying = fmTracks.firstOrNull()
        }
    }

    private suspend fun restoreCachedUserLibrary(profile: UserProfile) {
        val cached = withContext(Dispatchers.IO) {
            DesktopCachedLibrary(
                playlists = playlistCache.loadPlaylists(userPlaylistCacheKey(profile.userId)),
                likedTracks = playlistCache.loadLikedTracks(profile.userId),
            )
        }
        userPlaylists = cached.playlists
        likedTracks = cached.likedTracks
        isLiked = nowPlaying?.let { current -> likedTracks.any { it.id == current.id } } ?: false
    }

    private suspend fun syncUserLibrary(profile: UserProfile, forceRefresh: Boolean = false) {
        val cacheKey = userPlaylistCacheKey(profile.userId)
        val personal = loadAllUserPlaylists(profile.userId, cacheKey, forceRefresh)
        userPlaylists = personal

        // `/recommend/resource` sometimes omits picUrl/coverImgUrl for radar-style lists.
        // Always resolve covers before publishing to the home strip.
        val recommended = runCatching {
            ensurePlaylistCovers(
                gateway.dailyRecommendedPlaylists(forceRefresh).recommend.map { it.toPlaylistItem() },
                forceRefresh,
            )
        }.getOrDefault(emptyList())
        if (recommended.isNotEmpty()) {
            featuredPlaylists = (recommended + featuredPlaylists)
                .distinctBy { it.id }
                .let { ensurePlaylistCovers(it, forceRefresh) }
                .take(12)
            playlistCache.savePlaylists(FEATURED_CACHE_KEY, featuredPlaylists)
        } else if (featuredPlaylists.isEmpty() || featuredPlaylists.all { it.coverUrl.isNullOrBlank() }) {
            loadPublicLibrary(forceRefresh)
        } else {
            featuredPlaylists = ensurePlaylistCovers(featuredPlaylists, forceRefresh)
            playlistCache.savePlaylists(FEATURED_CACHE_KEY, featuredPlaylists)
        }

        // Prefer the private liked playlist order; /song/detail alone does not keep likelist order.
        val liked = personal.firstOrNull { it.isLikedCollection }
        likedTracks = when {
            liked != null -> runCatching {
                gateway.playlistTracks(liked.id, limit = 200, forceRefresh = forceRefresh)
                    .songs.map { it.toTrackItem() }
            }.getOrDefault(likedTracks)
            else -> {
                val likedIds = runCatching { gateway.likedSongIds(profile.userId, forceRefresh).ids.take(200) }
                    .getOrDefault(emptyList())
                if (likedIds.isEmpty()) {
                    emptyList()
                } else {
                    runCatching {
                        val byId = gateway.songDetails(likedIds, forceRefresh).songs.associateBy { it.id }
                        likedIds.mapNotNull { id -> byId[id]?.toTrackItem() }
                    }.getOrDefault(emptyList())
                }
            }
        }
        playlistCache.saveLikedTracks(profile.userId, likedTracks)

        val dailyTracks = runCatching {
            gateway.dailyRecommendedSongs(forceRefresh).data?.dailySongs.orEmpty().map { it.toTrackItem() }
        }
            .getOrDefault(emptyList())
        if (dailyTracks.isNotEmpty()) {
            recentTracks = dailyTracks
            playlistCache.saveTracks(RECENT_TRACKS_CACHE_ID, dailyTracks, complete = false)
            if (nowPlaying == null) nowPlaying = dailyTracks.first()
        } else if (recentTracks.isEmpty() && personal.isNotEmpty()) {
            recentTracks = runCatching {
                gateway.playlistTracks(
                    personal.first().id,
                    limit = 24,
                    forceRefresh = forceRefresh,
                ).songs.map { it.toTrackItem() }
            }.getOrDefault(emptyList())
            playlistCache.saveTracks(RECENT_TRACKS_CACHE_ID, recentTracks, complete = false)
            if (nowPlaying == null) nowPlaying = recentTracks.firstOrNull()
        }
        isLiked = nowPlaying?.let { current -> likedTracks.any { it.id == current.id } } ?: false
    }

    private fun resolveAndPlay(
        track: TrackItem,
        resumeProgress: Float = 0f,
        playWhenReady: Boolean = true,
    ) {
        playJob?.cancel()
        activePlaybackToken.set(0L)
        audioPlayer.stop()
        playJob = scope.launch {
            beginRequest(tr("status.preparing_quality", audioQuality.label))
            try {
                val songUrl = resolveSongUrl(track.id, audioQuality)
                if (nowPlaying?.id != track.id) return@launch
                streamUrl = songUrl?.url
                streamBitrate = songUrl?.br
                streamCacheVariant = audioCacheVariant(songUrl?.br, songUrl?.md5, songUrl?.type)
                streamExpectedBytes = songUrl?.size
                val playableUrl = songUrl?.url
                if (playableUrl.isNullOrBlank()) {
                    isPlaying = false
                    statusMessage = tr("status.quality_unavailable")
                    publishSystemMedia(
                        statusOverride = SystemMediaPlaybackStatus.STOPPED,
                        forcePosition = true,
                    )
                } else {
                    val safeResumeProgress = playableSeekProgress(resumeProgress, track.durationMillis)
                    progress = safeResumeProgress
                    isPlaying = playWhenReady
                    statusMessage = null
                    startAudioPlayback(
                        url = playableUrl,
                        track = track,
                        fromProgress = safeResumeProgress,
                        playWhenReady = playWhenReady,
                    )
                    prefetchAdjacentSongUrls()
                    publishSystemMedia(forcePosition = true)
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                isPlaying = false
                statusMessage = error.toFriendlyMessage(tr("status.play_fail"))
                publishSystemMedia(
                    statusOverride = SystemMediaPlaybackStatus.STOPPED,
                    forcePosition = true,
                )
            } finally {
                endRequest()
            }
        }
    }

    private suspend fun resolveSongUrl(trackId: Long, quality: AudioQuality): SongUrl? {
        val key = DesktopStreamCacheKey(trackId, quality)
        val now = System.currentTimeMillis()
        streamUrls[key]?.takeIf { it.expiresAtMillis > now }?.let { return it.songUrl }
        streamUrls.remove(key)

        val songUrl = withContext(Dispatchers.IO) {
            val requested = gateway.songUrls(listOf(trackId), quality = quality).data.firstOrNull()
            if (needsMp3PlaybackFallback(requested?.type, requested?.url)) {
                gateway.songUrls(listOf(trackId), quality = AudioQuality.EXHIGH).data.firstOrNull()
            } else {
                requested
            }
        }
        songUrl?.url?.takeIf(String::isNotBlank)?.let {
            val ttlMillis = (songUrl.expi?.coerceAtLeast(1)?.times(1_000L) ?: STREAM_URL_CACHE_TTL_MILLIS)
                .coerceAtMost(STREAM_URL_CACHE_TTL_MILLIS)
            streamUrls[key] = CachedDesktopSongUrl(songUrl, now + ttlMillis)
        }
        return songUrl
    }

    private fun prefetchAdjacentSongUrls() {
        val preferredQuality = audioQuality
        adjacentQueueTracks().forEach { track ->
            val key = DesktopStreamCacheKey(track.id, preferredQuality)
            val hasFreshUrl = streamUrls[key]?.expiresAtMillis ?: 0L
            if (hasFreshUrl > System.currentTimeMillis() || !streamUrlPrefetches.add(key)) return@forEach
            scope.launch {
                try {
                    resolveSongUrl(track.id, preferredQuality)
                } catch (error: CancellationException) {
                    throw error
                } catch (_: Throwable) {
                    // Prefetch is opportunistic: playback will still resolve normally if needed.
                } finally {
                    streamUrlPrefetches.remove(key)
                }
            }
        }
    }

    private fun startAudioPlayback(
        url: String,
        track: TrackItem,
        fromProgress: Float,
        playWhenReady: Boolean,
    ) {
        activePlaybackToken.set(0L)
        val token = audioPlayer.play(
            url = url,
            trackId = track.id,
            cacheVariant = streamCacheVariant,
            expectedBytes = streamExpectedBytes,
            durationMillis = track.durationMillis,
            fromProgress = playableSeekProgress(fromProgress, track.durationMillis),
            volume = volume,
            playWhenReady = playWhenReady,
        )
        activePlaybackToken.set(token)
        PlaybackDebugLog.event(
            "playback-start",
            "token=$token track=${track.id} from=$fromProgress playing=$playWhenReady",
        )
    }

    private suspend fun loadCompletePlaylist(
        playlist: PlaylistItem,
        requestGeneration: Long,
    ): List<TrackItem> {
        val expectedCount = playlist.trackCount.coerceAtLeast(0)
        val allAtOnce = try {
            gateway.playlistTracks(playlist.id, limit = null, forceRefresh = true).songs.map { it.toTrackItem() }
        } catch (error: CancellationException) {
            throw error
        } catch (_: Throwable) {
            emptyList()
        }
        if (!isCurrentPlaylistRequest(playlist.id, requestGeneration)) return emptyList()
        val combined = allAtOnce.distinctBy { it.id }.toMutableList()
        var reachedEnd = false
        if (combined.isNotEmpty()) {
            showPlaylist(playlist, combined)
            val complete = expectedCount == 0 || combined.size >= expectedCount
            playlistCache.saveTracks(playlist.id, combined, complete)
            if (complete) return combined
        }

        var offset = combined.size
        while (expectedCount == 0 || combined.size < expectedCount) {
            val page = gateway.playlistTracks(
                id = playlist.id,
                limit = PLAYLIST_PAGE_SIZE,
                offset = offset,
                forceRefresh = true,
            ).songs.map { it.toTrackItem() }
            if (!isCurrentPlaylistRequest(playlist.id, requestGeneration)) return emptyList()
            if (page.isEmpty()) break
            val knownIds = combined.asSequence().map { it.id }.toHashSet()
            combined += page.filterNot { it.id in knownIds }
            offset += page.size
            showPlaylist(playlist, combined)
            val complete = page.size < PLAYLIST_PAGE_SIZE || (expectedCount > 0 && combined.size >= expectedCount)
            playlistCache.saveTracks(playlist.id, combined, complete)
            statusMessage = if (expectedCount > 0) {
                tr("status.loaded_tracks", combined.size.coerceAtMost(expectedCount), expectedCount)
            } else {
                tr("status.loaded_tracks_n", combined.size)
            }
            if (complete) {
                reachedEnd = true
                break
            }
        }
        val complete = reachedEnd || expectedCount == 0 || combined.size >= expectedCount
        playlistCache.saveTracks(playlist.id, combined, complete)
        return combined
    }

    private fun isCurrentPlaylistRequest(playlistId: Long, requestGeneration: Long): Boolean =
        playlistRequestGeneration == requestGeneration && activePlaylist?.id == playlistId

    private suspend fun loadAllUserPlaylists(
        userId: Long,
        cacheKey: String,
        forceRefresh: Boolean = false,
    ): List<PlaylistItem> {
        val combined = mutableListOf<PlaylistItem>()
        var offset = 0
        do {
            val response = gateway.userPlaylists(
                userId,
                limit = USER_PLAYLIST_PAGE_SIZE,
                offset = offset,
                forceRefresh = forceRefresh,
            )
            val page = response.playlist.map { it.toPlaylistItem() }
            combined += page.filterNot { incoming -> combined.any { it.id == incoming.id } }
            userPlaylists = combined.toList()
            playlistCache.savePlaylists(cacheKey, userPlaylists)
            offset += page.size
        } while (response.more && page.isNotEmpty())
        return combined
    }

    /**
     * Some Gateway playlist payloads only carry a cover on `/playlist/detail`.
     * Fill missing artwork so the home strip never publishes bare gradient tiles when a cover exists.
     */
    private suspend fun ensurePlaylistCovers(
        playlists: List<PlaylistItem>,
        forceRefresh: Boolean = false,
    ): List<PlaylistItem> {
        if (playlists.isEmpty()) return playlists
        return playlists.map { playlist ->
            if (!playlist.coverUrl.isNullOrBlank()) return@map playlist
            val detailCover = runCatching {
                gateway.playlistDetail(playlist.id, forceRefresh = forceRefresh).playlist?.resolvedCoverUrl()
            }.getOrNull()?.takeIf { it.isNotBlank() }
            if (detailCover == null) playlist else playlist.copy(coverUrl = detailCover)
        }
    }

    private fun showPlaylist(playlist: PlaylistItem, tracks: List<TrackItem>) {
        activePlaylist = playlist.copy(trackCount = tracks.size.takeIf { it > 0 } ?: playlist.trackCount)
        activePlaylistTracks = tracks
        if (nowPlaying == null) nowPlaying = tracks.firstOrNull()
        isLiked = nowPlaying?.let { current -> likedTracks.any { it.id == current.id } } ?: false
    }

    private fun effectiveQueue(): List<TrackItem> {
        val base = when {
            activePlaylist != null && activePlaylistTracks.isNotEmpty() -> activePlaylistTracks
            searchResults.isNotEmpty() -> searchResults
            recentTracks.isNotEmpty() -> recentTracks
            else -> listOfNotNull(nowPlaying)
        }
        return if (shuffle) base.shuffled() else base
    }

    private fun adjacentQueueTracks(): List<TrackItem> {
        val queue = effectiveQueue()
        if (queue.size < 2) return emptyList()
        val index = queue.indexOfFirst { it.id == nowPlaying?.id }.let { if (it < 0) 0 else it }
        return listOf(
            queue[(index + 1) % queue.size],
            queue[(index - 1 + queue.size) % queue.size],
        ).distinctBy(TrackItem::id)
    }

    private fun publishSystemMedia(
        statusOverride: SystemMediaPlaybackStatus? = null,
        forcePosition: Boolean = false,
    ) {
        val track = nowPlaying
        val status = statusOverride ?: when {
            track == null -> SystemMediaPlaybackStatus.STOPPED
            isPlaying -> SystemMediaPlaybackStatus.PLAYING
            streamUrl.isNullOrBlank() -> SystemMediaPlaybackStatus.STOPPED
            else -> SystemMediaPlaybackStatus.PAUSED
        }
        systemMediaSession.publish(
            snapshot = SystemMediaSnapshot(
                trackId = track?.id,
                title = track?.title,
                artist = track?.artist,
                album = track?.album,
                coverUrl = track?.coverUrl,
                durationMillis = track?.durationMillis ?: 0L,
                playbackStatus = status,
                positionMillis = positionMillis,
            ),
            forcePosition = forcePosition,
        )
    }

    private fun beginRequest(message: String? = null) {
        activeRequests += 1
        isLoading = true
        if (message != null) statusMessage = message
    }

    private fun endRequest() {
        activeRequests = (activeRequests - 1).coerceAtLeast(0)
        isLoading = activeRequests > 0
    }

    private companion object {
        const val STREAM_URL_CACHE_SIZE = 6
        const val STREAM_URL_CACHE_TTL_MILLIS = 4 * 60_000L
        const val PLAYLIST_PAGE_SIZE = 500
        const val USER_PLAYLIST_PAGE_SIZE = 100
        const val FEATURED_CACHE_KEY = "featured"
        const val RECENT_TRACKS_CACHE_ID = -1L
        const val LIKED_FALLBACK_PLAYLIST_ID = -5L

        fun userPlaylistCacheKey(userId: Long): String = "user-$userId"
    }
}

private fun createDesktopGateway(baseUrl: String = DesktopSettings.gatewayBaseUrl): NeteaseMusicGateway =
    NeteaseMusicGateway(
        config = GatewayConfig(baseUrl = baseUrl),
        sessionStore = DesktopGatewaySessionStore(),
    )

private fun Song.toTrackItem(): TrackItem = TrackItem(
    id = id,
    title = name.ifBlank { tr("track.unknown_song") },
    artist = artists.joinToString(" / ") { it.name }.ifBlank { tr("track.unknown_artist") },
    album = album?.name.orEmpty().ifBlank { tr("track.unknown_album") },
    durationMillis = durationMillis ?: 0L,
    coverUrl = album?.picUrl ?: album?.blurPictureUrl,
)

private fun Playlist.toPlaylistItem(): PlaylistItem {
    val creatorName = creator?.nickname?.takeIf { it.isNotBlank() }
    val liked = specialType == LIKED_SPECIAL_TYPE || name.endsWith("喜欢的音乐")
    return PlaylistItem(
        id = id,
        title = name.ifBlank { tr("playlist.unnamed") },
        subtitle = buildString {
            trackCount?.let { count -> append(tr("playlist.tracks", count)) }
            if (creatorName != null) {
                if (isNotEmpty()) append(" · ")
                append(creatorName)
            }
            if (isEmpty()) append(description?.take(24) ?: tr("playlist.curated"))
        },
        coverUrl = resolvedCoverUrl(),
        trackCount = trackCount ?: 0,
        creatorName = creatorName,
        isLikedCollection = liked,
    )
}

private const val LIKED_SPECIAL_TYPE = 5

/** Prefer non-blank cover fields; empty strings must not mask `picUrl`. */
private fun Playlist.resolvedCoverUrl(): String? =
    sequenceOf(coverImgUrl, picUrl)
        .mapNotNull { it?.trim()?.takeIf(String::isNotBlank) }
        .firstOrNull()

private fun Throwable.toFriendlyMessage(fallback: String): String =
    if (LazerI18n.language == LazerLanguage.SIMPLIFIED_CHINESE) {
        message?.takeIf { it.isNotBlank() && it.length <= 120 } ?: fallback
    } else {
        fallback
    }

internal fun formatDuration(millis: Long): String {
    if (millis <= 0L) return "00:00"
    val totalSeconds = (millis / 1000.0).roundToInt()
    val minutes = totalSeconds / 60
    val seconds = totalSeconds % 60
    return "%02d:%02d".format(minutes, seconds)
}

/** Keep lyric jumps inside the playable range even when an LRC tail exceeds track metadata. */
internal fun lyricSeekProgress(timeMillis: Long, durationMillis: Long): Float {
    if (durationMillis <= 0L) return 0f
    val requested = timeMillis.coerceAtLeast(0L).toDouble() / durationMillis.toDouble()
    return playableSeekProgress(requested.toFloat(), durationMillis)
}

/** Stable cache variant: the content hash wins, with bitrate/type as a safe fallback. */
internal fun audioCacheVariant(bitrate: Int?, md5: String?, mediaType: String?): String {
    val hash = md5.orEmpty().trim().lowercase()
    return if (hash.isNotEmpty()) hash else "${bitrate ?: 0}-${mediaType.orEmpty().lowercase().ifBlank { "audio" }}"
}
