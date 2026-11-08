// i18n:data — interface strings declared here are translated at their render sites.
// ignore_for_file: prefer_initializing_formals — the protocol adapters keep
// private fields and stable named parameters; the lint cannot express that.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:smb_connect/smb_connect.dart';

import 'remote_source.dart';

/// One SMB directory entry.
class SmbEntry {
  const SmbEntry({
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

/// One open SMB file range.
class SmbRead {
  const SmbRead({
    required this.bytes,
    required this.close,
    this.totalBytes,
  });

  final Stream<List<int>> bytes;
  final int? totalBytes;
  final Future<void> Function() close;
}

/// The small SMB surface the adapter needs, so the path mapping and range
/// wiring can be tested without a server and `smb_connect` stays contained.
abstract interface class SmbSession {
  Future<List<SmbEntry>> listShares();
  Future<List<SmbEntry>> list(String path);
  Future<SmbEntry?> stat(String path);
  Future<SmbRead> read(String path, {required int start, int? end});
  Future<void> close();
}

typedef SmbSessionFactory =
    Future<SmbSession> Function(RemoteSourceConnection connection);

/// A source on a Windows/Samba share, driven by `smb_connect` (SMB2).
///
/// SMB cannot be browsed without a share, so the source's configured path is
/// `share/folder` and every path inside it is relative to that folder.
class SmbSourceClient implements RemoteSourceClient {
  SmbSourceClient({
    required SmbSession session,
    required String share,
    required String basePath,
  }) : _session = session,
       _share = share,
       _basePath = remoteNormalize(basePath);

  final SmbSession _session;
  final String _share;
  final String _basePath;

  @override
  NetworkSourceKind get kind => NetworkSourceKind.smb;

  /// Server path (`/share/folder/file`) for a source-relative path.
  String absolutePath(String path) {
    final String relative = remoteNormalize(path);
    final String folder = _basePath == '/'
        ? ''
        : _basePath.substring(1);
    final String combined = relative == '/'
        ? folder
        : '$folder$relative';
    final String cleaned = combined
        .split('/')
        .where((String part) => part.isNotEmpty)
        .join('/');
    return '/$_share${cleaned.isEmpty ? '' : '/$cleaned'}';
  }

  @override
  Future<RemoteListing> list(String path) async {
    final String normalized = remoteNormalize(path);
    return guardRemote(() async {
      final List<SmbEntry> entries = await _session.list(
        absolutePath(normalized),
      );
      final List<RemoteEntry> mapped = <RemoteEntry>[
        for (final SmbEntry entry in entries)
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
    return guardRemote(() async {
      final SmbEntry? entry = await _session.stat(absolutePath(normalized));
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
      final SmbRead read = await _session.read(
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

/// How many bytes a read of `[start, end]` (inclusive, null means to EOF)
/// covers, from a file of [total] bytes (`0` when the server did not say).
///
/// smb_connect's own API takes an exclusive end, so this conversion is the one
/// place the inclusive range is turned into a byte count.
int smbReadLength({required int start, required int? end, required int total}) {
  if (end != null) return end - start + 1;
  if (total > start) return total - start;
  return -1;
}

/// The live SMB session. All `smb_connect` usage lives here.
class SmbConnectSession implements SmbSession {
  SmbConnectSession._(this._connect);

  final SmbConnect _connect;
  bool _closed = false;

  static Future<SmbSession> connect(RemoteSourceConnection connection) async {
    try {
      final SmbConnect connect = await SmbConnect.connectAuth(
        host: connection.host,
        username: connection.username,
        password: connection.password,
        domain: connection.domain,
      ).timeout(connection.connectTimeout);
      return SmbConnectSession._(connect);
    } catch (error) {
      throw _map(error);
    }
  }

  @override
  Future<List<SmbEntry>> list(String path) async {
    try {
      final SmbFile? folder = await _withTimeout(_existing(path));
      if (folder == null || !folder.isDirectory()) return const <SmbEntry>[];
      final List<SmbFile> files = await _withTimeout(
        _connect.listFiles(folder),
      );
      return <SmbEntry>[
        for (final SmbFile file in files)
          if (file.name.isNotEmpty && file.name != '.' && file.name != '..')
            SmbEntry(
              name: file.name,
              isDirectory: file.isDirectory(),
              size: file.isDirectory() ? null : file.size,
              modifiedAt: _time(file.lastModified),
            ),
      ];
    } catch (error) {
      throw _map(error);
    }
  }

  @override
  Future<List<SmbEntry>> listShares() async {
    try {
      final List<SmbFile> shares = await _withTimeout(
        _connect.listShares(),
      );
      return <SmbEntry>[
        for (final SmbFile share in shares)
          SmbEntry(
            name: (share.name.isEmpty ? remoteName(share.path) : share.name)
                .replaceAll(r'\', ''),
            isDirectory: true,
          ),
      ];
    } catch (error) {
      throw _map(error);
    }
  }

  Future<SmbFile?> _existing(String path) async {
    final SmbFile file = await _connect.file(path);
    return file.isExists ? file : null;
  }

  @override
  Future<SmbEntry?> stat(String path) async {
    try {
      final SmbFile? file = await _withTimeout(_existing(path));
      if (file == null) return null;
      return SmbEntry(
        name: file.name,
        isDirectory: file.isDirectory(),
        size: file.isDirectory() ? null : file.size,
        modifiedAt: _time(file.lastModified),
      );
    } catch (error) {
      throw _map(error);
    }
  }

  @override
  Future<SmbRead> read(String path, {required int start, int? end}) async {
    try {
      final SmbFile? file = await _withTimeout(_existing(path));
      if (file == null) {
        throw const RemoteFailure(RemoteFailureKind.notFound);
      }
      final int total = file.size;
      // `openRead`'s third argument is an *exclusive* end: smb_connect reads
      // `end - start` bytes from `start`. Passing the inclusive last byte would
      // cut every range one byte short.
      final int remaining = smbReadLength(start: start, end: end, total: total);
      if (remaining == 0) {
        return SmbRead(
          bytes: const Stream<List<int>>.empty(),
          totalBytes: total > 0 ? total : null,
          close: () async {},
        );
      }
      final RandomAccessFile handle = await _withTimeout(_connect.open(file));
      try {
        await _withTimeout(handle.setPosition(start));
      } catch (_) {
        await handle.close();
        rethrow;
      }
      return SmbRead(
        bytes: _chunks(handle, remaining),
        totalBytes: total > 0 ? total : null,
        // Closing the handle on cancel releases the server-side file id; the
        // openRead stream would only close it after its generator finished,
        // which a seek never lets it do.
        close: () async {
          try {
            await handle.close();
          } catch (_) {}
        },
      );
    } catch (error) {
      throw _map(error);
    }
  }

  static const int _chunkSize = 64 * 1024;

  static Stream<List<int>> _chunks(
    RandomAccessFile handle,
    int remaining,
  ) async* {
    int left = remaining;
    while (left != 0) {
      final int want = left < 0
          ? _chunkSize
          : (left < _chunkSize ? left : _chunkSize);
      final Uint8List chunk;
      try {
        chunk = await handle.read(want);
      } catch (_) {
        // A truncated file or a dropped session ends the range; the caller sees
        // a short stream rather than a hung read.
        return;
      }
      if (chunk.isEmpty) return;
      yield chunk;
      if (left > 0) left -= chunk.length;
    }
  }

  static const Duration _operationTimeout = Duration(seconds: 30);

  /// A dead share must surface as a timeout rather than parking a request on a
  /// socket that never answers.
  static Future<T> _withTimeout<T>(Future<T> operation) => operation.timeout(
    _operationTimeout,
    onTimeout: () => throw const RemoteFailure(RemoteFailureKind.timeout),
  );

  static DateTime? _time(int value) {
    if (value <= 0) return null;
    // SMB reports epoch milliseconds; a couple of servers report seconds.
    final int millis = value > 100000000000 ? value : value * 1000;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  static RemoteFailure _map(Object error) {
    if (error is RemoteFailure) return error;
    final String text = error.toString().toLowerCase();
    if (text.contains('logon_failure') ||
        text.contains('access_denied') ||
        text.contains('password') ||
        text.contains('authentication')) {
      return RemoteFailure(RemoteFailureKind.auth, detail: '$error');
    }
    if (text.contains('object_name_not_found') ||
        text.contains('bad_network_name') ||
        text.contains('not_found')) {
      return RemoteFailure(RemoteFailureKind.notFound, detail: '$error');
    }
    if (text.contains('connect') ||
        text.contains('host') ||
        text.contains('socket')) {
      return RemoteFailure(RemoteFailureKind.unreachable, detail: '$error');
    }
    return RemoteFailure.from(error, fallback: RemoteFailureKind.protocol);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _connect.close();
    } catch (_) {}
  }
}
