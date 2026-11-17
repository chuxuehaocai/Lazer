// i18n:data — manifest validation messages are interface keys shown by the
// plugin UI through `context.tr`.
import 'dart:convert';

/// The portable, versioned contract shipped at the root of a plugin ZIP.
class PluginManifest {
  PluginManifest.fromJson(Map<String, dynamic> json)
    : id = json['id'] as String? ?? '',
      name = json['name'] as String? ?? '',
      version = json['version'] as String? ?? '',
      description = json['description'] as String? ?? '',
      author = json['author'] as String? ?? '',
      entry = json['entry'] as String? ?? 'main.lua',
      apiVersion = (json['apiVersion'] as num?)?.toInt() ?? 0,
      provider = json['provider'] as String? ?? '',
      capabilities = List<String>.from(json['capabilities'] as List? ?? []),
      auth = List<String>.from(json['auth'] as List? ?? []),
      domains = List<String>.from(
        (json['permissions'] as Map?)?['network'] as List? ?? [],
      ),
      socketDomains = List<String>.from(
        (json['permissions'] as Map?)?['socket'] as List? ?? [],
      ),
      socketServerBindings = List<String>.from(
        (json['permissions'] as Map?)?['socketServer'] as List? ?? [],
      ),
      websocketDomains = List<String>.from(
        (json['permissions'] as Map?)?['websocket'] as List? ?? [],
      ),
      websocketServerBindings = List<String>.from(
        (json['permissions'] as Map?)?['websocketServer'] as List? ?? [],
      ),
      storage = (json['permissions'] as Map?)?['storage'] == true,
      filesystem =
          (json['permissions'] as Map?)?['filesystem'] == true ||
          (json['permissions'] as Map?)?['files'] == true ||
          (json['permissions'] as Map?)?['file'] == true {
    if (!RegExp(r'^[a-z][a-z0-9_.-]{2,79}$').hasMatch(id) ||
        !RegExp(r'^[a-z][a-z0-9_-]{1,39}$').hasMatch(provider) ||
        provider == 'local' ||
        name.trim().isEmpty ||
        name.length > 100 ||
        !RegExp(r'^\d+\.\d+\.\d+(?:-[a-zA-Z0-9.-]+)?$').hasMatch(version) ||
        apiVersion != 1 ||
        !safePath(entry) ||
        !entry.endsWith('.lua') ||
        domains.length > 32 ||
        socketDomains.length > 32 ||
        websocketDomains.length > 32 ||
        socketServerBindings.length > 16 ||
        socketServerBindings.any(
          (binding) => _serverBinding(binding) == null,
        ) ||
        websocketServerBindings.length > 16 ||
        websocketServerBindings.any(
          (binding) => _serverBinding(binding) == null,
        ) ||
        domains.any(invalidNetworkRule) ||
        socketDomains.any(invalidNetworkRule) ||
        websocketDomains.any(invalidNetworkRule)) {
      throw const FormatException('插件清单无效，或不支持该插件 API 版本。');
    }
  }

  /// Whether a declared network rule would grant more than the plugin asked for.
  ///
  /// A wildcard such as `*.com` (or `*.co.uk`) would authorise every host under
  /// a public suffix, which is not a permission a plugin can meaningfully list.
  /// A wildcard must name a registrable domain, not a suffix.
  static bool invalidNetworkRule(String domain) {
    if (!RegExp(
      r'^(\*\.)?[a-zA-Z0-9][a-zA-Z0-9.-]*(?::\d{1,5})?$',
    ).hasMatch(domain)) {
      return true;
    }
    final port = RegExp(r':(\d+)$').firstMatch(domain);
    if (port != null && int.parse(port.group(1)!) > 65535) return true;
    if (!domain.startsWith('*.')) return false;
    final host = domain.substring(2).split(':').first.toLowerCase();
    final labels = host.split('.').where((label) => label.isNotEmpty).toList();
    if (labels.length < 2) return true;
    return labels.length == 2 && _publicSuffixes.contains(host);
  }

  /// Two-label suffixes that are registries rather than registrable domains.
  ///
  /// This is not the public-suffix list; it is the short list a plugin is
  /// realistically tempted to write as a wildcard. Anything longer must name
  /// its own label (`*.example.co.uk`), which is a real scope.
  static const Set<String> _publicSuffixes = <String>{
    'co.uk',
    'org.uk',
    'ac.uk',
    'gov.uk',
    'co.jp',
    'ne.jp',
    'or.jp',
    'com.au',
    'net.au',
    'org.au',
    'com.cn',
    'net.cn',
    'org.cn',
    'com.tw',
    'co.kr',
    'co.in',
    'co.nz',
    'co.za',
    'com.br',
    'com.mx',
    'com.tr',
  };

  factory PluginManifest.decode(String value) =>
      PluginManifest.fromJson(jsonDecode(value) as Map<String, dynamic>);

  final String id, name, version, description, author, entry, provider;
  final int apiVersion;
  final List<String> capabilities,
      auth,
      domains,
      socketDomains,
      websocketDomains;
  final List<String> socketServerBindings, websocketServerBindings;
  final bool storage, filesystem;

  static bool safePath(String path) =>
      path.isNotEmpty &&
      path.length <= 200 &&
      !path.contains('\\') &&
      !path.contains(':') &&
      !path.startsWith('/') &&
      path
          .split('/')
          .every(
            (p) =>
                p.isNotEmpty &&
                p != '.' &&
                p != '..' &&
                !p.endsWith('.') &&
                !p.endsWith(' ') &&
                !RegExp(r'[\x00-\x1f<>"|?*]').hasMatch(p),
          );

  bool permits(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      domains.any((domain) {
        final rule = Uri.parse('https://${domain.replaceFirst('*.', '')}');
        if (uri.port != rule.port) return false;
        return domain.startsWith('*.')
            ? uri.host == rule.host || uri.host.endsWith('.${rule.host}')
            : uri.host == rule.host;
      });

  bool permitsWebSocket(Uri uri) =>
      (uri.scheme == 'ws' || uri.scheme == 'wss') &&
      uri.userInfo.isEmpty &&
      websocketDomains.any((domain) {
        final rule = Uri.parse('https://${domain.replaceFirst('*.', '')}');
        if (rule.hasPort && uri.port != rule.port) return false;
        return domain.startsWith('*.')
            ? uri.host == rule.host || uri.host.endsWith('.${rule.host}')
            : uri.host == rule.host;
      });

  bool permitsSocket(String host, int port) {
    if (port < 0 || port > 65535) return false;
    final checkDomains = socketDomains.isNotEmpty ? socketDomains : domains;
    return checkDomains.any((domain) {
      final rule = Uri.parse('https://${domain.replaceFirst('*.', '')}');
      if (rule.hasPort && port != rule.port) return false;
      return domain.startsWith('*.')
          ? host == rule.host || host.endsWith('.${rule.host}')
          : host == rule.host;
    });
  }

  static ({String host, int port})? _serverBinding(String binding) {
    // Parse the declared port ourselves: Uri normalizes explicit :0 away for
    // ws, and a port of zero deliberately requests an ephemeral listener.
    final match = RegExp(
      r'^(\[[0-9a-fA-F:]+\]|localhost|\d+(?:\.\d+){3}):(\d{1,5})$',
      caseSensitive: false,
    ).firstMatch(binding);
    if (match == null) return null;
    final port = int.parse(match.group(2)!);
    if (port > 65535) return null;
    try {
      final host = Uri.parse('http://${match.group(1)}').host;
      final parts = host.split('.');
      if (!host.contains(':') &&
          host != 'localhost' &&
          (parts.length != 4 || parts.any((part) => int.parse(part) > 255))) {
        return null;
      }
      return (host: host, port: port);
    } on FormatException {
      return null;
    }
  }

  bool permitsSocketServer(String host, int port) {
    if (port < 0 || port > 65535) return false;
    final binding = _serverBinding(
      '${host.contains(':') ? '[$host]' : host}:$port',
    );
    if (binding == null) return false;
    final checkBindings = socketServerBindings.isNotEmpty
        ? socketServerBindings
        : websocketServerBindings;
    return checkBindings.any((rule) {
      final allowed = _serverBinding(rule)!;
      return allowed.host == binding.host &&
          (allowed.port == 0 || allowed.port == port);
    });
  }

  bool permitsWebSocketServer(String host, int port) {
    if (port < 0 || port > 65535) return false;
    final binding = _serverBinding(
      '${host.contains(':') ? '[$host]' : host}:$port',
    );
    if (binding == null) return false;
    return websocketServerBindings.any((rule) {
      final allowed = _serverBinding(rule)!;
      return allowed.host == binding.host && allowed.port == port;
    });
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'version': version,
    'description': description,
    'author': author,
    'entry': entry,
    'apiVersion': apiVersion,
    'provider': provider,
    'capabilities': capabilities,
    'auth': auth,
    'permissions': {
      'network': domains,
      'socket': socketDomains,
      'socketServer': socketServerBindings,
      'websocket': websocketDomains,
      'websocketServer': websocketServerBindings,
      'storage': storage,
      'filesystem': filesystem,
    },
  };
}

class PluginException implements Exception {
  const PluginException(this.message, {this.code});

  /// Marks a call abandoned because the plugin VM did not answer in time.
  ///
  /// The runtime restarts the VM after it; the operation itself never reached a
  /// result, so a caller may repeat it once against the fresh VM.
  static const int timeoutCode = 408;

  final String message;
  final int? code;
  @override
  String toString() => code == null ? message : '$message ($code)';
}
