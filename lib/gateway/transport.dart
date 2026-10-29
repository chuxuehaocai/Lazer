import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;

import 'crypto.dart';
import 'routes.dart';
import 'response_decoder.dart';

/// HTTP failure before a valid API response could be decoded. The upstream
/// body is never retained.
class GatewayHttpException implements Exception {
  GatewayHttpException(this.statusCode, this.endpoint);

  final int statusCode;
  final String endpoint;

  @override
  String toString() =>
      'Gateway request to $endpoint failed with HTTP $statusCode.';
}

/// Successful HTTP response that was not valid JSON.
class GatewayProtocolException implements Exception {
  GatewayProtocolException(
    this.endpoint, [
    this.detail = 'Invalid upstream JSON.',
  ]);

  final String endpoint;
  final String detail;

  @override
  String toString() => 'Gateway request to $endpoint returned malformed JSON.';
}

class GatewayServiceException implements Exception {
  GatewayServiceException(this.code, this.endpoint);
  final int code;
  final String endpoint;
  @override
  String toString() => 'Gateway request to $endpoint was rejected ($code).';
}

/// Cookies that make up a gateway session. The device/anonymous identifiers
/// are kept because the QR flow hands the confirmed session back through them:
/// `/login/qr/check` answers 803 with `MUSIC_U` plus whichever of these the
/// server rotated while the phone confirmed, and every later request has to
/// replay that exact set — api-enhanced passes the whole jar through the same
/// way (`cookieToJson` has no whitelist).
const Set<String> _sessionNames = <String>{
  'MUSIC_U',
  'MUSIC_A',
  'NMTID',
  'deviceId',
  'sDeviceId',
  '__csrf',
  // Older responses carry the CSRF value under this alias; api-enhanced's
  // cookie jar keeps it, and weapi requests read it when `__csrf` is missing.
  '__csrf_token',
  '_ntes_nuid',
  '_ntes_nnid',
  'WNMCID',
  'WEVNSM',
};

const Set<String> _cookieAttributeNames = <String>{
  'domain',
  'expires',
  'httponly',
  'max-age',
  'partitioned',
  'path',
  'priority',
  'sameparty',
  'samesite',
  'secure',
};

final RegExp _cookieNamePattern = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");

/// Converts a Cookie header or a flattened Set-Cookie response into a compact
/// Cookie header. Last value wins for a repeated name.
String? normalizeGatewaySessionCookie(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  final Map<String, String> cookies = <String, String>{};
  final input = value
      .trim()
      .replaceFirst(RegExp(r'^﻿'), '')
      .replaceFirst(RegExp(r'^cookie:\s*', caseSensitive: false), '');
  for (final String rawSegment in input.split(';')) {
    String segment = rawSegment.trim();
    if (segment.startsWith('Set-Cookie:')) {
      segment = segment.substring('Set-Cookie:'.length).trim();
    }
    if (segment.startsWith('set-cookie:')) {
      segment = segment.substring('set-cookie:'.length).trim();
    }
    final int separator = segment.indexOf('=');
    if (separator <= 0) continue;
    final String name = segment.substring(0, separator).trim();
    final String cookieValue = segment.substring(separator + 1).trim();
    if (!_cookieNamePattern.hasMatch(name)) continue;
    if (_cookieAttributeNames.contains(name.toLowerCase())) continue;
    if (!_sessionNames.contains(name)) continue;
    if (cookieValue.contains('\r') || cookieValue.contains('\n')) continue;
    cookies[name] = cookieValue;
  }
  if (cookies.isEmpty) return null;
  return cookies.entries
      .map((MapEntry<String, String> e) => '${e.key}=${e.value}')
      .join('; ');
}

const Set<String> _transportOverrides = <String>{
  'cookie',
  'domain',
  'crypto',
  'proxy',
  'headers',
  'realIP',
  'randomCNIP',
  'ua',
  'checkToken',
  'e_r',
};

/// Port of NeteaseTransport.kt: weapi/eapi POST transport, session cookies,
/// and the response envelopes the Kotlin wrapper synthesizes in-process.
class NeteaseTransport {
  NeteaseTransport({
    this.userAgent = 'Lazer',
    this.requestTimeout = const Duration(seconds: 30),
    io.HttpClient? client,
    DateTime Function()? clock,
  }) : _client =
           client ?? (io.HttpClient()..connectionTimeout = requestTimeout),
       _clock = clock ?? DateTime.now;

  final String userAgent;
  final Duration requestTimeout;
  final io.HttpClient _client;
  final DateTime Function() _clock;

  String? cookie;

  Future<Map<String, dynamic>> request(
    String alias,
    Map<String, String> parameters,
  ) async {
    if (!alias.startsWith('/') ||
        alias.startsWith('//') ||
        alias.contains('?') ||
        alias.contains('#') ||
        alias.contains(r'\') ||
        alias.contains(':') ||
        alias.contains('..')) {
      throw ArgumentError.value(
        alias,
        'alias',
        'Supply a supported relative Gateway route.',
      );
    }
    if (parameters.keys.any(_transportOverrides.contains)) {
      throw ArgumentError(
        'Built-in Gateway transport overrides are not supported.',
      );
    }
    if (alias == '/login/qr/create') {
      final String key = parameters['key'] ?? '';
      if (key.trim().isEmpty) throw ArgumentError('key cannot be blank.');
      final String qrUrl = _qrLoginUrl(key, parameters['platform'] ?? 'pc');
      return <String, dynamic>{
        'code': 200,
        'data': <String, dynamic>{'qrurl': qrUrl, 'qrimg': ''},
      };
    }
    if (alias == '/playlist/track/all') return _playlistTracks(parameters);
    final NeteaseRequest route = buildNeteaseRequest(alias, parameters);
    late final _Response result;
    try {
      result = await _execute(route, alias);
    } on GatewayProtocolException {
      // These public weapi endpoints currently sometimes return HTTP 200
      // with an empty body. Their ordinary HTTPS API equivalents carry the
      // same response schema and keep discovery and playback available.
      if (alias == '/song/detail') {
        result = await _executePublicPost(route, alias);
      } else if (const <String>{
        '/top/playlist',
        '/toplist/detail',
        '/song/url/v1',
        '/login/status',
        '/user/playlist',
        '/recommend/songs',
        '/recommend/resource',
        '/personalized/newsong',
        '/personal_fm',
        '/album',
        '/artist/top/song',
        '/simi/artist',
        '/user/detail',
      }.contains(alias)) {
        result = await _executePublicGet(route, alias);
      } else {
        rethrow;
      }
    }
    final Map<String, dynamic> body = result.body;
    switch (alias) {
      case '/login/qr/key':
        // The unikey response seeds the QR session (NMTID/__csrf/sDeviceId).
        // Every later /check poll must carry this cookie or the server treats
        // each poll as a fresh anonymous visitor and never reports 803.
        return <String, dynamic>{
          'code': 200,
          'data': body,
          if (result.cookie != null) 'cookie': result.cookie,
        };
      case '/login/status':
        return <String, dynamic>{'data': body};
      case '/login':
      case '/login/cellphone':
      case '/login/refresh':
        final bool successful = body['code'] == 200;
        if (successful && result.cookie != null) {
          return <String, dynamic>{...body, 'cookie': result.cookie};
        }
        return body;
      case '/login/qr/check':
        // api-enhanced forwards the response cookie on every poll code
        // (801/802 included), not just on 803: the session rotates while the
        // user scans and the next poll has to present the newest cookie.
        if (result.cookie != null) {
          return <String, dynamic>{...body, 'cookie': result.cookie};
        }
        return body;
      case '/captcha/sent/v1':
        // The SMS endpoint issues the anonymous device cookies (NMTID and
        // friends) that api-enhanced's jar keeps; the login half of the flow
        // must replay them so the code belongs to the same visitor.
        if (result.cookie != null) {
          return <String, dynamic>{...body, 'cookie': result.cookie};
        }
        return body;
      case '/check/music':
        final dynamic first =
            body['data'] is List && (body['data'] as List).isNotEmpty
            ? (body['data'] as List).first
            : null;
        final bool available =
            body['code'] == 200 &&
            first is Map<String, dynamic> &&
            first['code'] == 200;
        return <String, dynamic>{
          'code': 200,
          'success': available,
          'message': available ? 'ok' : '暂无版权',
        };
      default:
        if (body['code'] is int && body['code'] != 200) {
          throw GatewayServiceException(body['code'] as int, alias);
        }
        return body;
    }
  }

  Future<Map<String, dynamic>> _playlistTracks(
    Map<String, String> parameters,
  ) async {
    final int offset = int.tryParse(parameters['offset'] ?? '') ?? 0;
    final int limit = int.tryParse(parameters['limit'] ?? '') ?? 1000;
    if (offset < 0 || limit <= 0) throw ArgumentError('Invalid playlist page.');
    final Map<String, dynamic> detail = (await _execute(
      buildNeteaseRequest('/playlist/detail', parameters),
      '/playlist/track/all',
    )).body;
    if (detail['code'] != 200) return detail;
    final dynamic playlist = detail['playlist'];
    final dynamic trackIds = playlist is Map<String, dynamic>
        ? playlist['trackIds']
        : null;
    if (trackIds is! List) {
      throw GatewayProtocolException(
        '/playlist/track/all',
        'Missing track IDs.',
      );
    }
    final List<dynamic> page = trackIds.skip(offset).take(limit).toList();
    if (page.isEmpty) {
      return <String, dynamic>{
        'code': 200,
        'songs': <dynamic>[],
        'privileges': <dynamic>[],
      };
    }
    final List<Map<String, Object?>> payload = page.map<Map<String, Object?>>((
      dynamic track,
    ) {
      final dynamic id = track is Map<String, dynamic> ? track['id'] : null;
      final int? songId = id is int
          ? id
          : (id is String ? int.tryParse(id) : null);
      if (songId == null || songId <= 0) {
        throw ArgumentError('Invalid playlist track ID.');
      }
      return <String, Object?>{'id': songId};
    }).toList();
    final _Response songs = await _execute(
      NeteaseRequest(
        path: '/api/v3/song/detail',
        payload: <String, Object?>{'c': jsonEncode(payload)},
        encoding: NeteaseEncoding.weapi,
      ),
      '/playlist/track/all',
    );
    return songs.body;
  }

  Future<_Response> _execute(NeteaseRequest route, String alias) async {
    final String? currentCookie = cookie;
    final Map<String, String> cookies = <String, String>{};
    for (final String segment in (currentCookie ?? '').split(';')) {
      final int separator = segment.indexOf('=');
      if (separator > 0) {
        cookies[segment.substring(0, separator).trim()] = segment
            .substring(separator + 1)
            .trim();
      }
    }
    // The QR confirmation can hand the CSRF value back under either name;
    // api-enhanced accepts both and so do the upstream weapi endpoints.
    final String csrf = cookies['__csrf'] ?? cookies['__csrf_token'] ?? '';
    final bool plain = route.encoding == NeteaseEncoding.api;
    final bool web = route.encoding == NeteaseEncoding.weapi;
    final Map<String, Object?> payload = <String, Object?>{
      ...route.payload,
      if (!plain) 'e_r': false,
    };
    if (web) {
      payload['csrf_token'] = csrf;
    } else if (!plain) {
      // eapi authenticates the client through its envelope header. The
      // play-record deposit only credits entries from the desktop player, so
      // that route presents the osx identity the official player uses.
      final String os = route.desktopClient
          ? 'osx'
          : route.mobileClient
          ? 'android'
          : 'pc';
      final String appver = route.desktopClient
          ? '3.1.10.5100'
          : route.mobileClient
          ? '9.5.95'
          : '3.1.17.204416';
      payload['header'] = <String, Object?>{
        'os': os,
        'appver': appver,
        'osver': route.desktopClient
            ? '15.5'
            : route.mobileClient
            ? '14'
            : 'Microsoft-Windows-10-Professional-build-19045-64bit',
        'channel': route.mobileClient ? 'xiaomi' : 'netease',
        if (route.mobileClient) 'versioncode': '9005095',
        '__csrf': csrf,
        'requestId':
            '${_clock().millisecondsSinceEpoch}_${gatewayHexLower(_secureRandom(4))}',
        for (final String name in const <String>[
          'MUSIC_U',
          'MUSIC_A',
          'NMTID',
          'deviceId',
        ])
          if (cookies[name] != null) name: cookies[name],
      };
    }
    final Map<String, String> form = web
        ? gatewayWeapi(jsonEncode(payload))
        : plain
        ? <String, String>{
            for (final MapEntry<String, Object?> entry in payload.entries)
              entry.key: '${entry.value}',
          }
        : <String, String>{
            'params': gatewayEapi(route.path, jsonEncode(payload)),
          };
    final String host =
        route.domain ??
        (web || plain
            ? 'https://music.163.com'
            : 'https://interfacepc.music.163.com');
    final String endpoint = web
        ? '$host/weapi/'
        : plain
        ? host
        : '$host/eapi/';
    final String upstreamPath = route.path.startsWith('/api/')
        ? route.path.substring(5)
        : route.path;
    final String requestPath = plain ? route.path : upstreamPath;
    final io.HttpClientRequest request = await _client
        .postUrl(Uri.parse('$endpoint$requestPath'))
        .timeout(requestTimeout);
    request.headers.set(io.HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(
      io.HttpHeaders.userAgentHeader,
      route.desktopClient
          ? _osxUserAgent
          : plain
          ? _desktopUserAgent
          : userAgent,
    );
    request.headers.set('Referer', 'https://music.163.com/');
    request.headers.set(io.HttpHeaders.cacheControlHeader, 'no-cache');
    final String? requestCookie = route.mobileClient
        ? <String>[
            ?currentCookie,
            'os=android',
            'appver=9.5.95',
            'versioncode=9005095',
          ].join('; ')
        : route.desktopClient
        ? <String>[
            ?currentCookie,
            'os=osx',
            'appver=3.1.10.5100',
            'osver=15.5',
            'channel=netease',
          ].join('; ')
        : currentCookie;
    if (requestCookie != null) {
      request.headers.set(io.HttpHeaders.cookieHeader, requestCookie);
    }
    request.headers.contentType = io.ContentType(
      'application',
      'x-www-form-urlencoded',
      charset: 'utf-8',
    );
    request.write(
      form.entries
          .map(
            (MapEntry<String, String> e) =>
                '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
          )
          .join('&'),
    );
    final io.HttpClientResponse response = await request.close().timeout(
      requestTimeout,
    );
    final String bodyText = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw GatewayHttpException(response.statusCode, alias);
    }
    final Map<String, dynamic> normalizedBody;
    try {
      normalizedBody = await decodeGatewayResponse(bodyText);
    } on FormatException {
      throw GatewayProtocolException(alias);
    }
    final dynamic rawCode = normalizedBody['code'];
    final Map<String, dynamic> normalized = rawCode is num
        ? <String, dynamic>{...normalizedBody, 'code': rawCode.toInt()}
        : (rawCode is String && int.tryParse(rawCode) != null
              ? <String, dynamic>{...normalizedBody, 'code': int.parse(rawCode)}
              : normalizedBody);
    final List<String> setCookies = <String>[];
    response.headers.forEach((String name, List<String> values) {
      if (name == 'set-cookie') setCookies.addAll(values);
    });
    final String? mergedCookie = setCookies.isEmpty
        ? null
        : normalizeGatewaySessionCookie(
            <String>[
              ?currentCookie,
              for (final String setCookie in setCookies)
                setCookie.split(';').first,
            ].join('; '),
          );
    return _Response(normalized, mergedCookie);
  }

  Future<_Response> _executePublicGet(
    NeteaseRequest route,
    String alias,
  ) async {
    final Uri uri = Uri.https(
      'music.163.com',
      route.path,
      route.payload.map((key, value) => MapEntry(key, value.toString())),
    );
    final request = await _client.getUrl(uri).timeout(requestTimeout);
    request.headers.set(io.HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(io.HttpHeaders.userAgentHeader, userAgent);
    request.headers.set('Referer', 'https://music.163.com/');
    if (cookie != null) {
      request.headers.set(io.HttpHeaders.cookieHeader, cookie!);
    }
    final response = await request.close().timeout(requestTimeout);
    return _decodePublicResponse(response, alias);
  }

  Future<_Response> _executePublicPost(
    NeteaseRequest route,
    String alias,
  ) async {
    final Uri uri = Uri.https('music.163.com', route.path);
    final request = await _client.postUrl(uri).timeout(requestTimeout);
    request.headers.set(io.HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(io.HttpHeaders.userAgentHeader, userAgent);
    request.headers.set('Referer', 'https://music.163.com/');
    request.headers.contentType = io.ContentType(
      'application',
      'x-www-form-urlencoded',
      charset: 'utf-8',
    );
    if (cookie != null) {
      request.headers.set(io.HttpHeaders.cookieHeader, cookie!);
    }
    request.write(
      route.payload.entries
          .map(
            (entry) =>
                '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value.toString())}',
          )
          .join('&'),
    );
    final response = await request.close().timeout(requestTimeout);
    return _decodePublicResponse(response, alias);
  }

  Future<_Response> _decodePublicResponse(
    io.HttpClientResponse response,
    String alias,
  ) async {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw GatewayHttpException(response.statusCode, alias);
    }
    final bodyText = await response.transform(utf8.decoder).join();
    try {
      return _Response(await decodeGatewayResponse(bodyText), null);
    } on FormatException {
      throw GatewayProtocolException(alias);
    }
  }

  static List<int> _secureRandom(int size) {
    return List<int>.generate(size, (_) => _rng.nextInt(256));
  }

  /// Scan URL for the QR login, matching the official desktop client
  /// (`page:loginQrcode`): `https://music.163.com/login?codekey=<unikey>`.
  ///
  /// That client also reads a `chainId` for its login monitor, but only ever
  /// generates it on the platform layer from a real device id — a fabricated
  /// value names no session, so it is never invented here. A `web` platform
  /// request may append one when the session actually carries `sDeviceId`.
  String _qrLoginUrl(String key, String platform) {
    final String base =
        'https://music.163.com/login?codekey=${Uri.encodeQueryComponent(key)}';
    if (platform != 'web') return base;
    final String deviceId = _cookieValue(cookie, 'sDeviceId');
    if (deviceId.isEmpty) return base;
    final String chainId =
        'v1_${deviceId}_web_login_${_clock().millisecondsSinceEpoch}';
    return '$base&chainId=${Uri.encodeQueryComponent(chainId)}';
  }

  /// Reads a single cookie value out of a `Cookie` header, or ''.
  static String _cookieValue(String? header, String name) {
    for (final String segment in (header ?? '').split(';')) {
      final int separator = segment.indexOf('=');
      if (separator <= 0) continue;
      if (segment.substring(0, separator).trim() == name) {
        return segment.substring(separator + 1).trim();
      }
    }
    return '';
  }

  static final math.Random _rng = math.Random.secure();

  /// User agent of the desktop client, used for the plain `api` surface the
  /// QR sign-in endpoints live on.
  static const String _desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like '
      'Gecko) Safari/537.36 Chrome/91.0.4472.164 NeteaseMusicDesktop/3.1.29.205117';

  /// The macOS player identity that the client-log deposit expects; its
  /// headers mirror a Chrome build of the desktop player.
  static const String _osxUserAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
}

class _Response {
  const _Response(this.body, this.cookie);

  final Map<String, dynamic> body;
  final String? cookie;
}
