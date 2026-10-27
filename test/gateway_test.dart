import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/gateway/crypto.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/gateway/routes.dart';
import 'package:lazer_nextgen/gateway/transport.dart';

void main() {
  test('recommended playlist route matches api-enhanced weapi payload', () {
    final route = buildNeteaseRequest('/personalized', {'limit': '12'});
    expect(route.path, '/api/personalized/playlist');
    expect(route.encoding, NeteaseEncoding.weapi);
    expect(route.payload, {'limit': '12', 'total': true, 'n': 1000});
  });
  group('gatewayMd5', () {
    test('matches the standard vector', () {
      expect(gatewayMd5('hello'), '5d41402abc4b2a76b9719d911017c592');
      expect(gatewayMd5(''), 'd41d8cd98f00b204e9800998ecf8427e');
    });
  });

  group('gatewayWeapi', () {
    test('round-trips through both AES layers with a fixed secret', () {
      const String json = '{"s":"field notes","e_r":false}';
      final Map<String, String> form = gatewayWeapi(
        json,
        secret: 'abcdefghijklmnop',
      );
      expect(
        form['params'],
        'HAN+tvENK8H64oQcDLa2ba85QCsOmKfN8b681FgUu4zpOZWPb06WOC/aKMd2RbTA',
        reason: 'independent Node crypto AES-CBC vector',
      );
      expect(form.keys, <String>['params', 'encSecKey']);
      expect(form['encSecKey'], hasLength(256));
      final String first = gatewayAesCbcDecrypt(
        base64Decode(form['params']!),
        'abcdefghijklmnop',
      );
      final String original = gatewayAesCbcDecrypt(
        base64Decode(first),
        '0CoJUm6Qyw8W8jud',
      );
      expect(original, json);
    });

    test('is deterministic for a fixed secret', () {
      final Map<String, String> a = gatewayWeapi(
        '{}',
        secret: '0123456789abcdef',
      );
      final Map<String, String> b = gatewayWeapi(
        '{}',
        secret: '0123456789abcdef',
      );
      expect(a, b);
    });

    test('rejects a malformed secret', () {
      expect(() => gatewayWeapi('{}', secret: 'short'), throwsArgumentError);
      expect(
        () => gatewayWeapi('{}', secret: 'abcdefghijklmno-'),
        throwsArgumentError,
      );
    });
  });

  group('gatewayEapi', () {
    test('round-trips the path/json/md5 envelope', () {
      const String path = '/api/song/lyric';
      const String json = '{"id":123}';
      final String hex = gatewayEapi(path, json);
      expect(hex, equals(hex.toUpperCase()));
      final String payload = gatewayAesEcbDecrypt(
        _hexToBytes(hex),
        'e82ckenh8dichen8',
      );
      final String digest = gatewayMd5('nobody${path}use${json}md5forencrypt');
      expect(payload, '$path-36cd479b6b5-$json-36cd479b6b5-$digest');
    });
  });

  group('normalizeGatewaySessionCookie', () {
    test('accepts pasted header prefixes and preserves equals in values', () {
      expect(
        normalizeGatewaySessionCookie(
          '\uFEFFCookie: MUSIC_U=abc==; __csrf=token',
        ),
        'MUSIC_U=abc==; __csrf=token',
      );
    });
    test('drops Set-Cookie attributes and keeps the last value', () {
      final String? normalized = normalizeGatewaySessionCookie(
        'MUSIC_U=abc; Path=/; Domain=.music.163.com; __csrf=token123; '
        'MUSIC_U=final; Max-Age=0; Secure',
      );
      expect(normalized, 'MUSIC_U=final; __csrf=token123');
    });

    test('strips a Set-Cookie prefix and rejects malformed names', () {
      expect(
        normalizeGatewaySessionCookie('Set-Cookie: NMTID=nv; HttpOnly'),
        'NMTID=nv',
      );
      expect(normalizeGatewaySessionCookie('bad name=value'), isNull);
      expect(normalizeGatewaySessionCookie('=novalue'), isNull);
      expect(normalizeGatewaySessionCookie(null), isNull);
      expect(normalizeGatewaySessionCookie('   '), isNull);
    });

    test('keeps the QR session identifiers and the csrf alias', () {
      // `/login/qr/check` hands the confirmed session back with the device
      // cookies it rotated while the phone scanned; dropping them loses the
      // login exactly like api-enhanced's whitelist-free jar would.
      expect(
        normalizeGatewaySessionCookie(
          'MUSIC_U=u; __csrf_token=ct; _ntes_nuid=nuid; WNMCID=w; '
          'Path=/; Domain=.music.163.com; Secure',
        ),
        'MUSIC_U=u; __csrf_token=ct; _ntes_nuid=nuid; WNMCID=w',
      );
    });
  });

  group('buildNeteaseRequest', () {
    test('maps search onto /api/search/get', () {
      final NeteaseRequest request = buildNeteaseRequest(
        '/search',
        <String, String>{
          'keywords': 'nocturne',
          'type': '1',
          'limit': '30',
          'offset': '0',
        },
      );
      expect(request.path, '/api/search/get');
      expect(request.encoding, NeteaseEncoding.eapi);
      expect(request.payload['s'], 'nocturne');
      expect(request.payload['type'], '1');
      expect(request.payload['limit'], '30');
    });

    test('maps song url onto the web player url route', () {
      final NeteaseRequest request = buildNeteaseRequest(
        '/song/url/v1',
        <String, String>{'id': '42', 'level': 'standard'},
      );
      expect(request.path, '/api/song/enhance/player/url');
      expect(request.encoding, NeteaseEncoding.weapi);
      expect(request.payload['ids'], '[42]');
      expect(request.payload['br'], 128000);
    });

    test('maps every quality tier onto its player-url bitrate', () {
      const expected = <String, int>{
        'standard': 128000,
        'higher': 192000,
        'exhigh': 320000,
        'lossless': 999000,
      };
      for (final MapEntry<String, int> entry in expected.entries) {
        final NeteaseRequest request = buildNeteaseRequest(
          '/song/url/v1',
          <String, String>{'id': '42', 'level': entry.key},
        );
        expect(request.path, '/api/song/enhance/player/url');
        expect(request.payload['br'], entry.value, reason: entry.key);
      }
    });

    test('refuses a level the gateway cannot request', () {
      expect(
        () => buildNeteaseRequest('/song/url/v1', <String, String>{
          'id': '42',
          'level': 'dolby',
        }),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('maps the play record and the weblog upload', () {
      final NeteaseRequest record = buildNeteaseRequest(
        '/v1/play/record',
        <String, String>{'uid': '42', 'type': '0'},
      );
      expect(record.path, '/api/v1/play/record');
      expect(record.encoding, NeteaseEncoding.weapi);
      expect(record.payload['uid'], '42');
      expect(record.payload['type'], '0');

      final NeteaseRequest upload = buildNeteaseRequest(
        '/feedback/weblog',
        <String, String>{'logs': '[]'},
      );
      expect(upload.path, '/api/feedback/weblog');
      expect(upload.encoding, NeteaseEncoding.weapi);
      expect(upload.payload['logs'], '[]');
    });

    test('maps listen-together play commands and heartbeat', () {
      final NeteaseRequest command = buildNeteaseRequest(
        '/listentogether/play/command',
        <String, String>{
          'roomId': '42',
          'commandInfo': '{"commandType":"PLAY","progress":1500}',
        },
      );
      expect(command.path, '/api/listen/together/play/command/report');
      expect(command.encoding, NeteaseEncoding.eapi);
      expect(command.mobileClient, isTrue);
      expect(command.payload['roomId'], '42');
      expect(
        command.payload['commandInfo'],
        '{"commandType":"PLAY","progress":1500}',
      );

      final NeteaseRequest heartbeat = buildNeteaseRequest(
        '/listentogether/heartbeat',
        <String, String>{
          'roomId': '42',
          'songId': '7',
          'playStatus': 'PAUSE',
          'progress': '1500',
        },
      );
      expect(heartbeat.path, '/api/listen/together/heartbeat');
      expect(heartbeat.payload['playStatus'], 'PAUSE');
      expect(heartbeat.payload['playlistVersion'], '[]');
    });

    test('maps paged artist songs onto the native artist endpoint', () {
      final NeteaseRequest request = buildNeteaseRequest(
        '/artist/songs',
        const <String, String>{
          'id': '6452',
          'order': 'hot',
          'limit': '100',
          'offset': '200',
        },
      );
      expect(request.path, '/api/v1/artist/songs');
      expect(request.encoding, NeteaseEncoding.eapi);
      expect(request.payload['id'], '6452');
      expect(request.payload['limit'], '100');
      expect(request.payload['offset'], '200');
      expect(request.payload['private_cloud'], 'true');
    });

    test('maps comments and listen-together onto finite service routes', () {
      final comments = buildNeteaseRequest(
        '/comment/music',
        const <String, String>{'id': '42'},
      );
      expect(comments.path, '/api/v1/resource/comments/R_SO_4_42');
      final room = buildNeteaseRequest(
        '/listentogether/room/check',
        const <String, String>{'roomId': 'room_42'},
      );
      expect(room.mobileClient, isTrue);
      expect(room.payload['roomId'], 'room_42');
      expect(
        () => buildNeteaseRequest(
          '/listentogether/room/check',
          const <String, String>{'roomId': '../escape'},
        ),
        throwsArgumentError,
      );
    });

    test('maps cloud playlist creation and track manipulation', () {
      final NeteaseRequest create = buildNeteaseRequest(
        '/playlist/create',
        <String, String>{'name': '夜行', 'privacy': '10'},
      );
      expect(create.path, '/api/playlist/create');
      expect(create.encoding, NeteaseEncoding.weapi);
      expect(create.payload['name'], '夜行');
      expect(create.payload['privacy'], '10');
      expect(create.payload['type'], 'NORMAL');

      final NeteaseRequest add = buildNeteaseRequest(
        '/playlist/tracks',
        <String, String>{'op': 'add', 'pid': '42', 'tracks': '7,8'},
      );
      expect(add.path, '/api/playlist/manipulate/tracks');
      expect(add.encoding, NeteaseEncoding.weapi);
      expect(add.payload['op'], 'add');
      expect(add.payload['pid'], '42');
      expect(add.payload['trackIds'], '[7,8]');
      expect(add.payload['imme'], 'true');

      expect(
        () => buildNeteaseRequest('/playlist/create', <String, String>{
          'name': '   ',
        }),
        throwsArgumentError,
      );
      expect(
        () => buildNeteaseRequest('/playlist/tracks', <String, String>{
          'pid': '0',
          'tracks': '7',
        }),
        throwsArgumentError,
      );
    });

    test('rejects unsupported aliases and bad ids', () {
      expect(
        () => buildNeteaseRequest('/unknown', const <String, String>{}),
        throwsArgumentError,
      );
      expect(
        () => buildNeteaseRequest('/lyric', const <String, String>{'id': '0'}),
        throwsArgumentError,
      );
      expect(
        () =>
            buildNeteaseRequest('/lyric', const <String, String>{'id': 'abc'}),
        throwsArgumentError,
      );
    });
  });

  group('synthetic qr create', () {
    test('builds the scan URL locally without a network call', () async {
      final NeteaseTransport transport = NeteaseTransport();
      final Map<String, dynamic> body = await transport.request(
        '/login/qr/create',
        <String, String>{'key': 'abc123'},
      );
      expect(body['code'], 200);
      final Map<String, dynamic> data = body['data'] as Map<String, dynamic>;
      // Exactly the URL the official desktop client renders: key only.
      expect(data['qrurl'], 'https://music.163.com/login?codekey=abc123');
    });

    test('refuses a blank key', () async {
      final NeteaseTransport transport = NeteaseTransport();
      await expectLater(
        transport.request('/login/qr/create', <String, String>{'key': ''}),
        throwsArgumentError,
      );
    });

    test('never fabricates the web chainId device id', () async {
      final NeteaseTransport transport = NeteaseTransport()
        ..cookie = 'NMTID=abc';
      // The session minted the unikey anonymously, so it has no sDeviceId:
      // the phone still gets the plain codekey URL the app can confirm.
      final Map<String, dynamic> body = await transport.request(
        '/login/qr/create',
        <String, String>{'key': 'k1', 'platform': 'web'},
      );
      final String url =
          (body['data'] as Map<String, dynamic>)['qrurl'] as String;
      expect(url, startsWith('https://music.163.com/login?codekey=k1'));
      expect(url, isNot(contains('chainId')));
    });

    test('adds the web chainId only for a real sDeviceId', () async {
      final NeteaseTransport transport = NeteaseTransport()
        ..cookie = 'NMTID=abc; sDeviceId=DEV42';
      final Map<String, dynamic> body = await transport.request(
        '/login/qr/create',
        <String, String>{'key': 'k1', 'platform': 'web'},
      );
      expect(
        (body['data'] as Map<String, dynamic>)['qrurl'],
        contains('&chainId=v1_DEV42_web_login_'),
      );
    });
  });

  group('qr sign-in rides the plain api surface', () {
    test('the key route is the desktop client route', () {
      final NeteaseRequest route = buildNeteaseRequest(
        '/login/qr/key',
        const <String, String>{},
      );
      expect(route.path, '/api/login/qrcode/unikey');
      expect(route.encoding, NeteaseEncoding.api);
      expect(route.payload['type'], 3);
    });

    test('the poll sends the key, its type and the captcha token', () {
      final NeteaseRequest route = buildNeteaseRequest(
        '/login/qr/check',
        const <String, String>{'key': 'k1', 'secureCaptcha': 'token'},
      );
      expect(route.path, '/api/login/qrcode/client/login');
      expect(route.encoding, NeteaseEncoding.api);
      expect(route.payload['key'], 'k1');
      expect(route.payload['type'], 3);
      expect(route.payload['secureCaptcha'], 'token');
    });

    test('the poll defaults to an empty captcha token', () {
      final NeteaseRequest route = buildNeteaseRequest(
        '/login/qr/check',
        const <String, String>{'key': 'k1'},
      );
      expect(route.payload['secureCaptcha'], '');
    });

    test('a confirmed poll installs the session cookie it returns', () async {
      final NeteaseGateway gateway = NeteaseGateway(
        transport: _ConfirmedTransport(),
      );
      final GatewayQrCheck check = await gateway.checkQrCode('k1');
      expect(check.code, 803);
      // Without this the account lookup right after 803 runs as a guest.
      expect(gateway.sessionCookie, 'MUSIC_U=abc; __csrf=t');
    });
  });

  group('sms sign-in matches api-enhanced payloads', () {
    test('a captcha login posts the weapi cellphone form', () {
      final NeteaseRequest route = buildNeteaseRequest(
        '/login/cellphone',
        const <String, String>{
          'phone': '13800000000',
          'captcha': '123456',
          'countrycode': '86',
        },
      );
      expect(route.path, '/api/w/login/cellphone');
      expect(route.encoding, NeteaseEncoding.weapi);
      expect(route.payload['type'], '1');
      expect(route.payload['https'], 'true');
      expect(route.payload['phone'], '13800000000');
      expect(route.payload['countrycode'], '86');
      expect(route.payload['captcha'], '123456');
      expect(route.payload['remember'], 'true');
      expect(route.payload['secureCaptcha'], '');
      // The captcha form must never carry a password alongside it.
      expect(route.payload.containsKey('password'), isFalse);
    });

    test('sending a code posts the middle captcha form', () {
      final NeteaseRequest route = buildNeteaseRequest(
        '/captcha/sent/v1',
        const <String, String>{'phone': '13800000000', 'ctcode': '86'},
      );
      expect(route.path, '/api/middle/captcha/sent/v1');
      expect(route.encoding, NeteaseEncoding.eapi);
      expect(route.payload, <String, Object?>{
        'ctcode': '86',
        'secrete': 'music_middleuser_pclogin',
        'cellphone': '13800000000',
        'scene': '0',
      });
    });

    test('the code send keeps the device cookies it mints', () async {
      final NeteaseGateway gateway = NeteaseGateway(
        transport: _CaptchaSentTransport(),
      );
      await gateway.sendCaptcha('13800000000');
      expect(gateway.sessionCookie, 'NMTID=n1; _ntes_nuid=u1');
    });

    test('a successful captcha login installs the session cookie', () async {
      final NeteaseGateway gateway = NeteaseGateway(
        transport: _CaptchaLoginTransport(),
      );
      final GatewayLoginResult result = await gateway.loginWithPhoneCaptcha(
        '13800000000',
        '123456',
      );
      expect(result.ok, isTrue);
      expect(result.profile?.userId, 7);
      expect(gateway.sessionCookie, 'MUSIC_U=abc; __csrf=t');
    });
  });
  group('cloud playlists', () {
    test('reads ownership from the user playlist payload', () {
      final GatewayPlaylist owned = GatewayPlaylist.fromJson(<String, dynamic>{
        'id': 1,
        'name': '自己创建',
        'subscribed': false,
        'creator': <String, dynamic>{'userId': 7},
      });
      expect(owned.subscribed, isFalse);
      expect(owned.creatorId, 7);

      final GatewayPlaylist collected = GatewayPlaylist.fromJson(
        <String, dynamic>{
          'id': 2,
          'name': '收藏的歌单',
          'subscribed': true,
          'creator': <String, dynamic>{'userId': 9},
        },
      );
      expect(collected.subscribed, isTrue);
      expect(collected.creatorId, 9);
    });

    test('creates a private playlist and adds tracks', () async {
      final _PlaylistTransport transport = _PlaylistTransport();
      final NeteaseGateway gateway = NeteaseGateway(transport: transport);
      final GatewayPlaylist? created = await gateway.createPlaylist(
        '夜行',
        privacy: true,
      );
      expect(created?.id, 99);
      expect(created?.name, '夜行');
      expect(transport.requests.single.$1, '/playlist/create');
      expect(transport.requests.single.$2['privacy'], '10');

      await gateway.addTracksToPlaylist(99, <int>[7, 8]);
      expect(transport.requests.last.$1, '/playlist/tracks');
      expect(transport.requests.last.$2['pid'], '99');
      expect(transport.requests.last.$2['tracks'], '7,8');
    });

    test('rejects invalid names and track ids before any request', () async {
      final _PlaylistTransport transport = _PlaylistTransport();
      final NeteaseGateway gateway = NeteaseGateway(transport: transport);
      await expectLater(gateway.createPlaylist('  '), throwsArgumentError);
      await expectLater(
        gateway.addTracksToPlaylist(0, <int>[7]),
        throwsArgumentError,
      );
      await expectLater(
        gateway.addTracksToPlaylist(1, <int>[0]),
        throwsArgumentError,
      );
      expect(transport.requests, isEmpty);
    });
  });
}

/// Playlist transport that records the calls and answers like the service.
class _PlaylistTransport extends NeteaseTransport {
  final List<(String, Map<String, String>)> requests =
      <(String, Map<String, String>)>[];

  @override
  Future<Map<String, dynamic>> request(
    String alias,
    Map<String, String> parameters,
  ) async {
    requests.add((alias, Map<String, String>.of(parameters)));
    if (alias == '/playlist/create') {
      return <String, dynamic>{
        'code': 200,
        'playlist': <String, dynamic>{
          'id': 99,
          'name': parameters['name'],
          'trackCount': 0,
          'created': true,
        },
      };
    }
    return <String, dynamic>{'code': 200};
  }
}

/// Poll transport that answers a confirmed scan with the fresh session.
class _ConfirmedTransport extends NeteaseTransport {
  @override
  Future<Map<String, dynamic>> request(
    String alias,
    Map<String, String> parameters,
  ) async {
    expect(alias, '/login/qr/check');
    expect(parameters['secureCaptcha'], '');
    return <String, dynamic>{
      'code': 803,
      'message': '授权登陆成功',
      'cookie': 'MUSIC_U=abc; __csrf=t',
    };
  }
}

/// Captcha login transport: the account plus the rotated session cookie.
class _CaptchaLoginTransport extends NeteaseTransport {
  @override
  Future<Map<String, dynamic>> request(
    String alias,
    Map<String, String> parameters,
  ) async {
    expect(alias, '/login/cellphone');
    expect(parameters['phone'], '13800000000');
    expect(parameters['captcha'], '123456');
    expect(parameters['sca'], '');
    return <String, dynamic>{
      'code': 200,
      'cookie': 'MUSIC_U=abc; __csrf=t',
      'profile': <String, dynamic>{'userId': 7, 'nickname': '测试账户'},
      'account': <String, dynamic>{'id': 7},
    };
  }
}

/// SMS send transport: the anonymous device cookies the server mints.
class _CaptchaSentTransport extends NeteaseTransport {
  @override
  Future<Map<String, dynamic>> request(
    String alias,
    Map<String, String> parameters,
  ) async {
    expect(alias, '/captcha/sent/v1');
    expect(parameters['phone'], '13800000000');
    return <String, dynamic>{
      'code': 200,
      'data': true,
      'cookie': 'NMTID=n1; _ntes_nuid=u1',
    };
  }
}

List<int> _hexToBytes(String hex) {
  final List<int> bytes = <int>[];
  for (int i = 0; i < hex.length; i += 2) {
    bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return bytes;
}
