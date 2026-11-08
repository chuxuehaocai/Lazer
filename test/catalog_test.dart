import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/cache/disk_cache.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';

class _Gateway extends MusicGateway {
  @override
  final String connectionId = 'one';
  @override
  MusicProvider get provider =>
      const MusicProvider(id: 'fixture', name: 'Fixture');
  String account = 'alice';
  @override
  MusicUser? get user =>
      MusicUser(id: id(MusicEntityKind.user, account), name: account);
  @override
  Set<MusicCapability> get capabilities => const {
    MusicCapability.playlists,
    MusicCapability.favorites,
    MusicCapability.homeFeed,
    MusicCapability.lyrics,
  };
  bool offline = false, failSearch = false;
  int playlistCalls = 0,
      collectionCalls = 0,
      lyricCalls = 0,
      homeCalls = 0,
      searchCalls = 0,
      statsCalls = 0,
      albumCalls = 0;
  Completer<void>? gate;
  final offsets = <int>[];
  String title = 'First';
  MusicSong songAt(int i) => MusicSong(
    id: id(MusicEntityKind.song, '$i'),
    title: 'Song $i',
    artists: [
      MusicArtist(id: id(MusicEntityKind.artist, 'artist'), name: 'Artist'),
    ],
    duration: const Duration(minutes: 3),
    translatedTitle: '译名',
  );
  void check() {
    if (offline) throw const SocketException('offline');
  }

  @override
  Future<MusicPage<MusicSong>> playlistSongs(
    MusicId playlist, {
    int limit = 100,
    int offset = 0,
  }) async {
    playlistCalls++;
    offsets.add(offset);
    final saved = title;
    await gate?.future;
    check();
    return MusicPage(
      [
        for (var i = offset; i < (offset + limit).clamp(0, 205); i++)
          MusicSong(
            id: id(MusicEntityKind.song, '$i'),
            title: '$saved $i',
            artists: [],
            duration: Duration.zero,
          ),
      ],
      offset: offset,
      hasMore: offset + limit < 205,
    );
  }

  @override
  Future<MusicPage<MusicPlaylist>> playlists({
    int limit = 30,
    int offset = 0,
  }) async {
    collectionCalls++;
    check();
    return MusicPage(
      [
        MusicPlaylist(
          id: id(MusicEntityKind.playlist, 'likes'),
          name: '$account 喜欢的音乐',
          isFavorites: true,
          writable: true,
          owner: account,
        ),
        MusicPlaylist(
          id: id(MusicEntityKind.playlist, 'created'),
          name: 'Created',
          writable: true,
        ),
        MusicPlaylist(id: id(MusicEntityKind.playlist, 'saved'), name: 'Saved'),
      ],
      offset: offset,
      hasMore: false,
    );
  }

  @override
  Future<MusicPage<MusicSong>> favorites({
    int limit = 100,
    int offset = 0,
  }) async {
    check();
    return MusicPage([songAt(1)], offset: offset, hasMore: false);
  }

  @override
  Future<List<MusicLyrics>> lyrics(MusicId song) async {
    lyricCalls++;
    check();
    return [
      MusicLyrics(
        lines: [],
        lrc: '[00:00]Line $lyricCalls',
        translation: '[00:00]翻译',
        synced: true,
      ),
    ];
  }

  @override
  Future<MusicHome> homeFeed() async {
    homeCalls++;
    check();
    return MusicHome(daily: [songAt(42)], quick: [songAt(1)]);
  }

  @override
  Future<MusicSearchResult> search(
    String query, {
    int limit = 30,
    int offset = 0,
  }) async {
    searchCalls++;
    check();
    if (failSearch) throw const SocketException('search');
    final match = RegExp(r'Song (\d+)').firstMatch(query);
    final songs = match == null
        ? <MusicSong>[]
        : [songAt(int.parse(match.group(1)!))];
    return MusicSearchResult(
      songs: MusicPage(songs, offset: offset, hasMore: false),
      albums: MusicPage([], offset: 0, hasMore: false),
      artists: MusicPage([], offset: 0, hasMore: false),
      playlists: MusicPage([], offset: 0, hasMore: false),
    );
  }

  @override
  Future<MusicPage<MusicPlayRecord>> playStats({
    int limit = 100,
    int offset = 0,
  }) async {
    statsCalls++;
    check();
    return MusicPage(
      [MusicPlayRecord(song: songAt(1), playCount: 3)],
      offset: offset,
      hasMore: false,
    );
  }

  @override
  Future<MusicPage<MusicAlbum>> savedAlbums({
    int limit = 30,
    int offset = 0,
  }) async {
    albumCalls++;
    check();
    return MusicPage(
      [
        MusicAlbum(
          id: id(MusicEntityKind.album, '$offset'),
          title: title,
          artists: [],
        ),
      ],
      offset: offset,
      hasMore: offset == 0,
    );
  }
}

class _StubbornCache extends DiskCache {
  _StubbornCache({required super.directory});
  @override
  Future<void> expireJson(String key) async {}
}

class _WriteGateCache extends DiskCache {
  _WriteGateCache({required super.directory});
  final started = Completer<void>(), release = Completer<void>();
  bool first = true;
  @override
  Future<void> writeJson(
    String key,
    Map<String, dynamic> data, {
    DateTime? savedAt,
  }) async {
    await super.writeJson(key, data, savedAt: savedAt);
    if (first && key.startsWith('playlist-')) {
      first = false;
      started.complete();
      await release.future;
    }
  }
}

void main() {
  late Directory directory;
  late DiskCache disk;
  late _Gateway gateway;
  late Catalog catalog;
  late String playlist;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('neutral-catalog-');
    disk = DiskCache(directory: () async => directory);
    gateway = _Gateway();
    catalog = Catalog(gateway: gateway, cache: disk);
    playlist = gateway.id(MusicEntityKind.playlist, 'list').cacheKey;
  });
  tearDown(() async => directory.delete(recursive: true));
  test(
    'complete playlists page in order, coalesce, and reuse warm memory',
    () async {
      final lists = await Future.wait([
        catalog.playlistTracks(playlist),
        catalog.playlistTracks(playlist),
      ]);
      expect(lists.first, hasLength(205));
      expect(lists.last.last.title, 'First 204');
      expect(gateway.offsets, [0, 100, 200]);
      await disk.remove(
        CacheBucket.data,
        'playlist-v2:${gateway.cacheNamespace}:$playlist',
        extension: 'json',
      );
      await catalog.playlistTracks(playlist);
      expect(gateway.playlistCalls, 3);
    },
  );
  test(
    'stored playlist is available after restart and stale offline refresh',
    () async {
      await catalog.playlistTracks(playlist);
      gateway.offline = true;
      final restarted = Catalog(gateway: gateway, cache: disk);
      expect((await restarted.cachedPlaylistTracks(playlist))!.length, 205);
      expect(
        (await restarted.refreshPlaylist(playlist)).first.title,
        'First 0',
      );
    },
  );
  test('a failed disk tombstone cannot resurrect invalidated memory', () async {
    catalog = Catalog(
      gateway: gateway,
      cache: _StubbornCache(directory: () async => directory),
    );
    await catalog.playlistTracks(playlist);
    gateway.title = 'Changed';
    await catalog.invalidatePlaylist(playlist);
    expect((await catalog.playlistTracks(playlist)).first.title, 'Changed 0');
  });
  test(
    'invalidation during a disk write cannot make an old response fresh',
    () async {
      final cache = _WriteGateCache(directory: () async => directory);
      catalog = Catalog(gateway: gateway, cache: cache);
      final old = catalog.playlistTracks(playlist);
      await cache.started.future;
      gateway.title = 'Changed';
      await catalog.invalidatePlaylist(playlist);
      cache.release.complete();
      await old;
      expect((await catalog.playlistTracks(playlist)).first.title, 'Changed 0');
    },
  );
  test(
    'a slow playlist read is retired when a mutation invalidates it',
    () async {
      final gate = gateway.gate = Completer<void>();
      final old = catalog.playlistTracks(playlist);
      await Future<void>.delayed(Duration.zero);
      gateway.title = 'Changed';
      await catalog.invalidatePlaylist(playlist);
      gateway.gate = null;
      final fresh = await catalog.playlistTracks(playlist);
      gate.complete();
      await old;
      expect(fresh.first.title, 'Changed 0');
      expect((await catalog.playlistTracks(playlist)).first.title, 'Changed 0');
    },
  );
  test(
    'collections show a single personal favorite and preserve ownership',
    () async {
      final value = await catalog.userCollections(1);
      expect(value.liked!.name, 'alice 喜欢的音乐');
      expect(value.created.single.name, 'Created');
      expect(value.subscribed.single.name, 'Saved');
      expect(value.created.any((p) => p.id == value.liked!.id), isFalse);
      expect(value.liked!.trackIds, hasLength(1));
    },
  );
  test(
    'account collections and private playlists stay isolated on disk',
    () async {
      await catalog.userCollections(1);
      await catalog.playlistTracks(playlist);
      gateway.account = 'bob';
      expect(await catalog.cachedUserCollections(1), isNull);
      expect(await catalog.cachedPlaylistTracks(playlist), isNull);
      expect((await catalog.userCollections(1)).liked!.name, 'bob 喜欢的音乐');
      gateway.account = 'alice';
      expect(
        (await catalog.cachedUserCollections(1))!.liked!.name,
        'alice 喜欢的音乐',
      );
    },
  );
  test(
    'collection snapshots survive restart and explicit invalidation',
    () async {
      await catalog.userCollections(1);
      final restarted = Catalog(gateway: gateway, cache: disk);
      gateway.offline = true;
      expect(
        (await restarted.cachedUserCollections(1))!.created.single.name,
        'Created',
      );
      expect(
        (await restarted.userCollections(1)).subscribed.single.name,
        'Saved',
      );
      gateway.offline = false;
      await restarted.invalidateCollections(1);
      await restarted.userCollections(1);
      expect(gateway.collectionCalls, 2);
    },
  );
  test(
    'lyrics cache keeps translations offline and refreshes explicitly',
    () async {
      final track = catalog.trackFromMusicSong(gateway.songAt(42));
      await catalog.lyricsFor(track);
      gateway.offline = true;
      final restarted = Catalog(gateway: gateway, cache: disk);
      expect((await restarted.lyricsFor(track))!.tlyric, '[00:00]翻译');
      expect(gateway.lyricCalls, 1);
      gateway.offline = false;
      await restarted.invalidateLyrics(track.id);
      expect((await restarted.lyricsFor(track))!.lrc, '[00:00]Line 2');
    },
  );
  test(
    'home recommendations persist and stale data survives an offline refresh',
    () async {
      expect((await catalog.loadHome())!.daily.single.title, 'Song 42');
      gateway.offline = true;
      final restarted = Catalog(gateway: gateway, cache: disk);
      expect((await restarted.loadHome())!.quick.single.title, 'Song 1');
      await restarted.invalidateHome();
      expect((await restarted.loadHome())!.daily.single.title, 'Song 42');
    },
  );
  test(
    'search preserves translations and surfaces failures without sample music',
    () async {
      expect(
        (await catalog.search('Song 42')).tracks.single.translatedTitle,
        '译名',
      );
      gateway.failSearch = true;
      await expectLater(
        catalog.search('Song 42'),
        throwsA(isA<SocketException>()),
      );
    },
  );
  test('saved album refresh retires all cached page generations', () async {
    await catalog.savedAlbums(1);
    await catalog.savedAlbums(1, offset: 1);
    gateway.title = 'Fresh';
    await catalog.savedAlbums(1, force: true);
    expect(
      (await catalog.savedAlbums(1, offset: 1)).albums.single.title,
      'Fresh',
    );
    expect(gateway.albumCalls, 4);
  });
  test(
    'play statistics coalesce until invalidated and persist offline',
    () async {
      await Future.wait([catalog.playStats(1), catalog.playStats(1)]);
      expect(gateway.statsCalls, 1);
      gateway.offline = true;
      expect(
        (await Catalog(
          gateway: gateway,
          cache: disk,
        ).playStats(1)).single.playCount,
        3,
      );
      gateway.offline = false;
      await catalog.invalidatePlayStats(1);
      await catalog.playStats(1);
      expect(gateway.statsCalls, 2);
    },
  );
  test(
    'chart matching resolves every row and shares positive snapshots',
    () async {
      final chart = MusicChart(
        id: 'fixture-chart',
        title: 'Chart',
        source: 'Fixture',
        issueLabel: '',
        entries: [
          for (var i = 0; i < 40; i++)
            ChartEntry(rank: i + 1, title: 'Song $i', artist: 'Artist'),
        ],
      );
      final matched = await catalog.matchChart(chart);
      expect(matched.entries.every((e) => e.track != null), isTrue);
      expect(gateway.searchCalls, 40);
      await catalog.matchChart(chart);
      expect(gateway.searchCalls, 40);
    },
  );
  test(
    'search outages leave chart rows retryable and account caches separate',
    () async {
      const chart = MusicChart(
        id: 'chart',
        title: 'Chart',
        source: 'Fixture',
        issueLabel: '',
        entries: [ChartEntry(rank: 1, title: 'Song 1', artist: 'Artist')],
      );
      gateway.offline = true;
      expect((await catalog.matchChart(chart)).entries.single.track, isNull);
      gateway.offline = false;
      expect((await catalog.matchChart(chart)).entries.single.track, isNotNull);
      final before = gateway.searchCalls;
      gateway.account = 'bob';
      await catalog.matchChart(chart);
      expect(gateway.searchCalls, greaterThan(before));
    },
  );
}
