// i18n:data — interface strings declared here are translated at their render sites.
// ignore_for_file: prefer_initializing_formals — the protocol adapters keep
// private fields and stable named parameters; the lint cannot express that.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'remote_source.dart';

/// One SFTP directory entry, already reduced to what the browser needs.
class SftpEntry {
  const SftpEntry({
    required this.name,
    required this.isDirectory,
    this.size,
    this.modifiedAt,
  });

  final String name;
  final bool isDirectory;
  final int? size;
  final DateTime? modifiedAt;
}

/// One open SFTP file range.
class SftpRead {
  const SftpRead({
    required this.bytes,
    required this.close,
    this.totalBytes,
  });

  final Stream<List<int>> bytes;
  final int? totalBytes;
  final Future<void> Function() close;
}

/// The small SFTP surface the adapter needs.
///
/// Keeping it an interface lets the source logic — path mapping, listing sort,
/// range wiring — run in tests without an SSH server, and contains the
/// third-party client to one class.
abstract interface class SftpSession {
  Future<List<SftpEntry>> list(String path);
  Future<SftpEntry?> stat(String path);
  Future<SftpRead> read(String path, {required int start, int? end});
  Future<void> close();
}

typedef SftpSessionFactory =
    Future<SftpSession> Function(RemoteSourceConnection connection);

/// A source over SSH's SFTP subsystem, driven by `dartssh2`.
///
/// The host key is remembered on first use (trust on first use): a later
/// connection that presents a different key is refused until the listener
/// clears the stored fingerprint from the source's editor.
class SftpSourceClient implements RemoteSourceClient {
  SftpSourceClient({
    required SftpSession session,
    required String basePath,
  }) : _session = session,
       _basePath = remoteNormalize(basePath);

  factory SftpSourceClient.fromSession({
    required SftpSession session,
    required String basePath,
  }) => SftpSourceClient(session: session, basePath: basePath);

  final SftpSession _session;
  final String _basePath;

  @override
  NetworkSourceKind get kind => NetworkSourceKind.sftp;

  /// Absolute server path for a source-relative path.
  String absolutePath(String path) {
    final String relative = remoteNormalize(path);
    if (_basePath == '/') return relative;
    return remoteNormalize(
      relative == '/' ? _basePath : '$_basePath$relative',
    );
  }

  /// Source-relative path for a server path.
  String relativePath(String absolute) {
    final String normalized = remoteNormalize(absolute);
    if (normalized == _basePath) return '/';
    if (normalized.startsWith('$_basePath/')) {
      return remoteNormalize(normalized.substring(_basePath.length));
    }
    return normalized;
  }

  @override
  Future<RemoteListing> list(String path) async {
    final String normalized = remoteNormalize(path);
    return guardRemote(() async {
      final List<SftpEntry> entries = await _session.list(
        absolutePath(normalized),
      );
      final List<RemoteEntry> mapped = <RemoteEntry>[
        for (final SftpEntry entry in entries)
          if (entry.name.isNotEmpty && entry.name != '.' && entry.name != '..')
            RemoteEntry(
              name: entry.name,
              path: remoteJoin(normalized, entry.name),
              isDirectory: entry.isDirectory,
              size: entry.isDirectory ? null : entry.size,
              modifiedAt: entry.modifiedAt,
            ),
      ]..sort(byFolderThenName);
      return RemoteListing(path: normalized, entries: mapped);
    });
  }

  @override
  Future<RemoteEntry?> stat(String path) async {
    final String normalized = remoteNormalize(path);
    if (normalized == '/') {
      return const RemoteEntry(name: '/', path: '/', isDirectory: true);
    }
    return guardRemote(() async {
      final SftpEntry? entry = await _session.stat(absolutePath(normalized));
      if (entry == null) return null;
      return RemoteEntry(
        name: remoteName(normalized),
        path: normalized,
        isDirectory: entry.isDirectory,
        size: entry.isDirectory ? null : entry.size,
        modifiedAt: entry.modifiedAt,
      );
    });
  }

  @override
  Future<RemoteRead> open(String path, {int start = 0, int? end}) async {
    final String normalized = remoteNormalize(path);
    return guardRemote(() async {
      final SftpRead read = await _session.read(
        absolutePath(normalized),
        start: start,
        end: end,
      );
      return RemoteRead(
        bytes: read.bytes,
        totalBytes: read.totalBytes,
        close: read.close,
      );
    });
  }

  @override
  Future<void> close() => _session.close();
}

/// The live SFTP session. All `dartssh2` usage lives here.
class DartSftpSession implements SftpSession {
  DartSftpSession._(this._client, this._sftp);

  final SSHClient _client;
  final SftpClient _sftp;
  bool _closed = false;

  static Future<SftpSession> connect(RemoteSourceConnection connection) async {
    final SSHSocket socket;
    try {
      socket = await SSHSocket.connect(
        connection.host,
        connection.port == 0 ? 22 : connection.port,
        timeout: connection.connectTimeout,
      );
    } catch (error) {
      throw RemoteFailure.from(error);
    }
    String? presented;
    final SSHClient client = SSHClient(
      socket,
      username: connection.username.isEmpty
          ? 'anonymous'
          : connection.username,
      onPasswordRequest: () => connection.password,
      onVerifyHostKey: (String type, Uint8List fingerprint) {
        final String value = formatHostKey(type, fingerprint);
        presented = value;
        connection.onHostKey?.call(value);
        final String? expected = connection.expectedHostKey;
        if (expected == null || expected.isEmpty) return true;
        return expected == value;
      },
    );
    try {
      await client.authenticated.timeout(connection.connectTimeout);
    } catch (error) {
      client.close();
      if (presented != null &&
          connection.expectedHostKey != null &&
          presented != connection.expectedHostKey) {
        throw const RemoteFailure(
          RemoteFailureKind.tls,
          detail: 'SSH host key changed',
        );
      }
      throw RemoteFailure.from(error);
    }
    final SftpClient? sftp;
    try {
      sftp = await client.sftp();
    } catch (error) {
      client.close();
      throw RemoteFailure.from(error);
    }
    return DartSftpSession._(client, sftp);
  }

  /// `SHA256:…` in OpenSSH's own spelling, so a user can compare it with the
  /// NAS console. `dartssh2` 4 hands the callback the printable
  /// fingerprint bytes, not the raw digest; a callback that does supply a
  /// digest is still formatted as hex.
  static String formatHostKey(String type, Uint8List fingerprint) {
    final String text = utf8.decode(fingerprint, allowMalformed: true);
    if (text.startsWith('SHA256:') || text.startsWith('MD5:')) {
      return '${type.toUpperCase()} $text';
    }
    final String hex = fingerprint
        .map((int byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join(':');
    return '${type.toUpperCase()} MD5:$hex';
  }

  static const Duration _operationTimeout = Duration(seconds: 30);

  static Future<T> _withTimeout<T>(Future<T> operation) => operation.timeout(
    _operationTimeout,
    onTimeout: () => throw const RemoteFailure(RemoteFailureKind.timeout),
  );

  @override
  Future<List<SftpEntry>> list(String path) async {
    try {
      final List<SftpName> names = await _withTimeout(_sftp.listdir(path));
      return <SftpEntry>[
        for (final SftpName name in names)
          SftpEntry(
            name: name.filename,
            isDirectory: name.attr.mode?.type == SftpFileType.directory,
            size: name.attr.size,
            modifiedAt: _time(name.attr.modifyTime),
          ),
      ];
    } catch (error) {
      throw _map(error);
    }
  }

  @override
  Future<SftpEntry?> stat(String path) async {
    try {
      final SftpFileAttrs attrs = await _withTimeout(_sftp.stat(path));
      return SftpEntry(
        name: remoteName(path),
        isDirectory: attrs.mode?.type == SftpFileType.directory,
        size: attrs.size,
        modifiedAt: _time(attrs.modifyTime),
      );
    } on SftpStatusError catch (error) {
      if (error.code == SftpStatusCode.noSuchFile) return null;
      throw _map(error);
    } catch (error) {
      throw _map(error);
    }
  }

  @override
  Future<SftpRead> read(String path, {required int start, int? end}) async {
    try {
      final SftpFile file = await _withTimeout(_sftp.open(path));
      int? total;
      try {
        total = (await _withTimeout(file.stat())).size;
      } catch (_) {
        total = null;
      }
      final int? totalBytes = total;
      final int? length = end == null
          ? (totalBytes == null ? null : totalBytes - start)
          : end - start + 1;
      final Stream<Uint8List> source = file.read(
        offset: start,
        length: length,
      );
      return SftpRead(
        bytes: source,
        totalBytes: totalBytes,
        close: () async {
          try {
            await file.close();
          } catch (_) {}
        },
      );
    } catch (error) {
      throw _map(error);
    }
  }

  static DateTime? _time(int? seconds) => seconds == null || seconds <= 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(seconds * 1000);

  static RemoteFailure _map(Object error) {
    if (error is RemoteFailure) return error;
    if (error is SftpStatusError) {
      return switch (error.code) {
        SftpStatusCode.permissionDenied => const RemoteFailure(
          RemoteFailureKind.permission,
        ),
        SftpStatusCode.noSuchFile => const RemoteFailure(
          RemoteFailureKind.notFound,
        ),
        _ => RemoteFailure(
          RemoteFailureKind.protocol,
          detail: 'SFTP ${error.code}',
        ),
      };
    }
    return RemoteFailure.from(error);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      _sftp.close();
    } catch (_) {}
    try {
      _client.close();
    } catch (_) {}
  }
}
