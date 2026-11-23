import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/state/app_state.dart';

/// Account gateway whose answers change with [generation], so a replayed
/// snapshot is distinguishable from a fresh read.
class _SessionGateway extends MusicAccountGateway {
  int homeReads = 0;
  int collectionReads = 0;
  int favoriteReads = 0;

  /// Tags the payload; a test flips it to pretend the service moved on.
  String generation = 'first';

  MusicUser? _user;

  @override
  MusicProvider get provider =>
      const MusicProvider(id: 'fixture', name: 'Fixture Music');
  @override
  String get connectionId => 'account';
  @override
  MusicUser? get user => _user;
  @override
  Set<MusicCapability> get capabilities => const {
    MusicCapability.homeFeed,
    MusicCapability.playlists,
    MusicCapability.favorites,
  };
  @override
  Set<String> get authenticationMethods => const {'cookie'};

  MusicUser _account() =>
      MusicUser(id: id(MusicEntityKind.user, '7'), name: 'Seven');

  @override
  Future<MusicUser?> loginWithCookie(String cookie) async => _user = _account();
  @override
  Future<MusicUser?> checkSession() async => _user;
  @override
  Future<void> logout() async {
    _user = null;
  }

  @override
  void clearSession() {
    _user = null;
  }

  MusicSong _song(String value) => MusicSong(
    id: id(MusicEntityKind.song, value),
    title: value,
    artists: const [],
    duration: const Duration(minutes: 3),
  );

  MusicPlaylist _playlist(String value) => MusicPlaylist(
    id: id(MusicEntityKind.playlist, value),
    name: value,
    writable: true,
  );

  @override
  Future<MusicHome> homeFeed() async {
    homeReads++;
    return MusicHome(
      quick: [_song('$generation-quick-$homeReads')],
      recommended: [_playlist('$generation-recommended-$homeReads')],
    );
  }

  @override
  Future<MusicPage<MusicPlaylist>> playlists({
    int limit = 50,
    int offset = 0,
  }) async {
    collectionReads++;
    return MusicPage(
      [_playlist('$generation-created-$collectionReads')],
      offset: offset,
      hasMore: false,
    );
  }

  @override
  Future<MusicPage<MusicSong>> favorites({
    int limit = 100,
    int offset = 0,
  }) async {
    favoriteReads++;
    return MusicPage(
      [_song('$generation-liked-$favoriteReads')],
      offset: offset,
      hasMore: false,
    );
  }
}

void main() {
  test('a re-login reads the home feed again instead of replaying it', () async {
    final gateway = _SessionGateway();
    final catalog = Catalog(gateway: gateway);

    await gateway.loginWithCookie('cookie');
    final HomeFeed? first = await catalog.loadHome(userId: 7);
    expect(first?.quick.single.title, 'first-quick-1');
    expect(gateway.homeReads, 1);

    // Sign-out: the account's session ends before the credentials are dropped.
    catalog.rotateSession(gateway);
    await gateway.logout();
    expect(
      catalog.home,
      isNull,
      reason: 'a rotated session cannot stay painted',
    );
    expect(
      (await catalog.loadHome(userId: 0))?.quick.single.title,
      'first-quick-2',
    );

    // The same account signs back in, and the service answers with new data.
    gateway.generation = 'second';
    await gateway.loginWithCookie('cookie');
    catalog.rotateSession(gateway);
    final HomeFeed? again = await catalog.loadHome(userId: 7);
    expect(gateway.homeReads, 3, reason: 'login must reach the service');
    expect(again?.quick.single.title, 'second-quick-3');
    expect(again?.recommended.single.name, 'second-recommended-3');
  });

  test('a re-login reads the music library again', () async {
    final gateway = _SessionGateway();
    final catalog = Catalog(gateway: gateway);

    await gateway.loginWithCookie('cookie');
    final UserCollections first = await catalog.platformCollections(gateway);
    expect(first.created.single.name, 'first-created-1');
    expect(gateway.collectionReads, 1);

    catalog.rotateSession(gateway);
    gateway.generation = 'second';
    final UserCollections again = await catalog.platformCollections(gateway);
    expect(gateway.collectionReads, 2);
    expect(again.created.single.name, 'second-created-2');
  });

  test('a re-login reads the favorites playlist again', () async {
    final gateway = _SessionGateway();
    final catalog = Catalog(gateway: gateway);
    await gateway.loginWithCookie('cookie');
    final String favorites = gateway
        .id(MusicEntityKind.playlist, '__lazer_favorites__')
        .cacheKey;

    final List<Track> first = await catalog.playlistTracks(favorites);
    expect(first.single.title, 'first-liked-1');
    expect(gateway.favoriteReads, 1);

    catalog.rotateSession(gateway);
    gateway.generation = 'second';
    final List<Track> again = await catalog.playlistTracks(favorites);
    expect(gateway.favoriteReads, 2);
    expect(again.single.title, 'second-liked-2');
  });

  test('one session keeps using the snapshot it just read', () async {
    final gateway = _SessionGateway();
    final catalog = Catalog(gateway: gateway);
    await gateway.loginWithCookie('cookie');

    await catalog.loadHome(userId: 7);
    final HomeFeed? cached = await catalog.loadHome(userId: 7);
    expect(gateway.homeReads, 1);
    expect(cached?.quick.single.title, 'first-quick-1');

    await catalog.platformCollections(gateway);
    await catalog.platformCollections(gateway);
    expect(gateway.collectionReads, 1);
  });

  testWidgets('signing out and back in re-reads the home feed', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final gateway = _SessionGateway();
    final catalog = Catalog(gateway: gateway);
    final state = AppState(catalog: catalog);
    addTearDown(state.dispose);

    await tester.runAsync(() async {
      await state.signInWithCookie('cookie');
      await state.refreshHome();
    });
    await tester.pump();
    expect(gateway.homeReads, 1);
    expect(state.home?.quick.single.title, 'first-quick-1');

    await tester.runAsync(() => state.signOut());
    await tester.pump();
    final int afterSignOut = gateway.homeReads;

    gateway.generation = 'second';
    await tester.runAsync(() async {
      await state.signInWithCookie('cookie');
      await state.refreshHome();
    });
    await tester.pump();
    expect(
      gateway.homeReads,
      afterSignOut + 1,
      reason: 'the new session must read the service, not the old snapshot',
    );
    expect(state.home?.quick.single.title, 'second-quick-${afterSignOut + 1}');
  });
}
