import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/cache/disk_cache.dart';
import 'package:lazer_nextgen/data/biliboard.dart';
import 'package:lazer_nextgen/data/billboard.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';

class _Gateway extends NeteaseGateway {
  @override
  Future<List<GatewayPlaylist>> personalizedPlaylists({int limit = 12}) async =>
      const [];
  final List<List<int>> detailPages = <List<int>>[];
  bool failSearch = false;
  bool failPlaylist = false;
  bool failAll = false;
  List<GatewayPlaylist>? collectionFixtures;
  int playlistCalls = 0;
  int collectionCalls = 0;
  int audioCalls = 0;
  int lyricCalls = 0;
  int playRecordCalls = 0;

  @override
  Future<GatewayLyrics> preferredLyrics(int id) async {
    lyricCalls++;
    if (failAll) throw const SocketException('offline');
    return GatewayLyrics(lrc: '[00:00]Line $lyricCalls', tlyric: '[00:00]翻译');
  }

  @override
  Future<List<GatewayPlaylist>> topPlaylists({
    String category = '全部',
    int limit = 12,
    int offset = 0,
  }) async {
    if (failAll) throw const SocketException('offline');
    return const [GatewayPlaylist(id: 12, name: '真实歌单', trackCount: 501)];
  }

  @override
  Future<Map<String, dynamic>> playlistDetail(
    int id, {
    int subscriberLimit = 8,
  }) async {
    playlistCalls++;
    if (failPlaylist || failAll) throw const SocketException('offline');
    return <String, dynamic>{
      'code': 200,
      'playlist': <String, dynamic>{
        'id': id,
        'name': '真实歌单',
        'trackCount': 501,
        'trackIds': <Map<String, int>>[
          for (int songId = 1; songId <= 501; songId++)
            <String, int>{'id': songId},
        ],
      },
    };
  }

  @override
  Future<List<GatewayPlaylist>> userPlaylists(
    int uid, {
    int limit = 30,
    int offset = 0,
  }) async {
    collectionCalls++;
    if (failAll) throw const SocketException('offline');
    final List<GatewayPlaylist>? fixtures = collectionFixtures;
    if (fixtures != null) return fixtures;
    return [
      GatewayPlaylist(
        id: uid * 10,
        name: '喜欢的音乐',
        specialType: 5,
        trackCount: 501,
      ),
    ];
  }

  @override
  Future<GatewaySongUrl?> songUrl(int id, {String level = 'exhigh'}) async {
    audioCalls++;
    throw const SocketException('offline');
  }

  @override
  Future<List<GatewayPlayRecord>> playRecord(int uid) async {
    playRecordCalls++;
    if (failAll) throw const SocketException('offline');
    return const <GatewayPlayRecord>[
      GatewayPlayRecord(
        song: GatewaySong(
          id: 1,
          title: '曲目 1',
          artists: <String>['音乐人'],
          albumName: '专辑',
          duration: Duration(minutes: 3),
        ),
        playCount: 12,
      ),
    ];
  }

  @override
  Future<List<GatewaySong>> songDetails(List<int> ids) async {
    detailPages.add(ids);
    return ids
        .map(
          (id) => GatewaySong(
            id: id,
            title: '曲目 $id',
            artists: const <String>['音乐人'],
            albumName: '专辑',
            albumId: 9,
            duration: const Duration(minutes: 3),
            coverUrl: 'https://example.com/$id.jpg',
          ),
        )
        .toList();
  }

  @override
  Future<List<GatewaySong>> search(
    String keywords, {
    GatewaySearchType type = GatewaySearchType.song,
    int limit = 30,
    int offset = 0,
    bool useCloudSearch = false,
  }) async {
    if (failSearch) throw StateError('network unavailable');
    return songDetails(<int>[42]);
  }

  @override
  Future<List<GatewayAlbum>> searchAlbums(
    String keywords, {
    int limit = 10,
  }) async => const <GatewayAlbum>[];

  @override
  Future<List<GatewayPlaylist>> searchPlaylists(
    String keywords, {
    int limit = 20,
  }) async => const <GatewayPlaylist>[];
}

/// Simulates a disk that could not write its invalidation tombstone.
class _StubbornCache extends DiskCache {
  _StubbornCache({required super.directory});

  @override
  Future<void> expireJson(String key) async {}
}

class _GatedWriteCache extends DiskCache {
  _GatedWriteCache({required super.directory});
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  bool _first = true;
  @override
  Future<void> writeJson(
    String key,
    Map<String, dynamic> data, {
    DateTime? savedAt,
  }) async {
    await super.writeJson(key, data, savedAt: savedAt);
    if (_first && key == 'playlist-v2:guest:12') {
      _first = false;
      started.complete();
      await release.future;
    }
  }
}

class _GatedReadCache extends DiskCache {
  _GatedReadCache({required super.directory});
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  bool _first = true;
  @override
  Future<CachedJson?> readJson(String key) async {
    final value = await super.readJson(key);
    if (_first && key == 'playlist-v2:guest:12') {
      _first = false;
      started.complete();
      await release.future;
    }
    return value;
  }
}

class _ChartGateway extends NeteaseGateway {
  int searchCalls = 0;

  @override
  Future<List<GatewaySong>> search(
    String keywords, {
    GatewaySearchType type = GatewaySearchType.song,
    int limit = 30,
    int offset = 0,
    bool useCloudSearch = false,
  }) async {
    searchCalls++;
    final match = RegExp(r'^Song (\d+)').firstMatch(keywords);
    if (match == null) return const <GatewaySong>[];
    final id = int.parse(match.group(1)!);
    return <GatewaySong>[
      GatewaySong(
        id: id,
        title: 'Song $id',
        artists: <String>['Artist $id'],
        albumName: 'Album $id',
        duration: const Duration(minutes: 3),
      ),
    ];
  }
}

class _StaticBillboard extends BillboardClient {
  @override
  Future<MusicChart?> latestChart() async => const MusicChart(
    id: 'billboard:test',
    title: 'Billboard Hot 100',
    source: 'Billboard',
    issueLabel: 'Current',
    entries: <ChartEntry>[],
    providerKey: 'billboard:hot-100',
  );
}

class _RecoveringBiliboard extends BiliboardClient {
  int calls = 0;

  @override
  Future<List<MusicChart>> latestCharts() async {
    calls++;
    if (calls == 1) throw const SocketException('temporary outage');
    return const <MusicChart>[
      MusicChart(
        id: 'biliboard:1:124',
        title: '周榜',
        source: 'Biliboard',
        issueLabel: '2026 · 第 43 周',
        entries: <ChartEntry>[],
        providerKey: 'biliboard:1',
      ),
    ];
  }
}

class _FallbackChartGateway extends NeteaseGateway {
  int searchCalls = 0;

  @override
  Future<List<GatewaySong>> search(
    String keywords, {
    GatewaySearchType type = GatewaySearchType.song,
    int limit = 30,
    int offset = 0,
    bool useCloudSearch = false,
  }) async {
    searchCalls++;
    if (keywords != 'Nicole Kidman') return const <GatewaySong>[];
    return const <GatewaySong>[
      GatewaySong(
        id: 6,
        title: 'Nicole Kidman',
        artists: <String>['ADÉLA'],
        albumName: 'The Provocateur',
        duration: Duration(minutes: 3),
      ),
    ];
  }
}

class _SharedSongGateway extends NeteaseGateway {
  int searchCalls = 0;

  @override
  Future<List<GatewaySong>> search(
    String keywords, {
    GatewaySearchType type = GatewaySearchType.song,
    int limit = 30,
    int offset = 0,
    bool useCloudSearch = false,
  }) async {
    searchCalls++;
    if (searchCalls > 1) throw const SocketException('rate limited');
    return const <GatewaySong>[
      GatewaySong(
        id: 7,
        title: 'Shared Song',
        artists: <String>['Producer'],
        albumName: 'Shared Album',
        duration: Duration(minutes: 3),
      ),
    ];
  }
}

class _BiliboardAliasGateway extends NeteaseGateway {
  @override
  Future<List<GatewaySong>> search(
    String keywords, {
    GatewaySearchType type = GatewaySearchType.song,
    int limit = 30,
    int offset = 0,
    bool useCloudSearch = false,
  }) async => const <GatewaySong>[
    GatewaySong(
      id: 8,
      title: 'シャルル',
      artists: <String>['須田景凪'],
      albumName: 'Corridor',
      duration: Duration(minutes: 4),
    ),
  ];
}

class _CloudSearchFailureGateway extends NeteaseGateway {
  int cloudCalls = 0;
  int classicCalls = 0;

  @override
  Future<List<GatewaySong>> search(
    String keywords, {
    GatewaySearchType type = GatewaySearchType.song,
    int limit = 30,
    int offset = 0,
    bool useCloudSearch = false,
  }) async {
    if (useCloudSearch) {
      cloudCalls++;
      throw const SocketException('cloud search temporarily unavailable');
    }
    classicCalls++;
    return const <GatewaySong>[
      GatewaySong(
        id: 9,
        title: 'シスターに懺悔を',
        artists: <String>['廃原メモリ'],
        albumName: 'シスターに懺悔を',
        duration: Duration(minutes: 3),
      ),
    ];
  }
}

class _LateChartGateway extends NeteaseGateway {
  bool available = false;
  bool failing = false;
  int searchCalls = 0;

  @override
  Future<List<GatewaySong>> search(
    String keywords, {
    GatewaySearchType type = GatewaySearchType.song,
    int limit = 30,
    int offset = 0,
    bool useCloudSearch = false,
  }) async {
    searchCalls++;
    if (failing) throw const SocketException('search host unreachable');
    if (!available) return const <GatewaySong>[];
    return const <GatewaySong>[
      GatewaySong(
        id: 9,
        title: 'シスターに懺悔を',
        artists: <String>['廃原メモリ'],
        albumName: 'シスターに懺悔を',
        duration: Duration(minutes: 3),
      ),
    ];
  }
}

void main() {
  group('persistent catalogue cache', () {
    late Directory directory;
    late DiskCache disk;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('lazer-catalog-test-');
      disk = DiskCache(directory: () async => directory);
    });
    tearDown(() async => directory.delete(recursive: true));

    test(
      'lyrics refresh bypasses cached data and retains translations offline',
      () async {
        final gateway = _Gateway();
        final catalog = Catalog(gateway: gateway, cache: disk);
        const track = Track(
          id: '42',
          title: '',
          artist: '',
          album: '',
          duration: Duration.zero,
          coverSeed: 0,
        );
        expect((await catalog.lyricsFor(track))?.lrc, '[00:00]Line 1');
        expect((await catalog.lyricsFor(track))?.lrc, '[00:00]Line 1');
        expect(gateway.lyricCalls, 1);
        await catalog.invalidateLyrics(track.id);
        expect((await catalog.lyricsFor(track))?.lrc, '[00:00]Line 2');
        gateway.failAll = true;
        await catalog.invalidateLyrics(track.id);
        final offline = await catalog.lyricsFor(track);
        expect(offline?.lrc, '[00:00]Line 2');
        expect(offline?.tlyric, '[00:00]翻译');
      },
    );

    test(
      'a fresh playlist is served from memory after the disk snapshot is gone',
      () async {
        final gateway = _Gateway();
        final catalog = Catalog(gateway: gateway, cache: disk);
        final first = await catalog.playlistTracks('12');
        expect(first.length, 501);
        // Simulate the OS cache cleaner removing the file between two visits.
        await disk.remove(
          CacheBucket.data,
          'playlist-v2:guest:12',
          extension: 'json',
        );
        gateway.failAll = true;
        final warm = await catalog.playlistTracks('12');
        expect(warm.length, 501);
        expect(gateway.playlistCalls, 1);

        // An invalidation must drop the warm copy as well as the disk one.
        await catalog.invalidatePlaylist('12');
        await expectLater(
          catalog.playlistTracks('12'),
          throwsA(isA<SocketException>()),
        );
      },
    );

    test(
      'a stored playlist paints without the service until invalidated',
      () async {
        final first = Catalog(gateway: _Gateway(), cache: disk);
        final loaded = await first.playlistTracks('12');
        expect(loaded.length, 501);

        // A cold start: new catalog, same disk, and a service that is down.
        final offline = _Gateway()..failAll = true;
        final restarted = Catalog(
          gateway: offline,
          cache: DiskCache(directory: () async => directory),
        );
        final stored = await restarted.cachedPlaylistTracks('12');
        expect(stored?.length, 501);
        expect(stored?.first.id, loaded.first.id);
        expect(offline.playlistCalls, 0);

        // A mutation invalidates the snapshot: the page must not paint the
        // pre-mutation list, even though the payload stays as the offline
        // fallback for the blocking path.
        await restarted.invalidatePlaylist('12');
        expect(await restarted.cachedPlaylistTracks('12'), isNull);
        expect((await restarted.playlistTracks('12')).length, 501);
        expect(offline.playlistCalls, 1);
      },
    );

    test(
      'a failed disk tombstone cannot resurrect an invalidated playlist',
      () async {
        final gateway = _Gateway();
        final catalog = Catalog(
          gateway: gateway,
          cache: _StubbornCache(directory: () async => directory),
        );
        expect((await catalog.playlistTracks('12')).length, 501);
        await catalog.invalidatePlaylist('12');
        expect(await catalog.cachedPlaylistTracks('12'), isNull);

        // The disk file still looks fresh here, but the catalog must not take
        // it as a hit: only the failed fetch may fall back to it.
        gateway.failPlaylist = true;
        expect((await catalog.playlistTracks('12')).length, 501);
        expect(gateway.playlistCalls, 2);
      },
    );

    test(
      'invalidation during a cache write does not revive stale memory or disk',
      () async {
        final gated = _GatedWriteCache(directory: () async => directory);
        final gateway = _Gateway();
        final catalog = Catalog(gateway: gateway, cache: gated);
        final oldFetch = catalog.playlistTracks('12');
        await gated.started.future;
        await catalog.invalidatePlaylist('12');
        gated.release.complete();
        expect((await oldFetch), hasLength(501));
        expect(await catalog.cachedPlaylistTracks('12'), isNull);
        final restarted = Catalog(
          gateway: gateway,
          cache: DiskCache(directory: () async => directory),
        );
        expect(await restarted.cachedPlaylistTracks('12'), isNull);
        expect((await catalog.playlistTracks('12')), hasLength(501));
        expect(gateway.playlistCalls, 2);
        await gated.settle();
      },
    );

    test('an old snapshot read cannot replace a refreshed playlist', () async {
      await Catalog(gateway: _Gateway(), cache: disk).playlistTracks('12');
      final gated = _GatedReadCache(directory: () async => directory);
      final gateway = _Gateway();
      final catalog = Catalog(gateway: gateway, cache: gated);
      final oldRead = catalog.cachedPlaylistTracks('12');
      await gated.started.future;
      await catalog.invalidatePlaylist('12');
      expect(await catalog.playlistTracks('12'), hasLength(501));
      expect(gateway.playlistCalls, 1);
      gated.release.complete();
      expect(await oldRead, isNull);
      expect(await catalog.cachedPlaylistTracks('12'), hasLength(501));
      await gated.settle();
    });

    test(
      'stored collections paint without the service until invalidated',
      () async {
        final firstGateway = _Gateway()
          ..sessionCookie = 'MUSIC_U=fixture-account';
        final first = Catalog(gateway: firstGateway, cache: disk);
        final loaded = await first.userCollections(7);
        expect(loaded.liked?.id, '70');

        final offline = _Gateway()
          ..sessionCookie = 'MUSIC_U=fixture-account'
          ..failAll = true;
        final restarted = Catalog(
          gateway: offline,
          cache: DiskCache(directory: () async => directory),
        );
        final stored = await restarted.cachedUserCollections(7);
        expect(stored?.liked?.trackCount, 501);
        expect(offline.collectionCalls, 0);

        await restarted.invalidateCollections(7);
        expect(await restarted.cachedUserCollections(7), isNull);
      },
    );

    test(
      'playlist ownership comes from subscribed and creator fields',
      () async {
        final gateway = _Gateway()
          ..collectionFixtures = const <GatewayPlaylist>[
            GatewayPlaylist(
              id: 1,
              name: '喜欢的音乐',
              specialType: 5,
              subscribed: false,
              creatorId: 7,
            ),
            GatewayPlaylist(
              id: 2,
              name: '自己创建',
              subscribed: false,
              creatorId: 7,
            ),
            GatewayPlaylist(
              id: 3,
              name: '收藏的歌单',
              subscribed: true,
              creatorId: 9,
            ),
            GatewayPlaylist(id: 4, name: '旧版数据'),
          ];
        final collections = await Catalog(
          gateway: gateway,
          cache: disk,
        ).userCollections(7);
        expect(collections.liked?.id, '1');
        expect(collections.created.map((playlist) => playlist.id), <String>[
          '2',
        ]);
        expect(collections.subscribed.map((playlist) => playlist.id), <String>[
          '3',
          '4',
        ]);
      },
    );

    test(
      'play stats are cached in memory and on disk until invalidated',
      () async {
        final gateway = _Gateway();
        final catalog = Catalog(gateway: gateway, cache: disk);
        final first = await catalog.playStats(7);
        expect(first.single.songId, '1');
        expect(first.single.playCount, 12);
        expect(first.single.duration, const Duration(minutes: 3));
        expect(gateway.playRecordCalls, 1);

        // Opening 听歌排行 again must not hit the network.
        await catalog.playStats(7);
        expect(gateway.playRecordCalls, 1);

        // A forced refresh (the play-history retry) bypasses both layers.
        await catalog.playStats(7, force: true);
        expect(gateway.playRecordCalls, 2);

        // Uploading a play invalidates the cached record.
        await catalog.invalidatePlayStats(7);
        await catalog.playStats(7);
        expect(gateway.playRecordCalls, 3);

        // A restarted catalog serves the disk snapshot without a request.
        final restarted = Catalog(
          gateway: gateway,
          cache: DiskCache(directory: () async => directory),
        );
        final cached = await restarted.playStats(7);
        expect(cached.single.playCount, 12);
        expect(gateway.playRecordCalls, 3);
      },
    );

    test(
      'complete playlist is reused after restart, refreshed and available stale offline',
      () async {
        final firstGateway = _Gateway();
        final first = Catalog(gateway: firstGateway, cache: disk);
        final loaded = await Future.wait([
          first.playlistTracks('12'),
          first.playlistTracks('12'),
        ]);
        expect(loaded.first.length, 501);
        expect(firstGateway.playlistCalls, 1);
        expect(firstGateway.detailPages.map((page) => page.length), [500, 1]);
        final gateway = _Gateway()..failPlaylist = true;
        final restarted = Catalog(
          gateway: gateway,
          cache: DiskCache(directory: () async => directory),
        );
        final cached = await restarted.playlistTracks('12');
        expect(gateway.playlistCalls, 0);
        expect(
          cached.map((track) => track.id),
          loaded.first.map((track) => track.id),
        );
        expect(cached.first.coverUrl, loaded.first.first.coverUrl);
        final stale = await restarted.refreshPlaylist('12');
        expect(gateway.playlistCalls, 1);
        expect(stale.length, 501);
        gateway.failPlaylist = false;
        expect((await restarted.playlistTracks('12')).length, 501);
        expect(gateway.playlistCalls, 2);
      },
    );

    test(
      'personal collections and private playlists are separated by session',
      () async {
        final gateway = _Gateway()..sessionCookie = 'MUSIC_U=account-a';
        final catalog = Catalog(gateway: gateway, cache: disk);
        expect((await catalog.userCollections(7)).liked?.id, '70');
        await catalog.playlistTracks('12');
        gateway.failAll = true;
        expect((await catalog.userCollections(7)).liked?.trackCount, 501);
        await catalog.invalidateCollections(7);
        expect((await catalog.userCollections(7)).liked?.id, '70');
        gateway.sessionCookie = 'MUSIC_U=account-b';
        await expectLater(
          catalog.userCollections(8),
          throwsA(isA<SocketException>()),
        );
        await expectLater(
          catalog.playlistTracks('12'),
          throwsA(isA<SocketException>()),
        );
        gateway.clearSession();
        await expectLater(
          catalog.playlistTracks('12'),
          throwsA(isA<SocketException>()),
        );
      },
    );

    test(
      'home feed survives restart with real recommendations and metadata',
      () async {
        final catalog = Catalog(gateway: _Gateway(), cache: disk);
        final feed = (await catalog.loadHome())!;
        await disk.expireJson('home:guest:0');
        final gateway = _Gateway()..failAll = true;
        final restarted = Catalog(
          gateway: gateway,
          cache: DiskCache(directory: () async => directory),
        );
        final offline = (await restarted.loadHome())!;
        expect(offline.recommended.single.id, feed.recommended.single.id);
        expect(offline.quick.length, feed.quick.length);
        expect(offline.featured?.title, feed.featured?.title);
        expect(restarted.online, isFalse);
      },
    );

    test(
      'audio playback resolves a cached file before contacting the service',
      () async {
        final file = await disk.put(
          CacheBucket.audio,
          '42',
          () => Stream.value([1, 2, 3]),
          extension: 'mp3',
        );
        final gateway = _Gateway();
        final catalog = Catalog(gateway: gateway, cache: disk);
        const track = Track(
          id: '42',
          title: '',
          artist: '',
          album: '',
          duration: Duration.zero,
          coverSeed: 0,
        );
        expect(await catalog.audioUrlFor(track), file!.uri.toString());
        expect(gateway.audioCalls, 0);
      },
    );
  });

  test('song translations survive gateway parsing and catalogue mapping', () {
    final song = GatewaySong.fromJson(<String, dynamic>{
      'id': 42,
      'name': 'Original title',
      'tns': ['中文译名', 'Original title', '中文译名'],
    });
    expect(Catalog.trackFromSong(song).translatedTitle, '中文译名');
    final alternate = GatewaySong.fromJson(<String, dynamic>{
      'id': 43,
      'name': 'Another title',
      'transNames': ['另一首的译名'],
    });
    expect(alternate.translatedTitle, '另一首的译名');
  });

  test(
    'chart matching resolves every entry instead of only the first page',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lazer-chart-match-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final gateway = _ChartGateway();
      final catalog = Catalog(
        gateway: gateway,
        cache: DiskCache(directory: () async => directory),
      );
      final chart = MusicChart(
        id: 'billboard:test-100',
        title: 'Billboard Hot 100',
        source: 'Billboard',
        issueLabel: 'Test issue',
        entries: <ChartEntry>[
          for (var rank = 1; rank <= 100; rank++)
            ChartEntry(rank: rank, title: 'Song $rank', artist: 'Artist $rank'),
        ],
      );

      final matched = await catalog.matchChart(chart);

      expect(
        matched.entries.where((entry) => entry.track != null),
        hasLength(100),
      );
      expect(gateway.searchCalls, 100);
    },
  );

  test('a temporary Biliboard failure is retried instead of cached', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lazer-chart-source-cache-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final biliboard = _RecoveringBiliboard();
    final catalog = Catalog(
      gateway: _Gateway(),
      cache: DiskCache(directory: () async => directory),
      billboard: _StaticBillboard(),
      charts: biliboard,
    );

    final first = await catalog.discoveryCharts();
    final recovered = await catalog.discoveryCharts();

    expect(first.map((chart) => chart.providerKey), <String?>[
      'billboard:hot-100',
    ]);
    expect(
      recovered.map((chart) => chart.providerKey),
      contains('biliboard:1'),
    );
    expect(biliboard.calls, 2);
  });

  test('chart matching retries by title and folds artist diacritics', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lazer-chart-fallback-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final gateway = _FallbackChartGateway();
    final catalog = Catalog(
      gateway: gateway,
      cache: DiskCache(directory: () async => directory),
    );
    const chart = MusicChart(
      id: 'billboard:fallback',
      title: 'Billboard Hot 100',
      source: 'Billboard',
      issueLabel: 'Test issue',
      entries: <ChartEntry>[
        ChartEntry(rank: 1, title: 'Nicole Kidman', artist: 'ADELA'),
      ],
    );

    final matched = await catalog.matchChart(chart);

    expect(matched.entries.single.track?.id, '6');
    // Query, the classic-search pass behind an empty cloud answer, then the
    // title-only retry that actually hits.
    expect(gateway.searchCalls, 3);
  });

  test(
    'the same song reuses a positive match across Biliboard boards',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lazer-chart-shared-match-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final gateway = _SharedSongGateway();
      final catalog = Catalog(
        gateway: gateway,
        cache: DiskCache(directory: () async => directory),
      );
      MusicChart board(int id) => MusicChart(
        id: 'biliboard:$id:1',
        title: 'Board $id',
        source: 'Biliboard',
        issueLabel: 'Current',
        providerKey: 'biliboard:$id',
        entries: const <ChartEntry>[
          ChartEntry(rank: 1, title: 'Shared Song', artist: 'Producer'),
        ],
      );

      final weekly = await catalog.matchChart(board(1));
      final legends = await catalog.matchChart(board(2));

      expect(weekly.entries.single.track?.id, '7');
      expect(legends.entries.single.track?.id, '7');
      expect(gateway.searchCalls, 1);
    },
  );

  test(
    'Biliboard accepts an exact title when producer aliases differ',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lazer-chart-alias-match-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final catalog = Catalog(
        gateway: _BiliboardAliasGateway(),
        cache: DiskCache(directory: () async => directory),
      );
      const chart = MusicChart(
        id: 'biliboard:2:84',
        title: '传说曲周榜',
        source: 'Biliboard',
        issueLabel: 'Current',
        providerKey: 'biliboard:2',
        entries: <ChartEntry>[
          ChartEntry(rank: 1, title: 'シャルル', artist: 'バルーン'),
        ],
      );

      final matched = await catalog.matchChart(chart);

      expect(matched.entries.single.track?.id, '8');
    },
  );

  test('chart matching falls back when NetEase cloud search fails', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lazer-chart-search-fallback-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final gateway = _CloudSearchFailureGateway();
    final catalog = Catalog(
      gateway: gateway,
      cache: DiskCache(directory: () async => directory),
    );
    const chart = MusicChart(
      id: 'biliboard:1:124',
      title: '周榜',
      source: 'Biliboard',
      issueLabel: 'Current',
      providerKey: 'biliboard:1',
      entries: <ChartEntry>[
        ChartEntry(rank: 1, title: 'シスターに懺悔を', artist: '廃原メモリ'),
      ],
    );

    final matched = await catalog.matchChart(chart);

    expect(matched.entries.single.track?.id, '9');
    expect(gateway.cloudCalls, 1);
    expect(gateway.classicCalls, 1);
  });

  test(
    'a row that matched nothing is remembered briefly, not for weeks',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lazer-chart-retry-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final gateway = _LateChartGateway();
      final catalog = Catalog(
        gateway: gateway,
        cache: DiskCache(directory: () async => directory),
      );
      const chart = MusicChart(
        id: 'biliboard:1:124',
        title: '周榜',
        source: 'Biliboard',
        issueLabel: 'Current',
        providerKey: 'biliboard:1',
        entries: <ChartEntry>[
          ChartEntry(rank: 1, title: 'シスターに懺悔を', artist: '廃原メモリ'),
        ],
      );

      final firstVisit = await catalog.matchChart(chart);
      expect(firstVisit.entries.single.track, isNull);
      final afterMiss = gateway.searchCalls;
      expect(afterMiss, greaterThan(0));

      // Re-opening the board inside the miss window must not fire the same
      // searches again: that storm is what made the search host reject a whole
      // board and leave every row without a play link.
      final reopened = await catalog.matchChart(chart);
      expect(reopened.entries.single.track, isNull);
      expect(gateway.searchCalls, afterMiss);

      // An explicit retry searches again and resolves the row.
      gateway.available = true;
      final retried = await catalog.matchChart(chart, force: true);
      expect(retried.entries.single.track?.id, '9');
      expect(gateway.searchCalls, greaterThan(afterMiss));

      // Once resolved the row is served from cache, forced retry or not.
      final served = gateway.searchCalls;
      final again = await catalog.matchChart(chart, force: true);
      expect(again.entries.single.track?.id, '9');
      expect(gateway.searchCalls, served);
    },
  );

  test('a search outage leaves every row retryable', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lazer-chart-outage-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final gateway = _LateChartGateway()..failing = true;
    final catalog = Catalog(
      gateway: gateway,
      cache: DiskCache(directory: () async => directory),
    );
    const chart = MusicChart(
      id: 'biliboard:1:124',
      title: '周榜',
      source: 'Biliboard',
      issueLabel: 'Current',
      providerKey: 'biliboard:1',
      entries: <ChartEntry>[
        ChartEntry(rank: 1, title: 'シスターに懺悔を', artist: '廃原メモリ'),
      ],
    );

    expect((await catalog.matchChart(chart)).entries.single.track, isNull);

    // No negative entry is written for a transport failure, so the very next
    // visit resolves without waiting out any window.
    gateway
      ..failing = false
      ..available = true;
    expect((await catalog.matchChart(chart)).entries.single.track?.id, '9');
  });

  test('home and search contain only gateway music', () async {
    final gateway = _Gateway();
    final catalog = Catalog(gateway: gateway);
    final feed = await catalog.loadHome();
    expect(feed?.playlists.single.name, '真实歌单');
    expect(feed?.quick.length, 8);
    expect(feed?.recommended.single.id, '12');
    final results = await catalog.search('曲目');
    expect(results.tracks.single.id, '42');
    expect(results.tracks.single.coverUrl, 'https://example.com/42.jpg');
  });

  test('playlist loads every page and preserves service order', () async {
    final gateway = _Gateway();
    final tracks = await Catalog(gateway: gateway).playlistTracks('12');
    expect(gateway.detailPages.map((page) => page.length), <int>[500, 1]);
    expect(tracks.length, 501);
    expect(tracks.first.id, '1');
    expect(tracks.last.id, '501');
  });

  test(
    'search failure propagates instead of returning sample content',
    () async {
      final gateway = _Gateway()..failSearch = true;
      await expectLater(
        Catalog(gateway: gateway).search('曲目'),
        throwsStateError,
      );
    },
  );
}
