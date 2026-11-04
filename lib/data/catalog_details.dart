import 'models.dart';

class AlbumDetails {
  const AlbumDetails({
    required this.album,
    required this.tracks,
    this.description = '',
    this.company = '',
    this.publishTime,
  });
  final Album album;
  final List<Track> tracks;
  final String description, company;
  final int? publishTime;
  Map<String, dynamic> toJson() => {
    'album': album.toJson(),
    'tracks': tracks.map((track) => track.toJson()).toList(),
    'description': description,
    'company': company,
    'publishTime': publishTime,
  };
  factory AlbumDetails.fromJson(Map<String, dynamic> json) => AlbumDetails(
    album: Album.fromJson(json['album'] as Map<String, dynamic>),
    tracks: [
      for (final track in json['tracks'] as List)
        Track.fromJson(track as Map<String, dynamic>),
    ],
    description: json['description'] as String? ?? '',
    company: json['company'] as String? ?? '',
    publishTime: (json['publishTime'] as num?)?.toInt(),
  );
}

class ArtistDetails {
  const ArtistDetails({
    required this.artist,
    required this.tracks,
    this.description = '',
    this.musicCount = 0,
    this.albumCount = 0,
  });
  final ArtistRef artist;
  final List<Track> tracks;
  final String description;
  final int musicCount, albumCount;
  Map<String, dynamic> toJson() => {
    'artist': artist.toJson(),
    'tracks': tracks.map((track) => track.toJson()).toList(),
    'description': description,
    'musicCount': musicCount,
    'albumCount': albumCount,
  };
  factory ArtistDetails.fromJson(Map<String, dynamic> json) => ArtistDetails(
    artist: ArtistRef.fromJson(json['artist'] as Map<String, dynamic>),
    tracks: [
      for (final track in json['tracks'] as List)
        Track.fromJson(track as Map<String, dynamic>),
    ],
    description: json['description'] as String? ?? '',
    musicCount: json['musicCount'] as int? ?? 0,
    albumCount: json['albumCount'] as int? ?? 0,
  );
}

class ArtistAlbumPage {
  const ArtistAlbumPage({
    required this.albums,
    required this.more,
    required this.receivedCount,
  });
  final List<Album> albums;
  final bool more;
  final int receivedCount;
  Map<String, dynamic> toJson() => {
    'albums': albums.map((album) => album.toJson()).toList(),
    'more': more,
    'receivedCount': receivedCount,
  };
  factory ArtistAlbumPage.fromJson(Map<String, dynamic> json) =>
      ArtistAlbumPage(
        albums: [
          for (final album in json['albums'] as List)
            Album.fromJson(album as Map<String, dynamic>),
        ],
        more: json['more'] == true,
        receivedCount: json['receivedCount'] as int? ?? 0,
      );
}

/// One page of the account's collected albums (资料库 → 专辑).
class UserAlbumPage {
  const UserAlbumPage({
    required this.albums,
    required this.more,
    required this.receivedCount,
  });
  final List<Album> albums;
  final bool more;
  final int receivedCount;
  Map<String, dynamic> toJson() => {
    'albums': albums.map((album) => album.toJson()).toList(),
    'more': more,
    'receivedCount': receivedCount,
  };
  factory UserAlbumPage.fromJson(Map<String, dynamic> json) => UserAlbumPage(
    albums: [
      for (final album in json['albums'] as List)
        Album.fromJson(album as Map<String, dynamic>),
    ],
    more: json['more'] == true,
    receivedCount: json['receivedCount'] as int? ?? 0,
  );
}
