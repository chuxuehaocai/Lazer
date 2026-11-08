/// Declarative request hints supplied by the owning Lua platform.
/// The client has no knowledge of a provider's hosts or resize conventions.
class MediaRequestRules {
  static final Map<String, List<Map<String, dynamic>>> _owners = {};
  static final Map<String, Map<String, String>> _streams = {};

  /// Headers a plugin may never inject into a request.
  ///
  /// Request hints exist to carry a CDN's required `Referer`/`Origin` or a
  /// vendor header — not credentials. A hint that carried `Cookie` could leak
  /// one provider's session to another host, and `Host`/`Content-Length` would
  /// describe the request the client actually makes.
  static const Set<String> _forbiddenHeaders = <String>{
    'cookie',
    'authorization',
    'proxy-authorization',
    'host',
    'content-length',
    'connection',
    'transfer-encoding',
  };

  /// Registers [owner]'s rules, keeping only hints for hosts it may access.
  ///
  /// When [permittedDomains] is supplied (the plugin manifest's network
  /// permission list, which may be empty) a rule only applies to a host in that
  /// scope. Previously a plugin could register a rule for any host — including
  /// `*.com` — and rewrite every other provider's artwork to a fallback host.
  /// Callers that are not plugins (tests, the app's own hints) omit the list and
  /// keep the historical behaviour.
  static void register(
    String owner,
    List<Map<String, dynamic>> rules, {
    List<String>? permittedDomains,
  }) {
    final bool enforceScope = permittedDomains != null;
    final List<String> scope = permittedDomains ?? const <String>[];
    bool allowed(String host) => !enforceScope || _permitted(host, scope);
    final List<Map<String, dynamic>> accepted = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> rule in rules) {
      final String? host = _validHost(rule['host']);
      if (host == null || !allowed(host)) continue;
      final Map<String, dynamic> sanitized = <String, dynamic>{'host': host};
      final Object? resize = rule['artworkResize'];
      if (resize is Map &&
          resize['parameter'] is String &&
          resize['value'] is String) {
        sanitized['artworkResize'] = <String, dynamic>{
          'parameter': resize['parameter'],
          'value': resize['value'],
        };
      }
      final Object? headers = rule['headers'];
      if (headers is Map) {
        final Map<String, String> safe = <String, String>{};
        for (final MapEntry<Object?, Object?> entry in headers.entries) {
          final String? name = entry.key?.toString().toLowerCase();
          if (name == null ||
              name.isEmpty ||
              _forbiddenHeaders.contains(name) ||
              entry.value is! String) {
            continue;
          }
          safe[name] = entry.value! as String;
        }
        if (safe.isNotEmpty) sanitized['headers'] = safe;
      }
      final Object? fallbackHosts = rule['fallbackHosts'];
      if (fallbackHosts is List) {
        final List<String> safeFallbacks = <String>[
          for (final Object? fallback in fallbackHosts)
            if (_validHost(fallback) case final String host when allowed(host))
              host,
        ];
        if (safeFallbacks.isNotEmpty) {
          sanitized['fallbackHosts'] = safeFallbacks;
        }
      }
      accepted.add(sanitized);
    }
    _owners[owner] = accepted;
  }

  static String? _validHost(Object? value) {
    if (value is! String) return null;
    final String host = value.trim();
    if (host.isEmpty || host.length > 253) return null;
    if (!RegExp(
      r'^(\*\.)?[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?)*$',
    ).hasMatch(host)) {
      return null;
    }
    if (host.startsWith('*.')) {
      final List<String> labels = host
          .substring(2)
          .split('.')
          .where((String label) => label.isNotEmpty)
          .toList();
      // Same public-suffix rule as the manifest: `*.com` is not a host scope.
      if (labels.length < 2) return null;
    }
    return host;
  }

  static bool _permitted(String host, List<String> domains) {
    final String bare = host.startsWith('*.') ? host.substring(2) : host;
    for (final String domain in domains) {
      final String scope = domain.startsWith('*.')
          ? domain.substring(2)
          : domain;
      if (bare == scope) return true;
      if (host.startsWith('*.') || domain.startsWith('*.')) {
        if (bare.endsWith('.$scope')) return true;
      }
    }
    return false;
  }

  static void remove(String owner) => _owners.remove(owner);
  static void rememberStream(String url, Map<String, String> headers) {
    _streams.remove(url);
    _streams[url] = Map.unmodifiable(headers);
    while (_streams.length > 128) {
      _streams.remove(_streams.keys.first);
    }
  }

  static Map<String, dynamic>? rule(Uri uri) {
    for (final rules in _owners.values) {
      for (final rule in rules) {
        final host = rule['host'];
        if (host is! String) continue;
        if (uri.host == host ||
            host.startsWith('*.') &&
                (uri.host == host.substring(2) ||
                    uri.host.endsWith(host.substring(1)))) {
          return rule;
        }
      }
    }
    return null;
  }

  static Map<String, String> headers(String url) => {
    'User-Agent': 'Lazer/2.0',
    ...Map<String, String>.from(
      rule(Uri.parse(url))?['headers'] as Map? ?? const {},
    ),
    ...?_streams[url],
  };
}
