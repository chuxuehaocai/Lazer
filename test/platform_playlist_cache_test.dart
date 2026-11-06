import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/cache/disk_cache.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/library_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Gateway extends MusicGateway {
  _Gateway({this.connectionId = 'connection'}) {
    connect('alice');
  }
  @override
  final String connectionId;
  @override
  MusicProvider get provider =>
      const MusicProvider(id: 'fixture', name: 'Fixture');
  @override
  MusicUser? user;
  @override
  Set<MusicCapability> get capabilities => {
    MusicCapability.playlists,
    MusicCapability.favorites,
  };
  bool offline = false;
  int playlistCalls = 0, songCalls = 0, favoriteCalls = 0;
  int version = 1;
  Completer<void>? gate;
  final started = Completer<void>();
  void connect(String account) =>
      user = MusicUser(id: id(MusicEntityKind.user, account), name: account);
  String get playlistKey => id(MusicEntityKind.playlist, 'opaque:/夜').cacheKey;
  String get favoriteKey =>
      id(MusicEntityKind.playlist, 'real-favorites').cacheKey;
  MusicSong songAt(int index) => MusicSong(
    id: id(MusicEntityKind.song, 'song-${index == 204 ? 0 : index}'),
    title: '${user!.name} song $index v$version',
    coverUrl: 'https://images.test/song-$index.jpg',
    artists: [],
    duration: const Duration(minutes: 3),
  );
  void _check() {
    if (offline) throw const SocketException('offline');
  }

  @override
  Future<MusicPage<MusicPlaylist>> playlists({
    int limit = 30,
    int offset = 0,
  }) async {
    playlistCalls++;
    _check();
    final personal = MusicPlaylist(
      id: id(MusicEntityKind.playlist, 'real-favorites'),
      name: '${user!.name}喜欢的音乐',
      owner: user!.id.value,
      writable: true,
      isFavorites: true,
      songCount: 1,
    );
    return MusicPage(
      [
        personal,
        MusicPlaylist(
          id: id(MusicEntityKind.playlist, 'opaque:/夜'),
          name: 'Own playlist',
          writable: true,
          songCount: 205,
        ),
        personal,
      ].skip(offset).take(limit).toList(),
      offset: offset,
      hasMore: false,
    );
  }

  @override
  Future<MusicPage<MusicSong>> favorites({
    int limit = 100,
    int offset = 0,
  }) async {
    favoriteCalls++;
    _check();
    return MusicPage(
      offset == 0 ? [songAt(0)] : [],
      offset: offset,
      hasMore: false,
    );
  }

  @override
  Future<MusicPage<MusicSong>> playlistSongs(
    MusicId playlist, {
    int limit = 100,
    int offset = 0,
  }) async {
    songCalls++;
    if (!started.isCompleted) started.complete();
    if (offset == 0 && gate != null) await gate!.future;
    _check();
    final count = playlist.value == 'real-favorites' ? 1 : 205;
    final items = [
      for (var i = offset; i < count && i < offset + limit; i++) songAt(i),
    ];
    return MusicPage(
      items,
      offset: offset,
      hasMore: offset + items.length < count,
    );
  }
}

void main() {
  late Directory directory;
  late DiskCache disk;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('lazer-platform-cache-');
    disk = DiskCache(directory: () async => directory);
  });
  tearDown(() async {
    await disk.settle();
    await directory.delete(recursive: true);
  });
  Catalog catalog(_Gateway gateway) =>
      Catalog(cache: disk)..connections.add(gateway, select: true);

  test(
    'a real favorites playlist keeps its name and appears in only one collection',
    () async {
      final gateway = _Gateway();
      final data = catalog(gateway);
      final collections = await data.userCollections(1);
      expect(collections.liked!.id, gateway.favoriteKey);
      expect(collections.liked!.name, 'alice喜欢的音乐');
      expect(collections.liked!.trackIds, [gateway.songAt(0).id.cacheKey]);
      expect(collections.created.map((list) => list.id), [gateway.playlistKey]);
      expect(collections.subscribed, isEmpty);
    },
  );

  test(
    'complete opaque-ID playlists share requests and survive a cold offline restart',
    () async {
      final gateway = _Gateway()..gate = Completer<void>();
      final data = catalog(gateway);
      final first = data.playlistTracks(gateway.playlistKey);
      final second = data.playlistTracks(gateway.playlistKey);
      await gateway.started.future;
      gateway.gate!.complete();
      final tracks = await first;
      expect(await second, same(tracks));
      expect(tracks, hasLength(205));
      expect(
        tracks.last.id,
        tracks.first.id,
        reason: 'playlist duplicates preserve their positions',
      );
      expect(gateway.songCalls, 3);
      expect(await data.playlistTracks(gateway.playlistKey), same(tracks));
      expect(gateway.songCalls, 3);
      final offline = _Gateway()..offline = true;
      final restarted = catalog(offline);
      final stored = await restarted.cachedPlaylistTracks(offline.playlistKey);
      expect(stored!.map((track) => track.id), tracks.map((track) => track.id));
      expect(
        stored.map((track) => track.coverUrl),
        tracks.map((track) => track.coverUrl),
      );
      expect(
        (await restarted.playlistTracks(offline.playlistKey)).first.title,
        tracks.first.title,
      );
      expect(offline.songCalls, 0);
      expect(
        await restarted.refreshPlaylist(offline.playlistKey),
        hasLength(205),
      );
      expect(
        offline.songCalls,
        1,
        reason: 'failed refresh can use the prior snapshot',
      );
      offline.offline = false;
      offline.version = 2;
      expect(
        (await restarted.playlistTracks(offline.playlistKey)).first.title,
        contains('v2'),
      );
    },
  );

  test(
    'collections persist and account and connection namespaces stay independent',
    () async {
      final gateway = _Gateway();
      final data = catalog(gateway);
      await data.userCollections(1);
      await data.playlistTracks(gateway.playlistKey);
      expect((await data.userCollections(1)).liked!.name, 'alice喜欢的音乐');
      expect(gateway.playlistCalls, 1);
      final offline = _Gateway()..offline = true;
      final restarted = catalog(offline);
      expect(
        (await restarted.cachedUserCollections(1))!.liked!.name,
        'alice喜欢的音乐',
      );
      expect((await restarted.userCollections(1)).liked!.name, 'alice喜欢的音乐');
      expect(offline.playlistCalls, 0);
      offline.connect('bob');
      expect(await restarted.cachedUserCollections(1), isNull);
      expect(await restarted.cachedPlaylistTracks(offline.playlistKey), isNull);
      await expectLater(
        restarted.userCollections(1),
        throwsA(isA<SocketException>()),
      );
      await expectLater(
        restarted.playlistTracks(offline.playlistKey),
        throwsA(isA<SocketException>()),
      );
      final other = _Gateway(connectionId: 'different')..offline = true;
      restarted.connections.add(other, select: true);
      expect(await restarted.cachedPlaylistTracks(other.playlistKey), isNull);
    },
  );

  test(
    'a playlist cache belongs to its owner while another source is selected',
    () async {
      final gateway = _Gateway();
      final data = catalog(gateway);
      await data.playlistTracks(gateway.playlistKey);
      data.selectConnection('local:local');
      gateway.offline = true;
      expect(
        await data.cachedPlaylistTracks(gateway.playlistKey),
        hasLength(205),
      );
      expect(await data.playlistTracks(gateway.playlistKey), hasLength(205));
      expect(gateway.songCalls, 3);
      await data.invalidatePlaylist(gateway.playlistKey);
      expect(await data.cachedPlaylistTracks(gateway.playlistKey), isNull);
    },
  );

  test(
    'an account change during pagination cannot store songs under the old account',
    () async {
      final gateway = _Gateway()..gate = Completer<void>();
      final data = catalog(gateway);
      final pending = data.playlistTracks(gateway.playlistKey);
      final failure = expectLater(pending, throwsStateError);
      await gateway.started.future;
      gateway.connect('bob');
      gateway.gate!.complete();
      await failure;
      expect(await data.cachedPlaylistTracks(gateway.playlistKey), isNull);
      expect(
        (await data.playlistTracks(gateway.playlistKey)).first.title,
        startsWith('bob'),
      );
      gateway.connect('alice');
      expect(await data.cachedPlaylistTracks(gateway.playlistKey), isNull);
    },
  );

  testWidgets(
    'the library does not repeat owned playlists in the recommendation shelf',
    (tester) async {
      final gateway = _Gateway();
      final data = catalog(gateway);
      late UserCollections collections;
      await tester.runAsync(() async {
        collections = await data.userCollections(1);
        await data.loadHome(userId: 1);
      });
      final state = AppState(catalog: data)..collections = collections;
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(),
          home: Scaffold(
            body: AppLibraryPage(
              state: state,
              onOpenPlaylist: (_) {},
              onOpenLocalMusic: () {},
              onOpenSavedAlbums: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('alice喜欢的音乐'), findsOneWidget);
      expect(find.text('Own playlist'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
