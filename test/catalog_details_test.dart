import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/cache/disk_cache.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/catalog_details.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';

Map<String, dynamic> _album(int id) => {
  'id': id,
  'name': '专辑 $id',
  'description': '专辑简介',
  'company': '唱片公司',
  'publishTime': 1704067200000,
  'size': 1,
  'artists': [
    {'id': 11, 'name': '歌手甲'},
    {'id': 22, 'name': '歌手乙'},
  ],
};
Map<String, dynamic> _song() => {
  'id': 1,
  'name': '歌曲',
  'dt': 180000,
  'ar': [
    {'id': 11, 'name': '歌手甲'},
    {'id': 22, 'name': '歌手乙'},
  ],
  'al': {'id': 77, 'name': '专辑 77'},
};

class _Gateway extends NeteaseGateway {
  int albumCalls = 0, artistCalls = 0, songCalls = 0;
  final offsets = <int>[];
  bool offline = false, failArtistMetadata = false;
  Completer<void>? albumDelay, albumStarted;
  @override
  Future<Map<String, dynamic>> albumDetailRaw(int id) async {
    albumCalls++;
    if (albumStarted?.isCompleted == false) albumStarted!.complete();
    await albumDelay?.future;
    if (offline) throw const SocketException('offline');
    return {
      'album': _album(id),
      'songs': [_song()],
    };
  }

  @override
  Future<Map<String, dynamic>> artistDetail(int id) async {
    artistCalls++;
    if (offline || failArtistMetadata) throw const SocketException('offline');
    return {
      'data': {
        'artist': {
          'id': id,
          'name': '歌手甲',
          'cover': 'https://example.com/artist.jpg',
          'briefDesc': '歌手简介',
          'musicSize': 50,
          'albumSize': 32,
        },
      },
    };
  }

  @override
  Future<List<GatewaySong>> artistTopSongs(int id) async {
    songCalls++;
    if (offline) throw const SocketException('offline');
    return [GatewaySong.fromJson(_song())];
  }

  @override
  Future<Map<String, dynamic>> artistSongs(
    int id, {
    int limit = 100,
    int offset = 0,
  }) async {
    offsets.add(offset);
    return {
      'songs': offset == 0 ? [_song()] : <Map<String, dynamic>>[],
      'more': false,
    };
  }

  @override
  Future<Map<String, dynamic>> artistAlbums(
    int id, {
    int limit = 30,
    int offset = 0,
  }) async {
    offsets.add(offset);
    if (offline) throw const SocketException('offline');
    return {
      'hotAlbums': offset == 0
          ? [
              _album(77),
              {'id': 0},
            ]
          : [_album(78)],
      'more': offset == 0,
    };
  }
}

class _PlatformGateway extends MusicGateway {
  _PlatformGateway(this.connectionId);
  @override
  final String connectionId;
  @override
  MusicProvider get provider => MusicProvider.navidrome;
  @override
  MusicUser? get user => null;
  @override
  Set<MusicCapability> get capabilities => const {};

  int albumCalls = 0, songCalls = 0, pageCalls = 0;
  bool offline = false;
  Completer<void>? albumDelay, albumStarted;

  @override
  Future<MusicAlbum> album(MusicId id) async {
    albumCalls++;
    if (albumStarted?.isCompleted == false) albumStarted!.complete();
    await albumDelay?.future;
    if (offline) throw const SocketException('offline');
    return MusicAlbum(id: id, title: connectionId, artists: const []);
  }

  @override
  Future<MusicPage<MusicSong>> albumSongs(
    MusicId albumId, {
    int limit = 100,
    int offset = 0,
  }) async {
    songCalls++;
    return MusicPage(
      [
        MusicSong(
          id: id(MusicEntityKind.song, 'song'),
          title: 'Song',
          artists: const [],
          duration: const Duration(minutes: 3),
          albumId: albumId,
        ),
      ],
      offset: offset,
      hasMore: false,
    );
  }

  @override
  Future<MusicPage<MusicAlbum>> artistAlbums(
    MusicId artist, {
    int limit = 30,
    int offset = 0,
  }) async {
    pageCalls++;
    return MusicPage(
      [
        MusicAlbum(
          id: id(MusicEntityKind.album, 'album'),
          title: connectionId,
          artists: const [],
        ),
      ],
      offset: offset,
      hasMore: false,
    );
  }

  @override
  void close() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory directory;
  late DiskCache disk;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lazer-details-');
    disk = DiskCache(directory: () async => directory);
  });
  tearDown(() async => directory.delete(recursive: true));

  test(
    'artist identities survive mapping and cache serialization; old snapshots still load',
    () {
      final track = Catalog.trackFromSong(GatewaySong.fromJson(_song()));
      expect(track.artists.map((a) => a.id), [11, 22]);
      expect(Track.fromJson(track.toJson()).artists.last.name, '歌手乙');
      final old = track.toJson()..remove('artists');
      expect(Track.fromJson(old).artists, isEmpty);
      final album = Catalog.albumFromGateway(GatewayAlbum.fromJson(_album(77)));
      expect(album.artist, '歌手甲 / 歌手乙');
      expect(Album.fromJson(album.toJson()).artists.map((a) => a.id), [11, 22]);
      final singular = GatewayAlbum.fromJson({
        'artist': {'id': 11, 'name': '歌手甲'},
      });
      expect(singular.artists.single.id, 11);
      final full = Catalog.albumFromGateway(
        GatewayAlbum.fromJson({..._album(79), 'type': '\u4e13\u8f91'}),
      );
      final ep = Catalog.albumFromGateway(
        GatewayAlbum.fromJson({..._album(80), 'type': 'EP/Single'}),
      );
      expect(full.releaseGroup, AlbumReleaseGroup.album);
      expect(ep.releaseGroup, AlbumReleaseGroup.singleEp);
      expect(Album.fromJson(ep.toJson()).releaseType, 'EP/Single');
    },
  );

  test('a saved-album page survives the disk cache round trip', () {
    final page = AlbumPage(
      albums: <Album>[
        Catalog.albumFromGateway(GatewayAlbum.fromJson(_album(77))),
      ],
      more: true,
      receivedCount: 3,
      total: 34,
    );
    final restored = AlbumPage.fromJson(page.toJson());
    expect(restored.albums.single.title, page.albums.single.title);
    expect(restored.albums.single.artist, page.albums.single.artist);
    expect(restored.more, isTrue);
    expect(restored.receivedCount, 3);
    expect(restored.total, 34);
    // A snapshot written before the collection total was stored still loads.
    final older = page.toJson()..remove('total');
    expect(AlbumPage.fromJson(older).total, isNull);
  });

  test('artist songs use the paged endpoint and are cached', () async {
    final gateway = _Gateway();
    final catalog = Catalog(gateway: gateway, cache: disk);
    expect((await catalog.artistSongs(11)).single.title, '\u6b4c\u66f2');
    expect((await catalog.artistSongs(11)).single.id, '1');
    expect(gateway.offsets, [0]);
  });

  test(
    'album detail and playback share a coalesced persistent snapshot, including offline refresh',
    () async {
      final gateway = _Gateway();
      final catalog = Catalog(gateway: gateway, cache: disk);
      final results = await Future.wait([
        catalog.albumDetails(77),
        catalog.albumDetails(77),
      ]);
      expect(gateway.albumCalls, 1);
      expect(results.first.description, '专辑简介');
      expect(results.first.company, '唱片公司');
      expect(results.first.publishTime, 1704067200000);
      expect((await catalog.albumTracks(77)).single.albumId, 77);
      final restarted = Catalog(
        gateway: gateway,
        cache: DiskCache(directory: () async => directory),
      );
      gateway.offline = true;
      expect(
        (await restarted.albumDetails(77)).tracks.single.artists.last.id,
        22,
      );
      expect(gateway.albumCalls, 1);
      expect(
        (await restarted.albumDetails(77, force: true)).tracks.single.title,
        '歌曲',
      );
      expect(gateway.albumCalls, 2);
    },
  );

  test(
    'slow album requests from details and playback stay coalesced',
    () async {
      final gateway = _Gateway()
        ..albumDelay = Completer<void>()
        ..albumStarted = Completer<void>();
      final catalog = Catalog(gateway: gateway, cache: disk);
      final detail = catalog.albumDetails(77);
      await gateway.albumStarted!.future;
      final tracks = catalog.albumTracks(77);
      final reopened = catalog.albumDetails(77);
      expect(gateway.albumCalls, 1);
      gateway.albumDelay!.complete();
      await Future.wait<Object>([detail, tracks, reopened]);
      expect(gateway.albumCalls, 1);
    },
  );

  test(
    'failed expired album refreshes reuse stale data until an explicit retry',
    () async {
      final gateway = _Gateway();
      final first = Catalog(gateway: gateway, cache: disk);
      await first.albumDetails(77);
      await disk.expireJson('album-detail:77');
      final catalog = Catalog(gateway: gateway, cache: disk);
      gateway.offline = true;
      expect((await catalog.albumDetails(77)).tracks.single.id, '1');
      expect(gateway.albumCalls, 2);
      await catalog.albumDetails(77);
      await catalog.albumTracks(77);
      expect(gateway.albumCalls, 2);
      await catalog.albumDetails(77, force: true);
      expect(gateway.albumCalls, 3);
      await catalog.albumDetails(77);
      expect(gateway.albumCalls, 3);
      gateway.offline = false;
      await catalog.albumDetails(77, force: true);
      expect(gateway.albumCalls, 4);
    },
  );

  test(
    'uncached album failures cool down while explicit retry stays immediate',
    () async {
      final gateway = _Gateway()..offline = true;
      final catalog = Catalog(gateway: gateway, cache: disk);
      await expectLater(
        catalog.albumDetails(77),
        throwsA(isA<SocketException>()),
      );
      await expectLater(
        catalog.albumDetails(77),
        throwsA(isA<SocketException>()),
      );
      expect(gateway.albumCalls, 1);
      gateway.offline = false;
      expect(
        (await catalog.albumDetails(77, force: true)).tracks.single.id,
        '1',
      );
      expect(gateway.albumCalls, 2);
    },
  );

  test(
    'platform albums coalesce slow loads, persist offline and keep owners isolated',
    () async {
      final gateway = _PlatformGateway('first')
        ..albumDelay = Completer<void>()
        ..albumStarted = Completer<void>();
      final other = _PlatformGateway('second');
      final catalog = Catalog(cache: disk);
      catalog.connections.add(gateway);
      catalog.connections.add(other, select: true);
      final key = gateway.id(MusicEntityKind.album, 'album').cacheKey;
      final detail = catalog.albumDetailsFor(key);
      await gateway.albumStarted!.future;
      final tracks = catalog.albumTracksFor(key);
      final reopened = catalog.albumDetailsFor(key);
      gateway.albumDelay!.complete();
      await Future.wait<Object>([detail, tracks, reopened]);
      expect(gateway.albumCalls, 1);
      expect(gateway.songCalls, 1);
      expect(other.albumCalls, 0);
      expect((await catalog.albumDetailsFor(key)).album.title, 'first');

      final restarted = Catalog(cache: disk)..connections.add(gateway);
      gateway.offline = true;
      expect((await restarted.albumDetailsFor(key)).tracks, hasLength(1));
      expect(gateway.albumCalls, 1);
      expect(
        (await restarted.albumDetailsFor(key, force: true)).album.title,
        'first',
      );
      expect(gateway.albumCalls, 2);
      expect(
        (await catalog.albumDetailsFor(
          other.id(MusicEntityKind.album, 'album').cacheKey,
        )).album.title,
        'second',
      );
    },
  );

  test('platform artist pages share snapshots and support refresh', () async {
    final gateway = _PlatformGateway('artist-server');
    final catalog = Catalog(cache: disk)..connections.add(gateway);
    final artist = ArtistRef(
      id: 0,
      name: 'Artist',
      platformKey: gateway.id(MusicEntityKind.artist, 'artist').cacheKey,
    );
    await Future.wait([
      catalog.artistAlbumPageFor(artist),
      catalog.artistAlbumPageFor(artist),
    ]);
    expect(gateway.pageCalls, 1);
    await catalog.artistAlbumPageFor(artist);
    expect(gateway.pageCalls, 1);
    await catalog.artistAlbumPageFor(artist, force: true);
    expect(gateway.pageCalls, 2);
  });

  test(
    'failed artist release refresh keeps its page without repeated pulls',
    () async {
      final gateway = _Gateway();
      final catalog = Catalog(gateway: gateway, cache: disk);
      await catalog.artistAlbumPage(11);
      gateway.offline = true;
      await catalog.artistAlbumPage(11, force: true);
      await catalog.artistAlbumPage(11);
      await catalog.artistAlbumPage(11);
      expect(gateway.offsets, [0, 0]);
      gateway.offline = false;
      await catalog.artistAlbumPage(11, force: true);
      expect(gateway.offsets, [0, 0, 0]);
    },
  );

  test(
    'artist songs remain available when optional profile metadata fails and can be refreshed',
    () async {
      final gateway = _Gateway()..failArtistMetadata = true;
      final catalog = Catalog(gateway: gateway, cache: disk);
      const seed = ArtistRef(id: 11, name: '入口歌手');
      final details = await catalog.artistDetails(seed);
      expect(details.artist.name, seed.name);
      expect(details.tracks.single.id, '1');
      gateway.failArtistMetadata = false;
      final refreshed = await catalog.artistDetails(seed, force: true);
      expect(refreshed.artist.name, '歌手甲');
      expect(refreshed.artist.coverUrl, 'https://example.com/artist.jpg');
      expect(refreshed.description, '歌手简介');
      expect(refreshed.musicCount, 50);
      expect(refreshed.albumCount, 32);
      gateway.offline = true;
      expect(
        (await catalog.artistDetails(seed, force: true)).description,
        '歌手简介',
      );
    },
  );

  test(
    'artist album pages preserve server offsets when invalid entries are filtered',
    () async {
      final gateway = _Gateway();
      final catalog = Catalog(gateway: gateway, cache: disk);
      final first = await catalog.artistAlbumPage(11);
      expect(first.albums.map((album) => album.id), ['77']);
      expect(first.receivedCount, 2);
      expect(first.more, true);
      final next = await catalog.artistAlbumPage(
        11,
        offset: first.receivedCount,
      );
      expect(next.albums.single.id, '78');
      expect(next.more, false);
      await catalog.artistAlbumPage(11, offset: 2);
      expect(gateway.offsets, [0, 2]);
    },
  );
}
