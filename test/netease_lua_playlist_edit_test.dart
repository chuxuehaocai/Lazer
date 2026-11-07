import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/gateway/crypto.dart';
import 'package:lazer_nextgen/plugins/lua_plugin_runtime.dart';
import 'package:lazer_nextgen/plugins/plugin_manifest.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'playlist edits serialize IDs and reject ambiguous positional deletions',
    () async {
      final data = await Directory.systemTemp.createTemp(
        'netease-playlist-edits-',
      );
      addTearDown(() => data.delete(recursive: true));
      final source = await File(
        'plugins/lazer.netease/main.lua',
      ).readAsString();
      // Observe the JSON passed to the first WEAPI encryption layer, while
      // retaining the real VM, encryption and HTTP path for the provider.
      final instrumented =
          '''
local last_payload = nil
local original_crypto = host.crypto
host.crypto = function(request)
  if request.operation == "aes" and request.key == "0CoJUm6Qyw8W8jud" then
    last_payload = host.json_decode(request.text)
  end
  return original_crypto(request)
end
local plugin = (function()
$source
end)()
return { call = function(operation, args)
  if operation == "testLastPayload" then return last_payload end
  return plugin.call(operation, args)
end }
''';
      var mutations = 0;
      final runtime = LuaPluginRuntime(
        manifest: PluginManifest.decode(
          await File('plugins/lazer.netease/manifest.json').readAsString(),
        ),
        sources: {'main.lua': instrumented},
        dataDirectory: data.path,
        httpHandler: (request) async {
          final path = Uri.parse(request['url'] as String).path;
          final body = switch (path) {
            '/weapi/w/nuser/account/get' => {
              'code': 200,
              'profile': {'userId': 42, 'nickname': 'Listener'},
            },
            '/weapi/w/login' || '/weapi/w/login/cellphone' => {
              'code': 200,
              'profile': {'userId': 42, 'nickname': 'Listener'},
            },
            '/weapi/playlist/create' => {
              'code': 200,
              'playlist': {
                'id': 99,
                'name': 'Test',
                'creator': {'userId': 42},
              },
            },
            '/weapi/playlist/manipulate/tracks' => {'code': 200},
            '/eapi/v6/playlist/detail' => {
              'code': 200,
              'playlist': {
                'id': 99,
                'trackIds': [
                  {'id': 7},
                  {'id': 8},
                  {'id': 7},
                ],
              },
            },
            _ => throw StateError('Unexpected endpoint $path'),
          };
          if (path == '/weapi/playlist/manipulate/tracks') mutations++;
          return {'status': 200, 'headers': {}, 'body': jsonEncode(body)};
        },
      );
      addTearDown(runtime.close);
      final gateway = LuaMusicGateway(
        runtime: runtime,
        provider: MusicProvider.netease,
        connectionId: 'lazer.netease',
      );
      await gateway.loginWithCookie('MUSIC_U=fixture');
      final playlist = await gateway.createPlaylist('Test');
      expect(playlist.name, 'Test');
      expect(playlist.writable, true);
      await gateway.addToPlaylist(playlist.id, [
        gateway.id(MusicEntityKind.song, '7'),
        gateway.id(MusicEntityKind.song, '8'),
      ]);
      var payload = await runtime.invoke('testLastPayload') as Map;
      expect(payload['op'], 'add');
      expect(payload['trackIds'], isA<String>());
      expect(jsonDecode(payload['trackIds'] as String), [7, 8]);
      await gateway.removeFromPlaylist(playlist.id, [1]);
      payload = await runtime.invoke('testLastPayload') as Map;
      expect(payload['op'], 'del');
      expect(payload['trackIds'], isA<String>());
      expect(jsonDecode(payload['trackIds'] as String), [8]);
      expect(mutations, 2);
      for (final indexes in [
        [0],
        [3],
        [-1],
        <int>[],
      ]) {
        await expectLater(
          gateway.removeFromPlaylist(playlist.id, indexes),
          throwsA(isA<PluginException>()),
        );
        expect(
          mutations,
          2,
          reason:
              'an invalid or ambiguous edit must not reach the mutation endpoint',
        );
      }
      await expectLater(
        gateway.createPlaylist('  '),
        throwsA(isA<PluginException>()),
      );
      expect((await gateway.search('  \t ')).songs.items, isEmpty);
      const password = 'fixture-password-longer-than-sixteen';
      expect(
        await gateway.loginWithPassword('  listener@example.test  ', password),
        isNotNull,
      );
      payload = await runtime.invoke('testLastPayload') as Map;
      expect(payload['username'], 'listener@example.test');
      expect(payload['password'], gatewayMd5(password));
      expect(
        await gateway.loginWithPassword(' +86 138-0013-8000 ', password),
        isNotNull,
      );
      payload = await runtime.invoke('testLastPayload') as Map;
      expect(payload['phone'], '13800138000');
      expect(payload['password'], gatewayMd5(password));
    },
  );
}
