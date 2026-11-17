@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/plugins/lua_plugin_runtime_web.dart';
import 'package:lazer_nextgen/plugins/plugin_manager.dart';
import 'package:lazer_nextgen/plugins/plugin_manifest.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('web manager enforces consent around delayed private data', () async {
    SharedPreferences.setMockInitialValues({});
    final archive = Archive();
    for (final entry in {
      'manifest.json': jsonEncode({
        'id': 'fixture.webdata',
        'name': 'Web data',
        'version': '1.0.0',
        'provider': 'webdata',
        'apiVersion': 1,
        'permissions': {
          'data': ['library'],
        },
      }),
      'main.lua': '''
return {call=function(operation,args)
  if operation == "describe" then return {providers={}} end
  return host.library({operation="tracks",id="private-list"})
end}
''',
    }.entries) {
      final bytes = utf8.encode(entry.value);
      archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
    }
    final manager = PluginManager();
    addTearDown(() async {
      manager.dispose();
      await manager.shutdownSettled;
    });
    var allow = false;
    var calls = 0;
    final gate = Completer<Object?>();
    final entered = Completer<void>();
    manager.onPermissionRequest = (_, permission) async {
      expect(permission, 'data.library');
      return allow;
    };
    manager.onPlayerControl = (request) async {
      expect(request['command'], 'library_tracks');
      calls++;
      if (!entered.isCompleted) entered.complete();
      return gate.future;
    };
    final plugin = await manager.importZip(
      Uint8List.fromList(ZipEncoder().encode(archive)),
    );
    final runtime = plugin.runtime!;
    final forbidden = throwsA(
      isA<PluginException>().having((error) => error.code, 'code', 403),
    );
    await expectLater(runtime.invoke('library'), forbidden);
    expect(calls, 0);
    allow = true;
    final pending = runtime.invoke('library');
    final rejected = expectLater(pending, forbidden);
    await entered.future;
    await manager.setDataPermission(plugin.manifest.id, 'library', false);
    await manager.setDataPermission(plugin.manifest.id, 'library', true);
    gate.complete({
      'tracks': ['private-song'],
    });
    await rejected;
    expect(await runtime.invoke('library'), {
      'tracks': ['private-song'],
    });
    expect(calls, 2);
  });
  test(
    'web Lua awaits asynchronous host calls without losing its stack',
    () async {
      final gate = Completer<Object?>();
      final entered = Completer<void>();
      final runtime = LuaPluginRuntime(
        manifest: PluginManifest.fromJson({
          'id': 'fixture.webasync',
          'name': 'Async',
          'version': '1.0.0',
          'provider': 'async',
          'apiVersion': 1,
        }),
        sources: const {
          'main.lua': '''
return {call=function(operation,args)
  local state = host.player_state()
  return {value=state.value, argument=args.marker}
end}
''',
        },
        dataDirectory: 'web-async-test',
        onPlayerControl: (_) {
          entered.complete();
          return gate.future;
        },
      );
      addTearDown(runtime.close);
      Object? failure;
      var settled = false;
      final response = runtime
          .invoke('state', {'marker': 'preserved'})
          .then(
            (value) {
              settled = true;
              return value;
            },
            onError: (Object error, StackTrace stack) {
              failure = '$error\n$stack';
              settled = true;
              return null;
            },
          );
      await entered.future;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(settled, isFalse, reason: '$failure');
      gate.complete({'value': 42});
      expect(await response, {'value': 42, 'argument': 'preserved'});
    },
  );
  test(
    'web timer waits for actual VM work beyond caller-facing timeout',
    () async {
      final gate = Completer<Object?>();
      final entered = Completer<void>();
      var ticks = 0;
      final runtime = LuaPluginRuntime(
        manifest: PluginManifest.fromJson({
          'id': 'fixture.webtimer',
          'name': 'Timer',
          'version': '1.0.0',
          'provider': 'timer',
          'apiVersion': 1,
        }),
        sources: const {
          'main.lua': '''
host.timer({id="slow", intervalMs=100})
return {call=function(operation,args)
  if operation == "timer" then return host.player_state() end
  if operation == "cancel" then return host.timer({operation="cancel",id="slow"}) end
end}
''',
        },
        dataDirectory: 'web-timer-test',
        timeout: const Duration(milliseconds: 40),
        onPlayerControl: (_) {
          ticks++;
          if (!entered.isCompleted) entered.complete();
          return gate.future;
        },
      );
      addTearDown(runtime.close);
      await runtime.start();
      await entered.future;
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(ticks, 1, reason: 'The suspended VM still owns the timer slot');
      gate.complete(true);
      // A timer based on invoke().timeout would have queued three more calls;
      // this cancel goes behind them and exposes that backlog deterministically.
      await runtime.invoke('cancel');
      expect(ticks, 1);
      await runtime.shutdown();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(ticks, 1);
    },
  );
}
