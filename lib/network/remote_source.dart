// i18n:data — interface strings declared here are translated at their render sites.
import 'dart:async';

import 'remote_error.dart';

/// The network storage protocols the player speaks itself.
enum NetworkSourceKind { webdav, smb, sftp, ftp }

/// Protocols in the order the editor offers them.
const List<NetworkSourceKind> networkSourceKinds = NetworkSourceKind.values;

/// Protocol label for a kind. These are product names, so they are not
/// translated.
String networkSourceKindLabel(NetworkSourceKind kind) => switch (kind) {
  NetworkSourceKind.webdav => 'WebDAV',
  NetworkSourceKind.smb => 'SMB',
  NetworkSourceKind.sftp => 'SFTP',
  NetworkSourceKind.ftp => 'FTP',
};

/// What the editor asks for by default when the protocol is picked.
int networkSourceDefaultPort(NetworkSourceKind kind) => switch (kind) {
  NetworkSourceKind.webdav => 80,
  NetworkSourceKind.smb => 445,
  NetworkSourceKind.sftp => 22,
  NetworkSourceKind.ftp => 21,
};

/// The default port when TLS is on. SMB and SFTP are already encrypted.
int networkSourceDefaultSecurePort(NetworkSourceKind kind) => switch (kind) {
  NetworkSourceKind.webdav => 443,
  NetworkSourceKind.smb => 445,
  NetworkSourceKind.sftp => 22,
  NetworkSourceKind.ftp => 21,
};

/// Audio extensions every remote browser treats as playable. The set matches
/// the local library so a folder behaves the same wherever it lives.
const Set<String> networkAudioExtensions = <String>{
  'mp3',
  'flac',
  'm4a',
  'aac',
  'ogg',
  'oga',
  'opus',
  'wav',
  'wave',
  'mp4',
  'wma',
  'aiff',
  'aif',
  'ape',
  'dsf',
  'dff',
};

/// Playlist files a remote folder can carry. Importing one adds its tracks to
/// the queue instead of downloading it.
const Set<String> networkPlaylistExtensions = <String>{
  'm3u',
  'm3u8',
  'pls',
  'asx',
  'xspf',
};

/// Why a remote operation failed, in the small vocabulary the interface needs
/// to explain it. The detail is diagnostic text (a server code, a path) and is
/// shown beside the sentence rather than translated.
enum RemoteFailureKind {
  auth,
  notFound,
  permission,
  unreachable,
  timeout,
  protocol,
  tls,
  unsupported,
  cancelled,
  io,
}

class RemoteFailure implements Exception {
  const RemoteFailure(this.kind, {this.detail});

  final RemoteFailureKind kind;
  final String? detail;

  /// The sentence the interface paints. Kept in the data layer, translated at
  /// the render site, like every other status message in the app.
  String get message => switch (kind) {
    RemoteFailureKind.auth => '账号或密码不正确，或服务器拒绝了登录。',
    RemoteFailureKind.notFound => '服务器上找不到这个位置。',
    RemoteFailureKind.permission => '没有访问这个位置的权限。',
    RemoteFailureKind.unreachable => '无法连接到服务器，请检查地址、端口和网络。',
    RemoteFailureKind.timeout => '服务器响应超时，请稍后重试。',
    RemoteFailureKind.protocol => '服务器返回了无法识别的响应。',
    RemoteFailureKind.tls => '安全连接失败；如果服务器使用自签名证书，请允许它。',
    RemoteFailureKind.unsupported => '这个服务器不支持所需的操作。',
    RemoteFailureKind.cancelled => '操作已取消。',
    RemoteFailureKind.io => '读取数据时连接中断。',
  };

  /// Diagnostic suffix shown after [message] when the server said something.
  String get diagnostic => detail == null || detail!.isEmpty ? '' : detail!;

  /// Maps anything a protocol adapter can throw onto the vocabulary above.
  factory RemoteFailure.from(Object error, {RemoteFailureKind fallback = RemoteFailureKind.io}) {
    if (error is RemoteFailure) return error;
    if (error is TimeoutException) {
      return const RemoteFailure(RemoteFailureKind.timeout);
    }
    final platform = classifyPlatformError(error);
    if (platform != null) {
      return RemoteFailure(
        switch (platform.kind) {
          'tls' => RemoteFailureKind.tls,
          'unreachable' => RemoteFailureKind.unreachable,
          _ => fallback,
        },
        detail: platform.detail,
      );
    }
    return RemoteFailure(fallback, detail: error.toString());
  }

  @override
  String toString() => 'RemoteFailure(${kind.name}${detail == null ? '' : ': $detail'})';
}

/// One directory entry as the browser presents it.
class RemoteEntry {
  const RemoteEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.size,
    this.modifiedAt,
  });

  final String name;

  /// Root-anchored POSIX path inside the source, e.g. `/Music/Album/song.flac`.
  final String path;
  final bool isDirectory;
  final int? size;
  final DateTime? modifiedAt;

  String get extension => remoteExtension(name);
  bool get isAudio => !isDirectory && networkAudioExtensions.contains(extension);
  bool get isPlaylist =>
      !isDirectory && networkPlaylistExtensions.contains(extension);

  RemoteEntry copyWith({String? name, String? path, bool? isDirectory, int? size, DateTime? modifiedAt}) => RemoteEntry(
    name: name ?? this.name,
    path: path ?? this.path,
    isDirectory: isDirectory ?? this.isDirectory,
    size: size ?? this.size,
    modifiedAt: modifiedAt ?? this.modifiedAt,
  );

  @override
  String toString() => 'RemoteEntry(${isDirectory ? 'dir' : 'file'} $path)';
}

/// A directory listing plus the canonical path the server reported. Servers
/// disagree about trailing slashes and case, so the browser follows the
/// server's answer instead of echoing its own request.
class RemoteListing {
  const RemoteListing({required this.path, required this.entries});

  final String path;
  final List<RemoteEntry> entries;
}

/// An open range of a remote file.
///
/// [totalBytes] is the *full* object size when the protocol can report it, so
/// the HTTP gate can answer `Content-Range` and a seek past the end with 416.
/// [close] releases the underlying socket/request even if the consumer stopped
/// reading early.
class RemoteRead {
  const RemoteRead({
    required this.bytes,
    required this.close,
    this.totalBytes,
  });

  /// Wraps [source] so the caller can stop reading early and release whatever
  /// the adapter opened. [release] runs exactly once, whether the stream
  /// finished, failed or was cancelled.
  factory RemoteRead.fromStream(
    Stream<List<int>> source, {
    int? totalBytes,
    FutureOr<void> Function()? release,
  }) {
    StreamSubscription<List<int>>? subscription;
    bool released = false;
    late StreamController<List<int>> controller;

    Future<void> finish() async {
      if (released) return;
      released = true;
      try {
        await subscription?.cancel();
      } catch (_) {}
      subscription = null;
      try {
        await release?.call();
      } catch (_) {}
    }

    controller = StreamController<List<int>>(
      onListen: () {
        subscription = source.listen(
          controller.add,
          onError: (Object error, StackTrace stack) {
            controller.addError(error, stack);
            unawaited(finish());
          },
          onDone: () {
            unawaited(finish());
            if (!controller.isClosed) controller.close();
          },
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: finish,
    );
    return RemoteRead(
      bytes: controller.stream,
      totalBytes: totalBytes,
      close: finish,
    );
  }

  final Stream<List<int>> bytes;

  /// The full object size when the protocol reports it.
  final int? totalBytes;

  /// Stops the read and releases its connection. Idempotent.
  final Future<void> Function() close;
}

/// One connected protocol client. Implementations are cheap wrappers around a
/// session; the controller pools and recycles them.
abstract interface class RemoteSourceClient {
  NetworkSourceKind get kind;

  /// Lists [path]; an empty path means the source root.
  Future<RemoteListing> list(String path);

  /// Looks one entry up. Null means the server does not have it.
  Future<RemoteEntry?> stat(String path);

  /// Opens `[start, end]` of a file. A null [end] reads to the end.
  Future<RemoteRead> open(String path, {int start = 0, int? end});

  /// Closes the session. Safe to call more than once.
  Future<void> close();
}

/// Builds a client for a configured source. Injected so the controller can be
/// tested without a real NAS and so each adapter stays behind a seam.
typedef RemoteSourceClientFactory =
    Future<RemoteSourceClient> Function(RemoteSourceConnection connection);

/// Everything an adapter needs to open a connection, after the controller has
/// resolved the stored secret.
class RemoteSourceConnection {
  const RemoteSourceConnection({
    required this.kind,
    required this.host,
    required this.port,
    required this.secure,
    required this.username,
    required this.password,
    this.path = '/',
    this.domain = '',
    this.allowSelfSignedCertificate = false,
    this.expectedHostKey,
    this.onHostKey,
    this.connectTimeout = const Duration(seconds: 12),
  });

  final NetworkSourceKind kind;
  final String host;
  final int port;
  final bool secure;
  final String username;
  final String password;

  /// Base directory for WebDAV/FTP/SFTP, or `share/folder` for SMB.
  final String path;
  final String domain;
  final bool allowSelfSignedCertificate;

  /// SFTP: the fingerprint accepted last time, if any.
  final String? expectedHostKey;

  /// SFTP: called with the fingerprint the server presented, so a first
  /// connection can be remembered (trust on first use).
  final RemoteValueChanged<String>? onHostKey;
  final Duration connectTimeout;
}

/// Value callback used where importing foundation would be heavy.
typedef RemoteValueChanged<T> = void Function(T value);

/// Normalizes a remote path to a root-anchored POSIX path.
///
/// `.` and `..` are resolved lexically: the browser cannot ask the server what
/// `..` means on every protocol, and a path that climbs above the root must
/// not escape the configured base directory.
String remoteNormalize(String path) {
  final List<String> segments = <String>[];
  final String joined = path.trim();
  for (final String part in joined.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (segments.isNotEmpty) segments.removeLast();
      continue;
    }
    segments.add(part);
  }
  return '/${segments.join('/')}';
}

String _normalizeSegments(String path) {
  final List<String> segments = <String>[];
  for (final String part in path.replaceAll('\\', '/').split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (segments.isNotEmpty) segments.removeLast();
      continue;
    }
    segments.add(part);
  }
  return '/${segments.join('/')}';
}

String remoteJoin(String directory, String name) {
  final String base = remoteNormalize(directory);
  final String clean = name.trim();
  if (clean.isEmpty) return base;
  return remoteNormalize(clean.startsWith('/') ? clean : '$base/$clean');
}

String remoteParent(String path) {
  final String normalized = remoteNormalize(path);
  final int slash = normalized.lastIndexOf('/');
  if (slash <= 0) return '/';
  return normalized.substring(0, slash);
}

String remoteName(String path) {
  final String normalized = remoteNormalize(path);
  if (normalized == '/') return '';
  return normalized.substring(normalized.lastIndexOf('/') + 1);
}

String remoteExtension(String name) {
  final int dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

/// Whether [path] sits at or below [root].
bool remoteIsWithin(String root, String path) {
  final String normalizedRoot = remoteNormalize(root);
  final String normalizedPath = remoteNormalize(path);
  if (normalizedRoot == '/') return true;
  return normalizedPath == normalizedRoot ||
      normalizedPath.startsWith('$normalizedRoot/');
}

/// Splits a `share/folder` path as SMB users type it into a root-anchored path
/// plus the share name. A path with no share is an error, not a root listing:
/// SMB cannot browse a server without choosing a share.
(String share, String path) smbSplitShare(String raw) {
  final String normalized = _normalizeSegments(raw);
  final List<String> parts = normalized
      .split('/')
      .where((String part) => part.isNotEmpty)
      .toList();
  if (parts.isEmpty) return ('', '/');
  final String share = parts.removeAt(0);
  return (share, '/${parts.join('/')}');
}

/// Drops [count] leading bytes, then yields the rest of [source].
Stream<List<int>> skipBytes(Stream<List<int>> source, int count) async* {
  int remaining = count;
  await for (final List<int> chunk in source) {
    if (remaining <= 0) {
      yield chunk;
      continue;
    }
    if (chunk.length <= remaining) {
      remaining -= chunk.length;
      continue;
    }
    final List<int> tail = chunk.sublist(remaining);
    remaining = 0;
    yield tail;
  }
}

/// Reads at most [count] bytes from [stream] without buffering the whole file.
Stream<List<int>> limitedBytes(Stream<List<int>> source, int count) async* {
  if (count <= 0) return;
  int remaining = count;
  await for (final List<int> chunk in source) {
    if (chunk.length <= remaining) {
      remaining -= chunk.length;
      yield chunk;
      if (remaining == 0) return;
      continue;
    }
    yield chunk.sublist(0, remaining);
    return;
  }
}

/// Parses `bytes=start-end` requests. Null means "serve the whole object",
/// which is what a request without a header or with an unsupported unit asks
/// for. [RangeRequest.unsatisfiable] marks a range that cannot be served.
class RangeRequest {
  const RangeRequest(this.start, this.end);
  final int start;
  final int? end;
  static const RangeRequest whole = RangeRequest(0, null);

  /// Parses a client `Range` header against [total]. Returns null for "serve
  /// the whole file" and [RangeRequest.unsatisfiable] for an impossible range.
  static RangeRequest? parse(String? header, int? total) {
    if (header == null) return null;
    final String value = header.trim();
    if (!value.toLowerCase().startsWith('bytes=')) return null;
    final String spec = value.substring(6).trim();
    if (spec.isEmpty) return null;
    // Only one range is honoured; the player asks for one at a time.
    final String first = spec.split(',').first.trim();
    final int dash = first.indexOf('-');
    if (dash < 0) return unsatisfiable;
    final String left = first.substring(0, dash).trim();
    final String right = first.substring(dash + 1).trim();
    if (left.isEmpty) {
      // Suffix range: the last N bytes.
      final int? length = int.tryParse(right);
      if (length == null || length <= 0) return unsatisfiable;
      if (total == null) return whole;
      final int start = total - length;
      return RangeRequest(start < 0 ? 0 : start, total - 1);
    }
    final int? start = int.tryParse(left);
    if (start == null || start < 0) return unsatisfiable;
    final int? end = right.isEmpty ? null : int.tryParse(right);
    if (right.isNotEmpty && (end == null || end < 0)) return unsatisfiable;
    if (end != null && end < start) return unsatisfiable;
    if (total != null && start >= total) return unsatisfiable;
    return RangeRequest(start, end);
  }

  static const RangeRequest unsatisfiable = RangeRequest(-1, null);

  bool get isUnsatisfiable => start < 0;
}

/// MIME type the gate advertises for a file name. Browsers and decoders both
/// probe the bytes, but a correct type keeps the audio engine from guessing.
String audioContentType(String name) {
  final String type = switch (remoteExtension(name)) {
    'mp3' => 'audio/mpeg',
    'm4a' || 'mp4' => 'audio/mp4',
    'aac' => 'audio/aac',
    'flac' => 'audio/flac',
    'ogg' || 'oga' => 'audio/ogg',
    'opus' => 'audio/opus',
    'wav' || 'wave' => 'audio/wav',
    'wma' => 'audio/x-ms-wma',
    'aif' || 'aiff' => 'audio/aiff',
    'dsf' => 'audio/x-dsf',
    'dff' => 'audio/x-dff',
    _ => 'application/octet-stream',
  };
  return type;
}

/// Joins a list of path segments for display, e.g. `网络源 / Music / Album`.
String remoteDisplayPath(String path, {String separator = ' / '}) {
  final String normalized = remoteNormalize(path);
  if (normalized == '/') return '/';
  return normalized.split('/').where(
    (String part) => part.isNotEmpty,
  ).join(separator);
}

/// Encodes a remote path for use in a URL path segment chain.
String encodeRemotePath(String path) => remoteNormalize(
  path,
).split('/').where((String part) => part.isNotEmpty).map(Uri.encodeComponent).join('/');

/// Folder-first, then case-insensitive name. Shared by every adapter so a
/// folder lists the same way whatever the protocol.
int byFolderThenName(RemoteEntry a, RemoteEntry b) {
  if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
  return a.name.toLowerCase().compareTo(b.name.toLowerCase());
}

/// Runs [body] and turns anything it throws into a [RemoteFailure] unless it
/// is already one. Adapters wrap their whole surface with this so the
/// controller, the gate and the UI only ever see the small error vocabulary.
Future<T> guardRemote<T>(
  Future<T> Function() body, {
  RemoteFailureKind fallback = RemoteFailureKind.protocol,
}) async {
  try {
    return await body();
  } on RemoteFailure {
    rethrow;
  } catch (error) {
    throw RemoteFailure.from(error, fallback: fallback);
  }
}
