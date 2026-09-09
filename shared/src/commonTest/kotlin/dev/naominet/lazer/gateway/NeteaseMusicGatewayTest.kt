package dev.naominet.lazer.gateway

import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class NeteaseMusicGatewayTest {

    @Test
    fun `random Chinese IP is enabled by default for every gateway request`() = runTest {
        val client = HttpClient(MockEngine { request ->
            assertEquals("true", request.url.parameters["randomCNIP"])
            respond(content = "{\"code\":200}", headers = jsonHeaders())
        })
        val gateway = NeteaseMusicGateway(
            config = GatewayConfig(baseUrl = "https://gateway.example"),
            httpClient = client,
            closeHttpClient = false,
        )

        gateway.getRaw("/search", mapOf("keywords" to "quiet", "randomCNIP" to "false"))
    }

    @Test
    fun `daily recommendations decode their picUrl cover field`() = runTest {
        val client = HttpClient(MockEngine { request ->
            assertEquals("/api/recommend/resource", request.url.encodedPath)
            respond(
                content = """
                    {
                      "code": 200,
                      "recommend": [{
                        "id": 42,
                        "name": "今日推荐",
                        "picUrl": "https://p1.music.126.net/recommend.jpg",
                        "trackCount": 20
                      }]
                    }
                """.trimIndent(),
                headers = jsonHeaders(),
            )
        })
        val gateway = gateway(client)

        val playlist = gateway.dailyRecommendedPlaylists().recommend.single()

        assertEquals("https://p1.music.126.net/recommend.jpg", playlist.picUrl)
        assertNull(playlist.coverImgUrl)
    }

    @Test
    fun `forced playlist refresh adds the documented cache busting timestamp`() = runTest {
        val client = HttpClient(MockEngine { request ->
            assertEquals("/api/user/playlist", request.url.encodedPath)
            assertEquals("123456789", request.url.parameters["timestamp"])
            assertEquals("9", request.url.parameters["uid"])
            respond(content = "{\"code\":200,\"playlist\":[],\"more\":false}", headers = jsonHeaders())
        })

        gateway(client).userPlaylists(uid = 9, forceRefresh = true)
    }

    @Test
    fun `blank coverImgUrl does not hide picUrl when resolving covers`() = runTest {
        val client = HttpClient(MockEngine {
            respond(
                content = """
                    {
                      "code": 200,
                      "recommend": [{
                        "id": 7,
                        "name": "空白封面字段",
                        "coverImgUrl": "",
                        "picUrl": "https://p1.music.126.net/real.jpg",
                        "trackCount": 12
                      }]
                    }
                """.trimIndent(),
                headers = jsonHeaders(),
            )
        })
        val playlist = gateway(client).dailyRecommendedPlaylists().recommend.single()
        val cover = sequenceOf(playlist.coverImgUrl, playlist.picUrl)
            .mapNotNull { it?.trim()?.takeIf(String::isNotBlank) }
            .firstOrNull()

        assertEquals("https://p1.music.126.net/real.jpg", cover)
    }

    @Test
    fun `search encodes query, applies gateway options, and decodes an evolving response`() = runTest {
        val session = InMemoryGatewaySessionStore("MUSIC_U=existing-session")
        val client = HttpClient(MockEngine { request ->
            assertEquals(HttpMethod.Get, request.method)
            assertEquals("/api/search", request.url.encodedPath)
            assertEquals("A & B", request.url.parameters["keywords"])
            assertEquals("1", request.url.parameters["type"])
            assertEquals("5", request.url.parameters["limit"])
            assertEquals("2", request.url.parameters["offset"])
            assertEquals("116.25.146.177", request.url.parameters["realIP"])
            assertEquals("true", request.url.parameters["randomCNIP"])
            assertEquals("Lazer test client", request.url.parameters["ua"])
            assertEquals("MUSIC_U=existing-session", request.headers[HttpHeaders.Cookie])
            assertEquals("MUSIC_U=existing-session", request.url.parameters["cookie"])

            respond(
                content = """
                    {
                      "code": 200,
                      "result": {
                        "songCount": 1,
                        "songs": [{
                          "id": 33894312,
                          "name": "晴天",
                          "ar": [{"id": 6452, "name": "周杰伦"}],
                          "al": {"id": 1868553, "name": "叶惠美"},
                          "futureGatewayField": "ignored"
                        }]
                      }
                    }
                """.trimIndent(),
                headers = jsonHeaders(),
            )
        })
        val gateway = gateway(client, session)

        val response = gateway.search("A & B", limit = 5, offset = 2)

        assertEquals(200, response.code)
        assertEquals(1, response.result?.songCount)
        assertEquals("晴天", response.result?.songs?.single()?.name)
        assertEquals("周杰伦", response.result?.songs?.single()?.artists?.single()?.name)
        assertEquals("叶惠美", response.result?.songs?.single()?.album?.name)
    }

    @Test
    fun `password login uses POST body, timestamp, and stores returned cookie`() = runTest {
        val session = InMemoryGatewaySessionStore()
        val client = HttpClient(MockEngine { request ->
            assertEquals(HttpMethod.Post, request.method)
            assertEquals("/api/login/cellphone", request.url.encodedPath)
            assertEquals("123456789", request.url.parameters["timestamp"])
            assertFalse(request.url.toString().contains("secret-password"))

            val body = request.body as TextContent
            val payload = Json.parseToJsonElement(body.text).jsonObject
            assertEquals("13800138000", payload["phone"]?.toString()?.trim('"'))
            assertEquals("secret-password", payload["password"]?.toString()?.trim('"'))
            assertEquals("86", payload["countrycode"]?.toString()?.trim('"'))
            assertEquals("true", payload["randomCNIP"]?.toString()?.trim('"'))

            respond(
                content = """{"code":200,"cookie":"MUSIC_U=new-session","profile":{"userId":7,"nickname":"Lazer"}}""",
                headers = jsonHeaders(),
            )
        })
        val gateway = gateway(client, session)

        val response = gateway.loginWithPhonePassword(
            phone = "13800138000",
            password = "secret-password",
            countryCode = "86",
        )

        assertEquals(200, response.code)
        assertEquals("Lazer", response.profile?.nickname)
        assertEquals("MUSIC_U=new-session", session.cookie)
    }

    @Test
    fun `authorized QR result stores its session cookie`() = runTest {
        val session = InMemoryGatewaySessionStore()
        val client = HttpClient(MockEngine { request ->
            assertEquals(HttpMethod.Post, request.method)
            assertEquals("/api/login/qr/check", request.url.encodedPath)
            assertEquals("123456789", request.url.parameters["timestamp"])
            val body = request.body as TextContent
            val requestBody = Json.parseToJsonElement(body.text).jsonObject
            assertEquals("qr-key", requestBody["key"]?.toString()?.trim('"'))
            assertEquals("web", requestBody["platform"]?.toString()?.trim('"'))

            respond(
                content = """{"code":803,"message":"授权登录成功","cookie":"MUSIC_U=qr-session"}""",
                headers = jsonHeaders(),
            )
        })
        val gateway = gateway(client, session)

        val response = gateway.checkQrCode("qr-key", platform = "web")

        assertTrue(response.isAuthorized)
        assertEquals("MUSIC_U=qr-session", gateway.sessionCookie)
    }

    @Test
    fun `login status posts the session parameter with a cache busting timestamp`() = runTest {
        val session = InMemoryGatewaySessionStore("MUSIC_U=qr-session")
        val client = HttpClient(MockEngine { request ->
            assertEquals(HttpMethod.Post, request.method)
            assertEquals("/api/login/status", request.url.encodedPath)
            assertEquals("123456789", request.url.parameters["timestamp"])
            assertEquals("MUSIC_U=qr-session", request.headers[HttpHeaders.Cookie])

            val body = request.body as TextContent
            val payload = Json.parseToJsonElement(body.text).jsonObject
            assertEquals("MUSIC_U=qr-session", payload["cookie"]?.toString()?.trim('"'))

            respond(
                content = """{"data":{"code":200,"account":{"id":7},"profile":{"userId":7,"nickname":"Lazer"}}}""",
                headers = jsonHeaders(),
            )
        })
        val gateway = gateway(client, session)

        val response = gateway.loginStatus()

        assertEquals(7, response.data?.account?.id)
        assertEquals("Lazer", response.data?.profile?.nickname)
    }

    @Test
    fun `user detail provides a profile fallback for account-only login status`() = runTest {
        val session = InMemoryGatewaySessionStore("MUSIC_U=active-session")
        val client = HttpClient(MockEngine { request ->
            assertEquals(HttpMethod.Post, request.method)
            assertEquals("/api/user/detail", request.url.encodedPath)
            val body = request.body as TextContent
            val payload = Json.parseToJsonElement(body.text).jsonObject
            assertEquals("7", payload["uid"]?.toString()?.trim('"'))
            assertEquals("MUSIC_U=active-session", payload["cookie"]?.toString()?.trim('"'))
            respond(
                content = """{"code":200,"profile":{"userId":7,"nickname":"Lazer"}}""",
                headers = jsonHeaders(),
            )
        })
        val gateway = gateway(client, session)

        val response = gateway.userDetail(7)

        assertEquals("Lazer", response.profile?.nickname)
    }

    @Test
    fun `song URLs send all playback choices and decode nullable URLs`() = runTest {
        val client = HttpClient(MockEngine { request ->
            assertEquals(HttpMethod.Get, request.method)
            assertEquals("/api/song/url/v1", request.url.encodedPath)
            assertEquals("1,2", request.url.parameters["id"])
            assertEquals("hires", request.url.parameters["level"])
            assertEquals("true", request.url.parameters["unblock"])
            assertEquals("ste", request.url.parameters["immerseType"])

            respond(
                content = """
                    {
                      "code": 200,
                      "data": [
                        {"id":1,"url":"https://cdn.example/1.flac","br":999000,"size":42,"type":"flac"},
                        {"id":2,"url":null,"code":404}
                      ]
                    }
                """.trimIndent(),
                headers = jsonHeaders(),
            )
        })
        val gateway = gateway(client)

        val response = gateway.songUrls(
            ids = listOf(1, 2),
            quality = AudioQuality.HI_RES,
            unblock = true,
            immerseType = "ste",
        )

        assertEquals("https://cdn.example/1.flac", response.data[0].url)
        assertEquals(null, response.data[1].url)
    }

    @Test
    fun `artist detail decodes the nested artist returned by the gateway`() = runTest {
        val client = HttpClient(MockEngine { request ->
            assertEquals(HttpMethod.Get, request.method)
            assertEquals("/api/artist/detail", request.url.encodedPath)
            assertEquals("6452", request.url.parameters["id"])
            respond(
                content = """
                    {
                      "code": 200,
                      "message": "ok",
                      "data": {
                        "videoCount": 8,
                        "blacklist": false,
                        "artist": {
                          "id": 6452,
                          "name": "Jay Chou",
                          "alias": ["周董"],
                          "cover": "https://cdn.example/cover.jpg",
                          "albumSize": 44,
                          "musicSize": 568,
                          "mvSize": 9
                        }
                      }
                    }
                """.trimIndent(),
                headers = jsonHeaders(),
            )
        })
        val gateway = gateway(client)

        val response = gateway.artistDetail(6452)
        val detail = assertNotNull(response.data)

        assertEquals(8, detail.videoCount)
        assertFalse(detail.blacklist ?: true)
        assertEquals("Jay Chou", detail.artist?.name)
        assertEquals("https://cdn.example/cover.jpg", detail.artist?.cover)
        assertEquals(568, detail.artist?.musicSize)
    }

    @Test
    fun `HTTP errors expose status without leaking cookies`() = runTest {
        val client = HttpClient(MockEngine {
            respond(
                content = """{"code":502,"cookie":"MUSIC_U=should-not-leak","msg":"bad gateway"}""",
                status = HttpStatusCode.BadGateway,
                headers = jsonHeaders(),
            )
        })
        val gateway = gateway(client)

        val exception = assertFailsWith<GatewayHttpException> {
            gateway.lyrics(33894312)
        }

        assertEquals(502, exception.statusCode)
        assertEquals("/lyric", exception.endpoint)
        assertFalse(exception.responseBody.contains("MUSIC_U=should-not-leak"))
        assertTrue(exception.responseBody.contains("<redacted>"))
    }

    @Test
    fun `logout sends the session and clears it after a successful response`() = runTest {
        val session = InMemoryGatewaySessionStore("MUSIC_U=active-session")
        val client = HttpClient(MockEngine { request ->
            assertEquals(HttpMethod.Post, request.method)
            assertEquals("MUSIC_U=active-session", request.headers[HttpHeaders.Cookie])
            assertEquals("123456789", request.url.parameters["timestamp"])
            respond(content = "{\"code\":200}", headers = jsonHeaders())
        })
        val gateway = gateway(client, session)

        gateway.logout()

        assertNull(gateway.sessionCookie)
    }

    @Test
    fun `non JSON gateway responses identify the requested endpoint`() = runTest {
        val client = HttpClient(MockEngine {
            respond(content = "not JSON", headers = jsonHeaders())
        })
        val gateway = gateway(client)

        val exception = assertFailsWith<GatewayProtocolException> {
            gateway.lyrics(33894312)
        }

        assertEquals("/lyric", exception.endpoint)
    }

    @Test
    fun `raw routes reject absolute URLs`() = runTest {
        val gateway = gateway(HttpClient(MockEngine { error("request should not be reached") }))

        val exception = assertFailsWith<IllegalArgumentException> {
            gateway.getRaw("https://unexpected.example/search")
        }

        assertNotNull(exception.message)
    }

    @Test
    fun `base URL rejects embedded query parameters`() {
        assertFailsWith<IllegalArgumentException> {
            GatewayConfig(baseUrl = "https://gateway.example/api?override=true")
        }
    }

    private fun gateway(
        client: HttpClient,
        sessionStore: GatewaySessionStore = InMemoryGatewaySessionStore(),
    ): NeteaseMusicGateway = NeteaseMusicGateway(
        config = GatewayConfig(
            baseUrl = "https://gateway.example/api/",
            realIp = "116.25.146.177",
            randomChineseIp = true,
            userAgent = "Lazer test client",
        ),
        sessionStore = sessionStore,
        httpClient = client,
        closeHttpClient = false,
        nowMillis = { 123456789L },
    )

    private fun jsonHeaders() = headersOf(
        HttpHeaders.ContentType,
        ContentType.Application.Json.toString(),
    )
}
