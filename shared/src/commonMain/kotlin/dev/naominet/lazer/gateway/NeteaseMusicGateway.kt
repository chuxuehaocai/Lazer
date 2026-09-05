package dev.naominet.lazer.gateway

import dev.naominet.lazer.gateway.model.AlbumDetailResponse
import dev.naominet.lazer.gateway.model.ArtistDetailResponse
import dev.naominet.lazer.gateway.model.BannerResponse
import dev.naominet.lazer.gateway.model.DailyPlaylistsResponse
import dev.naominet.lazer.gateway.model.DailySongsResponse
import dev.naominet.lazer.gateway.model.LikedSongIdsResponse
import dev.naominet.lazer.gateway.model.LoginResponse
import dev.naominet.lazer.gateway.model.LoginStatusResponse
import dev.naominet.lazer.gateway.model.LyricResponse
import dev.naominet.lazer.gateway.model.MusicAvailabilityResponse
import dev.naominet.lazer.gateway.model.PersonalFmResponse
import dev.naominet.lazer.gateway.model.PlaylistDetailResponse
import dev.naominet.lazer.gateway.model.PlaylistTracksResponse
import dev.naominet.lazer.gateway.model.QrCheckResponse
import dev.naominet.lazer.gateway.model.QrCodeResponse
import dev.naominet.lazer.gateway.model.QrKeyResponse
import dev.naominet.lazer.gateway.model.SearchResponse
import dev.naominet.lazer.gateway.model.SongDetailResponse
import dev.naominet.lazer.gateway.model.SongUrlResponse
import dev.naominet.lazer.gateway.model.TopPlaylistsResponse
import dev.naominet.lazer.gateway.model.UserDetailResponse
import dev.naominet.lazer.gateway.model.UserPlaylistsResponse
import io.ktor.client.HttpClient
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.request.accept
import io.ktor.client.request.header
import io.ktor.client.request.request
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import io.ktor.serialization.kotlinx.json.json
import io.ktor.util.date.getTimeMillis
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put

/** Search types supported by `/search` and `/cloudsearch`. */
enum class SearchType(internal val apiValue: Int) {
    SONG(1),
    ALBUM(10),
    ARTIST(100),
    PLAYLIST(1000),
    USER(1002),
    MUSIC_VIDEO(1004),
    LYRIC(1006),
    RADIO(1009),
    VIDEO(1014),
    COMPREHENSIVE(1018),
    VOICE(2000),
}

/** Playback qualities accepted by `/song/url/v1`. */
enum class AudioQuality(
    internal val apiValue: String,
    val label: String,
    val description: String,
) {
    STANDARD("standard", "标准", "128 kbps"),
    HIGHER("higher", "较高", "192 kbps"),
    EXHIGH("exhigh", "极高", "320 kbps"),
    LOSSLESS("lossless", "无损", "FLAC"),
    HI_RES("hires", "Hi-Res", "Hi-Res FLAC"),
    JYEFFECT("jyeffect", "高清环绕", "音效增强"),
    SKY("sky", "沉浸环绕", "空间音频"),
    DOLBY("dolby", "杜比全景声", "Dolby Atmos"),
    JYMASTER("jymaster", "超清母带", "Master"),
}

/** Platform values accepted by `/banner`. */
enum class BannerPlatform(internal val apiValue: Int) {
    DESKTOP(0),
    ANDROID(1),
    IPHONE(2),
    IPAD(3),
}

/**
 * A Kotlin Multiplatform Wrapper around NeteaseCloudMusicApi Enhanced Gateway.
 *
 * Every documented route remains available via [getRaw] and [postRaw]. The typed methods cover
 * login plus the discovery, library, and playback paths a player needs first.
 */
class NeteaseMusicGateway(
    val config: GatewayConfig = GatewayConfig(),
    val sessionStore: GatewaySessionStore = InMemoryGatewaySessionStore(),
    private val httpClient: HttpClient = createDefaultHttpClient(config),
    private val closeHttpClient: Boolean = true,
    private val nowMillis: () -> Long = { getTimeMillis() },
) {
    /** The current raw Gateway session cookie, if the user has logged in. */
    val sessionCookie: String?
        get() = sessionStore.cookie

    /** Removes the locally held session cookie without making a network request. */
    fun clearSession() {
        sessionStore.cookie = null
    }

    /** Closes the owned HTTP client. Injected clients can opt out via `closeHttpClient = false`. */
    fun close() {
        if (closeHttpClient) {
            httpClient.close()
        }
    }

    /**
     * Calls any GET route exposed by the Gateway. Supply query parameters separately so they are
     * encoded correctly and a caller cannot accidentally replace the configured host.
     */
    suspend fun getRaw(
        path: String,
        parameters: Map<String, String> = emptyMap(),
    ): JsonElement = requestJson(HttpMethod.Get, path, parameters)

    /**
     * Calls any POST route exposed by the Gateway. A timestamp is included in the URL because
     * the Gateway documentation requires a unique POST URL to avoid its two-minute cache.
     */
    suspend fun postRaw(
        path: String,
        parameters: Map<String, String> = emptyMap(),
    ): JsonElement = requestJson(HttpMethod.Post, path, parameters)

    suspend inline fun <reified T> get(
        path: String,
        parameters: Map<String, String> = emptyMap(),
    ): T = gatewayJson.decodeFromJsonElement(getRaw(path, parameters))

    suspend inline fun <reified T> post(
        path: String,
        parameters: Map<String, String> = emptyMap(),
    ): T = gatewayJson.decodeFromJsonElement(postRaw(path, parameters))

    suspend fun anonymousLogin(): LoginResponse = rememberCookie(
        post<LoginResponse>("/register/anonimous"),
    )

    suspend fun loginWithPhonePassword(
        phone: String,
        password: String,
        countryCode: String? = null,
        sliderToken: String? = null,
    ): LoginResponse {
        require(phone.isNotBlank()) { "phone cannot be blank." }
        require(password.isNotBlank()) { "password cannot be blank." }
        return rememberCookie(
            post<LoginResponse>(
                "/login/cellphone",
                parametersOf(
                    "phone" to phone,
                    "password" to password,
                    "countrycode" to countryCode,
                    "sca" to sliderToken,
                ),
            ),
        )
    }

    suspend fun loginWithPhoneCaptcha(
        phone: String,
        captcha: String,
        countryCode: String = "86",
    ): LoginResponse {
        require(phone.isNotBlank()) { "phone cannot be blank." }
        require(captcha.isNotBlank()) { "captcha cannot be blank." }
        return rememberCookie(
            post<LoginResponse>(
                "/login/cellphone",
                parametersOf(
                    "phone" to phone,
                    "captcha" to captcha,
                    "countrycode" to countryCode,
                ),
            ),
        )
    }

    suspend fun loginWithEmail(email: String, password: String): LoginResponse {
        require(email.isNotBlank()) { "email cannot be blank." }
        require(password.isNotBlank()) { "password cannot be blank." }
        return rememberCookie(
            post<LoginResponse>("/login", parametersOf("email" to email, "password" to password)),
        )
    }

    suspend fun createQrKey(platform: String = "web"): QrKeyResponse =
        post("/login/qr/key", parametersOf("platform" to platform))

    suspend fun createQrCode(
        key: String,
        includeImage: Boolean = true,
        platform: String = "web",
    ): QrCodeResponse {
        require(key.isNotBlank()) { "key cannot be blank." }
        return post(
            "/login/qr/create",
            parametersOf("key" to key, "qrimg" to includeImage, "platform" to platform),
        )
    }

    suspend fun checkQrCode(key: String, platform: String = "web"): QrCheckResponse {
        require(key.isNotBlank()) { "key cannot be blank." }
        return rememberCookie(
            post<QrCheckResponse>(
                "/login/qr/check",
                parametersOf("key" to key, "platform" to platform),
            ),
        )
    }

    suspend fun refreshLogin(): LoginResponse = rememberCookie(post<LoginResponse>("/login/refresh"))

    /**
     * Uses POST so the request receives a cache-busting timestamp. The Gateway caches identical
     * GET URLs for two minutes, which can otherwise return a pre-login status immediately after a
     * QR login has supplied a new cookie.
     */
    suspend fun loginStatus(): LoginStatusResponse = post("/login/status")

    suspend fun userDetail(uid: Long): UserDetailResponse {
        require(uid > 0) { "uid must be positive." }
        return post("/user/detail", parametersOf("uid" to uid))
    }

    suspend fun logout(): JsonObject {
        val response = postRaw("/logout").jsonObject
        clearSession()
        return response
    }

    /** Logs out without exposing the transport JSON type to UI modules. */
    suspend fun logoutSession() {
        logout()
    }

    suspend fun sendCaptcha(phone: String, countryCode: String = "86"): JsonObject {
        require(phone.isNotBlank()) { "phone cannot be blank." }
        return postRaw("/captcha/sent/v1", parametersOf("phone" to phone, "ctcode" to countryCode)).jsonObject
    }

    suspend fun search(
        keywords: String,
        type: SearchType = SearchType.SONG,
        limit: Int = 30,
        offset: Int = 0,
        useCloudSearch: Boolean = false,
    ): SearchResponse {
        require(keywords.isNotBlank()) { "keywords cannot be blank." }
        require(limit > 0) { "limit must be greater than zero." }
        require(offset >= 0) { "offset cannot be negative." }
        return get(
            if (useCloudSearch) "/cloudsearch" else "/search",
            parametersOf(
                "keywords" to keywords,
                "type" to type.apiValue,
                "limit" to limit,
                "offset" to offset,
            ),
        )
    }

    suspend fun defaultSearchKeyword(): JsonObject = getRaw("/search/default").jsonObject

    suspend fun hotSearches(): JsonObject = getRaw("/search/hot/detail").jsonObject

    suspend fun searchSuggestions(keywords: String, mobile: Boolean = false): JsonObject {
        require(keywords.isNotBlank()) { "keywords cannot be blank." }
        return getRaw(
            "/search/suggest",
            parametersOf("keywords" to keywords, "type" to if (mobile) "mobile" else null),
        ).jsonObject
    }

    suspend fun songDetails(ids: Collection<Long>): SongDetailResponse {
        require(ids.isNotEmpty()) { "ids cannot be empty." }
        return get("/song/detail", parametersOf("ids" to ids.joinToString(",")))
    }

    suspend fun songUrls(
        ids: Collection<Long>,
        quality: AudioQuality = AudioQuality.EXHIGH,
        unblock: Boolean = false,
        immerseType: String? = null,
    ): SongUrlResponse {
        require(ids.isNotEmpty()) { "ids cannot be empty." }
        return get(
            "/song/url/v1",
            parametersOf(
                "id" to ids.joinToString(","),
                "level" to quality.apiValue,
                "unblock" to unblock,
                "immerseType" to immerseType,
            ),
        )
    }

    suspend fun isMusicAvailable(id: Long, bitrate: Int? = null): MusicAvailabilityResponse =
        get("/check/music", parametersOf("id" to id, "br" to bitrate))

    suspend fun lyrics(id: Long): LyricResponse = get("/lyric", parametersOf("id" to id))

    suspend fun wordByWordLyrics(id: Long): LyricResponse = get("/lyric/new", parametersOf("id" to id))

    suspend fun playlistDetail(id: Long, subscriberLimit: Int = 8): PlaylistDetailResponse {
        require(subscriberLimit >= 0) { "subscriberLimit cannot be negative." }
        return get("/playlist/detail", parametersOf("id" to id, "s" to subscriberLimit))
    }

    suspend fun playlistTracks(
        id: Long,
        limit: Int? = null,
        offset: Int = 0,
    ): PlaylistTracksResponse {
        require(limit == null || limit > 0) { "limit must be greater than zero." }
        require(offset >= 0) { "offset cannot be negative." }
        return get("/playlist/track/all", parametersOf("id" to id, "limit" to limit, "offset" to offset))
    }

    suspend fun userPlaylists(uid: Long, limit: Int = 30, offset: Int = 0): UserPlaylistsResponse {
        require(limit > 0) { "limit must be greater than zero." }
        require(offset >= 0) { "offset cannot be negative." }
        return get("/user/playlist", parametersOf("uid" to uid, "limit" to limit, "offset" to offset))
    }

    suspend fun topPlaylists(
        category: String? = null,
        order: String = "hot",
        limit: Int = 50,
        offset: Int = 0,
    ): TopPlaylistsResponse {
        require(limit > 0) { "limit must be greater than zero." }
        require(offset >= 0) { "offset cannot be negative." }
        return get(
            "/top/playlist",
            parametersOf("cat" to category, "order" to order, "limit" to limit, "offset" to offset),
        )
    }

    suspend fun albumDetail(id: Long): AlbumDetailResponse = get("/album", parametersOf("id" to id))

    suspend fun artistDetail(id: Long): ArtistDetailResponse = get("/artist/detail", parametersOf("id" to id))

    suspend fun artistTopSongs(id: Long): SongDetailResponse = get("/artist/top/song", parametersOf("id" to id))

    suspend fun banners(platform: BannerPlatform = BannerPlatform.DESKTOP): BannerResponse =
        get("/banner", parametersOf("type" to platform.apiValue))

    suspend fun dailyRecommendedSongs(): DailySongsResponse = get("/recommend/songs")

    suspend fun dailyRecommendedPlaylists(): DailyPlaylistsResponse = get("/recommend/resource")

    suspend fun personalFm(): PersonalFmResponse = get("/personal_fm")

    suspend fun likedSongIds(uid: Long): LikedSongIdsResponse = get("/likelist", parametersOf("uid" to uid))

    suspend fun setSongLiked(songId: Long, userId: Long, liked: Boolean): JsonObject =
        postRaw(
            "/song/like",
            parametersOf("id" to songId, "uid" to userId, "like" to liked),
        ).jsonObject

    /** Updates a liked song without exposing the transport JSON type to UI modules. */
    suspend fun updateSongLiked(songId: Long, userId: Long, liked: Boolean) {
        setSongLiked(songId, userId, liked)
    }

    private suspend fun requestJson(
        method: HttpMethod,
        path: String,
        inputParameters: Map<String, String>,
    ): JsonElement {
        val endpoint = config.endpointUrl(path)
        val requestParameters = configuredParameters(inputParameters)
        val response = httpClient.request(endpoint) {
            this.method = method
            accept(ContentType.Application.Json)
            sessionStore.cookie?.takeIf(String::isNotBlank)?.let {
                header(HttpHeaders.Cookie, it)
            }

            if (method == HttpMethod.Get) {
                url {
                    requestParameters.forEach { (key, value) -> this.parameters.append(key, value) }
                }
            } else {
                url {
                    this.parameters.append("timestamp", nowMillis().toString())
                }
                contentType(ContentType.Application.Json)
                setBody(
                    gatewayJson.encodeToString(
                        JsonObject.serializer(),
                        requestParameters.toJsonObject(),
                    ),
                )
            }
        }

        val responseBody = response.bodyAsText()
        if (!response.status.isSuccess()) {
            throw GatewayHttpException(
                statusCode = response.status.value,
                endpoint = path,
                responseBody = redactCookie(responseBody),
            )
        }

        return try {
            gatewayJson.parseToJsonElement(responseBody)
        } catch (exception: Throwable) {
            throw GatewayProtocolException(path, exception)
        }
    }

    private fun configuredParameters(parameters: Map<String, String>): Map<String, String> =
        parameters.toMutableMap().apply {
            // Non-browser clients must pass the login response cookie explicitly. Keep the Cookie
            // header as well for compatible deployments, while this parameter follows the
            // Gateway's documented contract for authenticated routes.
            sessionStore.cookie?.takeIf(String::isNotBlank)?.let { putIfAbsent("cookie", it) }
            config.realIp?.takeIf(String::isNotBlank)?.let { putIfAbsent("realIP", it) }
            if (config.randomChineseIp) putIfAbsent("randomCNIP", "true")
            config.userAgent?.takeIf(String::isNotBlank)?.let { putIfAbsent("ua", it) }
        }

    private fun rememberCookie(response: LoginResponse): LoginResponse = response.also {
        it.cookie?.takeIf(String::isNotBlank)?.let { cookie -> sessionStore.cookie = cookie }
    }

    private fun rememberCookie(response: QrCheckResponse): QrCheckResponse = response.also {
        it.cookie?.takeIf(String::isNotBlank)?.let { cookie -> sessionStore.cookie = cookie }
    }
}

private fun parametersOf(vararg values: Pair<String, Any?>): Map<String, String> =
    buildMap {
        values.forEach { (key, value) ->
            if (value != null) put(key, value.toString())
        }
    }

private fun Map<String, String>.toJsonObject(): JsonObject = buildJsonObject {
    this@toJsonObject.forEach { (key, value) -> put(key, value) }
}

private fun redactCookie(responseBody: String): String =
    COOKIE_FIELD_REGEX.replace(responseBody) { match ->
        match.groupValues[1] + "<redacted>" + match.groupValues[2]
    }

private val COOKIE_FIELD_REGEX = Regex("(\\\"cookie\\\"\\s*:\\s*\\\")[^\\\"]*(\\\")")

@PublishedApi
internal val gatewayJson = Json {
    ignoreUnknownKeys = true
    isLenient = true
    coerceInputValues = true
}

private fun createDefaultHttpClient(config: GatewayConfig): HttpClient = HttpClient {
    expectSuccess = false
    install(HttpTimeout) {
        requestTimeoutMillis = config.requestTimeoutMillis
        connectTimeoutMillis = config.requestTimeoutMillis
        socketTimeoutMillis = config.requestTimeoutMillis
    }
    install(ContentNegotiation) {
        json(gatewayJson)
    }
}
