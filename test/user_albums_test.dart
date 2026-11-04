import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/cache/disk_cache.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/catalog_details.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';

/// Serves three collected albums in pages of two.
class _AlbumGateway extends NeteaseGateway {
  final List<(int limit, int offset)> calls = <(int limit, int offset)>[];
  bool fail = false;

  @override
  Future<GatewayAlbumPage> collectedAlbums({
    int limit = 25,
    int offset = 0,
  }) async {
    calls.add((limit, offset));
    if (fail) throw const SocketException('offline');
    const int total = 3;
    final List<GatewayAlbum> albums = <GatewayAlbum>[
      for (int index = offset; index < total && index < offset + 2; index++)
        GatewayAlbum(
          id: 100 + index,
          title: 'Album $index',
          artist: 'Artist $index',
          trackCount: 10,
        ),
    ];
    return GatewayAlbumPage(
      albums: albums,
      more: offset + albums.length < total,
      count: total,
    );
  }
}

void main() {
  late Directory directory;
  late DiskCache disk;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lazer-albums-test-');
    disk = DiskCache(directory: () async => directory);
  });
  tearDown(() async => directory.delete(recursive: true));

  test('collected albums page by offset and are cached per offset', () async {
    final gateway = _AlbumGateway();
    final catalog = Catalog(gateway: gateway, cache: disk);

    final UserAlbumPage first = await catalog.userAlbums(7);
    expect(first.albums.map((album) => album.id), <String>['100', '101']);
    expect(first.more, isTrue);
    expect(first.receivedCount, 2);

    final UserAlbumPage second = await catalog.userAlbums(7, offset: 2);
    expect(second.albums.map((album) => album.id), <String>['102']);
    expect(second.more, isFalse);

    // A repeated read of the same offset must not hit the service again.
    await catalog.userAlbums(7, offset: 2);
    expect(gateway.calls, <(int, int)>[(30, 0), (30, 2)]);
  });

  test('a guest session is an empty page rather than a request', () async {
    final gateway = _AlbumGateway();
    final catalog = Catalog(gateway: gateway, cache: disk);
    final UserAlbumPage page = await catalog.userAlbums(0);
    expect(page.albums, isEmpty);
    expect(gateway.calls, isEmpty);
  });

  test('a failing page surfaces the error and caches nothing', () async {
    final gateway = _AlbumGateway()..fail = true;
    final catalog = Catalog(gateway: gateway, cache: disk);
    await expectLater(
      catalog.userAlbums(7),
      throwsA(isA<SocketException>()),
    );
    expect(gateway.calls, <(int, int)>[(30, 0)]);
  });
}
