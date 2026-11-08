import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'support/music_gateway.dart';

class _Account extends TestMusicGateway {
  _Account(this.connectionId);
  @override
  final String connectionId;
  @override
  Set<MusicCapability> get capabilities => const {};
  bool fail = false;
  @override
  Future<FixtureLoginStatus> fixtureLoginWithCookie(String cookie) async {
    if (fail) throw const MusicGatewayException('fixture', 'login', code: 40);
    return super.fixtureLoginWithCookie(cookie);
  }

  @override
  Future<FixtureLoginStatus> fixtureLoginStatus() async => user == null
      ? const FixtureLoginStatus()
      : const FixtureLoginStatus(
          profile: FixtureProfile(userId: 7, nickname: 'Tester'),
        );
}

class _Catalog extends Catalog {
  _Catalog({super.gateway});
  @override
  Future<HomeFeed?> loadHome({int? userId}) async => null;
  @override
  Future<UserCollections> userCollections(int uid) async =>
      UserCollections.empty;
  @override
  Future<UserCollections?> cachedUserCollections(int uid) async => null;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'failed authentication keeps an existing connection account intact',
    () async {
      final gateway = _Account('one');
      final state = AppState(catalog: _Catalog(gateway: gateway));
      addTearDown(state.dispose);
      expect((await state.signInWithCookie('fixture')).ok, isTrue);
      final before = state.user.handle;
      gateway.fail = true;
      expect((await state.signInWithCookie('invalid')).ok, isFalse);
      expect(state.user.handle, before);
      expect(state.musicAccounts, hasLength(1));
    },
  );
  test(
    'multiple accounts coexist with local selection and a scoped logout',
    () async {
      final first = _Account('one'), second = _Account('two');
      final catalog = _Catalog(gateway: LocalMusicGateway())
        ..connections.add(first)
        ..connections.add(second);
      final state = AppState(catalog: catalog);
      addTearDown(state.dispose);
      await state.selectMusicConnection(GatewayRegistry.keyOf(first));
      await state.signInWithCookie('first');
      await state.selectMusicConnection(GatewayRegistry.keyOf(second));
      await state.signInWithCookie('second');
      expect(state.musicAccounts, hasLength(2));
      final local = state.musicConnections
          .whereType<LocalMusicGateway>()
          .single;
      await state.selectMusicConnection(GatewayRegistry.keyOf(local));
      expect(state.isLocalPlayback, isTrue);
      expect(state.musicAccounts, hasLength(2));
      expect(state.isGuest, isFalse);
      await state.signOut(connectionKey: GatewayRegistry.keyOf(first));
      expect(state.musicAccounts.keys, [GatewayRegistry.keyOf(second)]);
      expect(state.isGuest, isFalse);
      await state.selectMusicConnection(GatewayRegistry.keyOf(second));
      expect(state.activeMusicSignedIn, isTrue);
    },
  );
  test('platform availability comes entirely from registered connections', () {
    final catalog = _Catalog();
    final state = AppState(catalog: catalog);
    addTearDown(state.dispose);
    expect(state.availableMusicPlatforms.map((g) => g.provider.id), ['local']);
    final gateway = _Account('external');
    catalog.connections.add(gateway);
    expect(state.availableMusicPlatforms.last, same(gateway));
  });
}
