// i18n:data — interface strings declared here are translated at their render sites.
import 'dart:convert';
import 'dart:math';

import 'remote_source.dart';

/// One configured network source: where it is, how to reach it and how its
/// interface should present it. The secret is not part of the model; it lives
/// in [NetworkCredentialsVault] under [id].
class NetworkSource {
  const NetworkSource({
    required this.id,
    required this.kind,
    required this.name,
    required this.host,
    required this.port,
    this.secure = false,
    this.path = '/',
    this.username = '',
    this.domain = '',
    this.allowSelfSignedCertificate = false,
    this.hostKey,
    this.addedAt,
    this.lastCheckedAt,
    this.lastError,
  });

  final String id;
  final NetworkSourceKind kind;

  /// Listener-visible name; falls back to `协议 · 主机` when empty.
  final String name;
  final String host;
  final int port;
  final bool secure;

  /// WebDAV/FTP/SFTP base directory, or `share/folder` for SMB.
  final String path;
  final String username;
  final String domain;
  final bool allowSelfSignedCertificate;

  /// SFTP host key accepted on the first connection.
  final String? hostKey;
  final DateTime? addedAt;
  final DateTime? lastCheckedAt;

  /// The last connection failure, kept so the source row can explain itself
  /// after a restart.
  final String? lastError;

  String get displayName {
    final String trimmed = name.trim();
    if (trimmed.isNotEmpty) return trimmed;
    return '${networkSourceKindLabel(kind)} · ${host.isEmpty ? '未设置地址' : host}';
  }

  /// `host:port`, or just the host when the port is the protocol's default.
  String get address {
    if (kind == NetworkSourceKind.smb) return host;
    final int defaultPort = secure
        ? networkSourceDefaultSecurePort(kind)
        : networkSourceDefaultPort(kind);
    return port == defaultPort || port <= 0 ? host : '$host:$port';
  }

  /// Where the source opens in the browser.
  String get rootPath => switch (kind) {
    NetworkSourceKind.smb => smbSplitShare(path).$2,
    _ => remoteNormalize(path),
  };

  /// A one-line `root/sub` label for the row subtitle.
  String get locationLabel {
    switch (kind) {
      case NetworkSourceKind.smb:
        final (String share, String folder) = smbSplitShare(path);
        if (share.isEmpty) return '未选择共享';
        return folder == '/' ? share : '$share$folder';
      default:
        return remoteNormalize(path);
    }
  }

  NetworkSource copyWith({
    String? name,
    String? host,
    int? port,
    bool? secure,
    String? path,
    String? username,
    String? domain,
    bool? allowSelfSignedCertificate,
    String? hostKey,
    bool clearHostKey = false,
    DateTime? addedAt,
    DateTime? lastCheckedAt,
    String? lastError,
    bool clearLastError = false,
  }) => NetworkSource(
    id: id,
    kind: kind,
    name: name ?? this.name,
    host: host ?? this.host,
    port: port ?? this.port,
    secure: secure ?? this.secure,
    path: path ?? this.path,
    username: username ?? this.username,
    domain: domain ?? this.domain,
    allowSelfSignedCertificate:
        allowSelfSignedCertificate ?? this.allowSelfSignedCertificate,
    hostKey: clearHostKey ? null : (hostKey ?? this.hostKey),
    addedAt: addedAt ?? this.addedAt,
    lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
    lastError: clearLastError ? null : (lastError ?? this.lastError),
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'kind': kind.name,
    'name': name,
    'host': host,
    'port': port,
    'secure': secure,
    'path': path,
    'username': username,
    'domain': domain,
    'allowSelfSignedCertificate': allowSelfSignedCertificate,
    'hostKey': hostKey,
    'addedAt': addedAt?.millisecondsSinceEpoch,
    'lastCheckedAt': lastCheckedAt?.millisecondsSinceEpoch,
    'lastError': lastError,
  };

  factory NetworkSource.fromJson(Map<String, Object?> json) {
    final NetworkSourceKind kind = decodeNetworkSourceKind(json['kind'] as String?);
    final int port = (json['port'] as num?)?.toInt() ?? 0;
    return NetworkSource(
      id: json['id'] as String? ?? '',
      kind: kind,
      name: json['name'] as String? ?? '',
      host: json['host'] as String? ?? '',
      port: port > 0
          ? port
          : (json['secure'] == true
                ? networkSourceDefaultSecurePort(kind)
                : networkSourceDefaultPort(kind)),
      secure: json['secure'] == true,
      path: json['path'] as String? ?? '/',
      username: json['username'] as String? ?? '',
      domain: json['domain'] as String? ?? '',
      allowSelfSignedCertificate: json['allowSelfSignedCertificate'] == true,
      hostKey: json['hostKey'] as String?,
      addedAt: _date(json['addedAt']),
      lastCheckedAt: _date(json['lastCheckedAt']),
      lastError: json['lastError'] as String?,
    );
  }

  static DateTime? _date(Object? value) {
    final int? millis = (value as num?)?.toInt();
    if (millis == null || millis <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  /// The connection descriptor for the adapters, once the secret is known.
  RemoteSourceConnection connection({
    required String password,
    RemoteValueChanged<String>? onHostKey,
    Duration connectTimeout = const Duration(seconds: 12),
  }) => RemoteSourceConnection(
    kind: kind,
    host: host,
    port: port,
    secure: secure,
    username: username,
    password: password,
    path: path,
    domain: domain,
    allowSelfSignedCertificate: allowSelfSignedCertificate,
    expectedHostKey: hostKey,
    onHostKey: onHostKey,
    connectTimeout: connectTimeout,
  );

  @override
  String toString() => 'NetworkSource($kind ${kind.name} $host:$port$path)';
}

NetworkSourceKind decodeNetworkSourceKind(String? value) {
  for (final NetworkSourceKind kind in NetworkSourceKind.values) {
    if (kind.name == value) return kind;
  }
  return NetworkSourceKind.webdav;
}

/// What an editor collects before a source exists. Kept separate from
/// [NetworkSource] so the form can hold a password that never enters the model.
class NetworkSourceDraft {
  NetworkSourceDraft({
    required this.kind,
    this.name = '',
    this.host = '',
    this.port = 0,
    this.secure = false,
    this.path = '/',
    this.username = '',
    this.password = '',
    this.domain = '',
    this.allowSelfSignedCertificate = false,
    this.clearHostKey = false,
  });

  factory NetworkSourceDraft.fromSource(NetworkSource source) =>
      NetworkSourceDraft(
        kind: source.kind,
        name: source.name,
        host: source.host,
        port: source.port,
        secure: source.secure,
        path: source.path,
        username: source.username,
        domain: source.domain,
        allowSelfSignedCertificate: source.allowSelfSignedCertificate,
      );

  NetworkSourceKind kind;
  String name;
  String host;
  int port;
  bool secure;
  String path;
  String username;
  String password;
  String domain;
  bool allowSelfSignedCertificate;

  /// Set when the listener asked to forget the SSH host key they trusted
  /// before, so the next connection is trusted again from scratch.
  bool clearHostKey;

  int get effectivePort => port > 0
      ? port
      : (secure
            ? networkSourceDefaultSecurePort(kind)
            : networkSourceDefaultPort(kind));

  /// Why the draft cannot be saved; null when it can.
  String? get invalidReason {
    if (host.trim().isEmpty) return '请填写服务器地址。';
    final int port = effectivePort;
    if (port <= 0 || port > 65535) return '端口应在 1 到 65535 之间。';
    if (kind == NetworkSourceKind.smb &&
        smbSplitShare(path).$1.isEmpty) {
      return 'SMB 需要先填写共享名，例如 Music 或 data/music。';
    }
    return null;
  }

  NetworkSource toSource({
    required String id,
    NetworkSource? previous,
    DateTime? now,
  }) => NetworkSource(
    id: id,
    kind: kind,
    name: name.trim(),
    host: host.trim(),
    // smb_connect always dials 445; accepting another port here would store a
    // number the connection cannot honour.
    port: kind == NetworkSourceKind.smb
        ? networkSourceDefaultPort(NetworkSourceKind.smb)
        : effectivePort,
    secure: secure,
    path: kind == NetworkSourceKind.smb
        ? _smbDraftPath(path)
        : remoteNormalize(path),
    username: username.trim(),
    domain: domain.trim(),
    allowSelfSignedCertificate: allowSelfSignedCertificate,
    hostKey: clearHostKey ? null : previous?.hostKey,
    addedAt: previous?.addedAt ?? now ?? DateTime.now(),
    lastCheckedAt: previous?.lastCheckedAt,
    lastError: previous?.lastError,
  );

  static String _smbDraftPath(String raw) {
    final (String share, String folder) = smbSplitShare(raw);
    return folder == '/' ? share : '$share$folder';
  }
}

/// Stable identifier for a new source: time plus randomness, no external uuid
/// package for one call site.
String newNetworkSourceId([Random? random]) {
  final Random source = random ?? Random.secure();
  final int stamp = DateTime.now().microsecondsSinceEpoch;
  final String noise = List<String>.generate(
    4,
    (_) => source.nextInt(0x7fffffff).toRadixString(36).padLeft(6, '0'),
  ).join();
  return 'ns-$stamp-$noise';
}

/// Deterministic identity for a track inside a source.
String networkTrackId(String sourceId, String path) {
  return 'network:${base64Url.encode(utf8.encode('$sourceId\u0000$path')).replaceAll('=', '')}';
}

/// The parts of [networkTrackId]'s payload. Null for anything else.
(String sourceId, String path)? decodeNetworkTrackId(String id) {
  if (!id.startsWith('network:')) return null;
  try {
    final String padded = id.substring(8);
    final String normalised = padded.padRight(
      padded.length + (4 - padded.length % 4) % 4,
      '=',
    );
    final String decoded = utf8.decode(base64Url.decode(normalised));
    final int separator = decoded.indexOf('\u0000');
    if (separator <= 0) return null;
    return (decoded.substring(0, separator), decoded.substring(separator + 1));
  } catch (_) {
    return null;
  }
}

/// `radio:<id>` / `podcast:<id>` ids used by the live surfaces.
String radioTrackId(String stationId) => 'radio:$stationId';
String podcastTrackId(String episodeId) => 'podcast:$episodeId';

/// Whether [id] belongs to a network source, an internet radio station or a
/// podcast episode. These are the ids the controller resolves itself instead of
/// asking the music catalogue.
bool isNetworkOwnedTrackId(String id) =>
    id.startsWith('network:') ||
    id.startsWith('radio:') ||
    id.startsWith('podcast:');

String? decodeStreamTrackId(String id, String prefix) {
  if (!id.startsWith('$prefix:')) return null;
  final String value = id.substring(prefix.length + 1);
  return value.isEmpty ? null : value;
}
