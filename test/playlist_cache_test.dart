import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/legacy/legacy_pages.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/state/app_state.dart';

const GatewayUserProfile _profile = GatewayUserProfile(
  userId: 7,
  nickname: '测试账户',
);

Playlist _playlist(String id, String name) => Playlist(
  id: id,
  name: name,
  trackIds: const <String>[],
  coverSeed: 1,
  trackCount: 1,
);

Track _track(String id, String title) => Track(
  id: id,
  title: title,
  artist: 'Artist',
  album: 'Album',
  duration: const Duration(minutes: 3),
  coverSeed: 1,
);

class _Gateway extends NeteaseGateway {
  @override
  Future<GatewayLoginStatus> loginWithCookie(String cookie) async {
    sessionCookie = 'MUSIC_U=fixture';
    return const GatewayLoginStatus(profile: _profile);
  }

  @override
  Future<Set<int>> likedSongIds(int uid) async => <int>{};
}

class _CachedCatalog extends Catalog {
  _CachedCatalog() : super(gateway: _Gateway());

  final List<Completer<UserCollections>> collectionRequests =
      <Completer<UserCollections>>[];
  final Completer<List<Track>> liveTracks = Completer<List<Track>>();
  int userCollectionCalls = 0;

  @override
  Future<UserCollections?> cachedUserCollections(int uid) async =>
      UserCollections(created: <Playlist>[_playlist('1', 'Stored list')]);

  @override
  Future<UserCollections> userCollections(int uid) {
    userCollectionCalls++;
    final Completer<UserCollections> request = Completer<UserCollections>();
    collectionRequests.add(request);
    return request.future;
  }

  @override
  Future<List<Track>?> cachedPlaylistTracks(String playlistId) async => <Track>[
    _track('1', 'Stored song'),
  ];

  @override
  Future<List<Track>> playlistTracks(String id) => liveTracks.future;

  @override
  Future<HomeFeed?> loadHome({int? userId}) async => null;

  @override
  Future<void> invalidateCollections(int uid) async {}

  @override
  Future<void> invalidatePlaylist(String id) async {}
}

class _SwitchingCatalog extends Catalog {
  _SwitchingCatalog() : super(gateway: _Gateway());
  final oldCache = Completer<List<Track>?>();
  final oldLive = Completer<List<Track>>();
  bool delayCache = false;
  int oldLiveCalls = 0;

  @override
  Future<List<Track>?> cachedPlaylistTracks(String id) =>
      id == '1' && delayCache
      ? oldCache.future
      : Future.value(id == '1' ? [_track('old', 'Old cached')] : null);

  @override
  Future<List<Track>> playlistTracks(String id) {
    if (id == '1') {
      oldLiveCalls++;
      return oldLive.future;
    }
    return Future.value([_track('new', 'New song')]);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('stored collections paint while the live request is pending', (
    tester,
  ) async {
    final _CachedCatalog catalog = _CachedCatalog();
    final AppState state = AppState(catalog: catalog);
    addTearDown(state.dispose);

    final AuthOutcome outcome = await state.signInWithCookie('MUSIC_U=fixture');
    expect(outcome.ok, isTrue);
    await tester.pump();
    await tester.pump();

    expect(state.collections.created.single.name, 'Stored list');
    expect(catalog.userCollectionCalls, 1);
    expect(state.collectionsLoading, isTrue);

    catalog.collectionRequests.single.complete(
      UserCollections(created: <Playlist>[_playlist('2', 'Fresh list')]),
    );
    await tester.pump();
    await tester.pump();

    expect(state.collections.created.single.name, 'Fresh list');
    expect(state.collectionsLoading, isFalse);
  });

  testWidgets('a forced refresh waits for the in-flight read and reads again', (
    tester,
  ) async {
    final _CachedCatalog catalog = _CachedCatalog();
    final AppState state = AppState(catalog: catalog);
    addTearDown(state.dispose);

    await state.signInWithCookie('MUSIC_U=fixture');
    await tester.pump();
    await tester.pump();
    expect(catalog.userCollectionCalls, 1);

    final Future<void> forced = state.refreshCollections(force: true);
    await tester.pump();
    expect(
      catalog.userCollectionCalls,
      1,
      reason: 'the forced read waits for the request already in flight',
    );

    catalog.collectionRequests[0].complete(
      UserCollections(created: <Playlist>[_playlist('2', 'First read')]),
    );
    await tester.pump();
    await tester.pump();
    expect(
      catalog.userCollectionCalls,
      2,
      reason: 'the stale response may predate the mutation, so read again',
    );

    catalog.collectionRequests[1].complete(
      UserCollections(created: <Playlist>[_playlist('3', 'Fresh list')]),
    );
    await forced;
    await tester.pump();
    expect(state.collections.created.single.name, 'Fresh list');
    expect(state.collectionsLoading, isFalse);
  });

  testWidgets('a playlist paints stored tracks before the service answers', (
    tester,
  ) async {
    final _CachedCatalog catalog = _CachedCatalog();
    final AppState state = AppState(catalog: catalog);
    addTearDown(state.dispose);
    final Playlist playlist = _playlist('12', 'Playlist fixture');

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLegacyTheme(),
        home: Scaffold(
          body: LegacyPlaylistPage(state: state, playlist: playlist),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Stored song'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    catalog.liveTracks.complete(<Track>[_track('2', 'Fresh song')]);
    await tester.pumpAndSettle();

    expect(find.text('Fresh song'), findsOneWidget);
    expect(find.text('Stored song'), findsNothing);
  });

  testWidgets('switching playlists ignores an older live response', (
    tester,
  ) async {
    final catalog = _SwitchingCatalog();
    final state = AppState(catalog: catalog);
    addTearDown(state.dispose);
    Widget page(String id) => MaterialApp(
      home: Scaffold(
        body: LegacyPlaylistPage(
          state: state,
          playlist: _playlist(id, 'List $id'),
        ),
      ),
    );
    await tester.pumpWidget(page('1'));
    await tester.pump();
    expect(find.text('Old cached'), findsOneWidget);
    await tester.pumpWidget(page('2'));
    await tester.pump();
    expect(find.text('New song'), findsOneWidget);
    catalog.oldLive.complete([_track('late', 'Old live')]);
    await tester.pump();
    expect(find.text('New song'), findsOneWidget);
    expect(find.text('Old live'), findsNothing);
  });

  testWidgets('a stale cache read does not start a live request', (
    tester,
  ) async {
    final catalog = _SwitchingCatalog()..delayCache = true;
    final state = AppState(catalog: catalog);
    addTearDown(state.dispose);
    Widget page(String id) => MaterialApp(
      home: Scaffold(
        body: LegacyPlaylistPage(
          state: state,
          playlist: _playlist(id, 'List $id'),
        ),
      ),
    );
    await tester.pumpWidget(page('1'));
    await tester.pumpWidget(page('2'));
    await tester.pump();
    catalog.oldCache.complete([_track('old', 'Old cached')]);
    await tester.pump();
    expect(catalog.oldLiveCalls, 0);
    expect(find.text('New song'), findsOneWidget);
  });
}
