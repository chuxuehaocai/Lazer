package dev.naominet.lazer

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
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
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

enum class AndroidRootDestination(val label: String, val motionIndex: Int) {
    HOME("今天", 0),
    DISCOVER("发现", 1),
    SEARCH("搜索", 2),
    LIBRARY("音乐库", 3),
    ME("我的", 4),
}

enum class AndroidLoginMethod(val label: String) {
    CAPTCHA("验证码"),
    PASSWORD("密码"),
    QR_CODE("二维码"),
}

enum class AndroidQrLoginState {
    IDLE,
    CREATING,
    WAITING_FOR_SCAN,
    WAITING_FOR_CONFIRMATION,
    EXPIRED,
    ERROR,
}

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

    var destination by mutableStateOf(AndroidRootDestination.HOME)
        private set
    var isSettingsVisible by mutableStateOf(false)
        private set
    var isDark by mutableStateOf(settings.isDark)
        private set
    var useSystemMonetColors by mutableStateOf(settings.useSystemMonetColors)
        private set
    var themeEngine by mutableStateOf(settings.themeEngine)
        private set
    var lyricFollowDelayMillis by mutableStateOf(settings.lyricFollowDelayMillis)
        private set
    var lyricAnimationSpeed by mutableStateOf(settings.lyricAnimationSpeed)
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
        bootstrap()
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

    fun updateThemeEngine(value: LazerThemeEngine) {
        themeEngine = value
        settings.themeEngine = value
    }

    fun updateLyricFollowDelay(value: Long) {
        lyricFollowDelayMillis = normalizeLyricFollowDelayMillis(value)
        settings.lyricFollowDelayMillis = lyricFollowDelayMillis
    }

    fun updateLyricAnimationSpeed(value: LyricAnimationSpeed) {
        lyricAnimationSpeed = value
        settings.lyricAnimationSpeed = value
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
        message = "音乐服务已切换"
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
                    message = "喜欢状态未能同步，请重试"
                }
        }
    }

    fun openPlaylist(playlist: AndroidPlaylist) {
        activePlaylist = playlist
        val cachedTracks = cache.loadTracks(playlist.id)
        activePlaylistTracks = cachedTracks
        isPlaylistLoading = true
        playlistJob?.cancel()
        playlistJob = scope.launch {
            try {
                val fresh = loadAllPlaylistTracks(playlist)
                if (activePlaylist?.id == playlist.id && fresh.isNotEmpty()) {
                    activePlaylistTracks = fresh
                }
            } catch (_: Throwable) {
                if (cachedTracks.isEmpty()) message = "歌单暂时没有同步成功，请稍后再试"
            } finally {
                if (activePlaylist?.id == playlist.id) isPlaylistLoading = false
            }
        }
    }

    fun closePlaylist() {
        playlistJob?.cancel()
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
                message = "搜索没有完成，请稍后再试"
            } finally {
                if (value == searchQuery) isSearching = false
            }
        }
    }

    fun loadLyrics(trackId: Long) {
        lyricJob?.cancel()
        lyrics = emptyList()
        lyricsMessage = null
        lyricsLoading = true
        lyricJob = scope.launch {
            try {
                val response = runCatching { gateway.wordByWordLyrics(trackId) }
                    .getOrElse { gateway.lyrics(trackId) }
                val timedLyrics = parseAndroidWordLyrics(response.yrc?.lyric)
                    .ifEmpty { parseAndroidLrc(response.lrc?.lyric) }
                val merged = mergeAndroidLyrics(
                    timedLyrics,
                    parseAndroidLrc(response.tlyric?.lyric),
                )
                lyrics = merged
                lyricsMessage = if (merged.isEmpty()) "这首歌暂时没有歌词" else null
            } catch (_: Throwable) {
                lyrics = emptyList()
                lyricsMessage = "歌词没有加载成功，请稍后再试"
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
            loginMessage = "请输入手机号后再获取验证码"
            return
        }
        scope.launch {
            isSendingCaptcha = true
            loginMessage = null
            try {
                val result = gateway.sendCaptcha(phone)
                val code = result["code"]?.toString()?.trim('"')?.toIntOrNull()
                check(code in 200..299) { "验证码发送失败" }
                captchaSent = true
                loginMessage = "验证码已发送，请留意手机"
            } catch (_: Throwable) {
                loginMessage = "验证码没有发送成功，请稍后再试"
            } finally {
                isSendingCaptcha = false
            }
        }
    }

    fun submitCaptchaLogin() {
        val phone = normalizedPhone() ?: run {
            loginMessage = "请输入手机号"
            return
        }
        if (loginCaptcha.isBlank()) {
            loginMessage = "请输入收到的验证码"
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
                loginMessage = "验证码登录没有完成，请检查后重试"
            } finally {
                isSubmittingLogin = false
            }
        }
    }

    fun submitPasswordLogin() {
        val phone = normalizedPhone() ?: run {
            loginMessage = "请输入手机号"
            return
        }
        if (loginPassword.isBlank()) {
            loginMessage = "请输入密码"
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
                loginMessage = "密码登录没有完成，请检查账号和密码"
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
                check(key.isNotBlank()) { "二维码初始化失败" }
                val code = gateway.createQrCode(key, includeImage = true).data
                qrImageData = code?.qrimg
                check(!qrImageData.isNullOrBlank()) { "二维码生成失败" }
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
                            loginMessage = "二维码登录没有完成，请重新生成"
                            return@launch
                        }
                    }
                }
            } catch (_: Throwable) {
                qrState = AndroidQrLoginState.ERROR
                loginMessage = "二维码生成失败，请重新生成"
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
            message = "已退出登录"
            runCatching { loadPublicContent() }
        }
    }

    fun close() {
        postLoginSyncJob?.cancel()
        maintenanceJob?.cancel()
        scope.cancel()
        gateway.close()
    }

    fun clearSongCache() {
        maintenanceJob?.cancel()
        maintenanceJob = scope.launch {
            val removed = withContext(Dispatchers.IO) {
                appContext.cacheDir.listFiles().orEmpty().count { it.deleteRecursively() }
            }
            message = if (removed > 0) "歌曲缓存已清除" else "歌曲缓存已经是空的"
        }
    }

    fun clearPlaylistCache() {
        val removed = cache.clearPlaylistData()
        message = if (removed > 0) "歌单缓存已清除" else "歌单缓存已经是空的"
    }

    fun forceResync() {
        maintenanceJob?.cancel()
        bootstrapJob?.cancel()
        postLoginSyncJob?.cancel()
        maintenanceJob = scope.launch {
            isLoading = true
            message = "正在重新同步…"
            try {
                currentUser?.let { loadSignedInContent(it, forceRefresh = true) }
                    ?: loadPublicContent(forceRefresh = true)
                message = "已重新同步"
            } catch (error: CancellationException) {
                throw error
            } catch (_: Throwable) {
                message = "重新同步没有完成，请稍后再试"
            } finally {
                isLoading = false
            }
        }
    }

    private fun bootstrap() {
        bootstrapJob?.cancel()
        isLoading = true
        featuredPlaylists = cache.loadFeaturedPlaylists()
        homeTracks = cache.loadTracks(HOME_TRACKS_CACHE_ID)
        val hasSavedSession = !gateway.sessionCookie.isNullOrBlank()
        val cachedProfile = cache.loadCurrentUser().takeIf { hasSavedSession }
        if (cachedProfile != null) {
            currentUser = cachedProfile
            restoreCachedSignedInContent(cachedProfile)
        } else if (!hasSavedSession) {
            currentUser = null
            userPlaylists = emptyList()
            likedSongIds = emptySet()
        }
        bootstrapJob = scope.launch {
            try {
                if (!hasSavedSession) {
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
                    "已显示本地内容，暂时无法同步"
                } else {
                    "暂时无法连接音乐服务，请稍后再试"
                }
            } finally {
                isLoading = false
            }
        }
    }

    private suspend fun loadPublicContent(forceRefresh: Boolean = false) {
        val freshPlaylists = gateway.topPlaylists(limit = 12, forceRefresh = forceRefresh)
            .playlists.map(::toAndroidPlaylist)
        if (freshPlaylists.isNotEmpty()) {
            featuredPlaylists = freshPlaylists
            cache.saveFeaturedPlaylists(freshPlaylists)
        }
        val source = featuredPlaylists.firstOrNull() ?: return
        val freshTracks = gateway.playlistTracks(source.id, limit = 50, forceRefresh = forceRefresh)
            .songs.map(::toAndroidTrack)
        if (freshTracks.isNotEmpty()) {
            homeTracks = freshTracks
            cache.saveTracks(HOME_TRACKS_CACHE_ID, freshTracks)
        }
    }

    private fun restoreCachedSignedInContent(profile: UserProfile) {
        userPlaylists = cache.loadUserPlaylists(profile.userId)
        likedSongIds = cache.loadLikedSongIds(profile.userId)
    }

    private suspend fun loadSignedInContent(profile: UserProfile, forceRefresh: Boolean = false) {
        runCatching { gateway.likedSongIds(profile.userId, forceRefresh).ids.toSet() }
            .getOrNull()
            ?.let { freshLikedSongIds ->
                likedSongIds = freshLikedSongIds
                cache.saveLikedSongIds(profile.userId, freshLikedSongIds)
            }
        val loadedPlaylists = loadAllUserPlaylists(profile.userId, forceRefresh)
        if (loadedPlaylists.isNotEmpty()) {
            userPlaylists = loadedPlaylists
            cache.saveUserPlaylists(profile.userId, loadedPlaylists)
        }

        val recommendedPlaylists = runCatching {
            gateway.dailyRecommendedPlaylists(forceRefresh).recommend.map(::toAndroidPlaylist)
        }.getOrDefault(emptyList())
        if (recommendedPlaylists.isNotEmpty()) {
            featuredPlaylists = recommendedPlaylists
            cache.saveFeaturedPlaylists(recommendedPlaylists)
        }

        val recommendedTracks = runCatching {
            gateway.dailyRecommendedSongs(forceRefresh).data?.dailySongs.orEmpty().map(::toAndroidTrack)
        }.getOrDefault(emptyList())
        if (recommendedTracks.isNotEmpty()) {
            homeTracks = recommendedTracks
            cache.saveTracks(HOME_TRACKS_CACHE_ID, recommendedTracks)
        } else if (homeTracks.isEmpty()) {
            loadPublicContent(forceRefresh)
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

    private suspend fun loadAllPlaylistTracks(playlist: AndroidPlaylist): List<AndroidTrack> {
        val refreshed = mutableListOf<AndroidTrack>()
        var offset = 0
        do {
            val page = gateway.playlistTracks(playlist.id, limit = PLAYLIST_PAGE_SIZE, offset = offset).songs
            if (page.isEmpty()) break
            refreshed += page.map(::toAndroidTrack)
            // Publish additive pages while preserving cache content already shown on screen.
            if (activePlaylist?.id == playlist.id) {
                activePlaylistTracks = (activePlaylistTracks + refreshed)
                    .distinctBy(AndroidTrack::id)
            }
            offset += page.size
            if (page.size < PLAYLIST_PAGE_SIZE) break
        } while (true)
        val complete = refreshed.distinctBy(AndroidTrack::id)
        if (complete.isNotEmpty()) cache.saveTracks(playlist.id, complete)
        return complete
    }

    private suspend fun resolveCurrentUser(): UserProfile? {
        if (gateway.sessionCookie.isNullOrBlank()) return null
        val status = gateway.loginStatus().data
        return status?.profile?.takeIf { it.userId > 0 }
            ?: status?.account?.id?.takeIf { it > 0 }?.let { gateway.userDetail(it).profile }
    }

    private suspend fun finishLogin(profileHint: UserProfile? = null) {
        val profile = profileHint?.takeIf { it.userId > 0 } ?: resolveCurrentUser()
        check(profile != null && profile.userId > 0) { "未能确认登录状态" }
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
        message = "登录成功，正在同步你的音乐"
        postLoginSyncJob?.cancel()
        postLoginSyncJob = scope.launch {
            isLoading = true
            try {
                loadSignedInContent(profile)
                message = "歌单已同步"
            } catch (error: CancellationException) {
                throw error
            } catch (_: Throwable) {
                message = "登录成功，个人音乐暂时未能同步，请稍后重试"
            } finally {
                isLoading = false
            }
        }
    }

    private fun validateLogin(code: Int, failureMessage: String?) {
        check(code in 200..299 && !gateway.sessionCookie.isNullOrBlank()) {
            failureMessage ?: "登录没有完成"
        }
    }

    private fun normalizedPhone(): String? = loginPhone
        .replace(" ", "")
        .removePrefix("+86")
        .takeIf { it.length >= 6 && it.all(Char::isDigit) }

    private companion object {
        const val HOME_TRACKS_CACHE_ID = -101L
        const val PLAYLIST_PAGE_SIZE = 500
        const val QR_POLL_INTERVAL_MILLIS = 1_800L
    }
}

private fun toAndroidTrack(song: Song): AndroidTrack = AndroidTrack(
    id = song.id,
    title = song.name.ifBlank { "未命名歌曲" },
    artist = song.artists.joinToString(" / ") { it.name }.ifBlank { "未知音乐人" },
    album = song.album?.name.orEmpty(),
    durationMillis = song.durationMillis ?: 0L,
    coverUrl = normalizedArtworkUrl(song.album?.picUrl),
)

private fun toAndroidPlaylist(playlist: Playlist): AndroidPlaylist = AndroidPlaylist(
    id = playlist.id,
    title = playlist.name.ifBlank { "未命名歌单" },
    subtitle = playlist.creator?.nickname?.takeIf(String::isNotBlank)
        ?: playlist.description?.takeIf(String::isNotBlank)
        ?: "${playlist.trackCount ?: 0} 首音乐",
    coverUrl = sequenceOf(playlist.coverImgUrl, playlist.picUrl)
        .mapNotNull(::normalizedArtworkUrl)
        .firstOrNull(),
    trackCount = playlist.trackCount ?: 0,
    isLikedCollection = playlist.specialType == 5 || playlist.name.endsWith("喜欢的音乐"),
)
