import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/cache/disk_cache.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/ui/home_pages.dart';

class _DailyGateway extends MusicGateway {
  bool offline = false;
  @override
  MusicProvider get provider =>
      const MusicProvider(id: 'fixture', name: 'Fixture');
  @override
  String get connectionId => 'daily';
  @override
  MusicUser? get user => null;
  @override
  Set<MusicCapability> get capabilities => const {MusicCapability.homeFeed};
  @override
  Future<MusicHome> homeFeed() async {
    if (offline) throw const SocketException('offline');
    final songs = [
      for (var i = 1; i <= 35; i++)
        MusicSong(
          id: id(MusicEntityKind.song, '$i'),
          title: 'Daily $i',
          artists: [],
          duration: const Duration(minutes: 3),
        ),
    ];
    return MusicHome(quick: songs.take(8).toList(), daily: songs);
  }
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
      expect(playlist.trackIds.last, 'fixture:daily:song:35');
      expect(
        (await catalog.playlistTracks(playlist.id)).last.id,
        'fixture:daily:song:35',
      );
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
