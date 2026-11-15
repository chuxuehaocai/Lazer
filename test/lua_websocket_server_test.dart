import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/plugins/lua_plugin_runtime.dart';
import 'package:lazer_nextgen/plugins/plugin_manifest.dart';
import 'package:lazer_nextgen/plugins/plugin_manager.dart';
import 'package:lazer_nextgen/plugins/plugin_socket_inbox.dart';

const _manifest = <String, Object>{
  'id': 'fixture.websocket',
  'name': 'Socket fixture',
  'version': '1.0.0',
  'provider': 'fixture',
  'apiVersion': 1,
  'permissions': {
    'websocket': ['127.0.0.1'],
    'websocketServer': ['127.0.0.1:0'],
  },
};
const _source = """
return {call=function(op,args)
  if op == "describe" then return {providers={{id="fixture",name="Fixture"}}} end
  if op == "server" then return host.websocket_server(args) end
  return host.websocket(args)
end}
""";

void main() {
  test(
    'server bind scopes reject unlisted addresses and require explicit grant',
    () async {
      final manifest = PluginManifest.fromJson(_manifest);
      expect(manifest.permitsWebSocketServer('127.0.0.1', 0), isTrue);
      expect(manifest.permitsWebSocketServer('0.0.0.0', 0), isFalse);
      expect(manifest.permitsWebSocketServer('127.0.0.1', 11234), isFalse);
      for (final scope in [
        '*:0',
        'example.com:1234',
        '127.0.0.1:65536',
        '127.0.0.1',
        'user@127.0.0.1:0',
      ]) {
        expect(
          () => PluginManifest.fromJson({
            ..._manifest,
            'permissions': {
              'websocketServer': [scope],
            },
          }),
          throwsFormatException,
        );
      }
      final runtime = LuaPluginRuntime(
        manifest: manifest,
        sources: const {'main.lua': _source},
        dataDirectory: '',
        websocketGranted: true,
      );
      addTearDown(runtime.close);
      await expectLater(
        runtime.invoke('server', {'operation': 'listen'}),
        throwsA(isA<PluginException>()),
      );
    },
  );

  test(
    'Lua server accepts, receives repeatedly, sends, broadcasts and releases port',
    () async {
      final runtime = LuaPluginRuntime(
        manifest: PluginManifest.fromJson(_manifest),
        sources: const {'main.lua': _source},
        dataDirectory: '',
        websocketServerGranted: true,
      );
      addTearDown(runtime.close);
      await expectLater(
        runtime.invoke('server', {'operation': 'listen', 'host': '0.0.0.0'}),
        throwsA(isA<PluginException>()),
      );
      final listening =
          await runtime.invoke('server', {
                'operation': 'listen',
                'path': '/lyrics',
              })
              as Map;
      final port = listening['port'] as int;
      await expectLater(
        WebSocket.connect('ws://127.0.0.1:$port/wrong'),
        throwsA(isA<WebSocketException>()),
      );
      final peer = await WebSocket.connect('ws://127.0.0.1:$port/lyrics');
      addTearDown(peer.close);
      final received = <Object?>[];
      final sub = peer.listen(received.add);
      addTearDown(sub.cancel);
      final accepted =
          await runtime.invoke('server', {'operation': 'accept'}) as Map;
      final clientId = accepted['clientId'];
      peer.add('one');
      peer.add('two');
      peer.add([0, 127, 255]);
      Future<Object?> receive() => runtime.invoke('server', {
        'operation': 'receive',
        'clientId': clientId,
        'timeoutMs': 1000,
      });
      expect(await receive(), 'one');
      expect(await receive(), 'two');
      expect(await receive(), [0, 127, 255]);
      expect(
        await runtime.invoke('server', {
          'operation': 'receive',
          'clientId': clientId,
          'timeoutMs': 0,
        }),
        isNull,
      );
      expect(
        await runtime.invoke('server', {
          'operation': 'send',
          'clientId': clientId,
          'data': 'reply',
        }),
        isTrue,
      );
      expect(
        await runtime.invoke('server', {
          'operation': 'broadcast',
          'data': 'all',
        }),
        1,
      );
      for (var i = 0; i < 100 && received.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(received, ['reply', 'all']);
      await runtime.invoke('server', {'operation': 'close'});
      final rebound = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      await rebound.close(force: true);
    },
  );

  test(
    'outbound Lua WebSocket receive preserves multiple queued messages',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final sockets = <WebSocket>[];
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((message) => socket.add(message));
        socket.add('first');
        socket.add('second');
      });
      addTearDown(() async {
        for (final socket in sockets) {
          await socket.close();
        }
      });
      final runtime = LuaPluginRuntime(
        manifest: PluginManifest.fromJson(_manifest),
        sources: const {'main.lua': _source},
        dataDirectory: '',
        websocketGranted: true,
      );
      addTearDown(runtime.close);
      await runtime.invoke('client', {'url': 'ws://127.0.0.1:${server.port}'});
      expect(await runtime.invoke('client', {'operation': 'receive'}), 'first');
      expect(
        await runtime.invoke('client', {'operation': 'receive'}),
        'second',
      );
      await runtime.invoke('client', {'operation': 'send', 'data': 'third'});
      expect(await runtime.invoke('client', {'operation': 'receive'}), 'third');
      expect(
        await runtime.invoke('client', {
          'operation': 'receive',
          'timeoutMs': 1,
        }),
        isNull,
      );
      await runtime.invoke('client', {
        'operation': 'send',
        'data': 'after timeout',
      });
      expect(
        await runtime.invoke('client', {'operation': 'receive'}),
        'after timeout',
      );
    },
  );

  test(
    'server permission survives restart and revocation closes the listener',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lazer-socket-permission-',
      );
      addTearDown(() => root.delete(recursive: true));
      final archive = Archive();
      for (final entry in {
        'manifest.json': jsonEncode(_manifest),
        'main.lua': _source,
      }.entries) {
        final bytes = utf8.encode(entry.value);
        archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
      }
      var manager = PluginManager(rootDirectory: root);
      final installed = await manager.importZip(
        Uint8List.fromList(ZipEncoder().encode(archive)),
      );
      expect(installed.websocketServerGranted, isFalse);
      await manager.setWebsocketServerPermission(installed.manifest.id, true);
      manager.dispose();
      manager = PluginManager(rootDirectory: root);
      addTearDown(manager.dispose);
      await manager.restore();
      final restored = manager.plugins.single;
      expect(restored.websocketServerGranted, isTrue);
      final listening =
          await restored.runtime!.invoke('server', {'operation': 'listen'})
              as Map;
      final port = listening['port'] as int;
      await manager.setWebsocketServerPermission(restored.manifest.id, false);
      expect(restored.websocketServerGranted, isFalse);
      await expectLater(
        restored.runtime!.invoke('server', {'operation': 'listen'}),
        throwsA(isA<PluginException>()),
      );
      final rebound = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      await rebound.close(force: true);
    },
  );

  test(
    'inbox bounds unsolicited messages and timeout does not discard new data',
    () async {
      final inbox = PluginSocketInbox();
      expect(await inbox.receive(1), isNull);
      for (var i = 0; i < 128; i++) {
        expect(inbox.add('message $i'), isTrue);
      }
      expect(inbox.add('overflow'), isFalse);
      expect(await inbox.receive(0), 'message 0');
      expect(inbox.add(List<int>.filled(1024 * 1024 + 1, 0)), isFalse);
      inbox.close(discard: true);
      expect(await inbox.receive(0), isNull);
    },
  );
}
