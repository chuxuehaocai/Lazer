package dev.naominet.lazer

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import dev.naominet.lazer.gateway.GatewaySessionStore
import dev.naominet.lazer.gateway.model.UserProfile
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
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
    private val lock = Any()
    private val writerScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var nextWriteRevision = 0L
    private val writeRevisions = mutableMapOf<String, Long>()

    // Parsed cache values stay in process after their first read. This keeps opening a playlist,
    // restoring the library, and replacing a playback queue from doing JSON work on the UI thread.
    private var featuredPlaylistsMemory: List<AndroidPlaylist>? = null
    private var currentUserMemory: UserProfile? = null
    private var hasReadCurrentUser = false
    private val userPlaylistsMemory = mutableMapOf<Long, List<AndroidPlaylist>>()
    private val likedSongIdsMemory = mutableMapOf<Long, Set<Long>>()
    private val tracksMemory = mutableMapOf<Long, List<AndroidTrack>>()

    fun loadFeaturedPlaylists(): List<AndroidPlaylist> = synchronized(lock) {
        featuredPlaylistsMemory
    } ?: decodePlaylists(preferences.getString(KEY_FEATURED, null)).also { playlists ->
        synchronized(lock) { featuredPlaylistsMemory = playlists }
    }

    fun saveFeaturedPlaylists(playlists: List<AndroidPlaylist>) {
        val snapshot = playlists.toList()
        synchronized(lock) { featuredPlaylistsMemory = snapshot }
        writeAsync(KEY_FEATURED) { encodePlaylists(snapshot) }
    }

    fun loadCurrentUser(): UserProfile? {
        synchronized(lock) {
            if (hasReadCurrentUser) return currentUserMemory
        }
        val profile = decodeUserProfile(preferences.getString(KEY_CURRENT_USER, null))
            ?: preferences.getLong(KEY_LAST_USER_ID, 0L)
                .takeIf { it > 0 }
                ?.let { UserProfile(userId = it) }
            ?: cachedUserIdHint(preferences.all.keys)?.let { UserProfile(userId = it) }
        synchronized(lock) {
            currentUserMemory = profile
            hasReadCurrentUser = true
        }
        return profile
    }

    fun saveCurrentUser(profile: UserProfile) {
        synchronized(lock) {
            currentUserMemory = profile
            hasReadCurrentUser = true
        }
        writeAsync(KEY_CURRENT_USER) { encodeUserProfile(profile) }
    }

    fun clearCurrentUser() {
        synchronized(lock) {
            currentUserMemory = null
            hasReadCurrentUser = true
        }
        removeAsync(KEY_CURRENT_USER)
    }

    fun loadUserPlaylists(userId: Long): List<AndroidPlaylist> = synchronized(lock) {
        userPlaylistsMemory[userId]
    } ?: decodePlaylists(preferences.getString(userPlaylistsKey(userId), null)).also { playlists ->
        synchronized(lock) { userPlaylistsMemory[userId] = playlists }
    }

    fun saveUserPlaylists(userId: Long, playlists: List<AndroidPlaylist>) {
        val snapshot = playlists.toList()
        synchronized(lock) { userPlaylistsMemory[userId] = snapshot }
        writeAsync(userPlaylistsKey(userId)) { encodePlaylists(snapshot) }
        writeAsync(KEY_LAST_USER_ID) { userId.toString() }
    }

    fun loadLikedSongIds(userId: Long): Set<Long> = synchronized(lock) {
        likedSongIdsMemory[userId]
    } ?: decodeSongIds(preferences.getString(likedSongIdsKey(userId), null)).also { songIds ->
        synchronized(lock) { likedSongIdsMemory[userId] = songIds }
    }

    fun saveLikedSongIds(userId: Long, songIds: Set<Long>) {
        val snapshot = songIds.toSet()
        synchronized(lock) { likedSongIdsMemory[userId] = snapshot }
        writeAsync(likedSongIdsKey(userId)) { encodeSongIds(snapshot) }
    }

    fun loadTracks(playlistId: Long): List<AndroidTrack> = synchronized(lock) {
        tracksMemory[playlistId]
    } ?: decodeTracks(preferences.getString(tracksKey(playlistId), null)).also { tracks ->
        synchronized(lock) { tracksMemory[playlistId] = tracks }
    }

    /** Returns only already-decoded data; safe to call from a click handler without disk or JSON work. */
    fun peekTracks(playlistId: Long): List<AndroidTrack>? = synchronized(lock) {
        tracksMemory[playlistId]
    }

    fun saveTracks(playlistId: Long, tracks: List<AndroidTrack>) {
        val snapshot = tracks.toList()
        synchronized(lock) { tracksMemory[playlistId] = snapshot }
        writeAsync(tracksKey(playlistId)) { encodeTracks(snapshot) }
    }

    /** Clears playlist and track data while keeping the cached signed-in identity intact. */
    fun clearPlaylistData(): Int {
        fun isPlaylistDataKey(key: String): Boolean =
            key == KEY_FEATURED ||
                key.startsWith("user.playlists.") ||
                key.startsWith("user.liked_song_ids.") ||
                key.startsWith("playlist.tracks.")

        val storedKeys = preferences.all.keys.filter(::isPlaylistDataKey)
        val keysToRemove = synchronized(lock) {
            // A save may still be encoding on the writer dispatcher and therefore not appear in
            // SharedPreferences yet. Invalidate those pending writes too, otherwise a cleared
            // playlist could reappear a moment later.
            val keys = (storedKeys + writeRevisions.keys.filter(::isPlaylistDataKey)).distinct()
            keys.forEach(::invalidateWrite)
            featuredPlaylistsMemory = null
            userPlaylistsMemory.clear()
            likedSongIdsMemory.clear()
            tracksMemory.clear()
            keys
        }
        preferences.edit().apply { keysToRemove.forEach(::remove) }.commit()
        return storedKeys.size
    }

    fun close() {
        writerScope.cancel()
    }

    private fun writeAsync(key: String, encode: () -> String) {
        val revision = synchronized(lock) {
            nextWriteRevision += 1
            nextWriteRevision.also { writeRevisions[key] = it }
        }
        writerScope.launch {
            val value = encode()
            synchronized(lock) {
                if (writeRevisions[key] != revision) return@launch
                if (key == KEY_LAST_USER_ID) {
                    preferences.edit().putLong(key, value.toLong()).apply()
                } else {
                    preferences.edit().putString(key, value).apply()
                }
            }
        }
    }

    private fun removeAsync(key: String) {
        val revision = synchronized(lock) {
            invalidateWrite(key)
            writeRevisions.getValue(key)
        }
        writerScope.launch {
            synchronized(lock) {
                if (writeRevisions[key] == revision) preferences.edit().remove(key).apply()
            }
        }
    }

    private fun invalidateWrite(key: String) {
        nextWriteRevision += 1
        writeRevisions[key] = nextWriteRevision
    }

    private fun encodeUserProfile(profile: UserProfile): String = JSONObject().apply {
        put("userId", profile.userId)
        put("nickname", profile.nickname)
        put("avatarUrl", profile.avatarUrl.orEmpty())
        put("signature", profile.signature.orEmpty())
    }.toString()

    private fun decodeUserProfile(serialized: String?): UserProfile? = runCatching {
        val item = JSONObject(serialized ?: return null)
        UserProfile(
            userId = item.optLong("userId"),
            nickname = item.optString("nickname"),
            avatarUrl = normalizedArtworkUrl(item.optString("avatarUrl")),
            signature = item.optString("signature").takeIf(String::isNotBlank),
        ).takeIf { it.userId > 0 }
    }.getOrNull()

    private fun encodeSongIds(songIds: Set<Long>): String = JSONArray().apply {
        songIds.forEach(::put)
    }.toString()

    private fun decodeSongIds(serialized: String?): Set<Long> = runCatching {
        val array = JSONArray(serialized ?: return emptySet())
        buildSet {
            repeat(array.length()) { index ->
                array.optLong(index).takeIf { it > 0 }?.let(::add)
            }
        }
    }.getOrDefault(emptySet())

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
    private fun likedSongIdsKey(userId: Long) = "user.liked_song_ids.$userId"
    private fun tracksKey(playlistId: Long) = "playlist.tracks.$playlistId"

    private companion object {
        const val KEY_FEATURED = "featured.playlists"
        const val KEY_CURRENT_USER = "session.current_user"
        const val KEY_LAST_USER_ID = "session.last_user_id"
    }
}

internal fun cachedUserIdHint(keys: Set<String>): Long? = keys
    .asSequence()
    .mapNotNull { key -> key.removePrefix("user.playlists.").takeIf { it != key }?.toLongOrNull() }
    .distinct()
    .singleOrNull()

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
