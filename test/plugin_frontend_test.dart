import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/plugins/plugin_package.dart';
import 'package:lazer_nextgen/listening/listening_statistics.dart';
import 'package:lazer_nextgen/plugins/plugin_data_access.dart';
import 'package:lazer_nextgen/plugins/plugin_manager.dart';
import 'package:lazer_nextgen/plugins/plugin_manifest.dart';
import 'package:lazer_nextgen/state/app_state.dart';

Map<String, Object?> _manifest(List<String> scopes) => {
  'id': 'fixture.frontend',
  'name': 'Frontend',
  'provider': 'frontend',
  'version': '1.0.0',
  'apiVersion': 1,
  'permissions': {'data': scopes},
};

Uint8List _package(List<String> scopes) {
  final archive = Archive();
  final files = {
    'manifest.json': jsonEncode(_manifest(scopes)),
    'frontend/index.html': '<main>Independent frontend</main>',
    'frontend/app.js': 'window.ready = true;',
    'frontend/app.css': 'main { color: white; }',
    'main.lua': '''
return {call=function(op,args)
  if op == "describe" then
    -- 声明一个平台：这个测试要验证插件读不到自己平台的私有数据，没有 gateway
    -- 就没有「自己平台」可试。
    return {providers={{id="frontend", name="Frontend"}}}
  end
  if op == "asset" then return host.resource(args.path or "frontend/index.html") end
  if op == "permissions" then return host.permissions() end
  if op == "request" then return host.request_permission(args.scope) end
  if op == "library" then return host.library(args) end
  if op == "user" then return host.user(args) end
  if op == "search" then return host.search(args) end
  if op == "recent" then return host.player_recent() end
  if op == "raw" then return host.player_control(args) end
  return nil
end}
''',
  };
  for (final entry in files.entries) {
    final bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('lazer-frontend-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await root.delete(recursive: true);
  });
  Future<PluginManager> manager(
    List<String> scopes, {
    bool appOwns = false,
  }) async {
    final result = PluginManager(
      rootDirectory: Directory('${root.path}/plugins'),
    );
    await result.importZip(_package(scopes));
    if (!appOwns) {
      addTearDown(() async {
        result.dispose();
        await result.shutdownSettled;
      });
    }
    return result;
  }

  test('manifest rejects unknown and duplicate private-data scopes', () {
    for (final scopes in [
      ['cookies'],
      ['history', 'history'],
    ]) {
      expect(
        () => PluginManifest.fromJson(_manifest(scopes)),
        throwsFormatException,
      );
    }
    final manifest = PluginManifest.fromJson(
      _manifest(['library', 'profile', 'history']),
    );
    expect(PluginManifest.fromJson(manifest.toJson()).dataPermissions, [
      'library',
      'profile',
      'history',
    ]);
  });

  test(
    'undeclared data never prompts or reaches the backend, including legacy aliases',
    () async {
      final plugins = await manager([]);
      var prompts = 0;
      var calls = 0;
      plugins.onPermissionRequest = (_, _) async {
        prompts++;
        return true;
      };
      plugins.onPlayerControl = (_) async {
        calls++;
        return {'secret': true};
      };
      final runtime = plugins.plugins.single.runtime!;
      for (final command in [
        'library_tracks',
        'user_profile',
        'user_statistics',
        'recent',
        'recent_tracks',
        'recenttracks',
      ]) {
        await expectLater(
          runtime.invoke('raw', {'command': command}),
          throwsA(isA<PluginException>()),
        );
      }
      for (final selector in ['op', 'action']) {
        await expectLater(
          runtime.invoke('raw', {selector: '  USER_PROFILE  '}),
          throwsA(isA<PluginException>()),
        );
      }
      await expectLater(
        runtime.invoke('recent'),
        throwsA(isA<PluginException>()),
      );
      expect(await runtime.invoke('request', {'scope': 'profile'}), false);
      expect(prompts, 0);
      expect(calls, 0);
    },
  );

  test(
    'Lua consent is scoped, persists, and revocation blocks subsequent requests',
    () async {
      final plugins = await manager(['library', 'profile', 'history']);
      var allow = false;
      final prompts = <String>[];
      var calls = 0;
      plugins.onPermissionRequest = (_, scope) async {
        prompts.add(scope);
        return allow;
      };
      plugins.onPlayerControl = (spec) async {
        calls++;
        expect(spec['_callerPluginId'], 'fixture.frontend');
        return {
          'items': ['allowed'],
        };
      };
      final runtime = plugins.plugins.single.runtime!;
      await expectLater(
        runtime.invoke('library', {'operation': 'tracks', 'id': 'list'}),
        throwsA(isA<PluginException>()),
      );
      expect(calls, 0);
      allow = true;
      expect(
        await runtime.invoke('library', {
          'operation': 'tracks',
          'id': 'list',
          '_callerPluginId': 'impersonated',
        }),
        {
          'items': ['allowed'],
        },
      );
      expect(
        await runtime.invoke('library', {'operation': 'tracks', 'id': 'list'}),
        {
          'items': ['allowed'],
        },
      );
      expect(prompts, ['data.library', 'data.library']);
      expect((await runtime.invoke('permissions') as Map)['granted'], [
        'library',
      ]);
      expect(
        plugins.plugins.single.dataAccess.granted,
        isNot(contains('profile')),
      );

      await plugins.setDataPermission('fixture.frontend', 'library', false);
      allow = false;
      await expectLater(
        runtime.invoke('library', {'operation': 'tracks', 'id': 'list'}),
        throwsA(isA<PluginException>()),
      );
      expect(calls, 2);
      await plugins.setDataPermission('fixture.frontend', 'history', true);
      await plugins.plugins.single.runtime!.shutdown();
      final restored = PluginManager(
        rootDirectory: Directory('${root.path}/plugins'),
      );
      addTearDown(() async {
        restored.dispose();
        await restored.shutdownSettled;
      });
      await restored.restore();
      expect(restored.plugins.single.dataAccess.granted, {'history'});
    },
  );

  test(
    'revocation discards a private response already loading in the backend',
    () async {
      final plugins = await manager(['profile']);
      plugins.onPermissionRequest = (_, _) async => true;
      final started = Completer<void>();
      final response = Completer<Object?>();
      plugins.onPlayerControl = (_) {
        started.complete();
        return response.future;
      };
      final request = plugins.plugins.single.runtime!.invoke('user', {
        'operation': 'profile',
      });
      final rejected = expectLater(request, throwsA(isA<PluginException>()));
      await started.future;
      await plugins.setDataPermission('fixture.frontend', 'profile', false);
      response.complete({'account': 'must not reach Lua'});
      await rejected;
    },
  );

  test(
    'revoking during the consent dialog prevents the late approval from restoring access',
    () async {
      final access = PluginDataAccess(
        PluginManifest.fromJson(_manifest(['profile'])),
      );
      final consent = Completer<bool>();
      final pending = access.request(
        'profile',
        (_) => consent.future,
        () async {},
      );
      access.setGranted('profile', false);
      consent.complete(true);
      expect(await pending, false);
      expect(access.granted, isEmpty);
    },
  );

  test(
    'bundled frontend assets stay read-only resources and cannot forge consent',
    () async {
      final plugins = await manager([]);
      expect(
        await plugins.plugins.single.runtime!.invoke('asset'),
        '<main>Independent frontend</main>',
      );
      for (final path in [
        '../secret.html',
        'C:/secret.html',
        '/secret.html',
        'frontend/../../secret.html',
      ]) {
        await expectLater(
          plugins.plugins.single.runtime!.invoke('asset', {'path': path}),
          throwsA(isA<PluginException>()),
        );
      }
      final archive = ZipDecoder().decodeBytes(_package(['profile']));
      final grant = utf8.encode('["profile"]');
      archive.addFile(ArchiveFile('.data-permissions', grant.length, grant));
      expect(
        () => decodePluginPackage(
          Uint8List.fromList(ZipEncoder().encode(archive)),
        ),
        throwsFormatException,
      );
    },
  );

  test('old consent cannot grant access after a VM lifecycle change', () async {
    final access = PluginDataAccess(
      PluginManifest.fromJson(_manifest(['profile'])),
    );
    final consent = Completer<bool>();
    final pending = access.request(
      'profile',
      (_) => consent.future,
      () async {},
    );
    access.suspend();
    access.resume();
    consent.complete(true);
    expect(await pending, false);
    expect(access.granted, isEmpty);
    expect(
      await access.request('profile', (_) async => true, () async {}),
      true,
    );
  });

  for (final action in ['disable', 'restart', 'uninstall']) {
    test(
      '$action invalidates private playback before asynchronous cleanup',
      () async {
        final plugins = await manager(['library'], appOwns: true);
        final gate = _DelayedLoad();
        final state = AppState(
          catalog: _DelayedCatalog(gate),
          pluginManager: plugins,
          listeningStatistics: ListeningStatisticsController(
            read: () async => null,
            write: (_) async {},
          ),
          artworkSeedLoader: (_) async => null,
        );
        addTearDown(state.dispose);
        plugins.onPermissionRequest = (_, _) async => true;
        final runtime = plugins.plugins.single.runtime!;
        final request = runtime.invoke('library', {
          'operation': 'play',
          'id': 'private-list',
        });
        final rejected = expectLater(request, throwsA(isA<PluginException>()));
        await gate.started.future;
        final cleanupStarted = Completer<void>();
        final cleanupRelease = Completer<void>();
        // Stop before runtime.shutdown even begins: provider cleanup or a slow
        // socket close must not leave the old authorization usable.
        plugins.beforeChange = (_) async {
          cleanupStarted.complete();
          await cleanupRelease.future;
        };
        // This test exercises teardown authorization, not catalogue reload or
        // background cache persistence after switching music providers.
        plugins.afterChange = null;
        final change = action == 'uninstall'
            ? plugins.uninstall('fixture.frontend')
            : plugins.setEnabled('fixture.frontend', action == 'restart');
        await cleanupStarted.future;
        gate.release.complete();
        await rejected;
        expect(state.queue, isEmpty);
        cleanupRelease.complete();
        await change;
        expect(state.queue, isEmpty);
      },
    );
  }

  for (final kind in ['playlist', 'album', 'song']) {
    for (final regrant in [false, true]) {
      test(
        '$kind revoked during loading cannot change queue${regrant ? " even after regrant" : ""}',
        () async {
          final plugins = await manager(['library'], appOwns: true);
          final gate = _DelayedLoad();
          final catalog = _DelayedCatalog(gate);
          final state = AppState(
            catalog: catalog,
            pluginManager: plugins,
            listeningStatistics: ListeningStatisticsController(
              read: () async => null,
              write: (_) async {},
            ),
            artworkSeedLoader: (_) async => null,
          );
          addTearDown(state.dispose);
          plugins.onPermissionRequest = (_, _) async => true;
          final id = catalog.activeGateway
              .id(
                kind == 'song'
                    ? MusicEntityKind.song
                    : kind == 'album'
                    ? MusicEntityKind.album
                    : MusicEntityKind.playlist,
                'private-item',
              )
              .cacheKey;
          final runtime = plugins.plugins.single.runtime!;
          final request = runtime.invoke('library', {
            'operation': 'play',
            'kind': kind,
            'id': id,
            '_assertDataAccess': true,
          });
          final rejected = expectLater(
            request,
            throwsA(isA<PluginException>()),
          );
          await gate.started.future;
          await plugins.setDataPermission('fixture.frontend', 'library', false);
          if (regrant) {
            await plugins.setDataPermission(
              'fixture.frontend',
              'library',
              true,
            );
          }
          gate.release.complete();
          await rejected;
          expect(state.queue, isEmpty);
          expect(state.current, isNull);
          expect(state.playing, false);
          final queue =
              await runtime.invoke('raw', {'command': 'queue'}) as Map;
          expect(queue['length'], 0);
          expect(queue['tracks'], isEmpty);
        },
      );
    }
  }

  test(
    'frontend queries use backend data, clamp pagination and omit paths and credential details',
    () async {
      final plugins = await manager([
        'library',
        'profile',
        'history',
      ], appOwns: true);
      final statistics = ListeningStatisticsController(
        read: () async => null,
        write: (_) async {},
      );
      final catalog = _FixtureCatalog();
      final state = AppState(
        catalog: catalog,
        pluginManager: plugins,
        listeningStatistics: statistics,
        artworkSeedLoader: (_) async => null,
      );
      addTearDown(state.dispose);
      plugins.onPermissionRequest = (_, _) async => true;
      final runtime = plugins.plugins.single.runtime!;
      final page =
          await runtime.invoke('library', {
                'operation': 'tracks',
                'id': 'fixture-list',
                'offset': 1,
                'limit': 9999,
              })
              as Map;
      expect(catalog.requestedPlaylist, 'fixture-list');
      expect(page['limit'], 200);
      expect(page['total'], 3);
      expect((page['items'] as List).length, 2);
      final track = (page['items'] as List).first as Map;
      expect(track['id'], 'song-1');
      expect(track.containsKey('localPath'), false);
      expect(track['coverUrl'], '');
      final profile =
          await runtime.invoke('user', {'operation': 'profile'}) as Map;
      expect(
        profile.keys,
        unorderedEquals(['activePlatform', 'activeConnection', 'accounts']),
      );
      expect(profile.containsKey('detail'), false);
      final account = (profile['accounts'] as List).single as Map;
      expect(account['id'], 'opaque-user-id');
      expect(account['platform'], 'fixture');
      expect(account['name'], 'Listener');
      expect(
        account.keys,
        unorderedEquals([
          'connection',
          'platform',
          'id',
          'name',
          'handle',
          'avatarUrl',
        ]),
      );
      expect(jsonEncode(profile), isNot(contains('secret-cookie')));
      final stats =
          await runtime.invoke('user', {
                'operation': 'statistics',
                'range': 'allTime',
              })
              as Map;
      expect(stats['source'], 'device');
      expect(stats['playCount'], 0);
      expect(stats['durationMs'], 0);
      final ownGateway = plugins.gateways.single;
      catalog.connections.add(ownGateway);
      catalog.selectConnection(GatewayRegistry.keyOf(ownGateway));
      await expectLater(
        runtime.invoke('library', {'operation': 'tracks', 'id': 'own-list'}),
        throwsA(isA<PluginException>()),
      );
    },
  );
}

class _FixtureCatalog extends Catalog {
  _FixtureCatalog() : super(gateway: _FixtureGateway());
  String? requestedPlaylist;
  @override
  Future<List<Track>> playlistTracks(String playlistId) async {
    requestedPlaylist = playlistId;
    return List.generate(
      3,
      (index) => Track(
        id: 'song-$index',
        title: 'Song $index',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(minutes: 3),
        coverSeed: index,
        localPath: '/private/audio.mp3',
        coverUrl: 'file:///private/cover.png',
      ),
    );
  }
}

class _FixtureGateway extends MusicGateway {
  final cookie = 'secret-cookie';
  @override
  MusicProvider get provider =>
      const MusicProvider(id: 'fixture', name: 'Fixture');
  @override
  String get connectionId => 'fixture-connection';
  @override
  Set<MusicCapability> get capabilities => {};
  @override
  MusicUser get user => MusicUser(
    id: id(MusicEntityKind.user, 'opaque-user-id'),
    name: 'Listener',
    avatarUrl: 'https://fixture.test/avatar.png',
  );
}

class _DelayedLoad {
  final started = Completer<void>();
  final release = Completer<void>();
  Future<void> wait() async {
    started.complete();
    await release.future;
  }
}

class _DelayedCatalog extends Catalog {
  _DelayedCatalog(this.gate) : super(gateway: _DelayedGateway(gate));
  final _DelayedLoad gate;
  Future<List<Track>> _loadTracks() async {
    await gate.wait();
    return [
      Track(
        id: activeGateway.id(MusicEntityKind.song, 'private-song').cacheKey,
        title: 'Private song',
        artist: 'Private artist',
        album: 'Private album',
        duration: const Duration(minutes: 3),
        coverSeed: 1,
      ),
    ];
  }

  @override
  Future<List<Track>> playlistTracks(String playlistId) => _loadTracks();
  @override
  Future<List<Track>> albumTracksFor(String key) => _loadTracks();
}

class _DelayedGateway extends _FixtureGateway {
  _DelayedGateway(this.gate);
  final _DelayedLoad gate;
  @override
  Future<MusicSong> song(MusicId songId) async {
    await gate.wait();
    return MusicSong(
      id: songId,
      title: 'Private song',
      artists: [],
      duration: const Duration(minutes: 3),
    );
  }
}
