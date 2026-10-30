import 'legacy_models.dart';
import 'music_gateway.dart';
import 'netease_gateway.dart';

/// Adapts the existing, tested NetEase protocol without exposing its response
/// envelopes or integer identifiers through the multi-platform boundary.
class NeteaseMusicGateway extends MusicGateway {
  NeteaseMusicGateway({required this.connectionId, NeteaseGateway? gateway})
    : legacy = gateway ?? NeteaseGateway(),
      _ownsGateway = gateway == null {
    if (connectionId.trim().isEmpty) {
      throw ArgumentError('Connection ID is required.');
    }
  }

  final NeteaseGateway legacy;
  final bool _ownsGateway;
  @override
  final String connectionId;
  MusicUser? _user;

  @override
  MusicProvider get provider => MusicProvider.netease;
  @override
  MusicUser? get user => _user;
  @override
  Set<MusicCapability> get capabilities => const {
    MusicCapability.search,
    MusicCapability.playlists,
    MusicCapability.editPlaylists,
    MusicCapability.favorites,
    MusicCapability.lyrics,
    MusicCapability.scrobble,
    MusicCapability.recommendations,
    MusicCapability.comments,
    MusicCapability.listenTogether,
  };

  MusicUser? _adopt(GatewayLoginStatus status) {
    final profile = status.profile;
    return _user = !status.signedIn || profile == null
        ? null
        : MusicUser(
            id: id(MusicEntityKind.user, '${profile.userId}'),
            name: profile.nickname,
            avatarUrl: profile.avatarUrl,
          );
  }

  Future<MusicUser?> loginWithCookie(String cookie) async {
    final status = await legacy.loginWithCookie(cookie);
    // The legacy gateway rolls back failed credentials; preserve the user too.
    if (!status.signedIn) return null;
    return _adopt(status);
  }

  /// QR/SMS authentication may use [legacy], then call this to adopt its user.
  @override
  Future<MusicUser?> checkSession() async => _adopt(await legacy.loginStatus());

  @override
  void clearSession() {
    _user = null;
    legacy.clearSession();
  }

  @override
  void close() {
    _user = null;
    if (_ownsGateway) {
      legacy.clearSession();
      legacy.close();
    }
  }

  int _numeric(MusicId id, MusicEntityKind kind) {
    final value = int.tryParse(remoteId(id, kind));
    if (value == null || value <= 0) {
      throw ArgumentError('Invalid NetEase identifier.');
    }
    return value;
  }

  int get _uid {
    final user = _user;
    if (user == null) {
      throw const MusicGatewayException(
        'netease',
        'session',
        httpStatus: 401,
        reason: 'Sign in required',
      );
    }
    return _numeric(user.id, MusicEntityKind.user);
  }

  MusicArtist _artist(GatewayArtist artist) => MusicArtist(
    id: id(MusicEntityKind.artist, '${artist.id}'),
    name: artist.name,
    coverUrl: artist.coverUrl,
  );

  MusicSong _song(GatewaySong song) => MusicSong(
    id: id(MusicEntityKind.song, '${song.id}'),
    title: song.title,
    artists: song.artistDetails.isNotEmpty
        ? song.artistDetails.map(_artist).toList()
        : [
            for (final name in song.artists)
              MusicArtist(id: id(MusicEntityKind.artist, ''), name: name),
          ],
    duration: song.duration,
    albumId: song.albumId > 0
        ? id(MusicEntityKind.album, '${song.albumId}')
        : null,
    albumName: song.albumName,
    coverUrl: song.coverUrl,
  );

  MusicAlbum _album(GatewayAlbum album) => MusicAlbum(
    id: id(MusicEntityKind.album, '${album.id}'),
    title: album.title,
    artists: album.artists.map(_artist).toList(),
    coverUrl: album.coverUrl,
    year: album.publishTime == null || album.publishTime! <= 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(album.publishTime!).year,
    songCount: album.trackCount,
  );

  MusicPlaylist _playlist(GatewayPlaylist playlist) => MusicPlaylist(
    id: id(MusicEntityKind.playlist, '${playlist.id}'),
    name: playlist.name,
    description: playlist.description,
    coverUrl: playlist.coverUrl,
    songCount: playlist.trackCount,
    owner: playlist.creatorId?.toString(),
    writable:
        playlist.created ||
        (_user != null && playlist.creatorId?.toString() == _user!.id.value),
    isFavorites: playlist.specialType == 5,
  );

  static List<Map<String, dynamic>> _list(Object? value) => value is List
      ? value.whereType<Map<String, dynamic>>().toList()
      : const [];

  MusicPage<T> _page<T>(List<T> items, int limit, int offset, {bool? more}) =>
      MusicPage(
        items.take(limit).toList(),
        offset: offset,
        hasMore: more ?? items.length > limit,
      );

  @override
  Future<MusicSearchResult> search(
    String query, {
    int limit = 30,
    int offset = 0,
  }) async {
    validatePage(limit, offset);
    if (query.trim().isEmpty) throw ArgumentError('Search query is required.');
    final results = await Future.wait([
      for (final type in GatewaySearchType.values)
        legacy.searchResultPage(query, type, limit: limit + 1, offset: offset),
    ]);
    return MusicSearchResult(
      songs: _page(
        _list(
          results[0]['songs'],
        ).map(GatewaySong.fromJson).map(_song).toList(),
        limit,
        offset,
      ),
      albums: _page(
        _list(
          results[1]['albums'],
        ).map(GatewayAlbum.fromJson).map(_album).toList(),
        limit,
        offset,
      ),
      artists: _page(
        _list(
          results[2]['artists'],
        ).map(GatewayArtist.fromJson).map(_artist).toList(),
        limit,
        offset,
      ),
      playlists: _page(
        _list(
          results[3]['playlists'],
        ).map(GatewayPlaylist.fromJson).map(_playlist).toList(),
        limit,
        offset,
      ),
    );
  }

  @override
  Future<MusicSong> song(MusicId id) async {
    final numeric = _numeric(id, MusicEntityKind.song);
    final songs = await legacy.songDetails([numeric]);
    for (final song in songs) {
      if (song.id == numeric) return _song(song);
    }
    throw const MusicGatewayException(
      'netease',
      'song',
      code: 70,
      reason: 'Song not found',
    );
  }

  @override
  Future<MusicAlbum> album(MusicId id) async {
    final album = await legacy.albumDetail(_numeric(id, MusicEntityKind.album));
    if (album == null) {
      throw const MusicGatewayException('netease', 'album', code: 70);
    }
    return _album(album);
  }

  @override
  Future<MusicPage<MusicSong>> albumSongs(
    MusicId id, {
    int limit = 100,
    int offset = 0,
  }) async {
    validatePage(limit, offset);
    final body = await legacy.albumDetailRaw(
      _numeric(id, MusicEntityKind.album),
    );
    final songs = _list(body['songs'])
        .skip(offset)
        .take(limit + 1)
        .map(GatewaySong.fromJson)
        .map(_song)
        .toList();
    return _page(songs, limit, offset);
  }

  @override
  Future<MusicArtist> artist(MusicId id) async {
    final body = await legacy.artistDetail(
      _numeric(id, MusicEntityKind.artist),
    );
    final data = body['data'];
    final value = data is Map ? data['artist'] : body['artist'];
    if (value is! Map<String, dynamic>) {
      throw const MusicGatewayException('netease', 'artist', code: 70);
    }
    final artist = GatewayArtist.fromJson(value);
    return MusicArtist(
      id: id,
      name: artist.name,
      coverUrl: artist.coverUrl,
      description: value['briefDesc'] as String? ?? '',
      albumCount: (value['albumSize'] as num?)?.toInt(),
    );
  }

  @override
  Future<MusicPage<MusicAlbum>> artistAlbums(
    MusicId id, {
    int limit = 30,
    int offset = 0,
  }) async {
    validatePage(limit, offset);
    final body = await legacy.artistAlbums(
      _numeric(id, MusicEntityKind.artist),
      limit: limit,
      offset: offset,
    );
    return _page(
      _list(body['hotAlbums']).map(GatewayAlbum.fromJson).map(_album).toList(),
      limit,
      offset,
      more: body['more'] == true,
    );
  }

  @override
  Future<MusicPage<MusicPlaylist>> playlists({
    int limit = 30,
    int offset = 0,
  }) async {
    validatePage(limit, offset);
    return _page(
      (await legacy.userPlaylists(
        _uid,
        limit: limit + 1,
        offset: offset,
      )).map(_playlist).toList(),
      limit,
      offset,
    );
  }

  @override
  Future<MusicPlaylist> playlist(MusicId id) async {
    final playlist = await legacy.topPlaylist(
      _numeric(id, MusicEntityKind.playlist),
    );
    if (playlist == null) {
      throw const MusicGatewayException('netease', 'playlist', code: 70);
    }
    return _playlist(playlist);
  }

  @override
  Future<MusicPage<MusicSong>> playlistSongs(
    MusicId id, {
    int limit = 100,
    int offset = 0,
  }) async {
    validatePage(limit, offset);
    final body = await legacy.playlistTracks(
      _numeric(id, MusicEntityKind.playlist),
      limit: limit + 1,
      offset: offset,
    );
    return _page(
      _list(body['songs']).map((item) {
        final nested = item['song'] ?? item['data'];
        return _song(
          GatewaySong.fromJson(nested is Map<String, dynamic> ? nested : item),
        );
      }).toList(),
      limit,
      offset,
    );
  }

  @override
  Future<MusicPlaylist> createPlaylist(
    String name, {
    bool isPublic = false,
  }) async {
    _uid;
    final playlist = await legacy.createPlaylist(name, privacy: !isPublic);
    if (playlist == null) {
      throw const MusicGatewayException('netease', 'createPlaylist');
    }
    final mapped = _playlist(playlist);
    return MusicPlaylist(
      id: mapped.id,
      name: mapped.name,
      description: mapped.description,
      coverUrl: mapped.coverUrl,
      songCount: mapped.songCount,
      owner: _user!.id.value,
      writable: true,
      isPublic: isPublic,
    );
  }

  @override
  Future<void> addToPlaylist(MusicId playlist, List<MusicId> songs) async {
    final playlistId = _numeric(playlist, MusicEntityKind.playlist);
    if (songs.isEmpty) throw ArgumentError('At least one song is required.');
    await legacy.addTracksToPlaylist(
      playlistId,
      songs.map((song) => _numeric(song, MusicEntityKind.song)).toList(),
    );
  }

  @override
  Future<void> removeFromPlaylist(MusicId playlist, List<int> indexes) async {
    final playlistId = _numeric(playlist, MusicEntityKind.playlist);
    if (indexes.isEmpty || indexes.any((index) => index < 0)) {
      throw ArgumentError('Invalid playlist positions.');
    }
    final body = await legacy.playlistDetail(playlistId);
    final raw = body['playlist'];
    if (raw is! Map<String, dynamic>) {
      throw const MusicGatewayException('netease', 'playlist');
    }
    final tracks = GatewayPlaylist.fromJson(raw).trackIds;
    if (indexes.any((index) => index >= tracks.length)) {
      throw RangeError('Playlist position is out of range.');
    }
    final removals = indexes.toSet().map((index) => tracks[index]).toSet();
    if (removals.any((id) => tracks.where((track) => track == id).length > 1)) {
      throw const MusicUnsupportedException(
        'netease',
        'positional removal of duplicate songs',
      );
    }
    await legacy.removeTracksFromPlaylist(playlistId, removals.toList());
  }

  @override
  Future<MusicPage<MusicSong>> favorites({
    int limit = 100,
    int offset = 0,
  }) async {
    validatePage(limit, offset);
    final ids = (await legacy.likedSongIds(
      _uid,
    )).skip(offset).take(limit + 1).toList();
    if (ids.isEmpty) return MusicPage([], offset: offset, hasMore: false);
    final details = await legacy.songDetails(ids.take(limit).toList());
    final byId = {for (final song in details) song.id: song};
    return _page(
      [
        for (final id in ids.take(limit))
          if (byId[id] != null) _song(byId[id]!),
      ],
      limit,
      offset,
      more: ids.length > limit,
    );
  }

  @override
  Future<void> setFavorite(MusicId song, bool favorite) =>
      legacy.setSongLiked(_numeric(song, MusicEntityKind.song), _uid, favorite);

  @override
  Future<MusicStream> stream(
    MusicId song, {
    MusicStreamQuality quality = MusicStreamQuality.original,
  }) async {
    final level = switch (quality) {
      MusicStreamQuality.original => 'lossless',
      MusicStreamQuality.high => 'exhigh',
      MusicStreamQuality.medium => 'higher',
      MusicStreamQuality.low => 'standard',
    };
    final result = await legacy.songUrl(
      _numeric(song, MusicEntityKind.song),
      level: level,
    );
    final uri = Uri.tryParse(result?.url ?? '');
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const MusicGatewayException(
        'netease',
        'stream',
        reason: 'Audio is unavailable',
      );
    }
    return MusicStream(
      uri: uri.scheme == 'http' ? uri.replace(scheme: 'https') : uri,
      suffix: result?.type,
      bitRate: result?.br,
      size: result?.size,
    );
  }

  @override
  Future<List<MusicLyrics>> lyrics(MusicId song) async {
    final result = await legacy.preferredLyrics(
      _numeric(song, MusicEntityKind.song),
    );
    if (result.pureMusic) return [];
    return [
      MusicLyrics(
        lines: const [],
        synced: result.hasTimedLyric,
        lrc: result.lrc,
        wordByWord: result.yrc,
        translation: result.tlyric ?? result.ytlrc,
      ),
    ];
  }

  @override
  Future<void> scrobble(
    MusicId song, {
    required Duration played,
    bool submission = true,
    DateTime? time,
  }) async {
    final songId = _numeric(song, MusicEntityKind.song);
    if (played.isNegative) {
      throw ArgumentError('Played duration cannot be negative.');
    }
    _uid;
    if (submission) {
      if (played == Duration.zero) return;
      await legacy.reportPlayback(
        songId: songId,
        playedSeconds: played.inSeconds,
      );
    } else {
      await legacy.reportPlayStart(songId: songId, sourceId: 0);
    }
  }

  @override
  Future<MusicPage<MusicSong>> recommendations({int limit = 30}) async {
    validatePage(limit, 0);
    final songs = await legacy.dailyRecommendedSongs();
    return MusicPage(
      songs.take(limit).map(_song).toList(),
      offset: 0,
      hasMore: false,
    );
  }
}
