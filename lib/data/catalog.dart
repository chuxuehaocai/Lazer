import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import '../cache/disk_cache.dart';
import '../cache/media_cache.dart';
import '../gateway/gateway.dart';
import '../lyrics/cached_lyrics_store.dart';
import '../utils/media_requests.dart';
import 'audio_quality.dart';
import 'billboard.dart';
import 'biliboard.dart';
import 'models.dart';
import 'catalog_details.dart';

part 'platform_catalog.dart';

/// A local playlist identity for the complete daily recommendation response.
const String dailyRecommendationsPlaylistId = 'daily-recommendations';

/// Albums read per 收藏的专辑 page. Large enough that a collection of a few
/// hundred albums opens in a handful of reads, small enough to stay a fast
/// first paint.

/// Music returned by the gateway.
class HomeFeed {
  const HomeFeed({
    this.featured,
    this.recommended = const [],
    required this.featuredTracks,
    required this.quick,
    this.daily = const <Track>[],
    required this.playlists,
    required this.albums,
    this.editorialPlaylists = const <Playlist>[],
  });

  final Album? featured;
  final List<Playlist> recommended;
  final List<Track> featuredTracks;
  final List<Track> quick;
  final List<Track> daily;
  final List<Playlist> playlists;
  final List<Album> albums;
  final List<Playlist> editorialPlaylists;

  bool get isEmpty =>
      recommended.isEmpty &&
      featured == null &&
      quick.isEmpty &&
      daily.isEmpty &&
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

  /// The "喜欢的音乐" collection (provider favorites flag), when present.
  final Playlist? liked;
  final List<Playlist> created;
  final List<Playlist> subscribed;

  static const UserCollections empty = UserCollections();
}

/// Gateway-backed catalogue. Failed requests never create fabricated music.
class Catalog {
  Catalog({
    MusicGateway? gateway,
    DiskCache? cache,
    BiliboardClient? charts,
    BillboardClient? billboard,
    CachedLyricsStore? lyricsCache,
  }) : cache = cache ?? DiskCache.shared,
       charts = charts ?? BiliboardClient(),
       billboard = billboard ?? BillboardClient(),
       audioCache = AudioCache(disk: cache),
       lyricsCache = lyricsCache ?? CachedLyricsStore() {
    connections.add(gateway ?? LocalMusicGateway());
  }
  final GatewayRegistry connections = GatewayRegistry();
  late final _PlatformCatalog _platform = _PlatformCatalog(this);
  MusicGateway get activeGateway => connections.active!;

  Track trackFromMusicSong(MusicSong song) => _platform.track(song);
  Playlist playlistFromMusicPlaylist(MusicPlaylist playlist) =>
      _platform.playlist(playlist);
  int _platformEpoch = 0;

  void selectConnection(String key) {
    connections.select(key);
    _platformEpoch++;
    _home = null;
    _homeError = null;
    _online = false;
  }

  final DiskCache cache;
  final BiliboardClient charts;
  final BillboardClient billboard;
  final AudioCache audioCache;
  final CachedLyricsStore lyricsCache;

  Future<void> cacheLyrics(Track track, {String? audioPath}) async {
    try {
      final payload =
          await lyricsCache.read(track, audioPath: audioPath) ??
          await lyricsFor(track);
      if (payload != null) {
        await lyricsCache.save(track, payload, audioPath: audioPath);
      }
    } catch (_) {
      // Missing lyrics must not turn an audio cache into a failure.
    }
  }

  final _requests = <String, _PendingRequest>{};
  final _failedRequests = <String, _FailedRequest>{};
  final Map<String, int> _epochs = <String, int>{};
  // Keys that a mutation invalidated but whose disk tombstone may not have
  // landed yet. Cache-first reads must skip them even during that window.
  final Set<String> _invalidatedKeys = <String>{};

  /// One generation per account scope for the paginated 收藏的专辑 reads. A
  /// forced refresh bumps it, which retires every cached page of the
  /// collection at once instead of only the one key a page happens to hold.
  final Map<String, int> _savedAlbumGenerations = <String, int>{};

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
    _failedRequests.remove(key);
    _invalidatedKeys.add(key);
    // Bump the epoch so a request that started before this invalidation can
    // never satisfy the next read: a forced refresh must observe the mutation.
    _epochs[key] = (_epochs[key] ?? 0) + 1;
    await cache.expireJson(key);
  }

  // Private playlists and recommendations must not cross session boundaries.
  String get _scope => activeGateway.cacheNamespace;

  String _collectionsKey(int uid, {MusicGateway? connection}) =>
      'collections:v3:${(connection ?? activeGateway).cacheNamespace}';

  String _playlistKey(String playlistId) {
    final reference = MusicId.tryParse(playlistId);
    final namespace = reference == null
        ? _scope
        : _platform.owner(reference).cacheNamespace;
    // v3 intentionally orphans v2 snapshots written before the Lua playlist
    // fetch/cache changes. Those old snapshots can hold a partial or stale
    // track list and must not mask a fresh load after upgrading.
    return 'playlist-v3:$namespace:$playlistId';
  }

  Future<T> _cached<T extends Object>(
    String key,
    Duration ttl,
    T Function(Map<String, dynamic>) decode,
    Map<String, dynamic> Function(T) encode,
    Future<T> Function() fetch, {
    Duration failureCooldown = Duration.zero,
  }) async {
    final int epoch = _epochs[key] ?? 0;
    final pending = _requests[key];
    if (pending != null && pending.epoch == epoch) {
      return await pending.future as T;
    }
    final failed = _failedRequests[key];
    if (failed != null &&
        failed.epoch == epoch &&
        DateTime.now().difference(failed.failedAt) < failureCooldown) {
      _online = false;
      if (failed.previous is T) return failed.previous as T;
      Error.throwWithStackTrace(failed.error, failed.stackTrace);
    }
    final remembered = _memory[key];
    if (!_invalidatedKeys.contains(key) &&
        remembered?.value is T &&
        _fresh(remembered!.savedAt, ttl)) {
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
        if (saved != null && (_epochs[key] ?? 0) == epoch) {
          try {
            previous = decode(saved.data);
          } catch (_) {
            if ((_epochs[key] ?? 0) == epoch) {
              await cache.remove(CacheBucket.data, key, extension: 'json');
            }
          }
          if (previous != null && (_epochs[key] ?? 0) == epoch) {
            if (!_invalidatedKeys.contains(key)) {
              _remember(key, previous, saved.savedAt);
            }
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
          _failedRequests.remove(key);
          await cache.writeJson(key, encode(result));
          if ((_epochs[key] ?? 0) == epoch) {
            _remember(key, result, DateTime.now());
            _invalidatedKeys.remove(key);
          }
        }
        return result;
      } catch (error, stackTrace) {
        _online = false;
        if (failureCooldown > Duration.zero && (_epochs[key] ?? 0) == epoch) {
          // A failed album refresh used to leave an expired snapshot behind,
          // so reopening any of its views immediately downloaded it again.
          // Remember the fallback (or error) briefly. Explicit invalidation
          // clears this entry, making a user's retry take effect immediately.
          _failedRequests
            ..remove(key)
            ..[key] = _FailedRequest(
              epoch: epoch,
              previous: previous,
              error: error,
              stackTrace: stackTrace,
            );
          while (_failedRequests.length > _memoryLimit) {
            _failedRequests.remove(_failedRequests.keys.first);
          }
        }
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
    final int epoch = _epochs[key] ?? 0;
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
      if ((_epochs[key] ?? 0) != epoch || _invalidatedKeys.contains(key)) {
        return null;
      }
      _remember(key, value, saved.savedAt);
      return value;
    } catch (_) {
      if ((_epochs[key] ?? 0) == epoch) {
        await cache.remove(CacheBucket.data, key, extension: 'json');
      }
      return null;
    }
  }

  /// The last stored track list for [playlistId], stale or not, or null when
  /// this playlist has never been opened in the current session scope.
  Future<List<Track>?> cachedPlaylistTracks(String playlistId) {
    if (playlistId == dailyRecommendationsPlaylistId) {
      return Future.value(
        _home?.daily.isNotEmpty == true ? _home!.daily : _home?.quick,
      );
    }
    if (MusicId.tryParse(playlistId) == null &&
        (int.tryParse(playlistId) ?? 0) <= 0) {
      return Future<List<Track>?>.value(null);
    }
    return _storedSnapshot<List<Track>>(
      _playlistKey(playlistId),
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

  Future<void> invalidatePlaylist(String id) => _expire(_playlistKey(id));

  Future<void> invalidateCollections(int uid) => _expire(_collectionsKey(uid));

  Future<void> invalidatePlatformCollections(MusicGateway owner) =>
      _expire(_collectionsKey(0, connection: owner));

  Future<void> invalidatePlatformFavorites(
    MusicGateway owner, {
    String? playlistId,
  }) async {
    final namespace = owner.cacheNamespace;
    final collectionsKey = _collectionsKey(0, connection: owner);
    final stored = await _storedSnapshot(collectionsKey, _decodeCollections);
    final ids = {
      owner
          .id(MusicEntityKind.playlist, _PlatformCatalog.favoritesKey)
          .cacheKey,
      ?stored?.liked?.id,
      ?playlistId,
    };
    await Future.wait([
      for (final id in ids) _expire('playlist-v3:$namespace:$id'),
      _expire(collectionsKey),
    ]);
  }

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
      _expire('provider-charts:$_scope'),
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
    final epoch = _platformEpoch;
    final selected = activeGateway;
    if (selected is LocalMusicGateway) {
      _home = null;
      _homeError = null;
      return null;
    }
    _homeError = null;
    try {
      final loaded = await _cached(
        'home:$_scope:${userId ?? 0}',
        const Duration(minutes: 20),
        _decodeHome,
        _encodeHome,
        () => _platform.home(selected),
      );
      if (epoch != _platformEpoch) return _home;
      _online = true;
      return _home = loaded;
    } catch (error) {
      if (epoch != _platformEpoch) return _home;
      _online = false;
      _homeError = error is MusicGatewayException && error.authenticationFailure
          ? '请登录 ${selected.provider.name}${selected is MusicAccountGateway ? '。' : ' 服务器。'}'
          : '曲库加载失败，请检查网络后重试。'; // i18n:key
      return _home = null;
    }
  }

  /// Search the live catalogue. Errors propagate to the search view.
  Future<SearchResults> search(String rawQuery) async {
    final query = rawQuery.trim();
    if (query.isEmpty) return SearchResults.empty;
    return _platform.search(activeGateway, query);
  }

  Future<List<Track>> personalFmTracks() async => (await activeGateway.radio(
    MusicRadioKind.personal,
  )).map(_platform.track).toList();

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

  Future<List<MusicChart>> providerCharts() {
    // The key, the gateway and the fetch must describe the same connection.
    // Reading `activeGateway` again after the cache await let a switch mid-load
    // store one platform's charts under the previous platform's namespace.
    final MusicGateway gateway = activeGateway;
    final String scope = gateway.cacheNamespace;
    return _cached(
      'provider-charts:$scope',
      const Duration(minutes: 30),
      _decodeCharts,
      _encodeCharts,
      () async {
        final lists = await gateway.charts();
        return Future.wait(
          lists.map((list) async {
            final songs = await gateway.playlistSongs(list.id, limit: 100);
            return MusicChart(
              id: list.id.cacheKey,
              title: list.name,
              source: gateway.provider.name,
              issueLabel: '',
              accent: 0,
              entries: [
                for (var i = 0; i < songs.items.length; i++)
                  ChartEntry(
                    rank: i + 1,
                    title: songs.items[i].title,
                  artist: songs.items[i].artists.map((a) => a.name).join(' / '),
                  track: _platform.track(songs.items[i]),
                ),
            ],
            providerKey: list.id.cacheKey,
          );
        }),
      );
    },
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
    final id = _platform.reference(liked.id, MusicEntityKind.playlist);
    final songs = await _platform
        .owner(id)
        .radio(MusicRadioKind.heart, playlist: id, limit: count);
    if (songs.isNotEmpty) return songs.map(_platform.track).toList();
    return List<Track>.of(await playlistTracks(liked.id))..shuffle();
  }

  Future<List<TrackPlayStat>> playStats(int uid, {bool force = false}) async {
    final key = 'play-stats:$_scope:$uid';
    if (force) await _expire(key);
    return _cached(
      key,
      const Duration(minutes: 5),
      _decodePlayStats,
      (stats) => {
        'stats': [for (final stat in stats) stat.toJson()],
      },
      () async {
        final records = await _platform.all(
          (offset) => activeGateway.playStats(limit: 100, offset: offset),
        );
        return [
          for (final record in records)
            TrackPlayStat(
              songId: record.song.id.cacheKey,
              playCount: record.playCount,
              duration: record.song.duration,
            ),
        ];
      },
    );
  }

  Future<void> invalidatePlayStats(int uid) =>
      _expire('play-stats:$_scope:$uid');
  static List<TrackPlayStat> _decodePlayStats(Map<String, dynamic> json) => [
    for (final row in json['stats'] as List? ?? const [])
      if (row is Map<String, dynamic>) TrackPlayStat.fromJson(row),
  ];

  Future<List<Track>> artistStationTracks(ArtistRef seed) async {
    final id = _platform.reference(seed.key, MusicEntityKind.artist);
    return (await _platform.owner(id).radio(MusicRadioKind.artist, seed: id))
        .map(_platform.track)
        .toList();
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

  /// How long a resolved row keeps its provider reference. Song ids do not move.
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
    final String matchKey = 'chart-entry-match-v3:$_scope:$identity';
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
      await cache.writeJson(
        'chart-entry-miss-v2:$_scope:$identity',
        <String, dynamic>{'title': entry.title},
      );
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
      'chart-entry-miss-v2:$_scope:$identity',
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
      final candidates =
          (await activeGateway
                  .search(value, limit: 8)
                  .timeout(const Duration(seconds: 5)))
              .songs
              .items;

      for (final candidate in candidates) {
        final double score = _chartMatchScore(entry, candidate);
        if (score > bestScore) {
          bestScore = score;
          match = _platform.track(candidate);
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

  static double _chartMatchScore(ChartEntry entry, MusicSong song) {
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
    final String candidateArtist = _normaliseMusicText(
      song.artists.map((artist) => artist.name).join(' / '),
    );
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
  Stream<List<Track>> playlistTrackPages(String playlistId) async* {
    if (playlistId == dailyRecommendationsPlaylistId) {
      final tracks = _home?.daily.isNotEmpty == true
          ? _home!.daily
          : _home?.quick ?? const <Track>[];
      if (tracks.isNotEmpty) yield tracks;
      return;
    }
    final accumulated = <Track>[];
    await for (final page in _platform.playlistTrackPages(playlistId)) {
      accumulated.addAll(page);
      // Yield as soon as one 100-song page is ready. Artwork widgets can load
      // their URLs independently while the next page is being requested.
      yield page;
    }
    final key = _playlistKey(playlistId);
    _remember(key, accumulated, DateTime.now());
    unawaited(
      cache.writeJson(key, {
        'tracks': accumulated.map((track) => track.toJson()).toList(),
      }),
    );
  }

  Future<List<Track>> playlistTracks(String playlistId) =>
      playlistId == dailyRecommendationsPlaylistId
      ? Future.value(
          _home?.daily.isNotEmpty == true
              ? _home!.daily
              : _home?.quick ?? const <Track>[],
        )
      : _cached(
          _playlistKey(playlistId),
          const Duration(minutes: 10),
          (json) => _decodeTracks(json['tracks']),
          (tracks) => {
            'tracks': tracks.map((track) => track.toJson()).toList(),
          },
          () => _platform.playlistTracks(playlistId),
        );

  Future<UserCollections> userCollections(int uid) =>
      platformCollections(activeGateway);

  Future<UserCollections> platformCollections(MusicGateway owner) {
    if (owner.user == null) return Future.value(UserCollections.empty);
    return _cached(
      _collectionsKey(0, connection: owner),
      const Duration(minutes: 5),
      _decodeCollections,
      _encodeCollections,
      () => _platform.collections(owner),
    );
  }

  Future<List<Track>> albumTracks(int albumId) => albumTracksFor(
    activeGateway.id(MusicEntityKind.album, '$albumId').cacheKey,
  );

  Future<AlbumPage> savedAlbums(
    int uid, {
    int offset = 0,
    bool force = false,
  }) async {
    if (offset < 0) throw ArgumentError.value(offset, 'offset');
    final scope = _scope;
    if (force) {
      _savedAlbumGenerations[scope] = (_savedAlbumGenerations[scope] ?? 0) + 1;
    }
    final key =
        'saved-albums:v4:$scope:${_savedAlbumGenerations[scope] ?? 0}:$offset';
    return _cached(
      key,
      const Duration(minutes: 15),
      AlbumPage.fromJson,
      (page) => page.toJson(),
      () => _platform.savedAlbums(activeGateway, offset),
      failureCooldown: const Duration(seconds: 30),
    );
  }

  Future<List<Track>> albumTracksFor(String key) async =>
      (await albumDetailsFor(key)).tracks;

  Future<AlbumDetails> albumDetailsFor(String key, {bool force = false}) async {
    final reference = MusicId.tryParse(key);
    if (reference == null) throw ArgumentError('Invalid album reference.');
    // Platform albums must share the same in-flight request and stored snapshot
    // as native catalogue albums. Opening a second detail or pressing play on a
    // slow connection used to start the entire metadata/song-page load again.
    final namespace = _platform.owner(reference).cacheNamespace;
    final cacheKey = 'album-detail:$namespace:$key';
    if (force) await _expire(cacheKey);
    return _cached(
      cacheKey,
      const Duration(hours: 1),
      AlbumDetails.fromJson,
      (value) => value.toJson(),
      () => _platform.albumDetails(key),
      failureCooldown: const Duration(seconds: 30),
    );
  }

  Future<ArtistAlbumPage> artistAlbumPageFor(
    ArtistRef artist, {
    int offset = 0,
    bool force = false,
  }) async {
    if (artist.platformKey == null) {
      return artistAlbumPage(artist.id, offset: offset, force: force);
    }
    final reference = _platform.reference(artist.key, MusicEntityKind.artist);
    final namespace = _platform.owner(reference).cacheNamespace;
    final key = 'artist-albums:$namespace:${artist.key}:$offset';
    if (force) await _expire(key);
    return _cached(
      key,
      const Duration(minutes: 15),
      ArtistAlbumPage.fromJson,
      (value) => value.toJson(),
      () => _platform.artistAlbumPage(artist, offset),
      failureCooldown: const Duration(seconds: 30),
    );
  }

  Future<List<Track>> artistSongsFor(
    ArtistRef artist, {
    bool force = false,
  }) async {
    if (artist.platformKey == null) return artistSongs(artist.id, force: force);
    final id = _platform.reference(artist.key, MusicEntityKind.artist);
    final key =
        'artist-songs:v2:${_platform.owner(id).cacheNamespace}:${id.cacheKey}';
    if (force) await _expire(key);
    return _cached(
      key,
      const Duration(minutes: 30),
      (json) => _decodeTracks(json['tracks']),
      (tracks) => {
        'tracks': [for (final track in tracks) track.toJson()],
      },
      () => _platform.artistSongs(artist),
      failureCooldown: const Duration(seconds: 30),
    );
  }

  Future<AlbumDetails> albumDetails(int albumId, {bool force = false}) =>
      albumDetailsFor(
        activeGateway.id(MusicEntityKind.album, '$albumId').cacheKey,
        force: force,
      );
  Future<ArtistDetails> artistDetails(
    ArtistRef artist, {
    bool force = false,
  }) async {
    if (artist.platformKey == null) {
      artist = ArtistRef(
        id: artist.id,
        name: artist.name,
        coverUrl: artist.coverUrl,
        platformKey: activeGateway
            .id(MusicEntityKind.artist, '${artist.id}')
            .cacheKey,
      );
    }
    final id = _platform.reference(artist.key, MusicEntityKind.artist);
    final key =
        'artist-detail:v2:${_platform.owner(id).cacheNamespace}:${id.cacheKey}';
    if (force) {
      await _expire(key);
      await artistSongsFor(artist, force: true);
    }
    return _cached(
      key,
      const Duration(minutes: 30),
      ArtistDetails.fromJson,
      (details) => details.toJson(),
      () => _platform.artistDetails(artist),
      failureCooldown: const Duration(seconds: 30),
    );
  }

  Future<ArtistAlbumPage> artistAlbumPage(
    int id, {
    int offset = 0,
    bool force = false,
  }) => artistAlbumPageFor(
    ArtistRef(
      id: 0,
      name: '',
      platformKey: activeGateway.id(MusicEntityKind.artist, '$id').cacheKey,
    ),
    offset: offset,
    force: force,
  );
  Future<List<Track>> artistSongs(int id, {bool force = false}) =>
      artistSongsFor(
        ArtistRef(
          id: 0,
          name: '',
          platformKey: activeGateway.id(MusicEntityKind.artist, '$id').cacheKey,
        ),
        force: force,
      );

  Future<AudioSource?> audioSourceFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
    bool useCache = true,
    bool Function()? isCancelled,
  }) => _platform.audioSource(
    track,
    quality,
    useCache,
    isCancelled: isCancelled,
  );
  static bool isRateLimited(Object? error) =>
      error is MusicGatewayException && error.httpStatus == 429;
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
    bool Function()? isCancelled,
  }) async => (await audioSourceFor(
    track,
    quality: quality,
    isCancelled: isCancelled,
  ))?.url;

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

  Future<GatewayLyrics?> _lyricsFor(Track track) => _platform.lyrics(track.id);

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
    daily: _decodeTracks(json['daily']),
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
    'daily': value.daily.map((t) => t.toJson()).toList(),
    'playlists': value.playlists.map((p) => p.toJson()).toList(),
    'albums': value.albums.map((a) => a.toJson()).toList(),
    'editorialPlaylists': value.editorialPlaylists
        .map((p) => p.toJson())
        .toList(),
  };
}

/// Raised when the search host answered but nothing scored high enough to be
/// trusted as the song behind a chart row. It is not a transport failure, so a
/// caller can tell "not in this catalogue" apart from "the network just failed".
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

/// A bounded pause after a failed refresh, including its last usable snapshot.
class _FailedRequest {
  _FailedRequest({
    required this.epoch,
    required this.previous,
    required this.error,
    required this.stackTrace,
  }) : failedAt = DateTime.now();

  final int epoch;
  final Object? previous;
  final Object error;
  final StackTrace stackTrace;
  final DateTime failedAt;
}
