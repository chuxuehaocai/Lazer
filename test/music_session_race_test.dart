import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/cache/disk_cache.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/plugins/lua_plugin_runtime.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Runtime extends Fake implements LuaPluginRuntime {
  Object? profile;
  final login = Completer<Object?>();
  @override
  Future<Object?> invoke(
    String operation, [
    Map<String, dynamic> args = const {},
    Duration? budget,
  ]) async {
    if (operation == 'loginPassword' || operation == 'loginCookie') {
      return login.future;
    }
    if (operation == 'session') return profile;
    if (operation == 'logout') {
      profile = null;
      return null;
    }
    return [];
  }

  @override
  void close() {}
}

LuaMusicGateway _gateway(String provider, _Runtime runtime) => LuaMusicGateway(
  runtime: runtime,
  provider: MusicProvider(id: provider, name: provider),
  connectionId: 'fixture',
  declaredCapabilities: {},
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('logout invalidates an in-flight login response', () async {
    final runtime = _Runtime();
    final gateway = _gateway('alpha', runtime);
    final pending = gateway.loginWithCookie('fixture');
    await gateway.logout();
    runtime.login.complete({'id': 'alice', 'name': 'Alice'});
    expect(await pending, isNull);
    expect(gateway.user, isNull);
  });

  test(
    'a late login belongs to its original platform and cannot replace another account',
    () async {
      final alphaRuntime = _Runtime();
      final betaRuntime = _Runtime()..profile = {'id': 'bob', 'name': 'Bob'};
      final alpha = _gateway('alpha', alphaRuntime);
      final beta = _gateway('beta', betaRuntime);
      final catalog =
          Catalog(
              cache: DiskCache(
                directory: () async =>
                    throw const FileSystemException('disabled'),
              ),
            )
            ..connections.add(alpha, select: true)
            ..connections.add(beta);
      final state = AppState(
        catalog: catalog,
        artworkSeedLoader: (_) async => null,
      );
      addTearDown(state.dispose);
      final pending = state.signInWithPassword('alice@example.test', 'fixture');
      await state.selectMusicConnection(GatewayRegistry.keyOf(beta));
      expect(state.user.name, 'Bob');
      alphaRuntime.login.complete({'id': 'alice', 'name': 'Alice'});
      expect((await pending).ok, isTrue);
      expect(state.user.name, 'Bob');
      expect(state.activeConnectionKey, GatewayRegistry.keyOf(beta));
      expect(
        state.musicAccounts.values.map((user) => user.name),
        containsAll(['Alice', 'Bob']),
      );
      await state.selectMusicConnection('local:local');
      expect(state.signedIn, isTrue);
      expect(state.musicAccounts, hasLength(2));
    },
  );
}
