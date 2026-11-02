import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// The HTTP proxy the operating system routes traffic through.
///
/// Dart only honours the `*_PROXY` environment variables, and a launcher never
/// hands those to a desktop build: on Windows the setting lives in the
/// registry, where the system-wide client picks it up. External chart hosts sit
/// behind Cloudflare and are routinely unreachable at usable speed without that
/// hop, so the value is resolved once and reused for every later request.
class SystemHttpProxy {
  const SystemHttpProxy({
    required this.host,
    required this.port,
    this.socks = false,
  });

  final String host;
  final int port;
  final bool socks;

  static SystemHttpProxy? _current;
  static DateTime? _checkedAt;

  /// Re-checked once a minute so starting the proxy after the app still works.
  static const Duration _retryAfter = Duration(minutes: 1);

  /// Resolves the proxy the machine is configured to use; `null` means direct.
  static Future<SystemHttpProxy?> resolve() async {
    final SystemHttpProxy? current = _current;
    if (current != null) return current;
    final DateTime? checkedAt = _checkedAt;
    if (checkedAt != null &&
        DateTime.now().difference(checkedAt) < _retryAfter) {
      return null;
    }
    _checkedAt = DateTime.now();
    _current = _fromEnvironment() ?? await _fromWindowsRegistry();
    return _current;
  }

  /// The value [HttpClient.findProxy] expects.
  String get rules => socks ? 'SOCKS $host:$port' : 'PROXY $host:$port';

  @override
  String toString() => rules;

  static SystemHttpProxy? _fromEnvironment() {
    for (final String key in const <String>[
      'HTTPS_PROXY',
      'https_proxy',
      'ALL_PROXY',
      'all_proxy',
      'HTTP_PROXY',
      'http_proxy',
    ]) {
      final String? value = Platform.environment[key];
      if (value == null || value.trim().isEmpty) continue;
      final SystemHttpProxy? parsed = parse(value);
      if (parsed != null) return parsed;
    }
    return null;
  }

  static Future<SystemHttpProxy?> _fromWindowsRegistry() async {
    if (!Platform.isWindows) return null;
    try {
      final ProcessResult result = await Process.run('reg', <String>[
        'query',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
      ]).timeout(const Duration(seconds: 3));
      if (result.exitCode != 0) return null;
      final String output = '${result.stdout}';
      if (!RegExp(r'ProxyEnable\s+REG_DWORD\s+0x1\b').hasMatch(output)) {
        return null;
      }
      final RegExpMatch? match = RegExp(
        r'ProxyServer\s+REG_SZ\s+(\S+)',
      ).firstMatch(output);
      final String? value = match?.group(1);
      return value == null ? null : parse(value);
    } catch (_) {
      // A missing or unusable registry value only means direct access.
      return null;
    }
  }

  /// Accepts `host:port`, `http://host:port`, `socks5://host:port`, the
  /// `http=host:port;https=host:port` form the registry uses, and a leading
  /// `user:password@`.
  static SystemHttpProxy? parse(String raw) {
    String value = raw.trim();
    if (value.isEmpty) return null;
    if (value.contains('=')) {
      final Map<String, String> entries = <String, String>{};
      for (final String part in value.split(';')) {
        final int at = part.indexOf('=');
        if (at <= 0) continue;
        entries[part.substring(0, at).trim().toLowerCase()] = part
            .substring(at + 1)
            .trim();
      }
      final String? chosen =
          entries['https'] ??
          entries['http'] ??
          (entries.isEmpty ? null : entries.values.first);
      if (chosen == null || chosen.isEmpty) return null;
      value = chosen;
    }
    bool socks = false;
    final int schemeEnd = value.indexOf('://');
    if (schemeEnd > 0) {
      final String scheme = value.substring(0, schemeEnd).toLowerCase();
      if (scheme.startsWith('socks')) {
        socks = true;
      } else if (scheme != 'http' && scheme != 'https') {
        return null;
      }
      value = value.substring(schemeEnd + 3);
    }
    final int credentials = value.lastIndexOf('@');
    if (credentials >= 0) value = value.substring(credentials + 1);
    value = value.split('/').first;
    final int colon = value.lastIndexOf(':');
    if (colon <= 0) return null;
    final String host = value.substring(0, colon).trim();
    final int? port = int.tryParse(value.substring(colon + 1).trim());
    if (host.isEmpty || port == null || port <= 0 || port > 65535) return null;
    return SystemHttpProxy(host: host, port: port, socks: socks);
  }
}

/// Opens a client for a host outside China.
///
/// Keep it for a whole logical load: one client reuses the TCP connection and
/// its TLS handshake across the handful of requests a chart needs, which is
/// most of the wall time when the round trip is slow.
http.Client openExternalClient({
  Duration connectionTimeout = const Duration(seconds: 8),
  SystemHttpProxy? proxy,
}) {
  final HttpClient inner = HttpClient()
    ..connectionTimeout = connectionTimeout
    ..idleTimeout = const Duration(seconds: 20);
  if (proxy != null) inner.findProxy = (Uri uri) => proxy.rules;
  return IOClient(inner);
}
