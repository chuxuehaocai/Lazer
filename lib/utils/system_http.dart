import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Supported routing modes for external HTTP traffic.
enum ProxyMode {
  /// Always connect directly without any proxy.
  direct,

  /// Follow the operating system proxy settings (registry on Windows, env elsewhere).
  system,

  /// Route through a user-specified HTTP or SOCKS proxy endpoint.
  custom,
}

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

  static const String defaultEndpoint = 'http://127.0.0.1:7890';
  static const ProxyMode defaultMode = ProxyMode.system;
  static const String prefKeyMode = 'network_proxy_mode';
  static const String prefKeyEndpoint = 'network_proxy_endpoint';

  static ProxyMode _currentMode = defaultMode;
  static String? _customEndpoint;
  static SystemHttpProxy? _current;
  static DateTime? _checkedAt;

  /// Re-checked once a minute so starting the proxy after the app still works.
  static const Duration _retryAfter = Duration(minutes: 1);

  /// Current proxy routing mode.
  static ProxyMode get currentMode => _currentMode;

  /// Cached system proxy rules string if already resolved, e.g. `PROXY 127.0.0.1:7890`.
  static String? get cachedSystemRules => _current?.rules;

  /// Current user-configured proxy endpoint.
  static String get customEndpoint =>
      (_customEndpoint != null && _customEndpoint!.trim().isNotEmpty)
          ? _customEndpoint!
          : defaultEndpoint;

  /// Configure or update the active proxy mode and optional endpoint.
  static void setMode(
    ProxyMode mode, {
    String? endpoint,
    String? initialSystemRules,
  }) {
    _currentMode = mode;
    if (endpoint != null) {
      final trimmed = endpoint.trim();
      _customEndpoint = trimmed.isEmpty ? defaultEndpoint : trimmed;
    }
    if (initialSystemRules != null && initialSystemRules.trim().isNotEmpty) {
      _current = parse(initialSystemRules);
    } else {
      _current = null;
    }
    _checkedAt = null;
    if (mode == ProxyMode.system) {
      unawaited(resolve());
    }
  }

  /// Initialize proxy mode and settings from SharedPreferences.
  static void initFromPreferences(SharedPreferences prefs) {
    final String? modeStr = prefs.getString(prefKeyMode);
    final String? endpoint = prefs.getString(prefKeyEndpoint);
    final ProxyMode mode = modeStr != null
        ? ProxyMode.values.firstWhere(
            (m) => m.name == modeStr,
            orElse: () => defaultMode,
          )
        : defaultMode;
    setMode(mode, endpoint: endpoint ?? defaultEndpoint);
  }

  /// Find-proxy callback suitable for [HttpClient.findProxy].
  static String currentFindProxyRule(Uri uri) {
    switch (_currentMode) {
      case ProxyMode.direct:
        return 'DIRECT';
      case ProxyMode.custom:
        final SystemHttpProxy? p = parse(customEndpoint);
        return p?.rules ?? 'DIRECT';
      case ProxyMode.system:
        final SystemHttpProxy? current = _current;
        return current?.rules ?? 'DIRECT';
    }
  }

  /// Resolves the proxy the machine is configured to use; `null` means direct.
  static Future<SystemHttpProxy?> resolve() async {
    switch (_currentMode) {
      case ProxyMode.direct:
        return null;
      case ProxyMode.custom:
        return parse(customEndpoint);
      case ProxyMode.system:
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
    bool socks = false;
    final String upper = value.toUpperCase();
    if (upper.startsWith('PROXY ')) {
      value = value.substring(6).trim();
    } else if (upper.startsWith('SOCKS ') || upper.startsWith('SOCKS5 ')) {
      socks = true;
      value = value.substring(value.indexOf(' ') + 1).trim();
    } else if (upper == 'DIRECT') {
      return null;
    }
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
