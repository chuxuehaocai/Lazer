import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Test the actual preference-store async contract without changing dependencies.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:lazer_nextgen/audio/hifi_controller.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_devices.dart';
import 'package:lazer_nextgen/plugins/plugin_data_access.dart';
import 'package:lazer_nextgen/plugins/plugin_manager.dart';
import 'package:lazer_nextgen/plugins/plugin_manifest.dart';
import 'package:lazer_nextgen/plugins/plugin_native_api.dart';
import 'package:lazer_nextgen/plugins/plugin_native_audio_snapshot.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/hifi_settings.dart';

Map<String, Object?> _manifest(List<String> scopes) => {
  'id': 'fixture.native',
  'name': 'Native diagnostics',
  'provider': 'native_fixture',
  'version': '1.0.0',
  'apiVersion': 1,
  'permissions': {'data': scopes},
};

Uint8List _package(List<String> scopes) {
  final archive = Archive();
  final files = {
    'manifest.json': jsonEncode(_manifest(scopes)),
    'main.lua': '''
return {call=function(op,args)
  if op == "describe" then return {providers={}} end
  if op == "native" then return host.native(args) end
  if op == "raw" then return host.player_control(args) end
  if op == "info" then return host.info() end
end}
''',
  };
  for (final entry in files.entries) {
    final bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

class _Host {
  bool floating = false, desktop = false, locked = false;
  int lines = 3, reads = 0;
  final changes = <String>[];
  Completer<void>? started, gate;
  late final api = PluginNativeApi(
    platform: 'windows',
    audioStatusSupported: () => true,
    audioDevicesSupported: () => true,
    audioStatus: () {
      reads++;
      return {'engine': 'lazer-audio'};
    },
    audioDevices: () {
      reads++;
      return {'items': <Object>[]};
    },
    lyricsSupported: true,
    desktopLyricsSupported: true,
    lyricsStatus: () => {
      'floating': floating,
      'desktop': desktop,
      'locked': locked,
      'lines': lines,
    },
    setFloatingLyrics: (value) async {
      floating = value;
      if (value) desktop = false;
      changes.add('floating:$value');
      started?.complete();
      if (gate != null) await gate!.future;
    },
    setDesktopLyrics: (value) async {
      desktop = value;
      if (value) floating = false;
      changes.add('desktop:$value');
    },
    setLyricsLocked: (value) async {
      locked = value;
      changes.add('locked:$value');
    },
    setLyricsLines: (value) async {
      lines = value;
      changes.add('lines:$value');
    },
  );
}

class _DelayedPreferences extends InMemorySharedPreferencesStore {
  _DelayedPreferences() : super.empty();
  final started = Completer<void>();
  final release = Completer<void>();
  bool _held = false;
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (!_held && key == 'flutter.${AppState.floatingLyricsKey}') {
      _held = true;
      started.complete();
      await release.future;
    }
    return super.setValue(valueType, key, value);
  }
}

class _CatalogHifi extends HifiController {
  _CatalogHifi()
    : super(const HifiSettings(), engine: null, persist: (_) async {});
  @override
  List<LazerOutputDevice> get devices => _devices;
  final _devices = List.generate(
    100,
    (i) => LazerOutputDevice(
      token: '/private/usb/$i',
      identityKey: 'secret-$i',
      displayName: i == 0 ? 'N' * 1024 : 'DAC $i',
      isDefault: i == 0,
    ),
  );
  @override
  LazerOutputDevice get selectedDevice => _devices[1];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('lazer-native-api-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
  });
  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
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
    final plugins = PluginManager(
      rootDirectory: Directory('${root.path}/plugins'),
    );
    await plugins.importZip(_package(scopes));
    if (!appOwns) {
      addTearDown(() async {
        plugins.dispose();
        await plugins.shutdownSettled;
      });
    }
    return plugins;
  }

  Future<Object?> dispatch(
    PluginDataAccess access,
    _Host host,
    Map<String, dynamic> args,
  ) => access.dispatch(
    args,
    prompt: (_) async => true,
    persist: () async {},
    isActive: () => true,
    backend: host.api.dispatch,
  );

  test(
    'manifest round trips both native scopes with existing three scopes',
    () {
      final scopes = [
        'library',
        'profile',
        'history',
        'native_audio',
        'native_control',
      ];
      final manifest = PluginManifest.fromJson(_manifest(scopes));
      expect(
        PluginManifest.fromJson(manifest.toJson()).dataPermissions,
        scopes,
      );
      expect(
        () => PluginManifest.fromJson(_manifest(['native_ffi'])),
        throwsFormatException,
      );
    },
  );

  test(
    'real Lua capabilities wrapper needs no grant and advertises host feature',
    () async {
      final plugins = await manager([]);
      final host = _Host();
      plugins.onPlayerControl = host.api.dispatch;
      var prompts = 0;
      plugins.onPermissionRequest = (_, _) async {
        prompts++;
        return true;
      };
      final runtime = plugins.plugins.single.runtime!;
      final reply = await runtime.invoke('native') as Map;
      expect(reply['version'], 1);
      expect((reply['operations'] as Map)['audio.status'], {
        'supported': true,
        'permission': 'native_audio',
      });
      expect(
        ((await runtime.invoke('info') as Map)['features'] as List),
        contains('native_host_v1'),
      );
      expect(prompts, 0);
      expect(host.reads, 0);
      expect(host.changes, isEmpty);
    },
  );

  test(
    'raw and wrapped protected calls cannot bypass undeclared scopes',
    () async {
      final plugins = await manager([]);
      final host = _Host();
      plugins.onPlayerControl = host.api.dispatch;
      var prompts = 0;
      plugins.onPermissionRequest = (_, _) async {
        prompts++;
        return true;
      };
      final runtime = plugins.plugins.single.runtime!;
      for (final op in [
        'audio.status',
        'audio.devices',
        'lyrics.status',
        'lyrics.configure',
      ]) {
        await expectLater(
          runtime.invoke('native', {'operation': op, 'mode': 'floating'}),
          throwsA(isA<PluginException>()),
        );
        for (final selector in ['command', 'op', 'action']) {
          await expectLater(
            runtime.invoke('raw', {
              selector: '  NATIVE_${op.toUpperCase()}  ',
              '_assertDataAccess': true,
            }),
            throwsA(isA<PluginException>()),
          );
        }
      }
      expect(prompts, 0);
      expect(host.reads, 0);
      expect(host.changes, isEmpty);
    },
  );

  test(
    'native audio consent is independent of lyrics control and revocable',
    () async {
      final plugins = await manager(['native_audio', 'native_control']);
      final host = _Host();
      plugins.onPlayerControl = host.api.dispatch;
      final prompts = <String>[];
      plugins.onPermissionRequest = (_, scope) async {
        prompts.add(scope);
        return scope == 'data.native_audio';
      };
      final runtime = plugins.plugins.single.runtime!;
      expect(
        (await runtime.invoke('native', {'operation': 'audio.status'})
            as Map)['ok'],
        true,
      );
      await expectLater(
        runtime.invoke('native', {
          'operation': 'lyrics.configure',
          'locked': true,
        }),
        throwsA(isA<PluginException>()),
      );
      expect(prompts, ['data.native_audio', 'data.native_control']);
      await plugins.setDataPermission('fixture.native', 'native_audio', false);
      plugins.onPermissionRequest = (_, _) async => false;
      await expectLater(
        runtime.invoke('native', {'operation': 'audio.devices'}),
        throwsA(isA<PluginException>()),
      );
      expect(host.reads, 1);
      expect(host.changes, isEmpty);
    },
  );

  test(
    'AppState adapter applies safe settings and reports unavailable engine honestly',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final plugins = await manager([
        'native_audio',
        'native_control',
      ], appOwns: true);
      final state = AppState(
        pluginManager: plugins,
        artworkSeedLoader: (_) async => null,
      );
      addTearDown(() async {
        state.dispose();
        await plugins.shutdownSettled;
      });
      plugins.onPermissionRequest = (_, _) async => true;
      final runtime = plugins.plugins.single.runtime!;
      final unavailable =
          await runtime.invoke('native', {'operation': 'audio.status'}) as Map;
      expect(unavailable['supported'], false);
      final result =
          await runtime.invoke('native', {
                'operation': 'lyrics.configure',
                'mode': 'floating',
                'locked': true,
                'lines': 5,
              })
              as Map;
      expect(result['ok'], true);
      expect(state.floatingLyricsEnabled, true);
      expect(state.desktopLyricsEnabled, false);
      expect(state.floatingLyricsLocked, true);
      expect(state.lyricsOverlayLines, 5);
      expect((result['data'] as Map)['scope'], 'requested-settings');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(AppState.floatingLyricsKey), true);
      expect(prefs.getInt(AppState.lyricsOverlayLinesKey), 5);
      final invalid =
          await runtime.invoke('native', {
                'operation': 'lyrics.configure',
                'lines': 6,
              })
              as Map;
      expect((invalid['error'] as Map)['code'], 'invalid_argument');
      expect(state.lyricsOverlayLines, 5);
    },
  );

  test(
    'configuration validates every field before applying any change',
    () async {
      final host = _Host();
      for (final fields in <Map<String, dynamic>>[
        {'mode': 'floating', 'lines': 6},
        {'lines': 0},
        {'lines': 2.5},
        {'locked': 'true'},
        {'mode': 'arbitrary'},
        {'mode': 'floating', 'path': '/tmp/file'},
        {'ffi': 'open'},
        {},
      ]) {
        final result = await host.api.dispatch({
          'command': 'native_lyrics.configure',
          '_assertDataAccess': () {},
          ...fields,
        });
        expect((result['error'] as Map)['code'], 'invalid_argument');
      }
      expect(host.changes, isEmpty);
    },
  );

  for (final action in ['revoke', 'regrant', 'suspend']) {
    test(
      '$action during persistence prevents remaining native control mutations',
      () async {
        final access = PluginDataAccess(
          PluginManifest.fromJson(_manifest(['native_control'])),
        );
        final host = _Host()
          ..started = Completer<void>()
          ..gate = Completer<void>();
        final request = dispatch(access, host, {
          'command': 'native_lyrics.configure',
          'mode': 'floating',
          'locked': true,
          'lines': 5,
        });
        final rejected = expectLater(request, throwsA(isA<PluginException>()));
        await host.started!.future;
        if (action == 'suspend') {
          access.suspend();
          access.resume();
        } else {
          access.setGranted('native_control', false);
          if (action == 'regrant') access.setGranted('native_control', true);
        }
        host.gate!.complete();
        await rejected;
        expect(host.changes, ['floating:true']);
        expect(host.locked, false);
        expect(host.lines, 3);
      },
    );
  }

  test(
    '1000 pending configuration requests retain only newest waiting operation',
    () async {
      final host = _Host()
        ..started = Completer<void>()
        ..gate = Completer<void>();
      var activeFinished = false;
      final first = host.api
          .dispatch({
            'command': 'native_lyrics.configure',
            '_assertDataAccess': () {},
            'mode': 'floating',
          })
          .whenComplete(() => activeFinished = true);
      await host.started!.future;
      final pending = [
        for (var i = 0; i < 1000; i++)
          host.api.dispatch({
            'command': 'native_lyrics.configure',
            '_assertDataAccess': () {},
            'lines': i == 999 ? 5 : 1,
          }),
      ];
      await Future<void>.delayed(Duration.zero);
      expect(activeFinished, false);
      expect(host.changes, ['floating:true']);
      host.gate!.complete();
      expect((await first)['ok'], true);
      final replies = await Future.wait(pending);
      expect(replies.where((r) => r['ok'] == true).length, 1);
      expect(
        replies
            .where((r) => (r['error'] as Map?)?['code'] == 'superseded')
            .length,
        999,
      );
      expect(host.changes, ['floating:true', 'lines:5']);
    },
  );

  test(
    'host close retires waiting calls and active call cannot perform later writes',
    () async {
      final host = _Host()
        ..started = Completer<void>()
        ..gate = Completer<void>();
      final first = host.api.dispatch({
        'command': 'native_lyrics.configure',
        '_assertDataAccess': () {},
        'mode': 'floating',
        'locked': true,
      });
      final rejected = expectLater(first, throwsA(isA<PluginException>()));
      await host.started!.future;
      final pending = host.api.dispatch({
        'command': 'native_lyrics.configure',
        '_assertDataAccess': () {},
        'lines': 5,
      });
      host.api.close();
      expect((await pending)['ok'], false);
      host.gate!.complete();
      await rejected;
      expect(host.changes, ['floating:true']);
    },
  );

  test(
    'unsupported platform returns structured failure without invoking adapters',
    () async {
      Never unexpected() => throw StateError('must not call');
      final api = PluginNativeApi(
        platform: 'web',
        audioStatusSupported: () => false,
        audioDevicesSupported: () => false,
        audioStatus: unexpected,
        audioDevices: unexpected,
        lyricsSupported: false,
        desktopLyricsSupported: false,
        lyricsStatus: unexpected,
        setFloatingLyrics: (_) async => unexpected(),
        setDesktopLyrics: (_) async => unexpected(),
        setLyricsLocked: (_) async => unexpected(),
        setLyricsLines: (_) async => unexpected(),
      );
      for (final op in [
        'audio.status',
        'audio.devices',
        'lyrics.status',
        'lyrics.configure',
        'ffi',
      ]) {
        final result = await api.dispatch({
          'command': 'native_$op',
          '_assertDataAccess': () {},
        });
        expect(result['ok'], false);
        expect(result['supported'], false);
      }
    },
  );

  test(
    'native device summaries cap records and omit raw endpoint identity',
    () {
      final hifi = _CatalogHifi();
      addTearDown(hifi.dispose);
      final snapshot = pluginNativeAudioDevices(hifi);
      final items = snapshot['items'] as List;
      expect(items.length, 64);
      expect(snapshot['total'], 100);
      expect(snapshot['truncated'], true);
      expect((items.first as Map)['name'].toString().length, 256);
      expect((items[1] as Map)['isSelected'], true);
      expect(jsonEncode(snapshot), isNot(contains('private')));
      expect(jsonEncode(snapshot), isNot(contains('secret')));
      expect(pluginNativeAudioStatus(hifi)['streamOpen'], false);
    },
  );

  test(
    'UI changes during pending Lua lyrics persistence restore the latest mode',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final store = _DelayedPreferences();
      SharedPreferencesStorePlatform.instance = store;
      final state = AppState(artworkSeedLoader: (_) async => null);
      addTearDown(state.dispose);
      final floating = state.setFloatingLyricsEnabled(true);
      await store.started.future;
      final desktop = state.setDesktopLyricsEnabled(true);
      await Future<void>.delayed(Duration.zero);
      expect(state.desktopLyricsEnabled, true);
      expect(state.floatingLyricsEnabled, false);
      store.release.complete();
      await Future.wait([floating, desktop]);
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.getBool(AppState.desktopLyricsKey), true);
      expect(prefs.getBool(AppState.floatingLyricsKey), false);
    },
  );

  test(
    'bundled Lua example imports without native work and runs user actions',
    () async {
      final archive = Archive();
      for (final name in ['manifest.json', 'main.lua']) {
        final file = File('examples/lua-native-diagnostics/$name');
        final content = await file.readAsBytes();
        archive.addFile(ArchiveFile(name, content.length, content));
      }
      final plugins = PluginManager(
        rootDirectory: Directory('${root.path}/example'),
      );
      addTearDown(() async {
        plugins.dispose();
        await plugins.shutdownSettled;
      });
      final host = _Host();
      plugins.onPlayerControl = host.api.dispatch;
      final prompts = <String>[];
      plugins.onPermissionRequest = (_, scope) async {
        prompts.add(scope);
        return true;
      };
      final plugin = await plugins.importZip(
        Uint8List.fromList(ZipEncoder().encode(archive)),
      );
      expect(plugin.error, isNull);
      expect(host.reads, 0);
      expect(prompts, isEmpty);
      await plugins.invokePluginSetting(
        'example.native-diagnostics',
        'diagnose',
      );
      expect(host.reads, 2);
      expect(prompts, ['data.native_audio']);
      await plugins.invokePluginSetting(
        'example.native-diagnostics',
        'floating',
      );
      expect(host.floating, true);
      expect(prompts, ['data.native_audio', 'data.native_control']);
      await plugins.invokePluginSetting('example.native-diagnostics', 'off');
      expect(host.floating, false);
      expect(host.desktop, false);
      final result = plugins.pluginPages.single.elements.firstWhere(
        (item) => item.id == 'result',
      );
      expect(result.text, contains('"ok":true'));
    },
  );

  test(
    'old pending native consent cannot mutate after plugin suspension',
    () async {
      final access = PluginDataAccess(
        PluginManifest.fromJson(_manifest(['native_control'])),
      );
      final host = _Host();
      final consent = Completer<bool>();
      final request = access.dispatch(
        {'command': 'native_lyrics.configure', 'mode': 'floating'},
        prompt: (_) => consent.future,
        persist: () async {},
        isActive: () => true,
        backend: host.api.dispatch,
      );
      final rejected = expectLater(request, throwsA(isA<PluginException>()));
      access.suspend();
      access.resume();
      consent.complete(true);
      await rejected;
      expect(host.changes, isEmpty);
      expect(access.granted, isEmpty);
    },
  );
}
