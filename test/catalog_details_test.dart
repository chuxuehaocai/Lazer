import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/cache/disk_cache.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/catalog_details.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';

class _PlatformGateway extends MusicGateway {
  _PlatformGateway(this.connectionId);
  @override
  final String connectionId;
  @override
  MusicProvider get provider =>
      const MusicProvider(id: 'fixture', name: 'Fixture');
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
    if (offline) throw const SocketException('offline');
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
    directory = await Directory.systemTemp.createTemp('details-');
    disk = DiskCache(directory: () async => directory);
  });
  tearDown(() async => directory.delete(recursive: true));
  test('opaque album identity and artist references survive serialization', () {
    final gateway = _PlatformGateway('one');
    final catalog = Catalog(gateway: gateway, cache: disk);
    final song = MusicSong(
      id: gateway.id(MusicEntityKind.song, 'song'),
      title: 'Title',
      artists: [
        MusicArtist(
          id: gateway.id(MusicEntityKind.artist, 'artist'),
          name: 'Artist',
        ),
      ],
      duration: Duration.zero,
      albumId: gateway.id(MusicEntityKind.album, 'album'),
    );
    final restored = Track.fromJson(catalog.trackFromMusicSong(song).toJson());
    expect(restored.artists.single.key, song.artists.single.id.cacheKey);
    expect(restored.albumIdentity, song.albumId!.cacheKey);
    final old = restored.toJson()..remove('artists');
    expect(Track.fromJson(old).artists, isEmpty);
  });
  test('album details and playback coalesce through a slow request', () async {
    final gateway = _PlatformGateway('one')
      ..albumDelay = Completer<void>()
      ..albumStarted = Completer<void>();
    final catalog = Catalog(gateway: gateway, cache: disk);
    final key = gateway.id(MusicEntityKind.album, 'album').cacheKey;
    final detail = catalog.albumDetailsFor(key);
    await gateway.albumStarted!.future;
    final tracks = catalog.albumTracksFor(key);
    final reopened = catalog.albumDetailsFor(key);
    expect(gateway.albumCalls, 1);
    gateway.albumDelay!.complete();
    await Future.wait<Object>([detail, tracks, reopened]);
    expect(gateway.songCalls, 1);
  });
  test(
    'album snapshots persist offline and remain isolated by owner',
    () async {
      final first = _PlatformGateway('first'),
          second = _PlatformGateway('second');
      final catalog = Catalog(gateway: first, cache: disk)
        ..connections.add(second);
      final key = first.id(MusicEntityKind.album, 'album').cacheKey;
      await catalog.albumDetailsFor(key);
      first.offline = true;
      final restarted = Catalog(gateway: first, cache: disk);
      expect(
        (await restarted.albumDetailsFor(key, force: true)).album.title,
        'first',
      );
      expect(
        (await catalog.albumDetailsFor(
          second.id(MusicEntityKind.album, 'album').cacheKey,
        )).album.title,
        'second',
      );
    },
  );
  test(
    'uncached failures cool down but explicit retry stays immediate',
    () async {
      final gateway = _PlatformGateway('one')..offline = true;
      final catalog = Catalog(gateway: gateway, cache: disk);
      final key = gateway.id(MusicEntityKind.album, 'album').cacheKey;
      for (var i = 0; i < 3; i++) {
        await expectLater(
          catalog.albumDetailsFor(key),
          throwsA(isA<SocketException>()),
        );
      }
      expect(gateway.albumCalls, 1);
      gateway.offline = false;
      expect(
        (await catalog.albumDetailsFor(key, force: true)).tracks,
        hasLength(1),
      );
      expect(gateway.albumCalls, 2);
    },
  );
  test('stale album failures are cached until an explicit retry', () async {
    final gateway = _PlatformGateway('one');
    final catalog = Catalog(gateway: gateway, cache: disk);
    final key = gateway.id(MusicEntityKind.album, 'album').cacheKey;
    await catalog.albumDetailsFor(key);
    gateway.offline = true;
    await catalog.albumDetailsFor(key, force: true);
    await catalog.albumDetailsFor(key);
    expect(gateway.albumCalls, 2);
    gateway.offline = false;
    await catalog.albumDetailsFor(key, force: true);
    expect(gateway.albumCalls, 3);
  });
  test('artist release pages coalesce and support explicit refresh', () async {
    final gateway = _PlatformGateway('one');
    final catalog = Catalog(gateway: gateway, cache: disk);
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
    await catalog.artistAlbumPageFor(artist, force: true);
    expect(gateway.pageCalls, 2);
  });
  test(
    'artist release failures preserve the previous page and retry on demand',
    () async {
      final gateway = _PlatformGateway('one');
      final catalog = Catalog(gateway: gateway, cache: disk);
      final artist = ArtistRef(
        id: 0,
        name: 'Artist',
        platformKey: gateway.id(MusicEntityKind.artist, 'artist').cacheKey,
      );
      await catalog.artistAlbumPageFor(artist);
      gateway.offline = true;
      expect(
        (await catalog.artistAlbumPageFor(artist, force: true)).albums,
        hasLength(1),
      );
      await catalog.artistAlbumPageFor(artist);
      expect(gateway.pageCalls, 2);
      gateway.offline = false;
      await catalog.artistAlbumPageFor(artist, force: true);
      expect(gateway.pageCalls, 3);
    },
  );
  test(
    'optional artist profile failure still opens cached songs and identity',
    () async {
      final gateway = _PlatformGateway('one');
      final catalog = Catalog(gateway: gateway, cache: disk);
      final artist = ArtistRef(
        id: 0,
        name: 'Seed',
        platformKey: gateway.id(MusicEntityKind.artist, 'artist').cacheKey,
      );
      final detail = await catalog.artistDetails(artist);
      expect(detail.artist.name, 'Seed');
      expect(detail.tracks.single.title, 'Song');
      await catalog.artistDetails(artist);
      expect(gateway.songCalls, 1);
    },
  );
  test('saved album page serialization retains paging offsets', () {
    const page = AlbumPage(
      albums: [],
      more: true,
      receivedCount: 30,
      total: 42,
    );
    final restored = AlbumPage.fromJson(page.toJson());
    expect(restored.receivedCount, 30);
    expect(restored.more, isTrue);
    expect(restored.total, 42);
  });
}
