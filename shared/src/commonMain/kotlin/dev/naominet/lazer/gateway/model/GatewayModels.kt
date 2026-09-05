package dev.naominet.lazer.gateway.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement

@Serializable
data class Artist(
    val id: Long = 0,
    val name: String = "",
    val alias: List<String> = emptyList(),
    val picUrl: String? = null,
    val cover: String? = null,
    val avatar: String? = null,
    val briefDesc: String? = null,
    val albumSize: Int? = null,
    val musicSize: Int? = null,
    val mvSize: Int? = null,
    val followed: Boolean? = null,
)

@Serializable
data class Album(
    val id: Long = 0,
    val name: String = "",
    val alias: List<String> = emptyList(),
    val picUrl: String? = null,
    @SerialName("blurPicUrl") val blurPictureUrl: String? = null,
    val artist: Artist? = null,
    val artists: List<Artist> = emptyList(),
    val publishTime: Long? = null,
    val size: Int? = null,
    val type: String? = null,
    val subType: String? = null,
)

@Serializable
data class Song(
    val id: Long = 0,
    val name: String = "",
    @SerialName("ar") val artists: List<Artist> = emptyList(),
    @SerialName("al") val album: Album? = null,
    @SerialName("dt") val durationMillis: Long? = null,
    @SerialName("alia") val aliases: List<String> = emptyList(),
    @SerialName("tns") val translations: List<String> = emptyList(),
    val mv: Long? = null,
    val fee: Int? = null,
    val popularity: Int? = null,
)

@Serializable
data class SongPrivilege(
    val id: Long = 0,
    val fee: Int? = null,
    val payed: Int? = null,
    val st: Int? = null,
    val pl: Int? = null,
    val dl: Int? = null,
    val fl: Int? = null,
    val maxbr: Int? = null,
)

@Serializable
data class SongUrl(
    val id: Long = 0,
    val url: String? = null,
    val br: Int? = null,
    val size: Long? = null,
    val md5: String? = null,
    val code: Int? = null,
    val expi: Int? = null,
    val type: String? = null,
    val fee: Int? = null,
    val gain: Double? = null,
    val freeTrialInfo: JsonElement? = null,
)

@Serializable
data class UserProfile(
    val userId: Long = 0,
    val nickname: String = "",
    val avatarUrl: String? = null,
    val signature: String? = null,
    val gender: Int? = null,
    val province: Int? = null,
    val city: Int? = null,
    val vipType: Int? = null,
    val followed: Boolean? = null,
)

@Serializable
data class Account(
    val id: Long = 0,
    val userName: String? = null,
    val type: Int? = null,
    val status: Int? = null,
    val vipType: Int? = null,
)

@Serializable
data class Playlist(
    val id: Long = 0,
    val name: String = "",
    val description: String? = null,
    val coverImgUrl: String? = null,
    /** `/recommend/resource` uses `picUrl`, while playlist list/detail routes use `coverImgUrl`. */
    val picUrl: String? = null,
    val creator: UserProfile? = null,
    val trackCount: Int? = null,
    val playCount: Long? = null,
    val subscribedCount: Long? = null,
    /**
     * NetEase marks the personal "liked songs" collection as `specialType = 5`.
     * Other values identify radar / official lists and are safe to ignore.
     */
    val specialType: Int? = null,
    val tags: List<String> = emptyList(),
    val tracks: List<Song> = emptyList(),
    val trackIds: List<TrackId> = emptyList(),
)

@Serializable
data class TrackId(
    val id: Long = 0,
    val v: Int? = null,
)

@Serializable
data class LyricLine(
    val version: Int? = null,
    val lyric: String? = null,
)

@Serializable
data class Banner(
    val targetId: Long? = null,
    val targetType: Int? = null,
    val imageUrl: String? = null,
    val typeTitle: String? = null,
    val url: String? = null,
)

@Serializable
data class QrKeyData(
    val unikey: String = "",
)

@Serializable
data class QrCodeData(
    val qrurl: String? = null,
    val qrimg: String? = null,
)

@Serializable
data class LoginResponse(
    val code: Int = 0,
    val cookie: String? = null,
    val profile: UserProfile? = null,
    val account: Account? = null,
    val message: String? = null,
    val msg: String? = null,
) {
    val failureMessage: String?
        get() = message ?: msg
}

@Serializable
data class QrKeyResponse(
    val code: Int = 0,
    val data: QrKeyData? = null,
)

@Serializable
data class QrCodeResponse(
    val code: Int = 0,
    val data: QrCodeData? = null,
)

@Serializable
data class QrCheckResponse(
    val code: Int = 0,
    val cookie: String? = null,
    val message: String? = null,
    val msg: String? = null,
) {
    val isAuthorized: Boolean
        get() = code == AUTHORIZED_CODE

    public companion object {
        public const val AUTHORIZED_CODE: Int = 803
        public const val EXPIRED_CODE: Int = 800
        public const val WAITING_FOR_SCAN_CODE: Int = 801
        public const val WAITING_FOR_CONFIRMATION_CODE: Int = 802
    }
}

@Serializable
data class LoginStatusData(
    val account: Account? = null,
    val profile: UserProfile? = null,
)

@Serializable
data class LoginStatusResponse(
    val code: Int = 0,
    val data: LoginStatusData? = null,
)

@Serializable
data class UserDetailResponse(
    val code: Int = 0,
    val profile: UserProfile? = null,
    val level: Int? = null,
    val listenSongs: Int? = null,
)

@Serializable
data class SearchResult(
    val songs: List<Song> = emptyList(),
    val songCount: Int = 0,
    val albums: List<Album> = emptyList(),
    val albumCount: Int = 0,
    val artists: List<Artist> = emptyList(),
    val artistCount: Int = 0,
    val playlists: List<Playlist> = emptyList(),
    val playlistCount: Int = 0,
)

@Serializable
data class SearchResponse(
    val code: Int = 0,
    val result: SearchResult? = null,
)

@Serializable
data class SongDetailResponse(
    val code: Int = 0,
    val songs: List<Song> = emptyList(),
    val privileges: List<SongPrivilege> = emptyList(),
)

@Serializable
data class SongUrlResponse(
    val code: Int = 0,
    val data: List<SongUrl> = emptyList(),
)

@Serializable
data class MusicAvailabilityResponse(
    val success: Boolean = false,
    val message: String? = null,
)

@Serializable
data class LyricResponse(
    val code: Int = 0,
    val lrc: LyricLine? = null,
    val tlyric: LyricLine? = null,
    val romalrc: LyricLine? = null,
    val yrc: LyricLine? = null,
    val pureMusic: Boolean? = null,
)

@Serializable
data class PlaylistDetailResponse(
    val code: Int = 0,
    val playlist: Playlist? = null,
    val privileges: List<SongPrivilege> = emptyList(),
)

@Serializable
data class PlaylistTracksResponse(
    val code: Int = 0,
    val songs: List<Song> = emptyList(),
    val privileges: List<SongPrivilege> = emptyList(),
)

@Serializable
data class UserPlaylistsResponse(
    val code: Int = 0,
    val playlist: List<Playlist> = emptyList(),
    val more: Boolean = false,
)

@Serializable
data class TopPlaylistsResponse(
    val code: Int = 0,
    val playlists: List<Playlist> = emptyList(),
    val total: Int = 0,
    val more: Boolean = false,
)

@Serializable
data class AlbumDetailResponse(
    val code: Int = 0,
    val album: Album? = null,
    val songs: List<Song> = emptyList(),
)

@Serializable
data class ArtistDetailData(
    val videoCount: Int? = null,
    val artist: Artist? = null,
    val blacklist: Boolean? = null,
    val preferShow: Int? = null,
    val showPriMsg: Boolean? = null,
)

@Serializable
data class ArtistDetailResponse(
    val code: Int = 0,
    val message: String? = null,
    val data: ArtistDetailData? = null,
)

@Serializable
data class BannerResponse(
    val code: Int = 0,
    val banners: List<Banner> = emptyList(),
)

@Serializable
data class DailySongsData(
    val dailySongs: List<Song> = emptyList(),
)

@Serializable
data class DailySongsResponse(
    val code: Int = 0,
    val data: DailySongsData? = null,
)

@Serializable
data class DailyPlaylistsResponse(
    val code: Int = 0,
    val recommend: List<Playlist> = emptyList(),
)

@Serializable
data class PersonalFmResponse(
    val code: Int = 0,
    val data: List<Song> = emptyList(),
)

@Serializable
data class LikedSongIdsResponse(
    val code: Int = 0,
    val ids: List<Long> = emptyList(),
)
