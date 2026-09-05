package dev.naominet.lazer

import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.util.Base64
import java.util.Properties

internal data class CachedPlaylistTracks(
    val tracks: List<TrackItem>,
    val complete: Boolean,
)

/** Persistent metadata/track cache. Cover images are cached separately by Coil's disk cache. */
internal class DesktopPlaylistCache(
    private val cacheDirectory: Path = Path.of(
        System.getProperty("user.home"),
        ".lazer",
        "cache",
        "playlists",
    ),
) {
    fun loadPlaylists(key: String): List<PlaylistItem> = load(file("collection", key)) { properties ->
        val count = properties.getProperty("count")?.toIntOrNull() ?: return@load emptyList()
        (0 until count).mapNotNull { index -> properties.readPlaylist("item.$index") }
    } ?: emptyList()

    fun savePlaylists(key: String, playlists: List<PlaylistItem>) {
        val properties = Properties().apply {
            setProperty("version", CACHE_VERSION)
            setProperty("count", playlists.size.toString())
            setProperty("savedAt", System.currentTimeMillis().toString())
            playlists.forEachIndexed { index, playlist -> writePlaylist("item.$index", playlist) }
        }
        save(file("collection", key), properties)
    }

    fun loadTracks(playlistId: Long): CachedPlaylistTracks? = load(file("tracks", playlistId.toString())) { properties ->
        val count = properties.getProperty("count")?.toIntOrNull() ?: return@load null
        val tracks = (0 until count).mapNotNull { index -> properties.readTrack("item.$index") }
        CachedPlaylistTracks(tracks, properties.getProperty("complete").toBoolean())
    }

    fun saveTracks(playlistId: Long, tracks: List<TrackItem>, complete: Boolean) {
        val properties = Properties().apply {
            setProperty("version", CACHE_VERSION)
            setProperty("count", tracks.size.toString())
            setProperty("complete", complete.toString())
            setProperty("savedAt", System.currentTimeMillis().toString())
            tracks.forEachIndexed { index, track -> writeTrack("item.$index", track) }
        }
        save(file("tracks", playlistId.toString()), properties)
    }

    private fun file(kind: String, key: String): Path {
        val safeKey = key.replace(Regex("[^A-Za-z0-9_-]"), "_")
        return cacheDirectory.resolve("$kind-$safeKey.properties")
    }

    private fun <T> load(path: Path, block: (Properties) -> T): T? = runCatching {
        if (!Files.isRegularFile(path)) return@runCatching null
        val properties = Properties().apply { Files.newInputStream(path).use(::load) }
        if (properties.getProperty("version") != CACHE_VERSION) return@runCatching null
        block(properties)
    }.getOrNull()

    private fun save(path: Path, properties: Properties) {
        runCatching {
            Files.createDirectories(path.parent)
            val temporary = path.resolveSibling("${path.fileName}.tmp")
            Files.newOutputStream(temporary).use { properties.store(it, "Lazer playlist cache") }
            runCatching {
                Files.move(temporary, path, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
            }.getOrElse {
                Files.move(temporary, path, StandardCopyOption.REPLACE_EXISTING)
            }
        }
    }

    private fun Properties.writePlaylist(prefix: String, item: PlaylistItem) {
        setProperty("$prefix.id", item.id.toString())
        setProperty("$prefix.title", encode(item.title))
        setProperty("$prefix.subtitle", encode(item.subtitle))
        setProperty("$prefix.cover", encode(item.coverUrl.orEmpty()))
        setProperty("$prefix.trackCount", item.trackCount.toString())
        setProperty("$prefix.creator", encode(item.creatorName.orEmpty()))
        setProperty("$prefix.liked", item.isLikedCollection.toString())
    }

    private fun Properties.readPlaylist(prefix: String): PlaylistItem? {
        val id = getProperty("$prefix.id")?.toLongOrNull() ?: return null
        val title = decode(getProperty("$prefix.title")) ?: return null
        val likedFlag = getProperty("$prefix.liked")?.toBooleanStrictOrNull()
            ?: title.endsWith("喜欢的音乐")
        return PlaylistItem(
            id = id,
            title = title,
            subtitle = decode(getProperty("$prefix.subtitle")) ?: "",
            coverUrl = decode(getProperty("$prefix.cover"))?.takeIf(String::isNotBlank),
            trackCount = getProperty("$prefix.trackCount")?.toIntOrNull() ?: 0,
            creatorName = decode(getProperty("$prefix.creator"))?.takeIf(String::isNotBlank),
            isLikedCollection = likedFlag,
        )
    }

    private fun Properties.writeTrack(prefix: String, item: TrackItem) {
        setProperty("$prefix.id", item.id.toString())
        setProperty("$prefix.title", encode(item.title))
        setProperty("$prefix.artist", encode(item.artist))
        setProperty("$prefix.album", encode(item.album))
        setProperty("$prefix.duration", item.durationMillis.toString())
        setProperty("$prefix.cover", encode(item.coverUrl.orEmpty()))
    }

    private fun Properties.readTrack(prefix: String): TrackItem? {
        val id = getProperty("$prefix.id")?.toLongOrNull() ?: return null
        return TrackItem(
            id = id,
            title = decode(getProperty("$prefix.title")) ?: return null,
            artist = decode(getProperty("$prefix.artist")) ?: "",
            album = decode(getProperty("$prefix.album")) ?: "",
            durationMillis = getProperty("$prefix.duration")?.toLongOrNull() ?: 0L,
            coverUrl = decode(getProperty("$prefix.cover"))?.takeIf(String::isNotBlank),
        )
    }

    private companion object {
        const val CACHE_VERSION = "1"
        val encoder: Base64.Encoder = Base64.getUrlEncoder().withoutPadding()
        val decoder: Base64.Decoder = Base64.getUrlDecoder()

        fun encode(value: String): String = encoder.encodeToString(value.toByteArray(Charsets.UTF_8))

        fun decode(value: String?): String? = value?.let {
            runCatching { String(decoder.decode(it), Charsets.UTF_8) }.getOrNull()
        }
    }
}
