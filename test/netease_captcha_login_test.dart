import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pointycastle/export.dart' as pc;

import 'package:lazer_nextgen/plugins/lua_plugin_runtime.dart';
import 'package:lazer_nextgen/plugins/plugin_manifest.dart';

final _plugin = Directory(
  Platform.environment['LAZER_NCM_PLUGIN'] ??
      p.join(r'E:\projects', 'lazer_ncm', 'netease-cloud'),
);
const _fixtureSecret = 'aaaaaaaaaaaaaaaa';

String _decrypt(String encoded, String key) {
  final cipher = pc.CBCBlockCipher(pc.AESEngine())
    ..init(
      false,
      pc.ParametersWithIV(
        pc.KeyParameter(Uint8List.fromList(utf8.encode(key))),
        Uint8List.fromList(utf8.encode('0102030405060708')),
      ),
    );
  final bytes = base64Decode(encoded);
  final output = Uint8List(bytes.length);
  for (var offset = 0; offset < bytes.length; offset += 16) {
    cipher.processBlock(bytes, offset, output, offset);
  }
  return utf8.decode(output.sublist(0, output.length - output.last));
}

String _decryptEapi(String hex) {
  final cipher = pc.ECBBlockCipher(pc.AESEngine())
    ..init(
      false,
      pc.KeyParameter(Uint8List.fromList(utf8.encode('e82ckenh8dichen8'))),
    );
  final bytes = Uint8List.fromList([
    for (var index = 0; index < hex.length; index += 2)
      int.parse(hex.substring(index, index + 2), radix: 16),
  ]);
  final output = Uint8List(bytes.length);
  for (var offset = 0; offset < bytes.length; offset += 16) {
    cipher.processBlock(bytes, offset, output, offset);
  }
  return utf8.decode(output.sublist(0, output.length - output.last));
}

class _Request {
  _Request(Map<String, dynamic> spec)
    : uri = Uri.parse(spec['url'] as String),
      headers = Map<String, dynamic>.from(spec['headers'] as Map),
      payload = _payload(spec['body'] as String);

  final Uri uri;
  final Map<String, dynamic> headers;
  final Map<String, dynamic> payload;

  static Map<String, dynamic> _payload(String body) {
    final fields = Uri.splitQueryString(body);
    if (!fields.containsKey('encSecKey')) {
      return Map<String, dynamic>.from(
        jsonDecode(_decryptEapi(fields['params']!).split('-36cd479b6b5-')[1])
            as Map,
      );
    }
    expect(fields['encSecKey']?.length, 256);
    final first = _decrypt(fields['params']!, _fixtureSecret);
    return Map<String, dynamic>.from(
      jsonDecode(_decrypt(first, '0CoJUm6Qyw8W8jud')) as Map,
    );
  }
}

Map<String, dynamic> _response(
  Map<String, dynamic> body, {
  String cookie = '',
}) => {
  'status': 200,
  'headers': {if (cookie.isNotEmpty) 'set-cookie': cookie},
  'body': jsonEncode(body),
};

Map<String, dynamic> _profile(int id) => {
  'code': 200,
  'profile': {'userId': id, 'nickname': 'Listener $id'},
};

Future<LuaPluginRuntime> _runtime(
  Map<String, dynamic> Function(_Request request) handler,
) async {
  final sources = <String, String>{
    for (final file in _plugin.listSync(recursive: true).whereType<File>())
      if (file.path.endsWith('.lua'))
        p.relative(file.path, from: _plugin.path).replaceAll(r'\', '/'): file
            .readAsStringSync(),
  };
  // Deterministic entropy lets the mock service decrypt the real two-layer
  // weapi envelope. The plugin source and host crypto remain unchanged.
  sources['main.lua'] =
      '''
host.random_hex = function(count) return string.rep("a", count * 2) end
${sources['main.lua']}
''';
  final data = await Directory.systemTemp.createTemp('netease-login-');
  final runtime = LuaPluginRuntime(
    manifest: PluginManifest.decode(
      File(p.join(_plugin.path, 'manifest.json')).readAsStringSync(),
    ),
    sources: sources,
    dataDirectory: data.path,
    httpHandler: (spec) async => handler(_Request(spec)),
  );
  addTearDown(() async {
    runtime.close();
    await data.delete(recursive: true);
  });
  return runtime;
}

void main() {
  final present = File(p.join(_plugin.path, 'ncm', 'account.lua')).existsSync();
  group(
    'NetEase authentication and lyric wire contract',
    () {
      test(
        'send and login match api-enhanced and use the same phone',
        () async {
          final requests = <_Request>[];
          final runtime = await _runtime((request) {
            requests.add(request);
            return request.uri.path.endsWith('/captcha/sent')
                ? _response({'code': 200})
                : _response(
                    _profile(42),
                    cookie: 'MUSIC_U=new-session; Path=/',
                  );
          });

          expect(
            await runtime.invoke('sendCaptcha', {'phone': '+86 138-0000-0000'}),
            true,
          );
          expect(requests.single.uri.path, '/weapi/sms/captcha/sent');
          expect(requests.single.payload, {
            'ctcode': '86',
            'secrete': 'music_middleuser_pclogin',
            'cellphone': '13800000000',
            'e_r': false,
            'csrf_token': '',
          });
          expect(requests.single.headers['User-Agent'], contains('Chrome/124'));
          expect(
            requests.single.headers['User-Agent'],
            isNot(contains('NeteaseMusicDesktop')),
          );

          final user = await runtime.invoke('loginCaptcha', {
            'phone': '+86 138-0000-0000',
            'captcha': ' 012345 ',
          });
          expect(user, containsPair('id', '42'));
          expect(requests.last.uri.path, '/weapi/w/login/cellphone');
          expect(requests.last.payload, {
            'type': '1',
            'https': 'true',
            'phone': '13800000000',
            'countrycode': '86',
            'remember': 'true',
            'captcha': '012345',
            'secureCaptcha': '',
            'e_r': false,
            'csrf_token': '',
          });
          expect(await runtime.invoke('exportCookie'), 'MUSIC_U=new-session');
        },
      );

      test(
        'failed login restores rotated cookies and reports rate limiting',
        () async {
          final runtime = await _runtime((request) {
            if (request.uri.path.endsWith('/account/get')) {
              return _response(_profile(7));
            }
            return _response({
              'code': -460,
            }, cookie: 'MUSIC_U=failed-attempt; Path=/');
          });
          await runtime.invoke('loginCookie', {
            'cookie': 'MUSIC_U=original; __csrf=csrf',
          });
          final result =
              await runtime.invoke('loginCaptcha', {
                    'phone': '13800000000',
                    'captcha': '012345',
                  })
                  as Map;
          expect((result['error'] as Map)['httpStatus'], 429);
          expect(
            await runtime.invoke('exportCookie'),
            'MUSIC_U=original; __csrf=csrf',
          );
          expect(await runtime.invoke('session'), containsPair('id', '7'));
        },
      );

      test(
        'unverifiable successful response restores the previous session',
        () async {
          var candidate = false;
          final runtime = await _runtime((request) {
            if (request.uri.path.endsWith('/account/get')) {
              return _response(candidate ? {'code': 200} : _profile(7));
            }
            candidate = true;
            return _response({
              'code': 200,
            }, cookie: 'MUSIC_U=unverified; Path=/');
          });
          await runtime.invoke('loginCookie', {'cookie': 'MUSIC_U=original'});
          expect(
            await runtime.invoke('loginCaptcha', {
              'phone': '13800000000',
              'captcha': '012345',
            }),
            isNull,
          );
          expect(await runtime.invoke('exportCookie'), 'MUSIC_U=original');
        },
      );

      test(
        'optional security token is forwarded without exposing it in errors',
        () async {
          final runtime = await _runtime((request) {
            expect(request.payload['secureCaptcha'], 'fixture-security-token');
            return _response({
              'code': 509,
              'message': 'private upstream detail',
            });
          });
          final result = await runtime.invoke('loginCaptcha', {
            'phone': '13800000000',
            'captcha': '012345',
            'secureCaptcha': 'fixture-security-token',
          });
          expect(result, {
            'error': {'code': 509, 'reason': 'Request failed'},
          });
        },
      );

      test(
        'lyrics return the service romanization for both lyric routes',
        () async {
          var useFallback = false;
          final runtime = await _runtime((request) {
            if (useFallback && request.uri.path.endsWith('/lyric/v1')) {
              return _response({'code': 200});
            }
            return _response({
              'code': 200,
              'lrc': {'lyric': '[00:01.00]原文'},
              'rlyric': {'lyric': '[00:01.00]genbun'},
              'yromalrc': {'lyric': '[1000,500](1000,500,0)genbun'},
            });
          });
          Future<void> check() async {
            final entries = await runtime.invoke('lyrics', {'id': '1'}) as List;
            expect(entries.single['romanization'], '[00:01.00]genbun');
            expect(
              entries.single['wordRomanization'],
              '[1000,500](1000,500,0)genbun',
            );
          }

          await check();
          useFallback = true;
          await check();
        },
      );
    },
    skip: present
        ? false
        : 'Set LAZER_NCM_PLUGIN to the NetEase plugin sources',
  );
}
