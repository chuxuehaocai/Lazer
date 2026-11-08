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
      storage = (json['permissions'] as Map?)?['storage'] == true {
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
        domains.any(
          (d) => !RegExp(
            r'^(\*\.)?[a-zA-Z0-9][a-zA-Z0-9.-]*(?::\d{1,5})?$',
          ).hasMatch(d),
        )) {
      throw const FormatException('插件清单无效，或不支持该插件 API 版本。');
    }
  }

  factory PluginManifest.decode(String value) =>
      PluginManifest.fromJson(jsonDecode(value) as Map<String, dynamic>);

  final String id, name, version, description, author, entry, provider;
  final int apiVersion;
  final List<String> capabilities, auth, domains;
  final bool storage;

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
    'permissions': {'network': domains, 'storage': storage},
  };
}

class PluginException implements Exception {
  const PluginException(this.message, {this.code});
  final String message;
  final int? code;
  @override
  String toString() => code == null ? message : '$message ($code)';
}
