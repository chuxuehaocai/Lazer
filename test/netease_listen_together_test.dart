import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pointycastle/export.dart' as pc;

import 'package:lazer_nextgen/plugins/lua_plugin_runtime.dart';
import 'package:lazer_nextgen/plugins/plugin_manifest.dart';

/// End-to-end check of the shipped NetEase plugin against the room contract
/// documented in docs/lua-plugins.md.
///
/// The service is faked, but the plugin is the real one: every request is
/// decrypted with the eapi key, its signature verified, and its envelope
/// compared with the client identity the room endpoints expect. Set
/// LAZER_NCM_PLUGIN to the plugin directory to run it elsewhere.
class _RoomRequest {
  _RoomRequest(this.uri, this.headers, this.payload);

  final Uri uri;
  final Map<String, String> headers;
  final Map<String, dynamic> payload;

  String get path => uri.path;
  String get cookie => headers['Cookie'] ?? headers['cookie'] ?? '';
  Map<String, dynamic> get header =>
      Map<String, dynamic>.from(payload['header'] as Map? ?? const {});
}

String _decryptParams(String hex) {
  final pc.ECBBlockCipher cipher = pc.ECBBlockCipher(pc.AESEngine())
    ..init(false, pc.KeyParameter(Uint8List.fromList(utf8.encode('e82ckenh8dichen8'))));
  final List<int> bytes = <int>[
    for (int index = 0; index < hex.length; index += 2)
      int.parse(hex.substring(index, index + 2), radix: 16),
  ];
  final Uint8List out = Uint8List(bytes.length);
  for (int offset = 0; offset < bytes.length; offset += 16) {
    cipher.processBlock(
      Uint8List.fromList(bytes.sublist(offset, offset + 16)),
      0,
      out,
      offset,
    );
  }
  final int pad = out.last;
  return utf8.decode(out.sublist(0, out.length - pad));
}

void main() {
  final Directory plugin = Directory(
    Platform.environment['LAZER_NCM_PLUGIN'] ??
        p.join(r'E:\projects', 'lazer_ncm', 'netease-cloud'),
  );
  // Both layouts ship: the flat 1.1 line and the modular 1.2 line.
  final bool present =
      plugin.existsSync() &&
      File(p.join(plugin.path, 'main.lua')).existsSync() &&
      (File(p.join(plugin.path, 'netease.lua')).existsSync() ||
          File(p.join(plugin.path, 'ncm', 'social.lua')).existsSync());

  test('the shipped plugin speaks the documented room contract', () async {
    final Map<String, String> sources = <String, String>{};
    for (final FileSystemEntity entity in plugin.listSync(recursive: true)) {
      if (entity is File && entity.path.endsWith('.lua')) {
        final String relative = p
            .relative(entity.path, from: plugin.path)
            .replaceAll(r'\', '/');
        sources[relative] = entity.readAsStringSync();
      }
    }
    final PluginManifest manifest = PluginManifest.decode(
      File(p.join(plugin.path, 'manifest.json')).readAsStringSync(),
    );
    final Directory data = await Directory.systemTemp.createTemp('netease-room');
    addTearDown(() => data.delete(recursive: true));

    final List<_RoomRequest> requests = <_RoomRequest>[];
    int roomFailure = 0;

    Future<Map<String, dynamic>> handle(Map<String, dynamic> spec) async {
      final Uri uri = Uri.parse(spec['url'] as String);
      final Map<String, String> headers = <String, String>{
        for (final MapEntry<dynamic, dynamic> entry
            in (spec['headers'] as Map? ?? const <String, String>{}).entries)
          entry.key.toString(): entry.value.toString(),
      };
      if (uri.path.contains('/weapi/')) {
        // weapi bodies are double-encrypted; the plugin only needs the paths.
        requests.add(_RoomRequest(uri, headers, const <String, dynamic>{}));
        final Map<String, dynamic> body = uri.path.endsWith(
          '/w/nuser/account/get',
        )
            ? <String, dynamic>{
                'code': 200,
                'profile': <String, dynamic>{'userId': 4242, 'nickname': 'Me'},
              }
            : <String, dynamic>{
                'code': 200,
                'data': <String, dynamic>{
                  'roomId': 'room-1',
                  'inviterId': 4242,
                  'members': <Map<String, dynamic>>[
                    <String, dynamic>{'userId': 4242, 'nickname': 'Ann'},
                  ],
                },
              };
        return <String, dynamic>{
          'status': 200,
          'headers': <String, dynamic>{},
          'body': jsonEncode(body),
        };
      }
      final String body = spec['body'] as String? ?? '';
      final String hex = body.startsWith('params=') ? body.substring(7) : '';
      final String plain = _decryptParams(hex);
      final List<String> parts = plain.split('-36cd479b6b5-');
      expect(parts.length, 3, reason: 'eapi envelope must carry path, body, digest');
      final String path = parts[0];
      final String payloadText = parts[1];
      final String digest = crypto.md5
          .convert(utf8.encode('nobody${path}use${payloadText}md5forencrypt'))
          .toString();
      expect(parts[2], digest, reason: 'eapi digest must match the payload');
      expect(uri.path, '/eapi${path.substring('/api'.length)}');
      requests.add(
        _RoomRequest(
          uri,
          headers,
          Map<String, dynamic>.from(jsonDecode(payloadText) as Map),
        ),
      );
      if (roomFailure != 0) {
        return <String, dynamic>{
          'status': 200,
          'headers': <String, dynamic>{},
          'body': jsonEncode(<String, dynamic>{
            'code': roomFailure,
            'message': 'fixture',
          }),
        };
      }
      return <String, dynamic>{
        'status': 200,
        'headers': <String, dynamic>{},
        'body': jsonEncode(<String, dynamic>{
          'code': 200,
          'data': <String, dynamic>{
            'roomId': 'room-1',
            'inviterId': 4242,
            'members': <Map<String, dynamic>>[
              <String, dynamic>{
                'userId': 4242,
                'nickname': 'Ann',
                'avatarUrl': 'https://a',
              },
            ],
          },
        }),
      };
    }

    final LuaPluginRuntime runtime = LuaPluginRuntime(
      manifest: manifest,
      sources: sources,
      dataDirectory: data.path,
      httpHandler: handle,
    );
    addTearDown(runtime.close);

    expect(
      await runtime.invoke('loginCookie', <String, dynamic>{
        'platform': 'netease',
        'cookie': 'MUSIC_U=token; __csrf=csrf',
      }),
      isNotNull,
    );

    Future<Object?> room(String operation, Map<String, dynamic> args) =>
        runtime.invoke('listenTogether', <String, dynamic>{
          'platform': 'netease',
          'operation': operation,
          ...args,
        });

    final Object? created = await room('create', const <String, dynamic>{});
    expect(created, containsPair('roomId', 'room-1'));
    expect(created, containsPair('inviterId', '4242'));
    final Map<String, dynamic> createRequest = requests.last.payload;
    expect(createRequest['refer'], 'songplay_more');
    final Map<String, dynamic> header = requests.last.header;
    expect(header['os'], 'android');
    expect(header['appver'], '9.5.95');
    expect(header['osver'], '14');
    expect(header['channel'], 'xiaomi');
    expect(header['versioncode'], '9005095');
    expect(header['MUSIC_U'], 'token');
    expect(header['__csrf'], 'csrf');
    expect(requests.last.cookie, contains('MUSIC_U=token'));
    expect(requests.last.cookie, contains('os=android'));
    expect(requests.last.cookie, contains('appver=9.5.95'));
    expect(requests.last.cookie, contains('versioncode=9005095'));

    await room('join', <String, dynamic>{'roomId': 'room-1', 'inviterId': '4242'});
    expect(requests.last.path, '/eapi/listen/together/play/invitation/accept');
    expect(requests.last.payload['refer'], 'inbox_invite');
    expect(requests.last.payload['roomId'], 'room-1');
    expect(requests.last.payload['inviterId'], '4242');

    await room('status', <String, dynamic>{'roomId': 'room-1'});
    expect(requests.last.path, '/eapi/listen/together/room/check');
    expect(requests.last.payload['roomId'], 'room-1');

    await room('status', const <String, dynamic>{});
    expect(requests.last.path, '/weapi/listen/together/status/get');

    await room('heartbeat', <String, dynamic>{
      'roomId': 'room-1',
      'songId': 'song-9',
      'playStatus': 'PAUSE',
      'progress': 1500,
    });
    expect(requests.last.path, '/eapi/listen/together/heartbeat');
    expect(requests.last.payload['songId'], 'song-9');
    expect(requests.last.payload['playStatus'], 'PAUSE');
    expect(requests.last.payload['progress'], 1500);
    expect(requests.last.payload['playlistVersion'], '[]');

    await room('command', <String, dynamic>{
      'roomId': 'room-1',
      'command': <String, dynamic>{
        'clientSeq': 3,
        'commandType': 'PLAY',
        'formerSongId': 'song-8',
        'playStatus': 'PLAY',
        'progress': 5000,
        'targetSongId': 'song-9',
        'triggerType': 'MANUAL',
      },
    });
    expect(requests.last.path, '/eapi/listen/together/play/command/report');
    final Map<String, dynamic> command = Map<String, dynamic>.from(
      jsonDecode(requests.last.payload['commandInfo'] as String) as Map,
    );
    expect(command['userId'], 4242);
    expect(command['ignoreUserId'], <int>[4242]);
    expect(command['serverSeq'], 0);
    expect(command['targetSongId'], 'song-9');
    expect(command['formerSongId'], 'song-8');
    expect(command['commandType'], 'PLAY');
    expect(command['progress'], 5000);

    await room('leave', <String, dynamic>{'roomId': 'room-1'});
    expect(requests.last.path, '/eapi/listen/together/end/v2');

    roomFailure = 301;
    expect(
      await room('create', const <String, dynamic>{}),
      <String, dynamic>{
        'error': <String, dynamic>{
          'code': 40,
          'httpStatus': 401,
          'reason': 'Request failed',
        },
      },
    );
    roomFailure = 429;
    final Map<String, dynamic> throttled =
        await room('create', const <String, dynamic>{}) as Map<String, dynamic>;
    expect((throttled['error'] as Map)['httpStatus'], 429);
  }, skip: present ? false : 'netease plugin sources are not installed');
}