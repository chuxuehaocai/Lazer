import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'music_gateway.dart';

/// Canonical server root, including a reverse proxy's path prefix.
Uri navidromeServerUri(String value, {bool allowInsecureHttp = false}) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      (uri.scheme != 'https' && uri.scheme != 'http') ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.pathSegments.any((part) => part == '.' || part == '..')) {
    throw ArgumentError(
      'Supply an HTTP(S) server URL without credentials, query or fragment.',
    );
  }
  if (uri.scheme == 'http' && !allowInsecureHttp) {
    throw ArgumentError('HTTP requires explicit allowInsecureHttp consent.');
  }
  var path = uri.path.replaceAll(RegExp(r'/+$'), '');
  if (path.endsWith('/rest')) path = path.substring(0, path.length - 5);
  return uri.replace(path: '$path/');
}

/// A replayable Subsonic credential, NOT a non-sensitive preference.
/// Store only in an OS credential vault if persistence is desired.
class NavidromeSession {
  const NavidromeSession._({
    required this.server,
    required this.username,
    required this.token,
    required this.salt,
  });

  final Uri server;
  final String username;
  final String token;
  final String salt;

  factory NavidromeSession.fromPassword({
    required Uri server,
    required String username,
    required String password,
  }) {
    if (username.trim().isEmpty || password.isEmpty) {
      throw ArgumentError('Username and password are required.');
    }
    final random = Random.secure();
    final salt = List.generate(
      16,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return NavidromeSession._(
      server: server,
      username: username.trim(),
      salt: salt,
      token: md5.convert(utf8.encode('$password$salt')).toString(),
    );
  }

  factory NavidromeSession.fromJson(
    Map<String, dynamic> json, {
    bool allowInsecureHttp = false,
  }) {
    final username = json['username'];
    final token = json['token'];
    final salt = json['salt'];
    if (username is! String ||
        username.trim().isEmpty ||
        token is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(token) ||
        salt is! String ||
        salt.length < 6 ||
        salt.length > 256 ||
        json['server'] is! String) {
      throw const FormatException('Invalid Navidrome session.');
    }
    return NavidromeSession._(
      server: navidromeServerUri(
        json['server'] as String,
        allowInsecureHttp: allowInsecureHttp,
      ),
      username: username.trim(),
      token: token,
      salt: salt,
    );
  }

  Map<String, dynamic> toJson() => {
    'server': server.toString(),
    'username': username,
    'token': token,
    'salt': salt,
  };

  Map<String, String> get _authentication => {
    'u': username,
    't': token,
    's': salt,
    'v': '1.16.1',
    'c': 'lazer',
    'f': 'json',
  };

  @override
  String toString() => 'NavidromeSession(<redacted>)';
}

class NavidromeTransport {
  NavidromeTransport({
    required this.server,
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client();

  final Uri server;
  final http.Client _client;
  final Duration timeout;
  bool _closed = false;
  static const _maxResponseBytes = 16 * 1024 * 1024;

  Uri _endpoint(String method) {
    if (_closed) throw StateError('Navidrome connection is closed.');
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9]*$').hasMatch(method)) {
      throw ArgumentError('Invalid Subsonic endpoint.');
    }
    return server.resolve('rest/$method.view');
  }

  Map<String, dynamic> _parameters(
    NavidromeSession session,
    Map<String, dynamic> parameters,
  ) {
    if (session.server != server) {
      throw ArgumentError('Session belongs to another server.');
    }
    if (parameters.keys.any(session._authentication.containsKey) ||
        parameters.containsKey('p')) {
      throw ArgumentError('Authentication parameters cannot be overridden.');
    }
    return {...parameters, ...session._authentication};
  }

  /// Only media URLs contain tokens; API requests carry them in the POST body.
  Uri mediaUri(
    String method,
    NavidromeSession session,
    Map<String, dynamic> parameters,
  ) {
    if (method != 'stream' && method != 'getCoverArt' && method != 'download') {
      throw ArgumentError('Not a media endpoint.');
    }
    return _endpoint(
      method,
    ).replace(queryParameters: _parameters(session, parameters));
  }

  Future<Map<String, dynamic>> request(
    String method,
    NavidromeSession session, [
    Map<String, dynamic> parameters = const {},
  ]) async {
    final request = http.Request('POST', _endpoint(method))
      ..followRedirects = false
      ..headers['Content-Type'] =
          'application/x-www-form-urlencoded; charset=utf-8'
      ..headers['Accept'] = 'application/json'
      ..body = Uri(queryParameters: _parameters(session, parameters)).query;
    try {
      return await _send(method, request).timeout(timeout);
    } on MusicGatewayException {
      rethrow;
    } on TimeoutException {
      throw MusicGatewayException(
        'navidrome',
        method,
        reason: 'Request timed out',
      );
    } catch (_) {
      // http exceptions often include the URL. Do not let signed data reach logs.
      throw MusicGatewayException(
        'navidrome',
        method,
        reason: 'Connection or response failure',
      );
    }
  }

  Future<Map<String, dynamic>> _send(
    String method,
    http.Request request,
  ) async {
    final response = await _client.send(request);
    if (response.statusCode != 200) {
      await response.stream.listen(null).cancel();
      throw MusicGatewayException(
        'navidrome',
        method,
        httpStatus: response.statusCode,
      );
    }
    if ((response.contentLength ?? 0) > _maxResponseBytes) {
      await response.stream.listen(null).cancel();
      throw MusicGatewayException(
        'navidrome',
        method,
        reason: 'Response too large',
      );
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(timeout)) {
      if (bytes.length + chunk.length > _maxResponseBytes) {
        throw MusicGatewayException(
          'navidrome',
          method,
          reason: 'Response too large',
        );
      }
      bytes.add(chunk);
    }
    final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
    final body = decoded is Map<String, dynamic>
        ? decoded['subsonic-response']
        : null;
    if (body is! Map<String, dynamic> ||
        (body['status'] != 'ok' && body['status'] != 'failed')) {
      throw MusicGatewayException(
        'navidrome',
        method,
        reason: 'Invalid Subsonic response',
      );
    }
    if (body['status'] == 'failed') {
      final error = body['error'];
      final code = error is Map ? error['code'] : null;
      throw MusicGatewayException(
        'navidrome',
        method,
        code: code is num ? code.toInt() : null,
      );
    }
    return body;
  }

  void close() {
    _closed = true;
    _client.close();
  }
}
