package dev.naominet.lazer

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.asImageBitmap
import dev.naominet.lazer.gateway.AudioQuality
import dev.naominet.lazer.gateway.GatewayConfig
import dev.naominet.lazer.gateway.NeteaseMusicGateway
import dev.naominet.lazer.gateway.normalizeGatewayBaseUrl
import dev.naominet.lazer.gateway.model.Playlist
import dev.naominet.lazer.gateway.model.Song
import dev.naominet.lazer.gateway.model.UserProfile
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.withContext

enum class AndroidRootDestination(private val labelKey: String, val motionIndex: Int) {
    HOME("nav.today", 0),
    DISCOVER("nav.discover", 1),
    SEARCH("nav.search", 2),
    LIBRARY("nav.library", 3),
    ME("nav.me", 4);

    val label: String get() = tr(labelKey)
}

enum class AndroidLoginMethod(private val labelKey: String) {
    CAPTCHA("login.method.captcha"),
    PASSWORD("login.method.password"),
    QR_CODE("login.method.qr");

    val label: String get() = tr(labelKey)
}

enum class AndroidQrLoginState {
    IDLE,
    CREATING,
    WAITING_FOR_SCAN,
    WAITING_FOR_CONFIRMATION,
    EXPIRED,
    ERROR,
}

private data class AndroidCachedSignedInContent(
    val userPlaylists: List<AndroidPlaylist>,
    val likedSongIds: Set<Long>,
)

private data class AndroidCachedBootstrap(
    val hasSavedSession: Boolean,
    val featuredPlaylists: List<AndroidPlaylist>,
    val homeTracks: List<AndroidTrack>,
    val profile: UserProfile?,
    val userPlaylists: List<AndroidPlaylist>,
    val likedSongIds: Set<Long>,
)

/**
 * Android presentation state backed by the shared Gateway client. All Gateway access stays here,
 * so composables only receive human-readable loading and failure states.
 */
class AndroidGatewayController(context: Context) {
    private val appContext = context.applicationContext
    private val cache = AndroidPlaylistCache(appContext)
    private val settings = AndroidSettingsStore(appContext)
    private val gatewaySessionStore = AndroidGatewaySessionStore(appContext)
    private var gateway = NeteaseMusicGateway(
        config = GatewayConfig(baseUrl = settings.gatewayBaseUrl),
        sessionStore = gatewaySessionStore,
    )
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var bootstrapJob: Job? = null
    private var searchJob: Job? = null
    private var playlistJob: Job? = null
    private var lyricJob: Job? = null
    private var qrLoginJob: Job? = null
    private var postLoginSyncJob: Job? = null
    private var maintenanceJob: Job? = null
    private var playlistRequestGeneration = 0L

    var destination by mutableStateOf(AndroidRootDestination.HOME)
        private set
    var isSettingsVisible by mutableStateOf(false)
        private set
    var isDark by mutableStateOf(settings.isDark)
        private set
    var useSystemMonetColors by mutableStateOf(settings.useSystemMonetColors)
        private set
    var palette by mutableStateOf(settings.palette)
        private set
    var backgroundImage by mutableStateOf<androidx.compose.ui.graphics.ImageBitmap?>(null)
        private set
    var backgroundImageEnabled by mutableStateOf(settings.backgroundImageEnabled)
        private set
    var backgroundAlpha by mutableStateOf(settings.backgroundAlpha)
        private set
    var style by mutableStateOf(settings.style)
        private set
    val themeEngine: LazerThemeEngine get() = style.themeEngine
    val liquidGlassEnabled: Boolean get() = style.usesLiquidGlass
    var language by mutableStateOf(settings.language)
        private set
    var lyricFollowDelayMillis by mutableStateOf(settings.lyricFollowDelayMillis)
        private set
    var lyricAnimationSpeed by mutableStateOf(settings.lyricAnimationSpeed)
        private set
    var wordLyricsEnabled by mutableStateOf(settings.wordLyricsEnabled)
        private set
    var lyricGlowEnabled by mutableStateOf(settings.lyricGlowEnabled)
        private set
    var lyricFontSizeSp by mutableIntStateOf(settings.lyricFontSizeSp)
        private set
    var showFullLyrics by mutableStateOf(settings.showFullLyrics)
        private set
    var audioQuality by mutableStateOf(settings.audioQuality)
        private set
    var exclusiveAudio by mutableStateOf(settings.exclusiveAudio)
        private set
    var gatewayBaseUrl by mutableStateOf(settings.gatewayBaseUrl)
        private set
    var currentUser by mutableStateOf<UserProfile?>(null)
        private set
    var featuredPlaylists by mutableStateOf<List<AndroidPlaylist>>(emptyList())
        private set
    var homeTracks by mutableStateOf<List<AndroidTrack>>(emptyList())
        private set
    var userPlaylists by mutableStateOf<List<AndroidPlaylist>>(emptyList())
        private set
    var likedSongIds by mutableStateOf<Set<Long>>(emptySet())
        private set
    var activePlaylist by mutableStateOf<AndroidPlaylist?>(null)
        private set
    var activePlaylistTracks by mutableStateOf<List<AndroidTrack>>(emptyList())
        private set
    var isLoading by mutableStateOf(false)
        private set
    var isPlaylistLoading by mutableStateOf(false)
        private set
    var message by mutableStateOf<String?>(null)
        private set

    var searchQuery by mutableStateOf("")
        private set
    var searchResults by mutableStateOf<List<AndroidTrack>>(emptyList())
        private set
    var isSearching by mutableStateOf(false)
        private set

    var lyrics by mutableStateOf<List<AndroidTimedLyricLine>>(emptyList())
        private set
    var lyricsLoading by mutableStateOf(false)
        private set
    var lyricsMessage by mutableStateOf<String?>(null)
        private set

    var isLoginVisible by mutableStateOf(false)
        private set
    var loginMethod by mutableStateOf(AndroidLoginMethod.CAPTCHA)
        private set
    var loginPhone by mutableStateOf("")
        private set
    var loginCaptcha by mutableStateOf("")
        private set
    var loginPassword by mutableStateOf("")
        private set
    var loginMessage by mutableStateOf<String?>(null)
        private set
    var isSendingCaptcha by mutableStateOf(false)
        private set
    var isSubmittingLogin by mutableStateOf(false)
        private set
    var captchaSent by mutableStateOf(false)
        private set
    var qrImageData by mutableStateOf<String?>(null)
        private set
    var qrState by mutableStateOf(AndroidQrLoginState.IDLE)
        private set

    init {
        LazerI18n.switchLanguage(language)
        scope.launch {
            loadLazerTranslations()
            loadBackgroundImage()
            bootstrap()
        }
    }

    fun updatePalette(value: LazerPalette) {
        palette = value
        settings.palette = value
    }

    fun updateBackgroundAlpha(value: Float) {
        backgroundAlpha = value.coerceIn(0f, 1f)
        settings.backgroundAlpha = backgroundAlpha
    }

    fun updateBackgroundImageEnabled(enabled: Boolean) {
        backgroundImageEnabled = enabled
        settings.backgroundImageEnabled = enabled
    }

    private suspend fun loadBackgroundImage() {
        val path = settings.backgroundImagePath ?: return
        val bitmap = withContext(Dispatchers.IO) {
            runCatching {
                android.graphics.BitmapFactory.decodeFile(path)?.asImageBitmap()
            }.getOrNull()
        }
        backgroundImage = bitmap
    }

    /** Copies the picked image into app storage and decodes it as the new background. */
    fun setBackgroundImage(uri: android.net.Uri) {
        scope.launch {
            val decoded = withContext(Dispatchers.IO) {
                runCatching {
                    val target = java.io.File(appContext.filesDir, BACKGROUND_IMAGE_FILE)
                    appContext.contentResolver.openInputStream(uri)?.use { input ->
                        target.outputStream().use(input::copyTo)
                    }
                    android.graphics.BitmapFactory.decodeFile(target.absolutePath)?.asImageBitmap()
                }.onFailure { android.util.Log.w("AndroidGatewayController", "background load failed", it) }
                    .getOrNull()
            }
            if (decoded != null) {
                backgroundImage = decoded
                settings.backgroundImagePath = java.io.File(appContext.filesDir, BACKGROUND_IMAGE_FILE).absolutePath
            }
        }
    }

    fun clearBackgroundImage() {
        backgroundImage = null
        settings.backgroundImagePath = null
        runCatching { java.io.File(appContext.filesDir, BACKGROUND_IMAGE_FILE).delete() }
    }

    val isSignedIn: Boolean get() = currentUser != null

    fun selectDestination(value: AndroidRootDestination) {
        destination = value
        isSettingsVisible = false
        closePlaylist()
        message = null
    }

    fun openSettings() {
        isSettingsVisible = true
    }

    fun closeSettings() {
        isSettingsVisible = false
    }

    fun toggleTheme() {
        isDark = !isDark
        settings.isDark = isDark
    }

    fun updateUseSystemMonetColors(enabled: Boolean) {
        useSystemMonetColors = enabled
        settings.useSystemMonetColors = enabled
    }

    fun updateStyle(value: LazerStyle) {
        style = value
        settings.style = value
    }

    fun updateLanguage(value: LazerLanguage) {
        if (language == value) return
        language = value
        LazerI18n.switchLanguage(value)
        settings.language = value
        message = null
        loginMessage = null
    }

    fun updateLyricFollowDelay(value: Long) {
        lyricFollowDelayMillis = normalizeLyricFollowDelayMillis(value)
        settings.lyricFollowDelayMillis = lyricFollowDelayMillis
    }

    fun updateLyricAnimationSpeed(value: LyricAnimationSpeed) {
        lyricAnimationSpeed = value
        settings.lyricAnimationSpeed = value
    }

    fun updateWordLyricsEnabled(enabled: Boolean) {
        wordLyricsEnabled = enabled
        settings.wordLyricsEnabled = enabled
    }

    fun updateLyricGlowEnabled(enabled: Boolean) {
        lyricGlowEnabled = enabled
        settings.lyricGlowEnabled = enabled
    }

    fun updateLyricFontSizeSp(value: Int) {
        lyricFontSizeSp = normalizeLyricFontSizeSp(value)
        settings.lyricFontSizeSp = lyricFontSizeSp
    }

    fun updateShowFullLyrics(enabled: Boolean) {
        showFullLyrics = enabled
        settings.showFullLyrics = enabled
    }

    fun updateAudioQuality(value: AudioQuality) {
        if (value !in ANDROID_AUDIO_QUALITY_OPTIONS || value == audioQuality) return
        audioQuality = value
        settings.audioQuality = value
    }

    fun updateExclusiveAudio(enabled: Boolean) {
        if (exclusiveAudio == enabled) return
        exclusiveAudio = enabled
        settings.exclusiveAudio = enabled
        AndroidPlaybackConnection.updateExclusiveAudio(appContext)
    }

    fun updateGatewayBaseUrl(value: String): Boolean {
        val normalized = normalizeGatewayBaseUrl(value) ?: return false
        if (normalized == gatewayBaseUrl) return true

        bootstrapJob?.cancel()
        searchJob?.cancel()
        playlistJob?.cancel()
        lyricJob?.cancel()
        qrLoginJob?.cancel()
        postLoginSyncJob?.cancel()
        gateway.close()
        playlistRequestGeneration += 1

        settings.gatewayBaseUrl = normalized
        gatewayBaseUrl = normalized
        gateway = NeteaseMusicGateway(
            config = GatewayConfig(baseUrl = normalized),
            sessionStore = gatewaySessionStore,
        )

        activePlaylist = null
        activePlaylistTracks = emptyList()
        isPlaylistLoading = false
        searchResults = emptyList()
        lyrics = emptyList()
        lyricsMessage = null
        isLoginVisible = false
        qrState = AndroidQrLoginState.IDLE
        qrImageData = null
        bootstrap()
        message = tr("status.music_switched")
        return true
    }

    fun isSongLiked(songId: Long): Boolean = songId in likedSongIds

    fun toggleSongLiked(track: AndroidTrack) {
        val user = currentUser
        if (user == null) {
            openLogin()
            return
        }
        val wasLiked = track.id in likedSongIds
        val nextLiked = !wasLiked
        likedSongIds = if (nextLiked) likedSongIds + track.id else likedSongIds - track.id
        cache.saveLikedSongIds(user.userId, likedSongIds)
        scope.launch {
            runCatching { gateway.updateSongLiked(track.id, user.userId, nextLiked) }
                .onFailure {
                    likedSongIds = if (wasLiked) likedSongIds + track.id else likedSongIds - track.id
                    cache.saveLikedSongIds(user.userId, likedSongIds)
                    message = tr("status.like_fail")
                }
        }
    }

    fun openPlaylist(playlist: AndroidPlaylist) {
        val requestGeneration = ++playlistRequestGeneration
        playlistJob?.cancel()
        activePlaylist = playlist
        val cachedTracks = cache.peekTracks(playlist.id).orEmpty()
        activePlaylistTracks = cachedTracks
        isPlaylistLoading = true
        playlistJob = scope.launch {
            val persistedTracks = if (cachedTracks.isEmpty()) {
                withContext(Dispatchers.IO) { cache.loadTracks(playlist.id) }
            } else {
                cachedTracks
            }
            if (!isCurrentPlaylistRequest(playlist.id, requestGeneration)) return@launch
            if (persistedTracks.isNotEmpty()) activePlaylistTracks = persistedTracks
            try {
                val fresh = loadAllPlaylistTracks(playlist, requestGeneration)
                if (isCurrentPlaylistRequest(playlist.id, requestGeneration) && fresh.isNotEmpty()) {
                    activePlaylistTracks = fresh
                }
            } catch (_: Throwable) {
                if (persistedTracks.isEmpty()) message = tr("status.playlist_sync_fail")
            } finally {
                if (isCurrentPlaylistRequest(playlist.id, requestGeneration)) isPlaylistLoading = false
            }
        }
    }

    fun closePlaylist() {
        playlistJob?.cancel()
        playlistRequestGeneration += 1
        activePlaylist = null
        activePlaylistTracks = emptyList()
        isPlaylistLoading = false
    }

    fun updateSearchQuery(value: String) {
        searchQuery = value
        searchJob?.cancel()
        if (value.isBlank()) {
            searchResults = emptyList()
            isSearching = false
            return
        }
        searchJob = scope.launch {
            delay(360)
            if (value != searchQuery) return@launch
            isSearching = true
            try {
                val searchSongs = gateway.search(value.trim(), limit = 30).result?.songs.orEmpty()
                val detailedSongs = searchSongs
                    .map(Song::id)
                    .takeIf(List<Long>::isNotEmpty)
                    ?.let { ids ->
                        runCatching { gateway.songDetails(ids).songs.associateBy(Song::id) }
                            .getOrDefault(emptyMap())
                    }
                    .orEmpty()
                searchResults = searchSongs.map { song ->
                    toAndroidTrack(detailedSongs[song.id] ?: song)
                }
            } catch (_: Throwable) {
                searchResults = emptyList()
                message = tr("status.search_fail")
            } finally {
                if (value == searchQuery) isSearching = false
            }
        }
    }

    fun loadLyrics(trackId: Long) {
        lyricJob?.cancel()
        lyrics = emptyList()
        SuperLyricPublisher.updateLyrics(trackId, emptyList())
        lyricsMessage = null
        lyricsLoading = true
        lyricJob = scope.launch {
            try {
                val response = gateway.preferredLyrics(trackId)
                val timedLyrics = parseAndroidWordLyrics(response.yrc?.lyric)
                    .ifEmpty { parseAndroidLrc(response.lrc?.lyric) }
                val merged = mergeAndroidLyrics(
                    timedLyrics,
                    parseAndroidLrc(response.tlyric?.lyric),
                )
                lyrics = merged
                SuperLyricPublisher.updateLyrics(trackId, merged)
                lyricsMessage = if (merged.isEmpty()) tr("status.no_lyrics") else null
            } catch (_: Throwable) {
                lyrics = emptyList()
                SuperLyricPublisher.updateLyrics(trackId, emptyList())
                lyricsMessage = tr("status.lyrics_fail")
            } finally {
                lyricsLoading = false
            }
        }
    }

    fun openLogin() {
        isLoginVisible = true
        loginMethod = AndroidLoginMethod.CAPTCHA
        loginMessage = null
    }

    fun closeLogin() {
        isLoginVisible = false
        qrLoginJob?.cancel()
        qrState = AndroidQrLoginState.IDLE
        qrImageData = null
        loginMessage = null
    }

    fun selectLoginMethod(method: AndroidLoginMethod) {
        loginMethod = method
        loginMessage = null
        if (method != AndroidLoginMethod.QR_CODE) {
            qrLoginJob?.cancel()
            qrState = AndroidQrLoginState.IDLE
            qrImageData = null
        } else {
            startQrLogin()
        }
    }

    fun updateLoginPhone(value: String) {
        loginPhone = value
        loginMessage = null
    }

    fun updateLoginCaptcha(value: String) {
        loginCaptcha = value
        loginMessage = null
    }

    fun updateLoginPassword(value: String) {
        loginPassword = value
        loginMessage = null
    }

    fun sendCaptcha() {
        val phone = normalizedPhone() ?: run {
            loginMessage = tr("login.captcha.phone_required")
            return
        }
        scope.launch {
            isSendingCaptcha = true
            loginMessage = null
            try {
                val result = gateway.sendCaptcha(phone)
                val code = result["code"]?.toString()?.trim('"')?.toIntOrNull()
                check(code in 200..299) { tr("login.captcha.send_fail") }
                captchaSent = true
                loginMessage = tr("login.captcha.sent")
            } catch (_: Throwable) {
                loginMessage = tr("login.captcha.send_fail")
            } finally {
                isSendingCaptcha = false
            }
        }
    }

    fun submitCaptchaLogin() {
        val phone = normalizedPhone() ?: run {
            loginMessage = tr("login.phone_required")
            return
        }
        if (loginCaptcha.isBlank()) {
            loginMessage = tr("login.code_required")
            return
        }
        scope.launch {
            isSubmittingLogin = true
            loginMessage = null
            try {
                val result = gateway.loginWithPhoneCaptcha(phone, loginCaptcha.trim())
                validateLogin(result.code, result.failureMessage)
                finishLogin(result.profile)
            } catch (_: Throwable) {
                loginMessage = tr("login.captcha_fail")
            } finally {
                isSubmittingLogin = false
            }
        }
    }

    fun submitPasswordLogin() {
        val phone = normalizedPhone() ?: run {
            loginMessage = tr("login.phone_required")
            return
        }
        if (loginPassword.isBlank()) {
            loginMessage = tr("login.password_required")
            return
        }
        scope.launch {
            isSubmittingLogin = true
            loginMessage = null
            try {
                val result = gateway.loginWithPhonePassword(phone, loginPassword, countryCode = "86")
                validateLogin(result.code, result.failureMessage)
                finishLogin(result.profile)
            } catch (_: Throwable) {
                loginMessage = tr("login.password_fail")
            } finally {
                isSubmittingLogin = false
            }
        }
    }

    fun startQrLogin() {
        qrLoginJob?.cancel()
        qrLoginJob = scope.launch {
            qrState = AndroidQrLoginState.CREATING
            qrImageData = null
            loginMessage = null
            try {
                val key = gateway.createQrKey().data?.unikey.orEmpty()
                check(key.isNotBlank()) { tr("login.qr_key_empty") }
                val code = gateway.createQrCode(key, includeImage = true).data
                qrImageData = code?.qrimg
                check(!qrImageData.isNullOrBlank()) { tr("login.qr_empty") }
                qrState = AndroidQrLoginState.WAITING_FOR_SCAN
                while (isActive) {
                    delay(QR_POLL_INTERVAL_MILLIS)
                    when (val result = gateway.checkQrCode(key).code) {
                        800 -> {
                            qrState = AndroidQrLoginState.EXPIRED
                            return@launch
                        }
                        801 -> qrState = AndroidQrLoginState.WAITING_FOR_SCAN
                        802 -> qrState = AndroidQrLoginState.WAITING_FOR_CONFIRMATION
                        803 -> {
                            finishLogin()
                            return@launch
                        }
                        else -> {
                            qrState = AndroidQrLoginState.ERROR
                            loginMessage = tr("login.qr_fail")
                            return@launch
                        }
                    }
                }
            } catch (_: Throwable) {
                qrState = AndroidQrLoginState.ERROR
                loginMessage = tr("login.qr_gen_fail_retry")
            }
        }
    }

    fun logout() {
        postLoginSyncJob?.cancel()
        scope.launch {
            AndroidPlaybackConnection.stopAndClearSession(appContext)
            try {
                gateway.logoutSession()
            } catch (_: Throwable) {
                gateway.clearSession()
            }
            currentUser = null
            cache.clearCurrentUser()
            userPlaylists = emptyList()
            likedSongIds = emptySet()
            destination = AndroidRootDestination.HOME
            message = tr("status.logged_out")
            runCatching { loadPublicContent() }
        }
    }

    fun close() {
        postLoginSyncJob?.cancel()
        maintenanceJob?.cancel()
        scope.cancel()
        cache.close()
        gateway.close()
    }

    fun clearSongCache() {
        maintenanceJob?.cancel()
        maintenanceJob = scope.launch {
            val removed = withContext(Dispatchers.IO) {
                appContext.cacheDir.listFiles().orEmpty().count { it.deleteRecursively() }
            }
            message = if (removed > 0) tr("status.songs_cleared") else tr("status.songs_empty")
        }
    }

    fun clearPlaylistCache() {
        maintenanceJob?.cancel()
        maintenanceJob = scope.launch {
            val removed = withContext(Dispatchers.IO) { cache.clearPlaylistData() }
            message = if (removed > 0) tr("status.playlists_cleared") else tr("status.playlists_empty")
        }
    }

    fun forceResync() {
        maintenanceJob?.cancel()
        bootstrapJob?.cancel()
        postLoginSyncJob?.cancel()
        maintenanceJob = scope.launch {
            isLoading = true
            message = tr("status.resyncing")
            try {
                currentUser?.let { loadSignedInContent(it, forceRefresh = true) }
                    ?: loadPublicContent(forceRefresh = true)
                message = tr("status.resynced")
            } catch (error: CancellationException) {
                throw error
            } catch (_: Throwable) {
                message = tr("status.resync_fail")
            } finally {
                isLoading = false
            }
        }
    }

    private fun bootstrap() {
        bootstrapJob?.cancel()
        isLoading = true
        val gatewayAtStart = gateway
        bootstrapJob = scope.launch {
            val cached = withContext(Dispatchers.IO) {
                val hasSavedSession = !gatewayAtStart.sessionCookie.isNullOrBlank()
                val profile = cache.loadCurrentUser().takeIf { hasSavedSession }
                AndroidCachedBootstrap(
                    hasSavedSession = hasSavedSession,
                    featuredPlaylists = cache.loadFeaturedPlaylists(),
                    homeTracks = cache.loadTracks(HOME_TRACKS_CACHE_ID),
                    profile = profile,
                    userPlaylists = profile?.let { cache.loadUserPlaylists(it.userId) }.orEmpty(),
                    likedSongIds = profile?.let { cache.loadLikedSongIds(it.userId) }.orEmpty(),
                )
            }
            if (gatewayAtStart !== gateway) return@launch
            featuredPlaylists = cached.featuredPlaylists
            homeTracks = cached.homeTracks
            if (cached.profile != null) {
                currentUser = cached.profile
                userPlaylists = cached.userPlaylists
                likedSongIds = cached.likedSongIds
            } else {
                currentUser = null
                userPlaylists = emptyList()
                likedSongIds = emptySet()
            }
            try {
                if (!cached.hasSavedSession) {
                    loadPublicContent()
                } else {
                    val freshProfile = resolveCurrentUser()
                    if (freshProfile == null) {
                        gateway.clearSession()
                        cache.clearCurrentUser()
                        currentUser = null
                        userPlaylists = emptyList()
                        likedSongIds = emptySet()
                        loadPublicContent()
                    } else {
                        currentUser = freshProfile
                        cache.saveCurrentUser(freshProfile)
                        restoreCachedSignedInContent(freshProfile)
                        loadSignedInContent(freshProfile)
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (_: Throwable) {
                message = if (currentUser != null) {
                    tr("status.local_only")
                } else {
                    tr("status.connect_fail")
                }
            } finally {
                isLoading = false
            }
        }
    }

    private suspend fun loadPublicContent(forceRefresh: Boolean = false) {
        val freshPlaylists = withContext(Dispatchers.IO) {
            gateway.topPlaylists(limit = 12, forceRefresh = forceRefresh)
                .playlists.map(::toAndroidPlaylist)
        }
        if (freshPlaylists.isNotEmpty()) {
            featuredPlaylists = freshPlaylists
            cache.saveFeaturedPlaylists(freshPlaylists)
        }
        val source = featuredPlaylists.firstOrNull() ?: return
        val freshTracks = withContext(Dispatchers.IO) {
            gateway.playlistTracks(source.id, limit = 50, forceRefresh = forceRefresh)
                .songs.map(::toAndroidTrack)
        }
        if (freshTracks.isNotEmpty()) {
            homeTracks = freshTracks
            cache.saveTracks(HOME_TRACKS_CACHE_ID, freshTracks)
        }
    }

    private suspend fun restoreCachedSignedInContent(profile: UserProfile) {
        val cached = withContext(Dispatchers.IO) {
            AndroidCachedSignedInContent(
                userPlaylists = cache.loadUserPlaylists(profile.userId),
                likedSongIds = cache.loadLikedSongIds(profile.userId),
            )
        }
        userPlaylists = cached.userPlaylists
        likedSongIds = cached.likedSongIds
    }

    private suspend fun loadSignedInContent(profile: UserProfile, forceRefresh: Boolean = false) {
        supervisorScope {
            // These endpoints are independent. Starting them together shortens a refresh by the
            // slowest request instead of the sum of all four round trips.
            val likedSongIdsRequest = async(Dispatchers.IO) {
                gatewayOrNull { gateway.likedSongIds(profile.userId, forceRefresh).ids.toSet() }
            }
            val userPlaylistsRequest = async(Dispatchers.IO) {
                gatewayOrNull { loadAllUserPlaylists(profile.userId, forceRefresh) }.orEmpty()
            }
            val recommendedPlaylistsRequest = async(Dispatchers.IO) {
                gatewayOrNull {
                    gateway.dailyRecommendedPlaylists(forceRefresh).recommend.map(::toAndroidPlaylist)
                }.orEmpty()
            }
            val recommendedTracksRequest = async(Dispatchers.IO) {
                gatewayOrNull {
                    gateway.dailyRecommendedSongs(forceRefresh).data?.dailySongs.orEmpty().map(::toAndroidTrack)
                }.orEmpty()
            }

            likedSongIdsRequest.await()?.let { freshLikedSongIds ->
                likedSongIds = freshLikedSongIds
                cache.saveLikedSongIds(profile.userId, freshLikedSongIds)
            }
            val loadedPlaylists = userPlaylistsRequest.await()
            if (loadedPlaylists.isNotEmpty()) {
                userPlaylists = loadedPlaylists
                cache.saveUserPlaylists(profile.userId, loadedPlaylists)
            }

            val recommendedPlaylists = recommendedPlaylistsRequest.await()
            if (recommendedPlaylists.isNotEmpty()) {
                featuredPlaylists = recommendedPlaylists
                cache.saveFeaturedPlaylists(recommendedPlaylists)
            }

            val recommendedTracks = recommendedTracksRequest.await()
            if (recommendedTracks.isNotEmpty()) {
                homeTracks = recommendedTracks
                cache.saveTracks(HOME_TRACKS_CACHE_ID, recommendedTracks)
            } else if (homeTracks.isEmpty()) {
                loadPublicContent(forceRefresh)
            }
        }
    }

    private suspend fun loadAllUserPlaylists(
        userId: Long,
        forceRefresh: Boolean = false,
    ): List<AndroidPlaylist> {
        val all = mutableListOf<AndroidPlaylist>()
        var offset = 0
        do {
            val page = gateway.userPlaylists(
                userId,
                limit = 50,
                offset = offset,
                forceRefresh = forceRefresh,
            )
            all += page.playlist.map(::toAndroidPlaylist)
            offset += page.playlist.size
            if (!page.more || page.playlist.isEmpty()) break
        } while (true)
        return all.distinctBy(AndroidPlaylist::id)
    }

    private suspend fun loadAllPlaylistTracks(
        playlist: AndroidPlaylist,
        requestGeneration: Long,
    ): List<AndroidTrack> {
        val refreshed = mutableListOf<AndroidTrack>()
        var offset = 0
        do {
            val page = withContext(Dispatchers.IO) {
                gateway.playlistTracks(
                    playlist.id,
                    limit = PLAYLIST_PAGE_SIZE,
                    offset = offset,
                    // The Gateway may retain a GET response briefly. The on-screen cache is already
                    // shown first, so a refresh must use a request-specific URL rather than risk
                    // accepting an old response after the user opened another playlist.
                    forceRefresh = true,
                ).songs.map(::toAndroidTrack)
            }
            if (!isCurrentPlaylistRequest(playlist.id, requestGeneration)) return emptyList()
            if (page.isEmpty()) break
            refreshed += page
            val currentPage = refreshed.distinctBy(AndroidTrack::id)
            // A request owns the visible list for its full lifetime. Do not combine it with a
            // previous cache snapshot: that is how a cancelled playlist request could leave B's
            // rows visible under A's header while the next page was arriving.
            activePlaylistTracks = currentPage
            offset += page.size
            if (page.size < PLAYLIST_PAGE_SIZE) break
        } while (true)
        val complete = refreshed.distinctBy(AndroidTrack::id)
        if (isCurrentPlaylistRequest(playlist.id, requestGeneration) && complete.isNotEmpty()) {
            cache.saveTracks(playlist.id, complete)
        }
        return complete
    }

    private fun isCurrentPlaylistRequest(playlistId: Long, requestGeneration: Long): Boolean =
        playlistRequestGeneration == requestGeneration && activePlaylist?.id == playlistId

    private suspend fun resolveCurrentUser(): UserProfile? {
        if (gateway.sessionCookie.isNullOrBlank()) return null
        val status = gateway.loginStatus().data
        return status?.profile?.takeIf { it.userId > 0 }
            ?: status?.account?.id?.takeIf { it > 0 }?.let { gateway.userDetail(it).profile }
    }

    private suspend fun finishLogin(profileHint: UserProfile? = null) {
        val profile = profileHint?.takeIf { it.userId > 0 } ?: resolveCurrentUser()
        check(profile != null && profile.userId > 0) { tr("login.no_profile") }
        bootstrapJob?.cancelAndJoin()
        bootstrapJob = null
        currentUser = profile
        cache.saveCurrentUser(profile)
        restoreCachedSignedInContent(profile)
        loginPassword = ""
        loginCaptcha = ""
        isLoginVisible = false
        qrLoginJob = null
        qrState = AndroidQrLoginState.IDLE
        qrImageData = null
        message = tr("status.login_success_syncing")
        postLoginSyncJob?.cancel()
        postLoginSyncJob = scope.launch {
            isLoading = true
            try {
                loadSignedInContent(profile)
                message = tr("status.synced")
            } catch (error: CancellationException) {
                throw error
            } catch (_: Throwable) {
                message = tr("status.login_sync_later")
            } finally {
                isLoading = false
            }
        }
    }

    private fun validateLogin(code: Int, failureMessage: String?) {
        check(code in 200..299 && !gateway.sessionCookie.isNullOrBlank()) {
            failureMessage ?: tr("login.fail_check")
        }
    }

    private fun normalizedPhone(): String? = loginPhone
        .replace(" ", "")
        .removePrefix("+86")
        .takeIf { it.length >= 6 && it.all(Char::isDigit) }

    private suspend fun <T> gatewayOrNull(request: suspend () -> T): T? = try {
        request()
    } catch (error: CancellationException) {
        throw error
    } catch (_: Throwable) {
        null
    }

    private companion object {
        const val BACKGROUND_IMAGE_FILE = "lazer.background.png"
        const val HOME_TRACKS_CACHE_ID = -101L
        const val PLAYLIST_PAGE_SIZE = 500
        const val QR_POLL_INTERVAL_MILLIS = 1_800L
    }
}

private fun toAndroidTrack(song: Song): AndroidTrack = AndroidTrack(
    id = song.id,
    title = song.name.ifBlank { tr("track.unknown_song") },
    artist = song.artists.joinToString(" / ") { it.name }.ifBlank { tr("track.unknown_artist.android") },
    album = song.album?.name.orEmpty(),
    durationMillis = song.durationMillis ?: 0L,
    coverUrl = normalizedArtworkUrl(song.album?.picUrl),
)

private fun toAndroidPlaylist(playlist: Playlist): AndroidPlaylist = AndroidPlaylist(
    id = playlist.id,
    title = playlist.name.ifBlank { tr("playlist.unnamed") },
    subtitle = playlist.creator?.nickname?.takeIf(String::isNotBlank)
        ?: playlist.description?.takeIf(String::isNotBlank)
        ?: tr("playlist.tracks", playlist.trackCount ?: 0),
    coverUrl = sequenceOf(playlist.coverImgUrl, playlist.picUrl)
        .mapNotNull(::normalizedArtworkUrl)
        .firstOrNull(),
    trackCount = playlist.trackCount ?: 0,
    isLikedCollection = playlist.specialType == 5 || playlist.name.endsWith("喜欢的音乐"),
)
