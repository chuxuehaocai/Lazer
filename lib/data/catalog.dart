import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import '../cache/disk_cache.dart';
import '../cache/media_cache.dart';
import '../gateway/gateway.dart';
import 'audio_quality.dart';
import 'billboard.dart';
import 'biliboard.dart';
import 'models.dart';
import 'catalog_details.dart';

/// Music returned by the gateway.
class HomeFeed {
  const HomeFeed({
    this.featured,
    this.recommended = const [],
    required this.featuredTracks,
    required this.quick,
    required this.playlists,
    required this.albums,
    this.editorialPlaylists = const <Playlist>[],
  });

  final Album? featured;
  final List<Playlist> recommended;
  final List<Track> featuredTracks;
  final List<Track> quick;
  final List<Playlist> playlists;
  final List<Album> albums;
  final List<Playlist> editorialPlaylists;

  bool get isEmpty =>
      recommended.isEmpty &&
      featured == null &&
      quick.isEmpty &&
      playlists.isEmpty &&
      albums.isEmpty &&
      editorialPlaylists.isEmpty;
}

class SearchResults {
  const SearchResults({
    this.tracks = const <Track>[],
    this.albums = const <Album>[],
    this.playlists = const <Playlist>[],
    this.artists = const <ArtistRef>[],
  });

  final List<Track> tracks;
  final List<Album> albums;
  final List<Playlist> playlists;

  /// Derived from the song hits: a query that matches songs also surfaces
  /// their artists, which is what the artists tab lists.
  final List<ArtistRef> artists;

  static const SearchResults empty = SearchResults();

  int get hits =>
      tracks.length + albums.length + playlists.length + artists.length;
}

/// A signed-in user's own collections, split the way the profile page shows
/// them: the personal liked-songs collection, playlists they created, and
/// playlists they subscribed to.
class UserCollections {
  const UserCollections({
    this.liked,
    this.created = const <Playlist>[],
    this.subscribed = const <Playlist>[],
  });

  /// The "喜欢的音乐" collection (NetEase `specialType = 5`), when present.
  final Playlist? liked;
  final List<Playlist> created;
  final List<Playlist> subscribed;

  static const UserCollections empty = UserCollections();
}

/// Gateway-backed catalogue. Failed requests never create fabricated music.
class Catalog {
  Catalog({
    NeteaseGateway? gateway,
    DiskCache? cache,
    BiliboardClient? charts,
    BillboardClient? billboard,
  }) : gateway = gateway ?? NeteaseGateway(),
       cache = cache ?? DiskCache.shared,
       charts = charts ?? BiliboardClient(),
       billboard = billboard ?? BillboardClient(),
       audioCache = AudioCache(disk: cache);

  final NeteaseGateway gateway;
  final DiskCache cache;
  final BiliboardClient charts;
  final BillboardClient billboard;
  final AudioCache audioCache;
  final _requests = <String, _PendingRequest>{};
  final Map<String, int> _epochs = <String, int>{};
  // Keys that a mutation invalidated but whose disk tombstone may not have
  // landed yet. Cache-first reads must skip them even during that window.
  final Set<String> _invalidatedKeys = <String>{};

  /// The hottest decoded snapshots, in front of the disk cache.
  ///
  /// Playlist tracks used to be re-read from disk and re-decoded on the UI
  /// isolate every time a playlist was opened, even while the snapshot was
  /// still fresh — a visible hitch on a long playlist. This small LRU keeps
  /// the decoded objects instead; invalidations remove the entry so a
  /// mutation is never masked by a warm copy.
  final LinkedHashMap<String, _MemorySnapshot> _memory =
      LinkedHashMap<String, _MemorySnapshot>();
  static const int _memoryLimit = 32;

  void _remember(String key, Object value, DateTime savedAt) {
    _memory
      ..remove(key)
      ..[key] = _MemorySnapshot(value, savedAt);
    while (_memory.length > _memoryLimit) {
      _memory.remove(_memory.keys.first);
    }
  }

  Future<void> _expire(String key) async {
    _memory.remove(key);
    _invalidatedKeys.add(key);
    // Bump the epoch so a request that started before this invalidation can
    // never satisfy the next read: a forced refresh must observe the mutation.
    _epochs[key] = (_epochs[key] ?? 0) + 1;
    await cache.expireJson(key);
  }

  // Private playlists and recommendations must not cross session boundaries.
  String get _scope {
    final cookie = gateway.sessionCookie;
    return cookie == null
        ? 'guest'
        : sha256.convert(utf8.encode(cookie)).toString();
  }

  // Versioned so collections cached before ownership was read from
  // `subscribed`/`creator` cannot keep every own playlist in the subscribed
  // shelf.
  String _collectionsKey(int uid) => 'collections:v2:$_scope:$uid';

  Future<T> _cached<T extends Object>(
    String key,
    Duration ttl,
    T Function(Map<String, dynamic>) decode,
    Map<String, dynamic> Function(T) encode,
    Future<T> Function() fetch,
  ) async {
    final int epoch = _epochs[key] ?? 0;
    final pending = _requests[key];
    if (pending != null && pending.epoch == epoch) {
      return await pending.future as T;
    }
    final remembered = _memory[key];
    if (remembered?.value is T && _fresh(remembered!.savedAt, ttl)) {
      _touch(key, remembered);
      return remembered.value as T;
    }
    final future = () async {
      // A warm but expired copy is already decoded. Reading and decoding the
      // same disk blob again costs a visible hitch on a long playlist, and
      // cache-first callers intentionally leave such a copy in memory.
      T? previous = remembered?.value is T ? remembered!.value as T : null;
      if (previous == null) {
        final saved = await cache.readJson(key);
        if (saved != null) {
          try {
            previous = decode(saved.data);
          } catch (_) {
            await cache.remove(CacheBucket.data, key, extension: 'json');
          }
          if (previous != null) {
            _remember(key, previous, saved.savedAt);
            // An invalidated key may still have a fresh-looking disk copy if
            // its tombstone write failed; never serve that as a hit.
            if (!_invalidatedKeys.contains(key) && saved.fresh(ttl)) {
              return previous;
            }
          }
        }
      }
      try {
        final result = await fetch();
        // A mutation can invalidate the key while the request is in flight;
        // its response predates the mutation, so it must not refill the cache.
        if ((_epochs[key] ?? 0) == epoch) {
          await cache.writeJson(key, encode(result));
          _remember(key, result, DateTime.now());
          _invalidatedKeys.remove(key);
        }
        return result;
      } catch (_) {
        _online = false;
        if (previous != null && (_epochs[key] ?? 0) == epoch) return previous;
        rethrow;
      }
    }();
    final entry = _PendingRequest(future, epoch);
    _requests[key] = entry;
    try {
      return await future;
    } finally {
      if (identical(_requests[key], entry)) _requests.remove(key);
    }
  }

  static bool _fresh(DateTime savedAt, Duration ttl) =>
      DateTime.now().difference(savedAt) < ttl;

  static bool _invalidated(DateTime savedAt) =>
      savedAt.millisecondsSinceEpoch == 0;

  void _touch(String key, _MemorySnapshot snapshot) {
    _memory
      ..remove(key)
      ..[key] = snapshot;
  }

  /// Reads a stored snapshot without contacting the service.
  ///
  /// Opening a playlist should paint the last known track list immediately;
  /// the caller can refresh it in the background afterwards. Unlike
  /// [_cached], an expired snapshot is returned as-is instead of blocking on
  /// the network, which is what made a cold or offline open feel uncached.
  Future<T?> _storedSnapshot<T extends Object>(
    String key,
    T Function(Map<String, dynamic>) decode,
  ) async {
    if (_invalidatedKeys.contains(key)) return null;
    final remembered = _memory[key];
    if (remembered?.value is T && !_invalidated(remembered!.savedAt)) {
      _touch(key, remembered);
      return remembered.value as T;
    }
    final saved = await cache.readJson(key);
    // An explicitly invalidated snapshot still serves as the offline fallback
    // for [_cached], but it must not paint the page before a fresh request.
    if (saved == null || saved.invalidated || _invalidatedKeys.contains(key)) {
      return null;
    }
    try {
      final value = decode(saved.data);
      _remember(key, value, saved.savedAt);
      return value;
    } catch (_) {
      await cache.remove(CacheBucket.data, key, extension: 'json');
      return null;
    }
  }

  /// The last stored track list for [playlistId], stale or not, or null when
  /// this playlist has never been opened in the current session scope.
  Future<List<Track>?> cachedPlaylistTracks(String playlistId) {
    if ((int.tryParse(playlistId) ?? 0) <= 0) {
      return Future<List<Track>?>.value(null);
    }
    return _storedSnapshot<List<Track>>(
      'playlist-v2:$_scope:$playlistId',
      (json) => _decodeTracks(json['tracks']),
    );
  }

  /// The last stored account collections, used to paint 资料库 on the first
  /// frame after a cold start while the live request runs in the background.
  Future<UserCollections?> cachedUserCollections(int uid) => uid <= 0
      ? Future<UserCollections?>.value(null)
      : _storedSnapshot<UserCollections>(
          _collectionsKey(uid),
          _decodeCollections,
        );

  Future<void> invalidatePlaylist(String id) =>
      _expire('playlist-v2:$_scope:$id');

  Future<void> invalidateCollections(int uid) => _expire(_collectionsKey(uid));

  Future<List<Track>> refreshPlaylist(String id) async {
    await invalidatePlaylist(id);
    return playlistTracks(id);
  }

  Future<void> invalidateHome({int? userId}) =>
      _expire('home:$_scope:${userId ?? 0}');

  Future<void> invalidateLyrics(String trackId) => _expire('lyrics:$trackId');

  /// Drops every discovery-chart snapshot, in memory and on disk.
  Future<void> invalidateDiscoveryCharts() async {
    await Future.wait(<Future<void>>[
      _expire('external-billboard-v1'),
      _expire('external-biliboard-v1'),
      _expire('netease-mirror-charts-v2'),
    ]);
  }

  /// Whether the last gateway interaction succeeded.
  bool get online => _online;
  bool _online = false;
  String? _homeError;
  String? get homeError => _homeError;

  HomeFeed? _home;

  /// The loaded home feed, or null until [loadHome] has run.
  HomeFeed? get home => _home;

  Future<HomeFeed?> loadHome({int? userId}) async {
    _homeError = null;
    try {
      _home = await _cached(
        'home:$_scope:${userId ?? 0}',
        const Duration(minutes: 20),
        _decodeHome,
        _encodeHome,
        () async {
          final feed = await _loadHome(userId: userId);
          if (feed == null) throw StateError('Home unavailable');
          return feed;
        },
      );
      _homeError = null;
      return _home;
    } catch (_) {
      _homeError = '曲库加载失败，请检查网络后重试。'; // i18n:key
      return _home = null;
    }
  }

  Future<HomeFeed?> _loadHome({int? userId}) async {
    _homeError = null;
    Object? firstFailure;
    Future<T?> optional<T>(Future<T> request) async {
      try {
        return await request;
      } catch (error) {
        firstFailure ??= error;
        return null;
      }
    }

    final signedIn = userId != null && userId > 0;
    final results = await Future.wait<Object?>(<Future<Object?>>[
      optional(gateway.topPlaylists(limit: 12)),
      optional(
        signedIn
            ? gateway.userPlaylists(userId, limit: 30)
            : Future<List<GatewayPlaylist>>.value(const <GatewayPlaylist>[]),
      ),
      optional(
        signedIn
            ? gateway.dailyRecommendedSongs()
            : Future<List<GatewaySong>>.value(const <GatewaySong>[]),
      ),
      optional(
        signedIn
            ? gateway.dailyRecommendedPlaylists()
            : Future<List<GatewayPlaylist>>.value(const <GatewayPlaylist>[]),
      ),
      optional(gateway.personalizedPlaylists()),
      optional(
        signedIn
            ? gateway.personalizedNewSongs(limit: 24)
            : Future<List<GatewaySong>>.value(const <GatewaySong>[]),
      ),
      // NetEase's main editorial account. Creator identity, rather than the
      // recommendation endpoint, keeps this shelf editorially sourced.
      optional(gateway.userPlaylists(1463586082, limit: 24)),
    ]);
    final top =
        results[0] as List<GatewayPlaylist>? ?? const <GatewayPlaylist>[];
    final userPlaylists =
        results[1] as List<GatewayPlaylist>? ?? const <GatewayPlaylist>[];
    final dailySongs =
        results[2] as List<GatewaySong>? ?? const <GatewaySong>[];
    final dailyPlaylists =
        results[3] as List<GatewayPlaylist>? ?? const <GatewayPlaylist>[];
    final personalized =
        results[4] as List<GatewayPlaylist>? ?? const <GatewayPlaylist>[];
    final newSongs = results[5] as List<GatewaySong>? ?? const <GatewaySong>[];
    final editorial =
        results[6] as List<GatewayPlaylist>? ?? const <GatewayPlaylist>[];
    final recommended = <int, GatewayPlaylist>{};
    for (final playlist in [...dailyPlaylists, ...personalized]) {
      recommended.putIfAbsent(playlist.id, () => playlist);
    }

    List<Track> quick = dailySongs.take(8).map(trackFromSong).toList();
    if (quick.isEmpty && top.isNotEmpty) {
      try {
        quick = (await playlistTracks(
          top.first.id.toString(),
        )).take(8).toList();
      } catch (error) {
        firstFailure ??= error;
      }
    }

    final uniquePlaylists = <int, GatewayPlaylist>{};
    for (final playlist in <GatewayPlaylist>[
      ...userPlaylists,
      ...recommended.values,
      ...top,
    ]) {
      if (playlist.id > 0) {
        uniquePlaylists.putIfAbsent(playlist.id, () => playlist);
      }
    }

    final albumSongs = <int, GatewaySong>{};
    for (final song in newSongs) {
      if (song.albumId > 0) albumSongs.putIfAbsent(song.albumId, () => song);
    }
    Album? featured;
    if (dailySongs.isNotEmpty && dailySongs.first.albumId > 0) {
      featured = albumFromSong(dailySongs.first);
    } else if (quick.isNotEmpty && quick.first.albumId > 0) {
      final track = quick.first;
      featured = Album(
        id: track.albumId.toString(),
        title: track.album,
        artist: track.artist,
        year: '',
        coverSeed: track.coverSeed,
        note: '',
        coverUrl: track.coverUrl,
      );
    }

    final feed = HomeFeed(
      recommended: (recommended.isEmpty ? top : recommended.values)
          .take(8)
          .map(playlistFromGateway)
          .toList(),
      featured: featured,
      featuredTracks: dailySongs
          .where((song) => song.albumId == dailySongs.firstOrNull?.albumId)
          .take(8)
          .map(trackFromSong)
          .toList(),
      quick: quick,
      playlists: uniquePlaylists.values
          .take(12)
          .map(playlistFromGateway)
          .toList(),
      albums: albumSongs.values.take(12).map(albumFromSong).toList(),
      editorialPlaylists: editorial
          .where((playlist) => playlist.specialType != 5)
          .take(12)
          .map(playlistFromGateway)
          .toList(),
    );
    _online = firstFailure == null || !feed.isEmpty;
    if (feed.isEmpty && firstFailure != null) {
      _homeError = '曲库加载失败，请检查网络后重试。'; // i18n:key
      _home = null;
    } else {
      if (feed.isEmpty) _homeError = '当前没有可展示的音乐。'; // i18n:key
      _home = feed;
    }
    return _home;
  }

  /// Search the live catalogue. Errors propagate to the search view.
  Future<SearchResults> search(String rawQuery) async {
    final String query = rawQuery.trim();
    if (query.isEmpty) return SearchResults.empty;
    try {
      final List<Object?> results = await Future.wait<Object?>(
        <Future<Object?>>[
          // cloudsearch carries album.picUrl; the legacy /search payload only
          // exposes a picId, which leaves track covers unrenderable.
          gateway.search(query, limit: 20, useCloudSearch: true),
          gateway.searchAlbums(query, limit: 10),
          gateway.searchPlaylists(query, limit: 10),
          gateway.searchArtists(query, limit: 10),
        ],
      );
      final List<GatewaySong> songs =
          results[0] as List<GatewaySong>? ?? const <GatewaySong>[];
      final List<GatewayAlbum> albumHits =
          results[1] as List<GatewayAlbum>? ?? const <GatewayAlbum>[];
      final List<GatewayArtist> artistHits =
          results[3] as List<GatewayArtist>? ?? const <GatewayArtist>[];
      final List<GatewayPlaylist> playlistHits =
          results[2] as List<GatewayPlaylist>? ?? const <GatewayPlaylist>[];
      _online = true;
      final List<Track> tracks = songs.map<Track>(trackFromSong).toList();
      final Map<int, ArtistRef> artistsById = <int, ArtistRef>{};
      for (final Track track in tracks) {
        for (final ArtistRef artist in track.artists) {
          if (artist.id > 0) artistsById[artist.id] = artist;
        }
      }
      return SearchResults(
        tracks: tracks,
        albums: albumHits.map<Album>(albumFromGateway).toList(),
        playlists: playlistHits.map<Playlist>(playlistFromGateway).toList(),
        artists: <ArtistRef>[
          for (final GatewayArtist artist in artistHits)
            ArtistRef(
              id: artist.id,
              name: artist.name,
              coverUrl: artist.coverUrl,
            ),
          ...artistsById.values.where(
            (ArtistRef artist) =>
                !artistHits.any((GatewayArtist hit) => hit.id == artist.id),
          ),
        ],
      );
    } catch (_) {
      _online = false;
      rethrow;
    }
  }

  Future<List<Track>> personalFmTracks() async =>
      (await gateway.personalFm()).map(trackFromSong).toList();

  /// External rankings load independently from the main discovery feed. A
  /// slow chart host must never hold the entire home page hostage.
  Future<List<MusicChart>> discoveryCharts() async {
    // Cache providers separately. If one host has a transient outage, a
    // successful sibling must not turn that partial shelf into a fresh
    // two-hour cache entry that prevents the failed provider from retrying.
    final loaded = await Future.wait<List<MusicChart>>(
      <Future<List<MusicChart>>>[
        _cached(
          'external-billboard-v1',
          const Duration(hours: 2),
          _decodeCharts,
          _encodeCharts,
          () async {
            final chart = await billboard.latestChart();
            if (chart == null) throw StateError('Billboard chart is empty.');
            return <MusicChart>[chart];
          },
        ).catchError((_) => const <MusicChart>[]),
        _cached(
          'external-biliboard-v1',
          const Duration(hours: 2),
          _decodeCharts,
          _encodeCharts,
          charts.latestCharts,
        ).catchError((_) => const <MusicChart>[]),
      ],
    );
    return <MusicChart>[...loaded.first, ...loaded.last];
  }

  static List<MusicChart> _decodeCharts(Map<String, dynamic> json) =>
      (json['charts'] as List? ?? const <Object>[])
          .whereType<Map<String, dynamic>>()
          .map(MusicChart.fromJson)
          .toList();

  static Map<String, dynamic> _encodeCharts(List<MusicChart> value) =>
      <String, Object?>{
        'charts': value.map((chart) => chart.toJson()).toList(),
      };

  /// NetEase mirrors a handful of established charts and, unlike a scraped
  /// ranking, gives us immediately playable song ids. These are current-only:
  /// the API does not expose a trustworthy issue archive.
  Future<List<MusicChart>> neteaseMirrorCharts() => _cached(
    'netease-mirror-charts-v2',
    const Duration(minutes: 30),
    (json) => (json['charts'] as List? ?? const <Object>[])
        .whereType<Map<String, dynamic>>()
        .map(MusicChart.fromJson)
        .toList(),
    (value) => <String, Object?>{
      'charts': value.map((chart) => chart.toJson()).toList(),
    },
    () async {
      final playlists = await gateway.chartPlaylists();
      final selected = playlists
          .where((playlist) {
            final name = playlist.name.toLowerCase();
            return name.contains('uk排行榜') ||
                name.contains('beatport') ||
                name.contains('oricon') ||
                name.contains('nrj');
          })
          .take(5);
      final loaded = await Future.wait<MusicChart?>([
        for (final playlist in selected)
          _neteaseChart(playlist).catchError((_) => null),
      ]);
      return loaded.whereType<MusicChart>().toList();
    },
  );

  Future<MusicChart?> _neteaseChart(GatewayPlaylist playlist) async {
    // Keep the complete source ranking. Several mirrored charts are Top 100
    // lists; the old 20-song cap made every board look artificially identical.
    final body = await gateway.playlistTracks(playlist.id);
    final rawSongs = body['songs'];
    if (rawSongs is! List) return null;
    final songs = rawSongs
        .whereType<Map<String, dynamic>>()
        .map((item) {
          final nested = item['song'] ?? item['data'];
          return GatewaySong.fromJson(
            nested is Map<String, dynamic> ? nested : item,
          );
        })
        .where((song) => song.id > 0 && song.title.isNotEmpty)
        .toList();
    if (songs.isEmpty) return null;
    return MusicChart(
      id: 'netease:${playlist.id}',
      title: playlist.name,
      source: '网易云镜像',
      issueLabel: '当前榜',
      entries: <ChartEntry>[
        for (var index = 0; index < songs.length; index++)
          ChartEntry(
            rank: index + 1,
            title: songs[index].title,
            artist: songs[index].artistLine,
            coverUrl: songs[index].coverUrl,
            track: trackFromSong(songs[index]),
          ),
      ],
      accent: 0xFFE94B64,
      providerKey: 'netease:${playlist.id}',
      logoUrl: playlist.coverUrl,
    );
  }

  Future<MusicChart> chartIssue(MusicChart chart, ChartIssue issue) => _cached(
    'chart-issue-v2:${chart.providerKey}:${issue.id}',
    const Duration(hours: 6),
    MusicChart.fromJson,
    (value) => value.toJson(),
    () => switch (chart.providerKey) {
      'billboard:hot-100' => billboard.chartForIssue(chart, issue),
      _ => charts.chartForIssue(chart, issue),
    },
  );

  /// The 心动 mode queue.
  ///
  /// The official app seeds the intelligence list with the song that is
  /// playing, asks for a batch, and keeps doing that as the queue advances;
  /// the station loader in [AppState] dedupes and appends those batches. The
  /// liked playlist only supplies the seed when nothing is playing yet and
  /// acts as the fallback when the service has no recommendation.
  Future<List<Track>> heartModeTracks(
    Playlist liked, {
    int? seedSongId,
    int count = 30,
  }) async {
    final int playlistId = int.tryParse(liked.id) ?? 0;
    if (playlistId <= 0) return const <Track>[];
    // The liked list is only needed to pick a seed when nothing is playing
    // yet; a refill seeded by the current song must not re-download it.
    List<Track> likedTracks = const <Track>[];
    if (seedSongId == null) {
      likedTracks = await playlistTracks(liked.id);
      if (likedTracks.isEmpty) return const <Track>[];
    }
    final int songId = seedSongId ?? int.tryParse(likedTracks.first.id) ?? 0;
    if (songId <= 0) return likedTracks;
    final generated = await gateway.intelligenceList(
      songId: songId,
      playlistId: playlistId,
      count: count,
    );
    if (generated.isNotEmpty) return generated.map(trackFromSong).toList();
    if (likedTracks.isEmpty) {
      likedTracks = await playlistTracks(liked.id);
    }
    return likedTracks;
  }

  /// The listener's play record, joined with each song's duration.
  ///
  /// Cached for five minutes: opening 听歌排行 used to force a network round
  /// trip (and a full upload flush) on every visit, which stalled the library.
  Future<List<TrackPlayStat>> playStats(int uid, {bool force = false}) async {
    if (uid <= 0) return const <TrackPlayStat>[];
    final key = 'play-stats:$_scope:$uid';
    if (force) await _expire(key);
    return _cached(
      key,
      const Duration(minutes: 5),
      _decodePlayStats,
      (stats) => <String, dynamic>{
        'stats': <Map<String, dynamic>>[
          for (final stat in stats) stat.toJson(),
        ],
      },
      () async {
        final records = await gateway.playRecord(uid);
        return <TrackPlayStat>[
          for (final record in records)
            TrackPlayStat(
              songId: '${record.song.id}',
              playCount: record.playCount,
              duration: record.song.duration,
            ),
        ];
      },
    );
  }

  Future<void> invalidatePlayStats(int uid) =>
      _expire('play-stats:$_scope:$uid');

  static List<TrackPlayStat> _decodePlayStats(Map<String, dynamic> json) {
    final raw = json['stats'];
    if (raw is! List) return const <TrackPlayStat>[];
    return <TrackPlayStat>[
      for (final row in raw)
        if (row is Map<String, dynamic>) TrackPlayStat.fromJson(row),
    ];
  }

  /// Records the start of a play in 最近播放.
  Future<void> reportPlayStart({required int songId, required int sourceId}) =>
      gateway.reportPlayStart(songId: songId, sourceId: sourceId);

  /// Uploads one qualified play to the account's cloud play record.
  Future<void> reportPlayback({
    required int songId,
    required int playedSeconds,
    int sourceId = 0,
  }) => gateway.reportPlayback(
    songId: songId,
    playedSeconds: playedSeconds,
    sourceId: sourceId,
  );

  // -- listen together -----------------------------------------------------

  Future<Map<String, dynamic>> listenTogetherCreateRoom() =>
      gateway.listenTogetherCreateRoom();

  Future<Map<String, dynamic>> listenTogetherAccept(
    String roomId,
    int inviterId,
  ) => gateway.listenTogetherAccept(roomId, inviterId);

  Future<Map<String, dynamic>> listenTogetherRoomCheck(String roomId) =>
      gateway.listenTogetherRoomCheck(roomId);

  Future<Map<String, dynamic>> listenTogetherEnd(String roomId) =>
      gateway.listenTogetherEnd(roomId);

  Future<Map<String, dynamic>> listenTogetherHeartbeat(
    String roomId,
    int songId,
    String playStatus,
    int progress,
  ) => gateway.listenTogetherHeartbeat(roomId, songId, playStatus, progress);

  Future<Map<String, dynamic>> listenTogetherPlayCommand(
    String roomId,
    Map<String, Object?> commandInfo,
  ) => gateway.listenTogetherPlayCommand(roomId, commandInfo);

  Future<List<Track>> artistStationTracks(ArtistRef seed) async {
    if (seed.id <= 0) return const <Track>[];
    final similar = await gateway.similarArtists(seed.id);
    final artistIds = <int>[
      seed.id,
      ...similar.take(4).map((artist) => artist.id),
    ];
    final groups = await Future.wait<List<GatewaySong>>(
      artistIds.map(
        (id) =>
            gateway.artistTopSongs(id).catchError((_) => const <GatewaySong>[]),
      ),
    );
    final List<Track> station = <Track>[];
    final Set<int> seen = <int>{};
    for (var row = 0; row < 8; row++) {
      for (final songs in groups) {
        if (row >= songs.length) continue;
        final song = songs[row];
        if (seen.add(song.id)) station.add(trackFromSong(song));
      }
    }
    return station;
  }

  Future<MusicChart> prepareChart(
    MusicChart chart, {
    bool force = false,
  }) async {
    var prepared = chart;
    if (chart.providerKey == 'billboard:hot-100') {
      try {
        prepared = await _cached(
          'billboard-history-v1:${chart.id}',
          const Duration(hours: 12),
          MusicChart.fromJson,
          (value) => value.toJson(),
          () => billboard.withHistory(chart),
        );
      } catch (_) {
        // Playback matching still works when the optional history host is down.
      }
    }
    return matchChart(prepared, force: force);
  }

  Future<MusicChart> matchChart(MusicChart chart, {bool force = false}) async {
    final List<ChartEntry> entries = <ChartEntry>[];
    final relaxedTitleMatch = (chart.providerKey ?? '').startsWith(
      'biliboard:',
    );
    for (var start = 0; start < chart.entries.length; start += 8) {
      final int end = math.min(start + 8, chart.entries.length);
      entries.addAll(
        await Future.wait(
          chart.entries
              .sublist(start, end)
              .map(
                (entry) => _matchChartEntry(
                  entry,
                  relaxedTitleMatch: relaxedTitleMatch,
                  force: force,
                ),
              ),
        ),
      );
    }
    return MusicChart(
      id: chart.id,
      title: chart.title,
      source: chart.source,
      issueLabel: chart.issueLabel,
      entries: entries,
      accent: chart.accent,
      providerKey: chart.providerKey,
      logoUrl: chart.logoUrl,
      issues: chart.issues,
      selectedIssueId: chart.selectedIssueId,
    );
  }

  /// How long a resolved row keeps its NetEase id. Song ids do not move.
  static const Duration _chartMatchTtl = Duration(days: 14);

  /// A row the search host does not know is remembered only briefly. A board
  /// with dozens of misses used to re-search every one of them on each visit,
  /// which is what pushed the search host into rejecting the whole board.
  static const Duration _chartMatchMissTtl = Duration(minutes: 15);

  Future<ChartEntry> _matchChartEntry(
    ChartEntry entry, {
    required bool relaxedTitleMatch,
    required bool force,
  }) async {
    final String identity = sha256
        .convert(
          utf8.encode(
            '${relaxedTitleMatch ? 'relaxed' : 'strict'}|'
            '${_normaliseMusicText(entry.title)}|'
            '${_normaliseMusicText(entry.translatedTitle ?? '')}|'
            '${_normaliseMusicText(entry.artist)}',
          ),
        )
        .toString();
    final String matchKey = 'chart-entry-match-v2:$identity';
    final Track? remembered = await _rememberedChartTrack(matchKey);
    if (remembered != null) return entry.copyWith(track: remembered);
    if (!force && await _recentlyMissed(identity)) return entry;
    try {
      final ChartEntry resolved = await _resolveChartEntry(
        entry,
        relaxedTitleMatch: relaxedTitleMatch,
      );
      await cache.writeJson(matchKey, resolved.toJson());
      return resolved;
    } on _NoChartMatch {
      await cache.writeJson('chart-entry-miss-v1:$identity', <String, dynamic>{
        'title': entry.title,
      });
      return entry;
    } catch (_) {
      // A search that failed for transport reasons stays retryable: writing a
      // negative entry here is what turned one bad minute into days of a board
      // with no playable rows at all.
      return entry;
    }
  }

  Future<Track?> _rememberedChartTrack(String key) async {
    final CachedJson? saved = await cache.readJson(key);
    if (saved == null || !saved.fresh(_chartMatchTtl)) return null;
    try {
      return ChartEntry.fromJson(saved.data).track;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _recentlyMissed(String identity) async {
    final CachedJson? saved = await cache.readJson(
      'chart-entry-miss-v1:$identity',
    );
    return saved != null && saved.fresh(_chartMatchMissTtl);
  }

  Future<ChartEntry> _resolveChartEntry(
    ChartEntry entry, {
    required bool relaxedTitleMatch,
  }) async {
    Track? match;
    final String sourceArtist = _normaliseMusicText(entry.artist);
    final String sourceTitle = _normaliseMusicText(entry.title);
    final requiredScore = relaxedTitleMatch
        ? .6
        : sourceArtist.isEmpty
        ? .65
        : .78;
    final String query = <String>[
      entry.title,
      entry.artist,
    ].where((part) => part.trim().isNotEmpty).join(' ');
    double bestScore = 0;

    Future<void> search(String value) async {
      List<GatewaySong> candidates = const <GatewaySong>[];
      try {
        candidates = await gateway
            .search(value, limit: 8, useCloudSearch: true)
            .timeout(const Duration(seconds: 5));
      } catch (_) {
        // The authenticated cloud-search route is intermittently rejected;
        // the classic search route remains usable on the same session.
      }
      if (candidates.isEmpty) {
        candidates = await gateway
            .search(value, limit: 8)
            .timeout(const Duration(seconds: 5));
      }
      for (final candidate in candidates) {
        final double score = _chartMatchScore(entry, candidate);
        if (score > bestScore) {
          bestScore = score;
          match = trackFromSong(candidate);
        }
      }
    }

    await search(query);
    final titleQuery = entry.title.trim();
    if (bestScore < requiredScore &&
        titleQuery.isNotEmpty &&
        titleQuery != query) {
      await search(titleQuery);
    }
    // Biliboard producer aliases often differ from the artist credit used by
    // streaming services. An exact canonical/translated title is sufficient
    // there; partial-title matches remain rejected.
    if (bestScore < requiredScore ||
        (sourceArtist.isEmpty && sourceTitle.runes.length < 4) ||
        match == null) {
      throw const _NoChartMatch();
    }
    return entry.copyWith(track: match);
  }

  static double _chartMatchScore(ChartEntry entry, GatewaySong song) {
    final String title = _normaliseMusicText(entry.title);
    final String translated = _normaliseMusicText(entry.translatedTitle ?? '');
    final String candidateTitle = _normaliseMusicText(song.title);
    double score = 0;
    if (title.isNotEmpty && candidateTitle == title) {
      score += .65;
    } else if (translated.isNotEmpty && candidateTitle == translated) {
      score += .6;
    } else if (title.length >= 3 &&
        (candidateTitle.contains(title) || title.contains(candidateTitle))) {
      score += .5;
    }
    final String sourceArtist = _normaliseMusicText(entry.artist);
    final String candidateArtist = _normaliseMusicText(song.artistLine);
    if (sourceArtist.isNotEmpty && candidateArtist.isNotEmpty) {
      if (sourceArtist == candidateArtist) {
        score += .35;
      } else if (sourceArtist.length >= 3 &&
          (candidateArtist.contains(sourceArtist) ||
              sourceArtist.contains(candidateArtist))) {
        score += .3;
      } else {
        final sourceParts = sourceArtist.split(' ').where((p) => p.length > 1);
        if (sourceParts.any(candidateArtist.contains)) score += .22;
      }
    }
    return score;
  }

  static String _normaliseMusicText(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[àáâãäåāăą]'), 'a')
      .replaceAll('æ', 'ae')
      .replaceAll(RegExp(r'[çćč]'), 'c')
      .replaceAll(RegExp(r'[ďđ]'), 'd')
      .replaceAll(RegExp(r'[èéêëēėę]'), 'e')
      .replaceAll(RegExp(r'[ìíîïīį]'), 'i')
      .replaceAll(RegExp(r'[ł]'), 'l')
      .replaceAll(RegExp(r'[ñńň]'), 'n')
      .replaceAll(RegExp(r'[òóôõöøōő]'), 'o')
      .replaceAll('œ', 'oe')
      .replaceAll(RegExp(r'[ř]'), 'r')
      .replaceAll(RegExp(r'[śšş]'), 's')
      .replaceAll('ß', 'ss')
      .replaceAll(RegExp(r'[ť]'), 't')
      .replaceAll(RegExp(r'[ùúûüūůű]'), 'u')
      .replaceAll(RegExp(r'[ýÿ]'), 'y')
      .replaceAll(RegExp(r'[źžż]'), 'z')
      .replaceAll(RegExp(r'\b(featuring|feat|ft|with)\.?\b.*$'), '')
      .replaceAll(RegExp(r'[^a-z0-9぀-ヿ㐀-鿿]+'), ' ')
      .trim();

  /// Reuses recent snapshots; expired snapshots remain available offline.
  Future<List<Track>> playlistTracks(String playlistId) => _cached(
    'playlist-v2:$_scope:$playlistId',
    const Duration(minutes: 10),
    (json) => _decodeTracks(json['tracks']),
    (tracks) => {'tracks': tracks.map((track) => track.toJson()).toList()},
    () => _playlistTracks(playlistId),
  );

  /// Fetches the complete playlist in stable 500-song pages.
  Future<List<Track>> _playlistTracks(String playlistId) async {
    final int id = int.tryParse(playlistId) ?? 0;
    if (id <= 0) throw ArgumentError.value(playlistId, 'playlistId');
    try {
      final Map<String, dynamic> body = await gateway.playlistDetail(id);
      final dynamic rawPlaylist = body['playlist'];
      if (rawPlaylist is! Map<String, dynamic>) {
        throw StateError('歌单数据不可用。'); // i18n:key
      }
      final GatewayPlaylist playlist = GatewayPlaylist.fromJson(rawPlaylist);
      final List<GatewaySong> ordered = <GatewaySong>[];
      if (playlist.trackIds.isNotEmpty) {
        // Large playlists are two or more song-detail pages; the round trips
        // are independent, so overlap them. A thousand-song list used to wait
        // for every page in turn even though each one is a separate request.
        final List<int> ids = playlist.trackIds;
        final int pages = (ids.length / 500).ceil();
        final List<List<GatewaySong>?> details =
            List<List<GatewaySong>?>.filled(pages, null);
        int next = 0;
        Future<void> worker() async {
          while (true) {
            final int page = next++;
            if (page >= pages) return;
            final int offset = page * 500;
            final int end = math.min(offset + 500, ids.length);
            details[page] = await gateway.songDetails(ids.sublist(offset, end));
          }
        }

        await Future.wait(<Future<void>>[
          for (var i = 0; i < math.min(4, pages); i++) worker(),
        ]);
        for (final List<GatewaySong>? page in details) {
          if (page != null) ordered.addAll(page);
        }
      }
      if (playlist.trackIds.isEmpty ||
          ordered.any((song) => song.title.isEmpty || song.artists.isEmpty)) {
        // Some editorial/recommendation playlists omit trackIds from detail.
        // The dedicated paged route also repairs incomplete song/detail rows.
        final int expected = math.max(
          1,
          math.max(playlist.trackCount, playlist.trackIds.length),
        );
        final List<GatewaySong> complete = <GatewaySong>[];
        // Fetch a handful of pages at a time, in order. Waiting for every
        // page of a long list before showing anything made a 5 000-song
        // playlist open in ten sequential round trips.
        for (int start = 0; start < expected; start += 500 * 3) {
          final List<int> offsets = <int>[
            for (
              int offset = start;
              offset < expected && offset < start + 500 * 3;
              offset += 500
            )
              offset,
          ];
          final List<Map<String, dynamic>> batch =
              await Future.wait(<Future<Map<String, dynamic>>>[
                for (final int offset in offsets)
                  gateway.playlistTracks(id, limit: 500, offset: offset),
              ]);
          var shortPage = false;
          for (final Map<String, dynamic> page in batch) {
            final rawSongs = page['songs'];
            final songs = rawSongs is List
                ? rawSongs
                      .whereType<Map<String, dynamic>>()
                      .map((item) {
                        final nested = item['song'] ?? item['data'];
                        return GatewaySong.fromJson(
                          nested is Map<String, dynamic> ? nested : item,
                        );
                      })
                      .where((song) => song.id > 0)
                      .toList()
                : const <GatewaySong>[];
            complete.addAll(songs);
            if (songs.length < 500) {
              shortPage = true;
              break;
            }
          }
          if (shortPage) break;
        }
        if (complete.isNotEmpty) {
          ordered
            ..clear()
            ..addAll(complete);
        }
      }
      _online = true;
      return ordered.map(trackFromSong).toList();
    } catch (_) {
      _online = false;
      rethrow;
    }
  }

  /// The signed-in user's own collections: liked songs, created playlists,
  /// subscribed playlists. Errors propagate to the profile view.
  Future<UserCollections> userCollections(int uid) => uid <= 0
      ? Future.value(UserCollections.empty)
      : _cached(
          _collectionsKey(uid),
          const Duration(minutes: 5),
          _decodeCollections,
          _encodeCollections,
          () => _userCollections(uid),
        );

  Future<UserCollections> _userCollections(int uid) async {
    if (uid <= 0) return UserCollections.empty;
    try {
      final List<GatewayPlaylist> raw = await gateway.userPlaylists(
        uid,
        limit: 1000,
      );
      _online = true;
      Playlist? liked;
      final List<Playlist> created = <Playlist>[];
      final List<Playlist> subscribed = <Playlist>[];
      for (final GatewayPlaylist p in raw) {
        final Playlist playlist = playlistFromGateway(p);
        // `/user/playlist` does not send `created`; own playlists have
        // `subscribed: false` and the account's id in `creator.userId`.
        final bool mine =
            p.created || p.creatorId == uid || p.subscribed == false;
        // The personal liked collection also shows up as an own playlist;
        // pull it out so the profile can label and count it on its own
        // (mirrors the reference: specialType 5, name fallback for legacy
        // payloads).
        if (p.specialType == 5 || (mine && p.name.endsWith('喜欢的音乐'))) {
          liked ??= playlist;
        } else if (mine) {
          created.add(playlist);
        } else {
          subscribed.add(playlist);
        }
      }
      return UserCollections(
        liked: liked,
        created: created,
        subscribed: subscribed,
      );
    } catch (_) {
      _online = false;
      rethrow;
    }
  }

  Future<List<Track>> albumTracks(int albumId) async {
    return (await albumDetails(albumId)).tracks;
  }

  Future<AlbumDetails> albumDetails(int albumId, {bool force = false}) async {
    if (albumId <= 0) throw ArgumentError.value(albumId, 'albumId');
    final key = 'album-detail:$albumId';
    if (force) await _expire(key);
    return _cached(
      key,
      const Duration(hours: 1),
      AlbumDetails.fromJson,
      (value) => value.toJson(),
      () async {
        final Map<String, dynamic> body = await gateway.albumDetailRaw(albumId);
        final rawAlbum = body['album'];
        if (rawAlbum is! Map<String, dynamic>) {
          throw StateError('Album metadata unavailable');
        }
        final dynamic songs = body['songs'];
        final List<GatewaySong> parsed = songs is List
            ? songs
                  .whereType<Map<String, dynamic>>()
                  .map<GatewaySong>(GatewaySong.fromJson)
                  .where((GatewaySong song) => song.id > 0)
                  .toList()
            : const <GatewaySong>[];
        _online = true;
        return AlbumDetails(
          album: albumFromGateway(GatewayAlbum.fromJson(rawAlbum)),
          tracks: parsed.map<Track>(trackFromSong).toList(),
          description: rawAlbum['description'] as String? ?? '',
          company: rawAlbum['company'] as String? ?? '',
          publishTime: (rawAlbum['publishTime'] as num?)?.toInt(),
        );
      },
    );
  }

  Future<ArtistDetails> artistDetails(
    ArtistRef seed, {
    bool force = false,
  }) async {
    if (seed.id <= 0) throw ArgumentError.value(seed.id, 'artistId');
    final key = 'artist-detail:${seed.id}';
    if (force) await _expire(key);
    return _cached(
      key,
      const Duration(minutes: 30),
      ArtistDetails.fromJson,
      (value) => value.toJson(),
      () async {
        final results = await Future.wait<Object>([
          gateway.artistTopSongs(seed.id),
          gateway.artistDetail(seed.id).catchError((_) => <String, dynamic>{}),
        ]);
        final tracks = (results[0] as List<GatewaySong>)
            .where((song) => song.id > 0)
            .map(trackFromSong)
            .toList();
        final payload = results[1] as Map<String, dynamic>;
        final data = payload['data'];
        final raw = data is Map<String, dynamic>
            ? data['artist']
            : payload['artist'];
        final metadata = raw is Map<String, dynamic>
            ? raw
            : <String, dynamic>{};
        final artist = GatewayArtist.fromJson(metadata);
        _online = true;
        return ArtistDetails(
          artist: ArtistRef(
            id: seed.id,
            name: artist.name.isEmpty ? seed.name : artist.name,
            coverUrl: artist.coverUrl ?? seed.coverUrl,
          ),
          tracks: tracks,
          description: metadata['briefDesc'] as String? ?? '',
          musicCount: (metadata['musicSize'] as num?)?.toInt() ?? 0,
          albumCount: (metadata['albumSize'] as num?)?.toInt() ?? 0,
        );
      },
    );
  }

  Future<ArtistAlbumPage> artistAlbumPage(
    int id, {
    int offset = 0,
    bool force = false,
  }) async {
    if (id <= 0 || offset < 0) throw ArgumentError('Invalid artist album page');
    final key = 'artist-albums:$id:$offset';
    if (force) await _expire(key);
    return _cached(
      key,
      const Duration(minutes: 15),
      ArtistAlbumPage.fromJson,
      (value) => value.toJson(),
      () async {
        final payload = await gateway.artistAlbums(id, offset: offset);
        final raw = payload['hotAlbums'];
        final albums = raw is List
            ? [
                for (final album in raw)
                  if (album is Map<String, dynamic>)
                    albumFromGateway(GatewayAlbum.fromJson(album)),
              ]
            : <Album>[];
        _online = true;
        return ArtistAlbumPage(
          albums: albums
              .where((album) => (int.tryParse(album.id) ?? 0) > 0)
              .toList(),
          more: payload['more'] == true && albums.isNotEmpty,
          receivedCount: raw is List ? raw.length : 0,
        );
      },
    );
  }

  Future<List<Track>> artistSongs(int id, {bool force = false}) async {
    if (id <= 0) throw ArgumentError.value(id, 'artistId');
    final key = 'artist-songs:$id';
    if (force) await _expire(key);
    return _cached(
      key,
      const Duration(minutes: 30),
      (json) => _decodeTracks(json['tracks']),
      (tracks) => <String, dynamic>{
        'tracks': tracks.map((track) => track.toJson()).toList(),
      },
      () async {
        const int limit = 100;
        var offset = 0;
        var more = true;
        final List<Track> tracks = <Track>[];
        final Set<String> ids = <String>{};
        while (more) {
          final payload = await gateway.artistSongs(
            id,
            limit: limit,
            offset: offset,
          );
          final dynamic raw = payload['songs'];
          final List<dynamic> page = raw is List ? raw : const <dynamic>[];
          for (final item in page.whereType<Map<String, dynamic>>()) {
            final song = GatewaySong.fromJson(item);
            if (song.id > 0) {
              final track = trackFromSong(song);
              if (ids.add(track.id)) tracks.add(track);
            }
          }
          offset += page.length;
          more = payload['more'] == true && page.isNotEmpty;
        }
        _online = true;
        return tracks;
      },
    );
  }

  /// Resolves a stream for [track] at [quality], degrading through the lower
  /// tiers when the account or the catalogue cannot provide the requested one.
  ///
  /// Cached playback files are quality-specific; [useCache] is false for
  /// downloads so they always fetch the rendition the user picked.
  Future<AudioSource?> audioSourceFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
    bool useCache = true,
  }) async {
    final int id = int.tryParse(track.id) ?? 0;
    if (id <= 0) return null;
    Object? failure;

    if (useCache) {
      final cached = await audioCache.find(track.id, quality: quality);
      if (cached != null) {
        return AudioSource(
          url: cached.uri.toString(),
          quality: quality,
          format: _audioFormat(null, cached.path),
        );
      }
    }

    bool mayTryUpstream = true;
    try {
      final AudioSource? resolved = await _resolveAudioSource(id, quality);
      if (resolved != null) {
        _online = true;
        if (useCache) {
          unawaited(
            audioCache.store(
              track.id,
              resolved.url,
              quality: resolved.quality,
              format: resolved.format,
            ),
          );
        }
        return resolved;
      }
    } catch (error) {
      // A transport failure would make every lower-tier request wait for the
      // same timeout again; cached fallbacks are still worth checking.
      failure = error;
      mayTryUpstream = false;
      _online = false;
    }

    for (final AudioQuality lower in quality.fallbackChain.skip(1)) {
      if (useCache) {
        final cached = await audioCache.find(track.id, quality: lower);
        if (cached != null) {
          return AudioSource(
            url: cached.uri.toString(),
            quality: lower,
            format: _audioFormat(null, cached.path),
          );
        }
      }
      if (!mayTryUpstream) continue;
      try {
        final AudioSource? resolved = await _resolveAudioSource(id, lower);
        if (resolved != null) {
          _online = true;
          if (useCache) {
            unawaited(
              audioCache.store(
                track.id,
                resolved.url,
                quality: resolved.quality,
                format: resolved.format,
              ),
            );
          }
          return resolved;
        }
      } catch (error) {
        failure ??= error;
        mayTryUpstream = false;
        _online = false;
      }
    }
    if (failure != null) throw failure;
    _online = false;
    return null;
  }

  /// Playback URL for a track, or null when the gateway has none (VIP /
  /// region lock / offline).
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => (await audioSourceFor(track, quality: quality))?.url;

  Future<AudioSource?> _resolveAudioSource(
    int id,
    AudioQuality requested,
  ) async {
    final GatewaySongUrl? result = await gateway.songUrl(
      id,
      level: requested.level,
    );
    final String? raw = result?.url;
    if (raw == null || raw.isEmpty) return null;
    final String url = raw.startsWith('http://')
        ? raw.replaceFirst('http://', 'https://')
        : raw;
    final AudioQuality actual =
        AudioQualityInfo.fromLevel(result?.level) ??
        AudioQualityInfo.fromBitrate(result?.br) ??
        requested;
    return AudioSource(
      url: url,
      quality: actual,
      format: _audioFormat(result?.type, url),
      bytes: result?.size,
    );
  }

  static const Set<String> _audioFormats = <String>{
    'mp3',
    'flac',
    'm4a',
    'aac',
    'ogg',
    'wav',
    'mp4',
  };

  static String? _audioFormat(String? type, String url) {
    final String declared = type?.trim().toLowerCase() ?? '';
    if (_audioFormats.contains(declared)) return declared;
    final String path = Uri.tryParse(url)?.path ?? url;
    final int dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return null;
    final String suffix = path.substring(dot + 1).toLowerCase();
    return _audioFormats.contains(suffix) ? suffix : null;
  }

  Future<GatewayLyrics?> lyricsFor(Track track) => _cached(
    'lyrics:${track.id}',
    const Duration(days: 7),
    (json) => GatewayLyrics(
      lrc: json['lrc'] as String?,
      yrc: json['yrc'] as String?,
      tlyric: json['tlyric'] as String?,
      ytlrc: json['ytlrc'] as String?,
      pureMusic: json['pureMusic'] as bool? ?? false,
    ),
    (lyrics) => {
      'lrc': lyrics.lrc,
      'yrc': lyrics.yrc,
      'tlyric': lyrics.tlyric,
      'ytlrc': lyrics.ytlrc,
      'pureMusic': lyrics.pureMusic,
    },
    () async {
      final lyrics = await _lyricsFor(track);
      if (lyrics == null) throw StateError('Lyrics unavailable');
      return lyrics;
    },
  );

  Future<GatewayLyrics?> _lyricsFor(Track track) async {
    final int id = int.tryParse(track.id) ?? 0;
    if (id <= 0) return null;
    try {
      final GatewayLyrics lyrics = await gateway.preferredLyrics(id);
      _online = true;
      return lyrics;
    } catch (_) {
      _online = false;
      rethrow;
    }
  }

  // -- mapping --------------------------------------------------------------

  static List<Track> _decodeTracks(dynamic raw) => (raw as List? ?? const [])
      .map((item) => Track.fromJson(item as Map<String, dynamic>))
      .toList();
  static List<Playlist> _decodePlaylists(dynamic raw) =>
      (raw as List? ?? const [])
          .map((item) => Playlist.fromJson(item as Map<String, dynamic>))
          .toList();
  static UserCollections _decodeCollections(Map<String, dynamic> json) =>
      UserCollections(
        liked: json['liked'] == null
            ? null
            : Playlist.fromJson(json['liked'] as Map<String, dynamic>),
        created: _decodePlaylists(json['created']),
        subscribed: _decodePlaylists(json['subscribed']),
      );
  static Map<String, dynamic> _encodeCollections(UserCollections value) => {
    'liked': value.liked?.toJson(),
    'created': value.created.map((p) => p.toJson()).toList(),
    'subscribed': value.subscribed.map((p) => p.toJson()).toList(),
  };
  static HomeFeed _decodeHome(Map<String, dynamic> json) => HomeFeed(
    featured: json['featured'] == null
        ? null
        : Album.fromJson(json['featured'] as Map<String, dynamic>),
    recommended: _decodePlaylists(json['recommended']),
    featuredTracks: _decodeTracks(json['featuredTracks']),
    quick: _decodeTracks(json['quick']),
    playlists: _decodePlaylists(json['playlists']),
    albums: (json['albums'] as List? ?? const [])
        .map((a) => Album.fromJson(a as Map<String, dynamic>))
        .toList(),
    editorialPlaylists: _decodePlaylists(json['editorialPlaylists']),
  );
  static Map<String, dynamic> _encodeHome(HomeFeed value) => {
    'featured': value.featured?.toJson(),
    'recommended': value.recommended.map((p) => p.toJson()).toList(),
    'featuredTracks': value.featuredTracks.map((t) => t.toJson()).toList(),
    'quick': value.quick.map((t) => t.toJson()).toList(),
    'playlists': value.playlists.map((p) => p.toJson()).toList(),
    'albums': value.albums.map((a) => a.toJson()).toList(),
    'editorialPlaylists': value.editorialPlaylists
        .map((p) => p.toJson())
        .toList(),
  };

  static int _seedFrom(int id) => id.hashCode & 0x7fffffff;

  static int _accentFrom(int id) => id.abs() % 3;

  static Track trackFromSong(GatewaySong song) => Track(
    id: song.id.toString(),
    title: song.title,
    artist: song.artistLine,
    artists: song.artistDetails.map(artistFromGateway).toList(),
    album: song.albumName,
    albumId: song.albumId,
    translatedTitle: song.translatedTitle,
    duration: song.duration,
    coverSeed: _seedFrom(song.id),
    accent: _accentFrom(song.id),
    coverUrl: song.coverUrl,
  );

  static Album albumFromSong(GatewaySong song) => Album(
    id: song.albumId.toString(),
    title: song.albumName,
    artist: song.artistLine,
    artists: song.artistDetails.map(artistFromGateway).toList(),
    year: '',
    coverSeed: _seedFrom(song.albumId),
    note: '',
    coverUrl: song.coverUrl,
  );

  static Album albumFromGateway(GatewayAlbum album) {
    final String year = album.publishTime != null && album.publishTime! > 0
        ? DateTime.fromMillisecondsSinceEpoch(
            album.publishTime!,
          ).year.toString()
        : '';
    return Album(
      id: album.id.toString(),
      title: album.title,
      artist: album.artist,
      artists: album.artists.map(artistFromGateway).toList(),
      year: year,
      coverSeed: _seedFrom(album.id),
      note: album.trackCount > 0 ? '${album.trackCount} 首曲目' : '', // i18n:key
      accent: _accentFrom(album.id),
      trackCount: album.trackCount > 0 ? album.trackCount : null,
      coverUrl: album.coverUrl,
      releaseType: album.releaseType,
      subType: album.subType,
    );
  }

  static ArtistRef artistFromGateway(GatewayArtist artist) =>
      ArtistRef(id: artist.id, name: artist.name, coverUrl: artist.coverUrl);

  static Playlist playlistFromGateway(GatewayPlaylist playlist) => Playlist(
    id: playlist.id.toString(),
    name: playlist.name,
    trackIds: playlist.trackIds.map<String>((int id) => id.toString()).toList(),
    coverSeed: _seedFrom(playlist.id),
    description: playlist.description,
    coverUrl: playlist.coverUrl,
    trackCount: playlist.trackCount,
  );
}

/// Raised when the search host answered but nothing scored high enough to be
/// trusted as the song behind a chart row. It is not a transport failure, so a
/// caller can tell "not on NetEase" apart from "the network just failed".
class _NoChartMatch implements Exception {
  const _NoChartMatch();
}

/// One decoded catalogue snapshot held in memory.
class _MemorySnapshot {
  const _MemorySnapshot(this.value, this.savedAt);
  final Object value;
  final DateTime savedAt;
}

/// An in-flight cache fill and the invalidation epoch it belongs to.
class _PendingRequest {
  const _PendingRequest(this.future, this.epoch);
  final Future<Object> future;
  final int epoch;
}
