/// Provider-neutral values. Remote IDs remain opaque strings, never integers.
library;

enum MusicEntityKind { song, album, artist, playlist, user }

enum MusicCapability {
  search,
  browseAlbums,
  savedAlbums,
  playlists,
  editPlaylists,
  favorites,
  lyrics,
  scrobble,
  recommendations,
  comments,
  listenTogether,
  radio,
  charts,
  homeFeed;

  /// Reads a capability name out of plugin data.
  ///
  /// Capabilities travel as strings in a manifest or a `describe` descriptor,
  /// so the same feature arrives as `listenTogether` from one plugin and
  /// `listen_together` from another. Names are compared with separators and
  /// case folded away; anything unknown is ignored instead of failing the
  /// whole platform description.
  static MusicCapability? parse(Object? name) {
    if (name is! String) return null;
    final String key = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (key.isEmpty) return null;
    for (final MusicCapability capability in MusicCapability.values) {
      if (capability.name.toLowerCase() == key) return capability;
    }
    return null;
  }

  /// Declared capabilities for a plugin platform.
  ///
  /// A plugin that predates `describe.capabilities` keeps the capabilities it
  /// shipped in its manifest; a descriptor that lists capabilities overrides
  /// them so one plugin can narrow what a single platform offers.
  static Set<MusicCapability> parseAll(
    Object? declared, {
    Iterable<String> fallback = const <String>[],
  }) {
    final Iterable<Object?> names = declared is List ? declared : fallback;
    return <MusicCapability>{
      for (final Object? name in names)
        if (parse(name) case final MusicCapability capability) capability,
    };
  }
}

class MusicProvider {
  const MusicProvider({
    required this.id,
    required this.name,
    this.experimental = false,
  });

  final String id;
  final String name;
  final bool experimental;
}

/// A reference cannot accidentally resolve against another account or server.
class MusicId {
  const MusicId({
    required this.provider,
    required this.connection,
    required this.kind,
    required this.value,
  });

  final String provider;
  final String connection;
  final MusicEntityKind kind;
  final String value;

  String get cacheKey => [
    provider,
    connection,
    kind.name,
    value,
  ].map(Uri.encodeComponent).join(':');

  Map<String, dynamic> toJson() => {
    'provider': provider,
    'connection': connection,
    'kind': kind.name,
    'value': value,
  };

  factory MusicId.fromJson(Map<String, dynamic> json) => MusicId(
    provider: json['provider'] as String,
    connection: json['connection'] as String,
    kind: MusicEntityKind.values.byName(json['kind'] as String),
    value: json['value'] as String,
  );

  static MusicId? tryParse(String value) {
    final parts = value.split(':');
    if (parts.length != 4) return null;
    try {
      final decoded = parts.map(Uri.decodeComponent).toList();
      if (decoded.any((part) => part.isEmpty)) return null;
      return MusicId(
        provider: decoded[0],
        connection: decoded[1],
        kind: MusicEntityKind.values.byName(decoded[2]),
        value: decoded[3],
      );
    } on ArgumentError {
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is MusicId &&
      provider == other.provider &&
      connection == other.connection &&
      kind == other.kind &&
      value == other.value;

  @override
  int get hashCode => Object.hash(provider, connection, kind, value);

  @override
  String toString() => cacheKey;
}

class MusicUser {
  const MusicUser({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.signature,
    this.membership,
  });
  final MusicId id;
  final String name;
  final String? avatarUrl;
  final String? signature, membership;
}

class MusicArtist {
  const MusicArtist({
    required this.id,
    required this.name,
    this.coverUrl,
    this.description = '',
    this.albumCount,
  });
  final MusicId id;
  final String name;
  final String? coverUrl;
  final String description;
  final int? albumCount;
}

class MusicSong {
  MusicSong({
    required this.id,
    required this.title,
    required List<MusicArtist> artists,
    required this.duration,
    this.albumId,
    this.albumName = '',
    this.coverUrl,
    this.trackNumber,
    this.discNumber,
    this.starred = false,
    this.contentType,
    this.suffix,
    this.bitRate,
    this.translatedTitle,
  }) : artists = List.unmodifiable(artists);

  final MusicId id;
  final String title;
  final List<MusicArtist> artists;
  final Duration duration;
  final MusicId? albumId;
  final String albumName;
  final String? coverUrl;
  final int? trackNumber;
  final int? discNumber;
  final bool starred;
  final String? contentType;
  final String? suffix;

  /// Bits per second (Subsonic's kbps field is converted by its adapter).
  final int? bitRate;
  final String? translatedTitle;
}

class MusicAlbum {
  MusicAlbum({
    required this.id,
    required this.title,
    required List<MusicArtist> artists,
    this.coverUrl,
    this.year,
    this.songCount = 0,
    this.description = '',
  }) : artists = List.unmodifiable(artists);
  final MusicId id;
  final String title;
  final List<MusicArtist> artists;
  final String? coverUrl;
  final int? year;
  final int songCount;
  final String description;
}

class MusicPlaylist {
  const MusicPlaylist({
    required this.id,
    required this.name,
    this.description = '',
    this.coverUrl,
    this.songCount = 0,
    this.owner,
    this.writable = false,
    this.isPublic = false,
    this.isFavorites = false,
  });
  final MusicId id;
  final String name;
  final String description;
  final String? coverUrl;
  final int songCount;
  final String? owner;
  final bool writable;
  final bool isPublic;
  final bool isFavorites;
}

class MusicPage<T> {
  MusicPage(List<T> items, {required this.offset, required this.hasMore})
    : items = List.unmodifiable(items);
  final List<T> items;
  final int offset;
  final bool hasMore;
  int get nextOffset => offset + items.length;
}

class MusicSearchResult {
  const MusicSearchResult({
    required this.songs,
    required this.albums,
    required this.artists,
    required this.playlists,
  });
  final MusicPage<MusicSong> songs;
  final MusicPage<MusicAlbum> albums;
  final MusicPage<MusicArtist> artists;
  final MusicPage<MusicPlaylist> playlists;
}

enum MusicStreamQuality { original, high, medium, low }

enum MusicAlbumSort { newest, random }

enum MusicRadioKind { personal, heart, artist }

class MusicHome {
  const MusicHome({
    this.featured,
    this.featuredSongs = const [],
    this.quick = const [],
    this.daily = const [],
    this.recommended = const [],
    this.playlists = const [],
    this.albums = const [],
    this.editorialPlaylists = const [],
  });
  final MusicAlbum? featured;
  final List<MusicSong> featuredSongs, quick, daily;
  final List<MusicPlaylist> recommended, playlists, editorialPlaylists;
  final List<MusicAlbum> albums;
}

class MusicStream {
  const MusicStream({
    required this.uri,
    this.contentType,
    this.suffix,
    this.bitRate,
    this.size,
    this.transcoded = false,
    this.headers = const {},
  });
  final Uri uri;
  final String? contentType;
  final String? suffix;
  final int? bitRate;
  final int? size;
  final bool transcoded;
  final Map<String, String> headers;

  // Signed URLs are credentials; never include them in diagnostics.
  @override
  String toString() => 'MusicStream(${uri.scheme}, transcoded: $transcoded)';
}

class MusicLyricLine {
  const MusicLyricLine({required this.text, this.start});
  final String text;
  final Duration? start;
}

class MusicLyrics {
  MusicLyrics({
    required List<MusicLyricLine> lines,
    this.language,
    this.synced = false,
    this.offset = Duration.zero,
    this.lrc,
    this.wordByWord,
    this.translation,
    this.wordTranslation,
  }) : lines = List.unmodifiable(lines);

  final List<MusicLyricLine> lines;
  final String? language;
  final bool synced;
  final Duration offset;
  final String? lrc;
  final String? wordByWord;
  final String? translation;
  final String? wordTranslation;
}

class MusicPlayRecord {
  const MusicPlayRecord({required this.song, required this.playCount});
  final MusicSong song;
  final int playCount;
}

/// Timed lyric payload shared by providers and the offline store.
class GatewayLyrics {
  const GatewayLyrics({
    this.lrc,
    this.yrc,
    this.tlyric,
    this.ytlrc,
    this.pureMusic = false,
  });

  final String? lrc;
  final String? yrc;
  final String? tlyric;
  final String? ytlrc;
  final bool pureMusic;

  bool get hasTimedLyric {
    final String? yrcLyric = yrc;
    final String? lrcLyric = lrc;
    if (yrcLyric != null && _yrcTimedLine.hasMatch(yrcLyric)) return true;
    return lrcLyric != null && _lrcTimedLine.hasMatch(lrcLyric);
  }

  static final RegExp _yrcTimedLine = RegExp(
    r'^\s*\[\d+,\d+\]',
    multiLine: true,
  );
  static final RegExp _lrcTimedLine = RegExp(
    r'^\s*\[\d{1,2}:\d{2}',
    multiLine: true,
  );
}
