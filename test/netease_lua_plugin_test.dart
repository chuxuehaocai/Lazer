import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/gateway/crypto.dart';
import 'package:lazer_nextgen/gateway/lua_music_gateway.dart';
import 'package:lazer_nextgen/gateway/music_gateway.dart';
import 'package:lazer_nextgen/plugins/lua_plugin_runtime.dart';
import 'package:lazer_nextgen/plugins/plugin_manifest.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PluginManifest manifest;
  late Map<String, String> sources;

  setUp(() async {
    final root = Directory.current;
    manifest = PluginManifest.decode(
      await File(
        '${root.path}/plugins/lazer.netease/manifest.json',
      ).readAsString(),
    );
    sources = {
      'main.lua': await File(
        '${root.path}/plugins/lazer.netease/main.lua',
      ).readAsString(),
    };
  });

  test(
    'describes the NetEase provider without requiring a network session',
    () async {
      final data = await Directory.systemTemp.createTemp(
        'netease-plugin-description-',
      );
      addTearDown(() => data.delete(recursive: true));
      final runtime = LuaPluginRuntime(
        manifest: manifest,
        sources: sources,
        dataDirectory: data.path,
        httpHandler: (_) async =>
            throw StateError('unexpected network request'),
      );
      addTearDown(runtime.close);
      final raw = await runtime.invoke('describe');
      expect(raw, {
        'providers': [
          {
            'id': 'netease',
            'name': '网易云音乐',
            'auth': ['qr', 'cookie', 'password', 'sms'],
            'capabilities': [
              'search',
              'browseAlbums',
              'savedAlbums',
              'playlists',
              'editPlaylists',
              'favorites',
              'lyrics',
              'scrobble',
              'recommendations',
              'comments',
            ],
            'loginHint': '扫码、手机号或邮箱登录网易云音乐',
            'cookieHint': '粘贴网易云音乐 Cookie',
          },
        ],
      });
    },
  );

  test(
    'handles QR setup, keeps rotated cookies, and verifies a cookie login',
    () async {
      final data = await Directory.systemTemp.createTemp(
        'netease-plugin-auth-',
      );
      addTearDown(() => data.delete(recursive: true));
      final requests = <Map<String, dynamic>>[];
      final runtime = LuaPluginRuntime(
        manifest: manifest,
        sources: sources,
        dataDirectory: data.path,
        httpHandler: (spec) async {
          requests.add(spec);
          final uri = Uri.parse(spec['url'] as String);
          if (uri.path == '/api/login/qrcode/unikey') {
            return {
              'status': 200,
              'headers': {'set-cookie': 'NMTID=anonymous; Path=/; HttpOnly'},
              'body': jsonEncode({
                'code': 200,
                'data': {'unikey': 'test-key'},
              }),
            };
          }
          if (uri.path == '/api/login/qrcode/client/login') {
            return {
              'status': 200,
              'headers': {},
              'body': jsonEncode({'code': 801, 'message': '等待扫码'}),
            };
          }
          if (uri.path == '/weapi/w/nuser/account/get') {
            final cookie = (spec['headers'] as Map)['Cookie'] as String? ?? '';
            if (cookie.contains('MUSIC_U=good')) {
              return {
                'status': 200,
                'headers': {},
                'body': jsonEncode({
                  'code': 200,
                  'profile': {
                    'userId': 42,
                    'nickname': '测试用户',
                    'avatarUrl': 'https://p1.music.126.net/avatar.jpg',
                  },
                  'account': {'id': 42, 'userName': 'test'},
                }),
              };
            }
            return {
              'status': 200,
              'headers': {},
              'body': jsonEncode({
                'code': 200,
                'profile': null,
                'account': null,
              }),
            };
          }
          throw StateError('unexpected endpoint ${uri.path}');
        },
      );
      addTearDown(runtime.close);
      final gateway = LuaMusicGateway(
        runtime: runtime,
        provider: const MusicProvider(id: 'netease', name: '网易云音乐'),
        connectionId: 'lazer.netease',
      );

      String? key;
      try {
        key = await gateway.qrKey();
      } on Object {
        fail(
          'QR key request endpoints: ${requests.map((spec) => Uri.parse(spec['url'] as String).path).toList()}',
        );
      }
      expect(key, 'test-key');
      expect(
        await gateway.qrUrl(key!),
        'https://music.163.com/login?codekey=test-key',
      );
      expect(await gateway.qrCheck(key), 801);
      expect(
        await gateway.loginWithCookie(
          'Cookie: MUSIC_U=good; __csrf=token; ignored=value',
        ),
        isNotNull,
      );
      expect((await gateway.checkSession())?.name, '测试用户');
      expect(await gateway.loginWithCookie('MUSIC_U=invalid'), isNull);
      expect((await gateway.checkSession())?.id.value, '42');
      expect(
        requests.any((spec) => (spec['headers'] as Map).containsKey('Cookie')),
        isTrue,
      );
    },
  );

  test(
    'maps search, playback streams and timed lyrics through the shared models',
    () async {
      final data = await Directory.systemTemp.createTemp(
        'netease-plugin-data-',
      );
      addTearDown(() => data.delete(recursive: true));
      final requests = <String>[];
      final runtime = LuaPluginRuntime(
        manifest: manifest,
        sources: sources,
        dataDirectory: data.path,
        httpHandler: (spec) async {
          final uri = Uri.parse(spec['url'] as String);
          requests.add(uri.toString());
          dynamic body;
          if (uri.path == '/eapi/cloudsearch/pc') {
            final form = Uri.splitQueryString(spec['body'] as String);
            final encrypted = form['params']!;
            final bytes = [
              for (var i = 0; i < encrypted.length; i += 2)
                int.parse(encrypted.substring(i, i + 2), radix: 16),
            ];
            final payload = gatewayAesEcbDecrypt(bytes, 'e82ckenh8dichen8');
            final parts = payload.split('-36cd479b6b5-');
            expect(parts, hasLength(3));
            expect(parts.first, '/api/cloudsearch/pc');
            expect(jsonDecode(parts[1]), isA<Map>());
            expect(encrypted, gatewayEapi(parts.first, parts[1]));
            body = {
              'code': 200,
              'result': {
                'songs': [
                  {
                    'id': 7,
                    'name': 'Song',
                    'dt': 123000,
                    'ar': [
                      {'id': 8, 'name': 'Artist'},
                    ],
                    'al': {
                      'id': 9,
                      'name': 'Album',
                      'picUrl': 'https://p1.music.126.net/a.jpg',
                    },
                  },
                ],
                'albums': [
                  {
                    'id': 9,
                    'name': 'Album',
                    'artists': [
                      {'id': 8, 'name': 'Artist'},
                    ],
                    'size': 1,
                  },
                ],
                'artists': [
                  {'id': 8, 'name': 'Artist'},
                ],
                'playlists': [
                  {
                    'id': 10,
                    'name': 'Mix',
                    'trackCount': 3,
                    'creator': {'userId': 42},
                  },
                ],
              },
            };
          } else if (uri.path == '/weapi/song/enhance/player/url') {
            body = {
              'code': 200,
              'data': [
                {
                  'id': 7,
                  'url': 'http://media.example/song.flac',
                  'br': 999000,
                  'type': 'flac',
                  'size': 1234,
                },
              ],
            };
          } else if (uri.path == '/eapi/song/lyric/v1') {
            body = {
              'code': 200,
              'lrc': {'lyric': '[00:01.00]line'},
              'yrc': {'lyric': '[1000,3000](0,500,0)line'},
              'tlyric': {'lyric': '[00:01.00]translation'},
            };
          } else {
            throw StateError('unexpected endpoint ${uri.path}');
          }
          return {'status': 200, 'headers': {}, 'body': jsonEncode(body)};
        },
      );
      addTearDown(runtime.close);
      final gateway = LuaMusicGateway(
        runtime: runtime,
        provider: const MusicProvider(id: 'netease', name: '网易云音乐'),
        connectionId: 'lazer.netease',
      );

      late final MusicSearchResult result;
      try {
        result = await gateway.search('Song', limit: 10);
      } on Object {
        fail('Search request endpoints: $requests');
      }
      expect(result.songs.items.single.title, 'Song');
      expect(result.songs.items.single.artists.single.name, 'Artist');
      expect(result.albums.items.single.title, 'Album');
      expect(result.artists.items.single.name, 'Artist');
      expect(result.playlists.items.single.name, 'Mix');
      final stream = await gateway.stream(result.songs.items.single.id);
      expect(stream.uri.scheme, 'https');
      expect(stream.suffix, 'flac');
      final lyrics = await gateway.lyrics(result.songs.items.single.id);
      expect(lyrics.single.synced, isTrue);
      expect(lyrics.single.lrc, contains('[00:01.00]'));
      expect(
        requests.where((url) => url.contains('/eapi/cloudsearch/pc')).length,
        4,
      );
    },
  );
}
