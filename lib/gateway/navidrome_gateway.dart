import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'music_gateway.dart';
import 'navidrome_transport.dart';

export 'navidrome_transport.dart' show NavidromeSession;

/// Experimental Navidrome adapter using only Subsonic/OpenSubsonic APIs.
/// One immutable server + username pair per connection; login is transactional.
class NavidromeGateway extends MusicGateway {
  NavidromeGateway({
    required String serverUrl,
    required String username,
    bool allowInsecureHttp = false,
    http.Client? client,
    Duration timeout = const Duration(seconds: 20),
  }) : server = navidromeServerUri(
         serverUrl,
         allowInsecureHttp: allowInsecureHttp,
       ),
       username = username.trim() {
    if (this.username.isEmpty) throw ArgumentError('Username is required.');
    _transport = NavidromeTransport(
      server: server,
      client: client,
      timeout: timeout,
    );
  }

  final Uri server;
  final String username;
  late final NavidromeTransport _transport;
  NavidromeSession? _session;
  MusicUser? _user;
  int _generation = 0;
  bool _closed = false;

  @override
  MusicProvider get provider => MusicProvider.navidrome;
  @override
  late final String connectionId = sha256
      .convert(utf8.encode(jsonEncode([server.toString(), username])))
      .toString();
  @override
  MusicUser? get user => _user;

  /// Sensitive. The caller must use secure storage, not SharedPreferences.
  NavidromeSession? get session => _session;

  @override
  Set<MusicCapability> get capabilities => const {
    MusicCapability.search,
    MusicCapability.browseAlbums,
    MusicCapability.playlists,
    MusicCapability.editPlaylists,
    MusicCapability.favorites,
    MusicCapability.lyrics,
    MusicCapability.scrobble,
    MusicCapability.recommendations,
  };

  Future<MusicUser> login(String password) => restoreSession(
    NavidromeSession.fromPassword(
      server: server,
      username: username,
      password: password,
    ),
  );

  Future<MusicUser> restoreSession(NavidromeSession candidate) async {
    if (_closed) throw StateError('Navidrome connection is closed.');
    if (candidate.server != server || candidate.username != username) {
      throw ArgumentError('Session belongs to another connection.');
    }
    final generation = ++_generation;
    await _transport.request('ping', candidate);
    _checkGeneration(generation);
    _session = candidate;
    return _user = MusicUser(
      id: id(MusicEntityKind.user, username),
      name: username,
    );
  }

  @override
  Future<MusicUser?> checkSession() async {
    if (_session == null) return null;
    try {
      await _request('ping');
      return _user;
    } on MusicGatewayException catch (error) {
      if (!error.authenticationFailure) rethrow;
      clearSession();
      return null;
    }
  }

  @override
  void clearSession() {
    ++_generation;
    _session = null;
    _user = null;
  }

  @override
  void close() {
    clearSession();
    _closed = true;
    _transport.close();
  }

  void _checkGeneration(int generation) {
    if (_closed || generation != _generation) {
      throw const MusicGatewayException(
        'navidrome',
        'session',
        reason: 'Session changed during request',
      );
    }
  }

  NavidromeSession get _authenticated =>
      _session ??
      (throw const MusicGatewayException(
        'navidrome',
        'session',
        code: 40,
        reason: 'Sign in required',
      ));

  Future<Map<String, dynamic>> _request(
    String method, [
    Map<String, dynamic> parameters = const {},
  ]) async {
    final generation = _generation;
    try {
      final result = await _transport.request(
        method,
        _authenticated,
        parameters,
      );
      _checkGeneration(generation);
      return result;
    } on MusicGatewayException {
      _checkGeneration(generation);
      rethrow;
    }
  }

  static Map<String, dynamic> _map(Object? value) =>
      value is Map<String, dynamic> ? value : const {};
  static List<Map<String, dynamic>> _list(Object? value) => value is List
      ? value.whereType<Map<String, dynamic>>().toList()
      : const [];
  static String _string(Object? value) => value is String
      ? value
      : value is num
      ? '$value'
      : '';
  static int? _int(Object? value) =>
      value is num ? value.toInt() : int.tryParse(_string(value));

  String _requiredId(Map<String, dynamic> value) {
    final raw = _string(value['id']);
    if (raw.isEmpty) {
      throw const MusicGatewayException(
        'navidrome',
        'decode',
        reason: 'Missing entity ID',
      );
    }
    return raw;
  }

  String? _cover(Object? value) {
    final cover = _string(value);
    return cover.isEmpty
        ? null
        : _transport.mediaUri('getCoverArt', _authenticated, {
            'id': cover,
            'size': '600',
          }).toString();
  }

  MusicArtist _artist(Map<String, dynamic> value) => MusicArtist(
    id: id(MusicEntityKind.artist, _requiredId(value)),
    name: _string(value['name']),
    coverUrl: _cover(value['coverArt']),
    albumCount: _int(value['albumCount']),
  );

  List<MusicArtist> _artists(Map<String, dynamic> value) {
    final multiple = _list(value['artists']);
    if (multiple.isNotEmpty) return multiple.map(_artist).toList();
    final artistId = _string(value['artistId']);
    final name = _string(value['artist']);
    if (name.isEmpty) return const [];
    // An absent reference stays empty; never invent a routable artist ID.
    return [MusicArtist(id: id(MusicEntityKind.artist, artistId), name: name)];
  }

  MusicSong _song(Map<String, dynamic> value) {
    final albumId = _string(value['albumId']);
    return MusicSong(
      id: id(MusicEntityKind.song, _requiredId(value)),
      title: _string(value['title']),
      artists: _artists(value),
      duration: Duration(
        milliseconds:
            ((value['duration'] is num
                        ? value['duration'] as num
                        : num.tryParse(_string(value['duration'])) ?? 0) *
                    1000)
                .round(),
      ),
      albumId: albumId.isEmpty ? null : id(MusicEntityKind.album, albumId),
      albumName: _string(value['album']),
      coverUrl: _cover(value['coverArt']),
      trackNumber: _int(value['track']),
      discNumber: _int(value['discNumber']),
      starred: _string(value['starred']).isNotEmpty,
      contentType: value['contentType'] as String?,
      suffix: value['suffix'] as String?,
      bitRate: _int(value['bitRate']) == null
          ? null
          : _int(value['bitRate'])! * 1000,
    );
  }

  MusicAlbum _album(Map<String, dynamic> value) => MusicAlbum(
    id: id(MusicEntityKind.album, _requiredId(value)),
    title: _string(value['name'] ?? value['title']),
    artists: _artists(value),
    coverUrl: _cover(value['coverArt']),
    year: _int(value['year']),
    songCount: _int(value['songCount']) ?? 0,
  );

  MusicPlaylist _playlist(Map<String, dynamic> value) => MusicPlaylist(
    id: id(MusicEntityKind.playlist, _requiredId(value)),
    name: _string(value['name']),
    description: _string(value['comment']),
    coverUrl: _cover(value['coverArt']),
    songCount: _int(value['songCount']) ?? 0,
    owner: value['owner'] as String?,
    writable: value['owner'] == username,
    isPublic: value['public'] == true,
  );

  MusicPage<T> _slice<T>(List<T> items, int limit, int offset) {
    validatePage(limit, offset);
    return MusicPage(
      items.skip(offset).take(limit).toList(),
      offset: offset,
      hasMore: items.length > offset + limit,
    );
  }

  @override
  Future<MusicSearchResult> search(
    String query, {
    int limit = 30,
    int offset = 0,
  }) async {
    validatePage(limit, offset);
    if (query.trim().isEmpty) throw ArgumentError('Search query is required.');
    final results = await Future.wait([
      _request('search3', {
        'query': query.trim(),
        'songCount': '${limit + 1}',
        'songOffset': '$offset',
        'albumCount': '${limit + 1}',
        'albumOffset': '$offset',
        'artistCount': '${limit + 1}',
        'artistOffset': '$offset',
      }),
      _request('getPlaylists'),
    ]);
    final result = _map(results[0]['searchResult3']);
    MusicPage<T> page<T>(List<T> items) => MusicPage(
      items.take(limit).toList(),
      offset: offset,
      hasMore: items.length > limit,
    );
    final matches = _list(_map(results[1]['playlists'])['playlist'])
        .where(
          (value) => _string(
            value['name'],
          ).toLowerCase().contains(query.trim().toLowerCase()),
        )
        .map(_playlist)
        .toList();
    return MusicSearchResult(
      songs: page(_list(result['song']).map(_song).toList()),
      albums: page(_list(result['album']).map(_album).toList()),
      artists: page(_list(result['artist']).map(_artist).toList()),
      playlists: _slice(matches, limit, offset),
    );
  }

  @override
  Future<MusicSong> song(MusicId id) async => _song(
    _map(
      (await _request('getSong', {
        'id': remoteId(id, MusicEntityKind.song),
      }))['song'],
    ),
  );

  Future<Map<String, dynamic>> _albumDetail(MusicId id) async => _map(
    (await _request('getAlbum', {
      'id': remoteId(id, MusicEntityKind.album),
    }))['album'],
  );

  @override
  Future<MusicAlbum> album(MusicId id) async => _album(await _albumDetail(id));

  @override
  Future<MusicPage<MusicAlbum>> albums({
    MusicAlbumSort sort = MusicAlbumSort.newest,
    int limit = 30,
    int offset = 0,
  }) async {
    validatePage(limit, offset);
    // The server caps getAlbumList2 at 500; a full page at that ceiling
    // needs one subsequent read to find the terminal empty page.
    final size = sort == MusicAlbumSort.random || limit == 500
        ? limit
        : limit + 1;
    final body = await _request('getAlbumList2', {
      'type': sort.name,
      'size': '$size',
      'offset': '$offset',
    });
    final albums = _list(
      _map(body['albumList2'])['album'],
    ).map(_album).toList();
    return MusicPage(
      albums.take(limit).toList(),
      offset: offset,
      hasMore:
          sort != MusicAlbumSort.random &&
          (albums.length > limit || (limit == 500 && albums.length == limit)),
    );
  }

  @override
  Future<MusicPage<MusicSong>> albumSongs(
    MusicId id, {
    int limit = 100,
    int offset = 0,
  }) async {
    validatePage(limit, offset);
    return _slice(
      _list((await _albumDetail(id))['song']).map(_song).toList(),
      limit,
      offset,
    );
  }

  Future<Map<String, dynamic>> _artistDetail(MusicId id) async => _map(
    (await _request('getArtist', {
      'id': remoteId(id, MusicEntityKind.artist),
    }))['artist'],
  );

  @override
  Future<MusicArtist> artist(MusicId id) async =>
      _artist(await _artistDetail(id));

  @override
  Future<MusicPage<MusicAlbum>> artistAlbums(
    MusicId id, {
    int limit = 30,
    int offset = 0,
  }) async {
    validatePage(limit, offset);
    return _slice(
      _list((await _artistDetail(id))['album']).map(_album).toList(),
      limit,
      offset,
    );
  }

  @override
  Future<MusicPage<MusicPlaylist>> playlists({
    int limit = 30,
    int offset = 0,
  }) async {
    validatePage(limit, offset);
    final body = await _request('getPlaylists');
    return _slice(
      _list(_map(body['playlists'])['playlist']).map(_playlist).toList(),
      limit,
      offset,
    );
  }

  Future<Map<String, dynamic>> _playlistDetail(MusicId id) async => _map(
    (await _request('getPlaylist', {
      'id': remoteId(id, MusicEntityKind.playlist),
    }))['playlist'],
  );

  @override
  Future<MusicPlaylist> playlist(MusicId id) async =>
      _playlist(await _playlistDetail(id));

  @override
  Future<MusicPage<MusicSong>> playlistSongs(
    MusicId id, {
    int limit = 100,
    int offset = 0,
  }) async {
    validatePage(limit, offset);
    return _slice(
      _list((await _playlistDetail(id))['entry']).map(_song).toList(),
      limit,
      offset,
    );
  }

  @override
  Future<MusicPlaylist> createPlaylist(
    String name, {
    bool isPublic = false,
  }) async {
    if (name.trim().isEmpty) throw ArgumentError('Playlist name is required.');
    final created = _playlist(
      _map(
        (await _request('createPlaylist', {'name': name.trim()}))['playlist'],
      ),
    );
    // Subsonic createPlaylist has no privacy parameter; always set it explicitly.
    await _request('updatePlaylist', {
      'playlistId': created.id.value,
      'public': '$isPublic',
    });
    return MusicPlaylist(
      id: created.id,
      name: created.name,
      description: created.description,
      coverUrl: created.coverUrl,
      songCount: created.songCount,
      owner: username,
      writable: true,
      isPublic: isPublic,
    );
  }

  @override
  Future<void> addToPlaylist(MusicId playlist, List<MusicId> songs) async {
    final playlistId = remoteId(playlist, MusicEntityKind.playlist);
    if (songs.isEmpty) throw ArgumentError('At least one song is required.');
    final ids = songs
        .map((song) => remoteId(song, MusicEntityKind.song))
        .toList();
    await _request('updatePlaylist', {
      'playlistId': playlistId,
      'songIdToAdd': ids,
    });
  }

  @override
  Future<void> removeFromPlaylist(MusicId playlist, List<int> indexes) async {
    final playlistId = remoteId(playlist, MusicEntityKind.playlist);
    if (indexes.isEmpty || indexes.any((index) => index < 0)) {
      throw ArgumentError('Non-negative playlist positions are required.');
    }
    await _request('updatePlaylist', {
      'playlistId': playlistId,
      'songIndexToRemove': indexes.toSet().map((index) => '$index').toList(),
    });
  }

  @override
  Future<MusicPage<MusicSong>> favorites({
    int limit = 100,
    int offset = 0,
  }) async {
    validatePage(limit, offset);
    final body = await _request('getStarred2');
    return _slice(
      _list(_map(body['starred2'])['song']).map(_song).toList(),
      limit,
      offset,
    );
  }

  @override
  Future<void> setFavorite(MusicId song, bool favorite) async {
    await _request(favorite ? 'star' : 'unstar', {
      'id': remoteId(song, MusicEntityKind.song),
    });
  }

  @override
  Future<MusicStream> stream(
    MusicId song, {
    MusicStreamQuality quality = MusicStreamQuality.original,
  }) async {
    final remote = remoteId(song, MusicEntityKind.song);
    final metadata = await this.song(song);
    final bitrate = switch (quality) {
      MusicStreamQuality.original => 0,
      MusicStreamQuality.high => 320,
      MusicStreamQuality.medium => 192,
      MusicStreamQuality.low => 128,
    };
    final original = quality == MusicStreamQuality.original;
    return MusicStream(
      uri: _transport.mediaUri('stream', _authenticated, {
        'id': remote,
        'maxBitRate': '$bitrate',
        'format': original ? 'raw' : 'mp3',
      }),
      contentType: original ? metadata.contentType : 'audio/mpeg',
      suffix: original ? metadata.suffix : 'mp3',
      bitRate: original ? metadata.bitRate : bitrate * 1000,
      transcoded: !original,
    );
  }

  @override
  Future<List<MusicLyrics>> lyrics(MusicId song) async {
    final remote = remoteId(song, MusicEntityKind.song);
    try {
      final body = await _request('getLyricsBySongId', {'id': remote});
      final lyrics = _list(_map(body['lyricsList'])['structuredLyrics']);
      if (lyrics.isNotEmpty) {
        return lyrics
            .map(
              (value) => MusicLyrics(
                language: value['lang'] as String?,
                synced: value['synced'] == true,
                offset: Duration(milliseconds: _int(value['offset']) ?? 0),
                lines: _list(value['line'])
                    .map(
                      (line) => MusicLyricLine(
                        text: _string(line['value']),
                        start:
                            value['synced'] == true &&
                                _int(line['start']) != null
                            ? Duration(milliseconds: _int(line['start'])!)
                            : null,
                      ),
                    )
                    .toList(),
              ),
            )
            .toList();
      }
    } on MusicGatewayException catch (error) {
      // Older servers lack songLyrics. Never hide auth/network failures.
      if (error.httpStatus != 404 && error.code != 70) rethrow;
    }
    final metadata = await this.song(song);
    final body = await _request('getLyrics', {
      'artist': metadata.artists.firstOrNull?.name ?? '',
      'title': metadata.title,
    });
    final text = _string(_map(body['lyrics'])['value']);
    return text.isEmpty
        ? []
        : [
            MusicLyrics(
              lines: const LineSplitter()
                  .convert(text)
                  .map((line) => MusicLyricLine(text: line))
                  .toList(),
              lrc: text,
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
    final remote = remoteId(song, MusicEntityKind.song);
    if (played.isNegative ||
        (time != null && time.millisecondsSinceEpoch < 0)) {
      throw ArgumentError('Invalid scrobble time.');
    }
    if (submission && played == Duration.zero) return;
    await _request('scrobble', {
      'id': remote,
      'submission': '$submission',
      if (time != null) 'time': '${time.millisecondsSinceEpoch}',
    });
  }

  @override
  Future<MusicPage<MusicSong>> recommendations({int limit = 30}) async {
    validatePage(limit, 0);
    final body = await _request('getRandomSongs', {'size': '$limit'});
    return MusicPage(
      _list(_map(body['randomSongs'])['song']).map(_song).toList(),
      offset: 0,
      hasMore: false,
    );
  }
}
