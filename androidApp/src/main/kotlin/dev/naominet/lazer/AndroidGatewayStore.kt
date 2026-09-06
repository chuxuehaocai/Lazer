package dev.naominet.lazer

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import dev.naominet.lazer.gateway.GatewaySessionStore
import org.json.JSONArray
import org.json.JSONObject
import java.nio.ByteBuffer
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Netease cover URLs are returned by different Gateway endpoints in several forms. Android 9+
 * blocks clear-text image requests, so make both fresh responses and older cached values usable
 * before Coil sees them.
 */
internal fun normalizedArtworkUrl(raw: String?): String? {
    val value = raw?.trim()?.takeIf(String::isNotBlank) ?: return null
    return when {
        value.startsWith("//") -> "https:$value"
        value.startsWith("http://", ignoreCase = true) -> "https://${value.substringAfter("://")}"
        value.startsWith("https://", ignoreCase = true) -> value
        else -> null
    }
}

/**
 * A small Android-only representation of the data the player needs to render and queue a song.
 * Keeping it independent from the transport model avoids passing cookies or raw API responses into
 * the UI and lets the playback service restore its queue without an Activity.
 */
data class AndroidTrack(
    val id: Long,
    val title: String,
    val artist: String,
    val album: String,
    val durationMillis: Long,
    val coverUrl: String? = null,
) {
    val durationLabel: String get() = formatPlaybackTime(durationMillis)
}

data class AndroidPlaylist(
    val id: Long,
    val title: String,
    val subtitle: String,
    val coverUrl: String? = null,
    val trackCount: Int = 0,
    val isLikedCollection: Boolean = false,
)

/**
 * The app restores metadata and complete track lists before asking Gateway for a refresh. Coil
 * owns the matching image disk cache, so the same cover URL is also available offline first.
 */
class AndroidPlaylistCache(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences(
        "lazer.android.playlist.cache",
        Context.MODE_PRIVATE,
    )

    fun loadFeaturedPlaylists(): List<AndroidPlaylist> = decodePlaylists(preferences.getString(KEY_FEATURED, null))

    fun saveFeaturedPlaylists(playlists: List<AndroidPlaylist>) {
        preferences.edit().putString(KEY_FEATURED, encodePlaylists(playlists)).apply()
    }

    fun loadUserPlaylists(userId: Long): List<AndroidPlaylist> =
        decodePlaylists(preferences.getString(userPlaylistsKey(userId), null))

    fun saveUserPlaylists(userId: Long, playlists: List<AndroidPlaylist>) {
        preferences.edit().putString(userPlaylistsKey(userId), encodePlaylists(playlists)).apply()
    }

    fun loadTracks(playlistId: Long): List<AndroidTrack> =
        decodeTracks(preferences.getString(tracksKey(playlistId), null))

    fun saveTracks(playlistId: Long, tracks: List<AndroidTrack>) {
        preferences.edit().putString(tracksKey(playlistId), encodeTracks(tracks)).apply()
    }

    private fun encodePlaylists(playlists: List<AndroidPlaylist>): String = JSONArray().apply {
        playlists.forEach { playlist ->
            put(
                JSONObject().apply {
                    put("id", playlist.id)
                    put("title", playlist.title)
                    put("subtitle", playlist.subtitle)
                    put("coverUrl", playlist.coverUrl)
                    put("trackCount", playlist.trackCount)
                    put("liked", playlist.isLikedCollection)
                },
            )
        }
    }.toString()

    private fun decodePlaylists(serialized: String?): List<AndroidPlaylist> = runCatching {
        val array = JSONArray(serialized ?: return emptyList())
        List(array.length()) { index ->
            array.getJSONObject(index).let { item ->
                AndroidPlaylist(
                    id = item.optLong("id"),
                    title = item.optString("title"),
                    subtitle = item.optString("subtitle"),
                    coverUrl = normalizedArtworkUrl(item.optString("coverUrl")),
                    trackCount = item.optInt("trackCount"),
                    isLikedCollection = item.optBoolean("liked"),
                )
            }
        }.filter { it.id > 0 && it.title.isNotBlank() }
    }.getOrDefault(emptyList())

    private fun encodeTracks(tracks: List<AndroidTrack>): String = JSONArray().apply {
        tracks.forEach { track ->
            put(
                JSONObject().apply {
                    put("id", track.id)
                    put("title", track.title)
                    put("artist", track.artist)
                    put("album", track.album)
                    put("durationMillis", track.durationMillis)
                    put("coverUrl", track.coverUrl)
                },
            )
        }
    }.toString()

    private fun decodeTracks(serialized: String?): List<AndroidTrack> = runCatching {
        val array = JSONArray(serialized ?: return emptyList())
        List(array.length()) { index ->
            array.getJSONObject(index).let { item ->
                AndroidTrack(
                    id = item.optLong("id"),
                    title = item.optString("title"),
                    artist = item.optString("artist"),
                    album = item.optString("album"),
                    durationMillis = item.optLong("durationMillis"),
                    coverUrl = normalizedArtworkUrl(item.optString("coverUrl")),
                )
            }
        }.filter { it.id > 0 && it.title.isNotBlank() }
    }.getOrDefault(emptyList())

    private fun userPlaylistsKey(userId: Long) = "user.playlists.$userId"
    private fun tracksKey(playlistId: Long) = "playlist.tracks.$playlistId"

    private companion object {
        const val KEY_FEATURED = "featured.playlists"
    }
}

/**
 * Persists the Gateway cookie with an app-scoped Android Keystore AES key. If the keystore becomes
 * unavailable (for example after a device restore), the cookie is treated as expired rather than
 * falling back to plaintext storage.
 */
class AndroidGatewaySessionStore(context: Context) : GatewaySessionStore {
    private val preferences: SharedPreferences = context.applicationContext.getSharedPreferences(
        "lazer.android.session",
        Context.MODE_PRIVATE,
    )
    private var inMemoryCookie: String? = null

    override var cookie: String?
        get() = inMemoryCookie ?: preferences.getString(KEY_COOKIE, null)?.let(::decrypt)
        set(value) {
            inMemoryCookie = value
            if (value.isNullOrBlank()) {
                preferences.edit().remove(KEY_COOKIE).apply()
            } else {
                encrypt(value)?.let { encrypted ->
                    preferences.edit().putString(KEY_COOKIE, encrypted).apply()
                } ?: preferences.edit().remove(KEY_COOKIE).apply()
            }
        }

    private fun encrypt(value: String): String? = runCatching {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val cipherText = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        val payload = ByteBuffer.allocate(1 + cipher.iv.size + cipherText.size)
            .put(cipher.iv.size.toByte())
            .put(cipher.iv)
            .put(cipherText)
            .array()
        Base64.encodeToString(payload, Base64.NO_WRAP)
    }.getOrNull()

    private fun decrypt(value: String): String? = runCatching {
        val payload = Base64.decode(value, Base64.NO_WRAP)
        val buffer = ByteBuffer.wrap(payload)
        val ivSize = buffer.get().toInt() and 0xFF
        require(ivSize in 12..16 && payload.size > ivSize + 1)
        val iv = ByteArray(ivSize)
        buffer.get(iv)
        val cipherText = ByteArray(buffer.remaining())
        buffer.get(cipherText)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, iv))
        cipher.doFinal(cipherText).toString(Charsets.UTF_8)
    }.getOrNull()?.also { inMemoryCookie = it } ?: run {
        preferences.edit().remove(KEY_COOKIE).apply()
        null
    }

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEY_STORE).apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEY_STORE).apply {
            init(
                KeyGenParameterSpec.Builder(
                    KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build(),
            )
        }.generateKey()
    }

    private companion object {
        const val KEY_COOKIE = "gateway.cookie"
        const val KEY_ALIAS = "lazer.gateway.cookie.v1"
        const val ANDROID_KEY_STORE = "AndroidKeyStore"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
    }
}

fun formatPlaybackTime(millis: Long): String {
    val seconds = (millis.coerceAtLeast(0L) / 1_000L).toInt()
    return "%d:%02d".format(seconds / 60, seconds % 60)
}
