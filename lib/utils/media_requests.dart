/// Declarative request hints supplied by the owning Lua platform.
/// The client has no knowledge of a provider's hosts or resize conventions.
class MediaRequestRules {
  static final Map<String, List<Map<String, dynamic>>> _owners = {};
  static final Map<String, Map<String, String>> _streams = {};

  static void register(String owner, List<Map<String, dynamic>> rules) {
    _owners[owner] = rules;
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
