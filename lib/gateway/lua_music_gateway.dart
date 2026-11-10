import 'package:flutter/foundation.dart' show kIsWeb;

import '../plugins/lua_plugin_runtime.dart';
import '../plugins/plugin_manifest.dart' show PluginException;
import 'music_gateway.dart';

/// Provider-neutral adapter for a Lua plugin. A plugin returns JSON-shaped
/// values; this class is deliberately the only place that turns them into
/// client models, keeping Lua independent from Dart and Flutter.
class LuaMusicGateway extends MusicAccountGateway {
  LuaMusicGateway({
    required this.runtime,
    required this.provider,
    required this.connectionId,
    this.declaredCapabilities,
    this.authenticationMethods = const {},
    this.pluginId,
    this.loginHint,
    this.cookieHint,
    this.forgotPasswordUrl,
  });
  final LuaPluginRuntime runtime;
  final String? pluginId;
  @override
  final Set<String> authenticationMethods;
  @override
  @override
  @override
  final String? loginHint, cookieHint, forgotPasswordUrl;
  bool supportsAuthentication(String method) =>
      authenticationMethods.contains(method);

  @override
  final MusicProvider provider;
  @override
  final String connectionId;
  final Set<MusicCapability>? declaredCapabilities;
  MusicUser? _user;
  int _authGeneration = 0;
  final Map<String, String> _qrKeys = {};
  @override
  MusicUser? get user => _user;
  @override
  Set<MusicCapability> get capabilities =>
      declaredCapabilities ??
      const {
        MusicCapability.search,
        MusicCapability.browseAlbums,
        MusicCapability.playlists,
        MusicCapability.editPlaylists,
        MusicCapability.favorites,
        MusicCapability.lyrics,
        MusicCapability.scrobble,
        MusicCapability.recommendations,
      };

  /// Per-operation wall clock for the shared plugin queue.
  ///
  /// One plugin runs its calls one at a time, and a track resolve waits behind
  /// whatever else the app asked for. Background work therefore gets a tighter
  /// budget than the plugin default: a wedged upload report must not park the
  /// lane the next `stream` needs. Resolving a track keeps the default, because
  /// it is the one call the listener is actually waiting on.
  static const Map<String, Duration> _budgets = <String, Duration>{
    'scrobble': Duration(seconds: 10),
    'playStats': Duration(seconds: 10),
    'lyrics': Duration(seconds: 10),
    'song': Duration(seconds: 10),
  };

  Future<dynamic> _call(
    String operation, [
    Map<String, dynamic> args = const {},
  ]) async {
    final Duration? budget = _budgets[operation];
    try {
      return await _callOnce(operation, args, budget);
    } on PluginException catch (error) {
      // A timed-out plugin restarts its own VM; the abandoned call never reached
      // a result, so repeating it once on the fresh VM is safe and turns "the
      // plugin is dead until you re-enable it" into one slow answer. Only the
      // track resolve is worth that second wait: background work is retried from
      // its own queue instead, without making the listener wait for it.
      if (error.code != PluginException.timeoutCode) rethrow;
      if (operation != 'stream') rethrow;
      return _callOnce(operation, args, budget);
    }
  }

  Future<dynamic> _callOnce(
    String operation,
    Map<String, dynamic> args,
    Duration? budget,
  ) async {
    final value = await runtime.invoke(operation, {
      'platform': provider.id,
      ...args,
    }, budget);
    if (value is Map && value['error'] is Map) {
      final error = value['error'] as Map;
      final int? code = (error['code'] as num?)?.toInt();
      // The sandbox reports an HTTP status it parsed out of a thrown Lua error
      // through `code`. Treating it as an application code hid 401/429 from the
      // login prompt and the retry messaging.
      final int? httpStatus =
          (error['httpStatus'] as num?)?.toInt() ??
          (code != null && code >= 400 && code <= 599 ? code : null);
      throw MusicGatewayException(
        provider.id,
        operation,
        code: code,
        httpStatus: httpStatus,
      );
    }
    return value;
  }

  List<dynamic> _list(Object? value) => value is List ? value : const [];

  Map<String, dynamic> _mapResult(Object? value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    // A nil or list where an object was promised is a plugin bug. Mapping it to
    // an empty object made it look like a successful empty result.
    throw MusicGatewayException(provider.id, 'response', reason: 'invalid payload');
  }
  String _string(Object? value) => value?.toString() ?? '';
  MusicId _id(MusicEntityKind kind, Object? value) => id(kind, _string(value));
  MusicArtist _artist(Map value) => MusicArtist(
    id: _id(MusicEntityKind.artist, value['id']),
    name: _string(value['name']),
    coverUrl: value['coverUrl'] as String?,
    description: _string(value['description']),
    albumCount: (value['albumCount'] as num?)?.toInt(),
  );
  MusicSong _song(Map value) => MusicSong(
    id: _id(MusicEntityKind.song, value['id']),
    title: _string(value['title']),
    artists: _list(value['artists']).whereType<Map>().map(_artist).toList(),
    duration: Duration(
      milliseconds: (value['durationMs'] as num?)?.toInt() ?? 0,
    ),
    albumId: value['albumId'] == null
        ? null
        : _id(MusicEntityKind.album, value['albumId']),
    albumName: _string(value['albumName']),
    coverUrl: value['coverUrl'] as String?,
    starred: value['starred'] == true,
    contentType: value['contentType'] as String?,
    suffix: value['suffix'] as String?,
    bitRate: (value['bitRate'] as num?)?.toInt(),
    translatedTitle: value['translatedTitle'] as String?,
  );
  MusicAlbum _album(Map value) => MusicAlbum(
    id: _id(MusicEntityKind.album, value['id']),
    title: _string(value['title']),
    artists: _list(value['artists']).whereType<Map>().map(_artist).toList(),
    coverUrl: value['coverUrl'] as String?,
    year: (value['year'] as num?)?.toInt(),
    songCount: (value['songCount'] as num?)?.toInt() ?? 0,
    description: _string(value['description']),
  );
  MusicPlaylist _playlist(Map value) => MusicPlaylist(
    id: _id(MusicEntityKind.playlist, value['id']),
    name: _string(value['name']),
    description: _string(value['description']),
    coverUrl: value['coverUrl'] as String?,
    songCount: (value['songCount'] as num?)?.toInt() ?? 0,
    owner: value['owner'] as String?,
    writable: value['writable'] == true,
    isPublic: value['isPublic'] == true,
    isFavorites: value['isFavorites'] == true,
  );
  MusicPage<T> _page<T>(
    Object? raw,
    T Function(Map) convert,
    int offset,
    int limit,
  ) {
    // Lua's empty table arrives as `{}` rather than `[]`; that is the plugin
    // saying "no rows", not a malformed page. A non-empty map or a scalar is
    // malformed though, and returning an empty page for it hid plugin bugs.
    if (raw is Map && raw.isEmpty) raw = const <Object?>[];
    if (raw != null && raw is! List) {
      throw MusicGatewayException(
        provider.id,
        'response',
        reason: 'invalid payload',
      );
    }
    final list = raw is List
        ? raw.whereType<Map>().map(convert).toList()
        : <T>[];
    return MusicPage(
      list.take(limit).toList(),
      offset: offset,
      hasMore: list.length >= limit,
    );
  }

  @override
  Future<MusicUser?> checkSession() async {
    final generation = _authGeneration;
    final raw = await _call('session');
    if (generation != _authGeneration) return null;
    return _adopt(raw);
  }

  Future<MusicUser?> _login(String operation, Map<String, dynamic> args) async {
    final generation = ++_authGeneration;
    final raw = await _call(operation, args);
    if (generation != _authGeneration) return null;
    return _adopt(raw, preserveOnFailure: true);
  }

  @override
  Future<MusicUser?> loginWithCookie(String cookie) =>
      _login('loginCookie', {'cookie': cookie});

  @override
  Future<MusicUser?> loginWithPassword(String account, String password) =>
      _login('loginPassword', {'account': account, 'password': password});
  @override
  Future<MusicUser?> loginWithCaptcha(String phone, String captcha) =>
      _login('loginCaptcha', {'phone': phone, 'captcha': captcha});
  @override
  Future<void> sendCaptcha(String phone) async {
    await _call('sendCaptcha', {'phone': phone});
  }

  @override
  Future<String?> qrKey() async {
    final raw = await _call('qrKey');
    return raw?.toString().isEmpty == true ? null : raw?.toString();
  }

  @override
  Future<String> qrUrl(String key) async {
    final url = (await _call('qrUrl', {
      'key': key,
      'web': kIsWeb,
    }))?.toString() ?? '';
    if (url.isNotEmpty) {
      _qrKeys.clear();
      _qrKeys[url] = key;
    }
    return url;
  }

  @override
  Future<int> qrCheck(String key) async =>
      (await _call('qrCheck', {'key': _qrKeys[key] ?? key}) as num?)?.toInt() ??
      0;
  MusicUser? _adopt(Object? raw, {bool preserveOnFailure = false}) {
    if (raw is! Map || raw['id'] == null || _string(raw['id']).isEmpty) {
      if (!preserveOnFailure) _user = null;
      return null;
    }
    return _user = MusicUser(
      id: _id(MusicEntityKind.user, raw['id']),
      name: _string(raw['name']),
      avatarUrl: raw['avatarUrl'] as String?,
      signature: raw['signature'] as String?,
      membership: raw['membership'] as String?,
    );
  }

  @override
  Future<void> logout() async {
    final generation = ++_authGeneration;
    try {
      await _call('logout');
    } finally {
      if (generation == _authGeneration) _user = null;
    }
  }

  @override
  void clearSession() {
    ++_authGeneration;
    _user = null;
  }

  @override
  void close() => runtime.close();
  @override
  Future<MusicSearchResult> search(
    String query, {
    int limit = 30,
    int offset = 0,
  }) async {
    final raw = await _call('search', {
      'query': query,
      'limit': limit,
      'offset': offset,
    });
    final map = raw is Map ? raw : const {};
    return MusicSearchResult(
      songs: _page(map['songs'], _song, offset, limit),
      albums: _page(map['albums'], _album, offset, limit),
      artists: _page(map['artists'], _artist, offset, limit),
      playlists: _page(map['playlists'], _playlist, offset, limit),
    );
  }

  @override
  Future<MusicSong> song(MusicId id) async => _song(
    _mapResult(await _call('song', {'id': remoteId(id, MusicEntityKind.song)})),
  );
  @override
  Future<MusicAlbum> album(MusicId id) async => _album(
    _mapResult(await _call('album', {'id': remoteId(id, MusicEntityKind.album)})),
  );
  @override
  Future<MusicPage<MusicAlbum>> albums({
    MusicAlbumSort sort = MusicAlbumSort.newest,
    int limit = 30,
    int offset = 0,
  }) async => _page(
    (await _call('albums', {
      'sort': sort.name,
      'limit': limit,
      'offset': offset,
    })),
    _album,
    offset,
    limit,
  );
  @override
  Future<MusicPage<MusicSong>> albumSongs(
    MusicId id, {
    int limit = 100,
    int offset = 0,
  }) async => _page(
    (await _call('albumSongs', {
      'id': remoteId(id, MusicEntityKind.album),
      'limit': limit,
      'offset': offset,
    })),
    _song,
    offset,
    limit,
  );
  @override
  Future<MusicArtist> artist(MusicId id) async => _artist(
    _mapResult(
      await _call('artist', {'id': remoteId(id, MusicEntityKind.artist)}),
    ),
  );
  @override
  Future<MusicPage<MusicSong>> artistSongs(
    MusicId id, {
    int limit = 100,
    int offset = 0,
  }) async => _page(
    await _call('artistSongs', {
      'id': remoteId(id, MusicEntityKind.artist),
      'limit': limit,
      'offset': offset,
    }),
    _song,
    offset,
    limit,
  );
  @override
  Future<MusicPage<MusicAlbum>> artistAlbums(
    MusicId id, {
    int limit = 30,
    int offset = 0,
  }) async => _page(
    (await _call('artistAlbums', {
      'id': remoteId(id, MusicEntityKind.artist),
      'limit': limit,
      'offset': offset,
    })),
    _album,
    offset,
    limit,
  );
  @override
  Future<MusicPage<MusicPlaylist>> playlists({
    int limit = 30,
    int offset = 0,
  }) async => _page(
    (await _call('playlists', {'limit': limit, 'offset': offset})),
    _playlist,
    offset,
    limit,
  );
  @override
  Future<MusicPlaylist> playlist(MusicId id) async => _playlist(
    _mapResult(
      await _call('playlist', {'id': remoteId(id, MusicEntityKind.playlist)}),
    ),
  );
  @override
  Future<MusicPage<MusicSong>> playlistSongs(
    MusicId id, {
    int limit = 100,
    int offset = 0,
  }) async => _page(
    (await _call('playlistSongs', {
      'id': remoteId(id, MusicEntityKind.playlist),
      'limit': limit,
      'offset': offset,
    })),
    _song,
    offset,
    limit,
  );
  @override
  Future<MusicPlaylist> createPlaylist(
    String name, {
    bool isPublic = false,
  }) async => _playlist(
    _mapResult(
      await _call('createPlaylist', {'name': name, 'isPublic': isPublic}),
    ),
  );
  @override
  Future<void> addToPlaylist(MusicId playlist, List<MusicId> songs) async {
    await _call('addToPlaylist', {
      'playlist': remoteId(playlist, MusicEntityKind.playlist),
      'songs': songs.map((s) => remoteId(s, MusicEntityKind.song)).toList(),
    });
  }

  @override
  Future<void> removeFromPlaylist(MusicId playlist, List<int> indexes) async {
    await _call('removeFromPlaylist', {
      'playlist': remoteId(playlist, MusicEntityKind.playlist),
      'indexes': indexes,
    });
  }

  @override
  Future<MusicPage<MusicSong>> favorites({
    int limit = 100,
    int offset = 0,
  }) async => _page(
    (await _call('favorites', {'limit': limit, 'offset': offset})),
    _song,
    offset,
    limit,
  );
  @override
  Future<void> setFavorite(MusicId song, bool favorite) async {
    await _call('setFavorite', {
      'id': remoteId(song, MusicEntityKind.song),
      'favorite': favorite,
    });
  }

  @override
  Future<MusicStream> stream(
    MusicId song, {
    MusicStreamQuality quality = MusicStreamQuality.original,
  }) async {
    final raw = _mapResult(
      await _call('stream', {
        'id': remoteId(song, MusicEntityKind.song),
        'quality': quality.name,
      }),
    );
    return MusicStream(
      uri: Uri.parse(_string(raw['url'])),
      contentType: raw['contentType'] as String?,
      suffix: raw['suffix'] as String?,
      bitRate: (raw['bitRate'] as num?)?.toInt(),
      size: (raw['size'] as num?)?.toInt(),
      transcoded: raw['transcoded'] == true,
      headers: Map<String, String>.from(raw['headers'] as Map? ?? const {}),
    );
  }

  @override
  Future<List<MusicLyrics>> lyrics(MusicId song) async {
    final raw = await _call('lyrics', {
      'id': remoteId(song, MusicEntityKind.song),
    });
    return raw is! List
        ? const []
        : [
            for (final item in raw.whereType<Map>())
              MusicLyrics(
                lines: [
                  for (final line in _list(item['lines']).whereType<Map>())
                    MusicLyricLine(
                      text: _string(line['text']),
                      start: (line['startMs'] as num?) == null
                          ? null
                          : Duration(
                              milliseconds: (line['startMs'] as num).toInt(),
                            ),
                    ),
                ],
                synced: item['synced'] == true,
                translation:
                    item['translation'] as String? ?? item['tlyric'] as String?,
                wordTranslation:
                    item['wordTranslation'] as String? ??
                    item['ytlrc'] as String?,
                wordByWord: item['wordByWord'] as String?,
                lrc: item['lrc'] as String?,
                offset: Duration(
                  milliseconds: (item['offsetMs'] as num?)?.toInt() ?? 0,
                ),
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
    await _call('scrobble', {
      'id': remoteId(song, MusicEntityKind.song),
      'playedMs': played.inMilliseconds,
      'submission': submission,
      'time': time?.toIso8601String(),
    });
  }

  @override
  Future<MusicPage<MusicPlayRecord>> playStats({
    int limit = 100,
    int offset = 0,
  }) async {
    final raw = await _call('playStats', {'limit': limit, 'offset': offset});
    final map = raw is Map ? raw : const {};
    final records = map['records'] is List
        ? (map['records'] as List).whereType<Map>().toList()
        : const <Map>[];
    return MusicPage(
      [
        for (final record in records)
          MusicPlayRecord(
            song: _song(Map.from(record['song'] as Map)),
            playCount: (record['playCount'] as num?)?.toInt() ?? 0,
          ),
      ],
      offset: offset,
      hasMore: records.length >= limit,
    );
  }

  @override
  Future<MusicPage<MusicSong>> recommendations({int limit = 30}) async => _page(
    (await _call('recommendations', {'limit': limit})),
    _song,
    0,
    limit,
  );

  @override
  Future<String?> exportCookie() async =>
      (await _call('exportCookie')) as String?;

  @override
  Future<MusicPage<MusicAlbum>> savedAlbums({
    int limit = 30,
    int offset = 0,
  }) async => _page(
    await _call('savedAlbums', {'limit': limit, 'offset': offset}),
    _album,
    offset,
    limit,
  );

  @override
  Future<MusicHome> homeFeed() async {
    final raw = _mapResult(await _call('homeFeed'));
    List<T> values<T>(String key, T Function(Map) convert) =>
        _list(raw[key]).whereType<Map>().map(convert).toList();
    return MusicHome(
      featured: raw['featured'] is Map ? _album(raw['featured'] as Map) : null,
      featuredSongs: values('featuredSongs', _song),
      quick: values('quick', _song),
      daily: values('daily', _song),
      recommended: values('recommended', _playlist),
      playlists: values('playlists', _playlist),
      albums: values('albums', _album),
      editorialPlaylists: values('editorialPlaylists', _playlist),
    );
  }

  @override
  Future<List<MusicPlaylist>> charts() async =>
      _list(await _call('charts')).whereType<Map>().map(_playlist).toList();

  @override
  Future<List<MusicSong>> radio(
    MusicRadioKind kind, {
    MusicId? seed,
    MusicId? playlist,
    int limit = 30,
  }) async => _list(
    await _call('radio', {
      'kind': kind.name,
      'seed': seed?.value,
      'playlist': playlist?.value,
      'limit': limit,
    }),
  ).whereType<Map>().map(_song).toList();

  @override
  Future<Map<String, dynamic>> comments(
    MusicId song, {
    int limit = 20,
    int offset = 0,
  }) async => Map<String, dynamic>.from(
    await _call('comments', {
      'id': remoteId(song, MusicEntityKind.song),
      'limit': limit,
      'offset': offset,
    }),
  );

  @override
  Future<void> setCommentLiked(
    MusicId song,
    String commentId,
    bool liked,
  ) async {
    await _call('setCommentLiked', {
      'id': remoteId(song, MusicEntityKind.song),
      'commentId': commentId,
      'liked': liked,
    });
  }

  @override
  Future<Map<String, dynamic>> listenTogether(
    String operation, [
    Map<String, dynamic> args = const {},
  ]) async => Map<String, dynamic>.from(
    await _call('listenTogether', {'operation': operation, ...args}),
  );
}
