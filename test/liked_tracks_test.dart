import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/cache/disk_cache.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';

/// Mirrors a real "喜欢的音乐" collection: 1154 ids in the detail payload.
class _BigLikedGateway extends NeteaseGateway {
  static const int songCount = 1154;
  int detailCalls = 0;
  int detailPages = 0;

  @override
  Future<Map<String, dynamic>> playlistDetail(
    int id, {
    int subscriberLimit = 8,
  }) async {
    detailCalls++;
    return <String, dynamic>{
      'code': 200,
      'playlist': <String, dynamic>{
        'id': id,
        'name': '喜欢的音乐',
        'trackCount': songCount,
        'trackIds': <Map<String, int>>[
          for (int songId = 1; songId <= songCount; songId++)
            <String, int>{'id': songId},
        ],
      },
    };
  }

  @override
  Future<List<GatewaySong>> songDetails(List<int> ids) async {
    detailPages++;
    return <GatewaySong>[
      for (final int id in ids)
        GatewaySong(
          id: id,
          title: 'Song $id',
          artists: const <String>['Tester'],
          albumName: 'Album',
          duration: const Duration(seconds: 3),
        ),
    ];
  }
}

void main() {
  late Directory directory;
  late DiskCache disk;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lazer-liked-test-');
    disk = DiskCache(directory: () async => directory);
  });
  tearDown(() async => directory.delete(recursive: true));

  test('a liked collection larger than 1000 loads every track', () async {
    final gateway = _BigLikedGateway();
    final catalog = Catalog(gateway: gateway, cache: disk);
    final List<Track> tracks = await catalog.playlistTracks('501');
    expect(tracks.length, _BigLikedGateway.songCount);
    expect(tracks.first.id, '1');
    expect(tracks.last.id, '1154');
    // 1154 ids are fetched in 500-song pages by the catalogue.
    expect(gateway.detailPages, 3);
  });
}
