import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/cache/disk_cache.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/legacy/legacy_home_pages.dart';

class _DailyGateway extends NeteaseGateway {
  bool offline = false;

  @override
  Future<List<GatewaySong>> dailyRecommendedSongs() async {
    if (offline) throw const SocketException('offline');
    return List<GatewaySong>.generate(
      35,
      (index) => GatewaySong(
        id: index + 1,
        title: 'Daily ${index + 1}',
        artists: const <String>['Artist'],
        albumName: 'Album',
        duration: const Duration(minutes: 3),
      ),
    );
  }

  @override
  Future<List<GatewayPlaylist>> topPlaylists({
    String category = '全部',
    int limit = 12,
    int offset = 0,
  }) async => const [];
  @override
  Future<List<GatewayPlaylist>> userPlaylists(
    int uid, {
    int limit = 30,
    int offset = 0,
  }) async => const [];
  @override
  Future<List<GatewayPlaylist>> personalizedPlaylists({int limit = 12}) async =>
      const [];
  @override
  Future<List<GatewayPlaylist>> dailyRecommendedPlaylists() async => const [];
  @override
  Future<List<GatewaySong>> personalizedNewSongs({int limit = 20}) async =>
      const [];
}

void main() {
  test(
    'daily playlist keeps all recommendations beyond the quick shelf and survives restart',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lazer-daily-playlist-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final disk = DiskCache(directory: () async => directory);
      final catalog = Catalog(gateway: _DailyGateway(), cache: disk);
      final feed = (await catalog.loadHome(userId: 7))!;
      expect(feed.quick, hasLength(8));
      expect(feed.daily, hasLength(35));
      final playlist = dailyRecommendationsPlaylist(feed);
      expect(playlist.id, dailyRecommendationsPlaylistId);
      expect(playlist.trackCount, 35);
      expect(playlist.trackIds.last, '35');
      expect((await catalog.playlistTracks(playlist.id)).last.id, '35');
      expect(await catalog.cachedPlaylistTracks(playlist.id), hasLength(35));

      final restarted = Catalog(
        gateway: _DailyGateway()..offline = true,
        cache: DiskCache(directory: () async => directory),
      );
      final storedFeed = (await restarted.loadHome(userId: 7))!;
      expect(storedFeed.daily, hasLength(35));
      final stored = await restarted.playlistTracks(
        dailyRecommendationsPlaylistId,
      );
      expect(stored.map((track) => track.id), playlist.trackIds);
    },
  );

  test('older feeds without a daily field still open their quick tracks', () {
    const track = Track(
      id: '7',
      title: 'Quick',
      artist: 'Artist',
      album: 'Album',
      duration: Duration(minutes: 3),
      coverSeed: 7,
    );
    const feed = HomeFeed(
      featuredTracks: [],
      quick: [track],
      playlists: [],
      albums: [],
    );
    expect(dailyRecommendationsPlaylist(feed).trackIds, ['7']);
    expect(
      dailyRecommendationsPlaylist(feed, serverLibrary: true).name,
      '随机发现',
    );
  });
}
