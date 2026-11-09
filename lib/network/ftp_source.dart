// i18n:data — interface strings declared here are translated at their render sites.
// ignore_for_file: prefer_initializing_formals — the protocol adapters keep
// private fields and stable named parameters; the lint cannot express that.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'remote_source.dart';

/// A plain FTP source (RFC 959), plus the two extensions a NAS needs:
/// `MLSD`/`MLST` for structured listings and `REST`/`SIZE` for seeking.
///
/// FTPS is deliberately not spoken: a NAS on a home network usually serves FTP
/// inside the LAN, and a second TLS handshake would double the state this
/// adapter keeps. SFTP is the encrypted alternative the app offers.
class FtpSourceClient implements RemoteSourceClient {
  FtpSourceClient({
    required String host,
    int port = 21,
    String username = 'anonymous',
    String password = '',
    String basePath = '/',
    Duration timeout = const Duration(seconds: 20),
    Future<Socket> Function(String host, int port, Duration timeout)? connect,
  }) : _host = host,
       _port = port,
       _username = username,
       _password = password,
       _basePath = remoteNormalize(basePath),
       _timeout = timeout,
       _connect = connect ?? _defaultConnect;

  factory FtpSourceClient.fromConnection(RemoteSourceConnection connection) =>
      FtpSourceClient(
        host: connection.host,
        port: connection.port == 0 ? 21 : connection.port,
        username: connection.username.isEmpty
            ? 'anonymous'
            : connection.username,
        password: connection.password,
        basePath: connection.path,
        timeout: connection.connectTimeout,
      );

  static Future<Socket> _defaultConnect(
    String host,
    int port,
    Duration timeout,
  ) => Socket.connect(host, port, timeout: timeout);

  final String _host;
  final int _port;
  final String _username;
  final String _password;
  final String _basePath;
  final Duration _timeout;
  final Future<Socket> Function(String host, int port, Duration timeout)
  _connect;

  Socket? _control;
  StreamSubscription<String>? _subscription;
  bool _closed = false;
  bool _ready = false;
  Future<void>? _connecting;

  /// Serializes whole operations, including the lifetime of an open read: one
  /// RETR at a time, and no command may slip inside another's transfer.
  Future<void> _busy = Future<void>.value();

  final StringBuffer _buffer = StringBuffer();
  final List<_FtpReply> _replies = <_FtpReply>[];
  Completer<_FtpReply>? _waiting;
  int _replyCode = 0;
  bool _multiline = false;
  final List<String> _replyLines = <String>[];

  @override
  NetworkSourceKind get kind => NetworkSourceKind.ftp;

  /// Absolute server path for a path relative to the configured base.
  String absolutePath(String path) {
    final String relative = remoteNormalize(path);
    if (_basePath == '/') return relative;
    return remoteNormalize(relative == '/' ? _basePath : '$_basePath$relative');
  }

  /// Remote path relative to the base for an absolute server path.
  String relativePath(String absolute) {
    final String normalized = remoteNormalize(absolute);
    if (normalized == _basePath) return '/';
    if (_basePath.startsWith('/') &&
        normalized.startsWith('$_basePath/')) {
      return remoteNormalize(normalized.substring(_basePath.length));
    }
    return normalized;
  }

  /// Waits for the previous operation and becomes the exclusive user of the
  /// control channel. The returned completer must be completed when done.
  Future<Completer<void>> _acquire() async {
    final Future<void> previous = _busy;
    final Completer<void> gate = Completer<void>();
    _busy = gate.future;
    await previous;
    return gate;
  }

  Future<T> _exclusive<T>(Future<T> Function() body) async {
    final Completer<void> gate = await _acquire();
    try {
      return await body();
    } finally {
      if (!gate.isCompleted) gate.complete();
    }
  }

  Future<void> _ensureConnected() {
    if (_ready) return Future<void>.value();
    if (_closed) {
      return Future<void>.error(const RemoteFailure(RemoteFailureKind.cancelled));
    }
    return _connecting ??= _connectAndLogin().whenComplete(() {
      _connecting = null;
    });
  }

  Future<void> _connectAndLogin() async {
    final Socket socket;
    try {
      socket = await _connect(_host, _port, _timeout);
    } catch (error) {
      throw RemoteFailure.from(error);
    }
    _control = socket;
    socket.setOption(SocketOption.tcpNoDelay, true);
    _subscription = socket
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(_onText, onError: _onError, onDone: _onDone);
    final _FtpReply greeting = await _readReply();
    if (greeting.code != 220 && greeting.code != 120) _fail(greeting);
    final _FtpReply user = await _send('USER $_username');
    if (user.code == 331) {
      final _FtpReply pass = await _send(
        'PASS ${_password.isEmpty ? 'anonymous' : _password}',
      );
      if (pass.code != 230 && pass.code != 202) _fail(pass);
    } else if (user.code != 230) {
      _fail(user);
    }
    final _FtpReply type = await _send('TYPE I');
    if (type.code != 200) _fail(type);
    // Most NAS speak UTF-8 for names; a server that does not support the
    // command simply ignores it.
    try {
      await _send('OPTS UTF8 ON');
    } catch (_) {}
    _ready = true;
  }

  Never _fail(_FtpReply reply) {
    final String detail = reply.lines.isEmpty
        ? 'FTP ${reply.code}'
        : 'FTP ${reply.code} ${reply.lines.last}';
    if (reply.code == 530) {
      throw RemoteFailure(RemoteFailureKind.auth, detail: detail);
    }
    if (reply.code == 550 || reply.code == 450) {
      throw RemoteFailure(RemoteFailureKind.notFound, detail: detail);
    }
    if (reply.code == 500 || reply.code == 502 || reply.code == 504) {
      throw RemoteFailure(RemoteFailureKind.unsupported, detail: detail);
    }
    throw RemoteFailure(RemoteFailureKind.protocol, detail: detail);
  }

  void _onText(String text) {
    _buffer.write(text);
    _parseReplies();
  }

  void _onError(Object error) {
    final Completer<_FtpReply>? waiting = _waiting;
    _waiting = null;
    waiting?.completeError(RemoteFailure.from(error));
  }

  void _onDone() {
    final Completer<_FtpReply>? waiting = _waiting;
    _waiting = null;
    waiting?.completeError(const RemoteFailure(RemoteFailureKind.io));
  }

  void _parseReplies() {
    final String raw = _buffer.toString();
    int consumed = 0;
    while (true) {
      final int end = raw.indexOf('\r\n', consumed);
      if (end < 0) break;
      final String line = raw.substring(consumed, end);
      consumed = end + 2;
      _consumeLine(line);
    }
    if (consumed > 0) {
      _buffer
        ..clear()
        ..write(raw.substring(consumed));
    }
  }

  void _consumeLine(String line) {
    if (line.isEmpty) return;
    final int? code = int.tryParse(line.length >= 3 ? line.substring(0, 3) : '');
    if (code == null) {
      if (_multiline) _replyLines.add(line);
      return;
    }
    if (_multiline) {
      _replyLines.add(line);
      if (line.length >= 4 && line[3] == ' ') {
        _multiline = false;
        _deliver(_FtpReply(_replyCode, List<String>.of(_replyLines)));
        _replyLines.clear();
      }
      return;
    }
    if (line.length >= 4 && line[3] == '-') {
      _replyCode = code;
      _multiline = true;
      _replyLines
        ..clear()
        ..add(line.substring(4));
      return;
    }
    _deliver(
      _FtpReply(code, <String>[
        line.length > 3 ? line.substring(4).trim() : '',
      ]),
    );
  }

  void _deliver(_FtpReply reply) {
    final Completer<_FtpReply>? waiting = _waiting;
    if (waiting != null) {
      _waiting = null;
      waiting.complete(reply);
      return;
    }
    _replies.add(reply);
  }

  Future<_FtpReply> _readReply([Duration? timeout]) {
    if (_replies.isNotEmpty) {
      return Future<_FtpReply>.value(_replies.removeAt(0));
    }
    final Completer<_FtpReply> completer = Completer<_FtpReply>();
    _waiting = completer;
    return completer.future.timeout(
      timeout ?? _timeout,
      onTimeout: () {
        if (identical(_waiting, completer)) _waiting = null;
        // A command that never answered leaves the control channel out of
        // step; the next operation starts a fresh session instead of reading
        // a stale reply as its own.
        _dropConnection();
        throw const RemoteFailure(RemoteFailureKind.timeout);
      },
    );
  }

  void _write(String line) {
    final Socket? socket = _control;
    if (socket == null || _closed) {
      throw const RemoteFailure(RemoteFailureKind.io);
    }
    socket.write('$line\r\n');
  }

  Future<_FtpReply> _send(String line) async {
    _write(line);
    return _readReply();
  }

  @override
  Future<RemoteListing> list(String path) async {
    final String normalized = remoteNormalize(path);
    return guardRemote(() async {
      return _exclusive(() async {
        await _ensureConnected();
        final String absolute = absolutePath(normalized);
        final List<RemoteEntry> entries;
        try {
          entries = await _transferListing(
            'MLSD $absolute',
            normalized,
            machine: true,
          );
        } on RemoteFailure catch (failure) {
          // MLSD is optional; a server that refuses it gets the legacy parser.
          if (failure.kind != RemoteFailureKind.unsupported) rethrow;
          final List<RemoteEntry> legacy = await _transferListing(
            'LIST $absolute',
            normalized,
            machine: false,
          );
          legacy.sort(byFolderThenName);
          return RemoteListing(path: normalized, entries: legacy);
        }
        entries.sort(byFolderThenName);
        return RemoteListing(path: normalized, entries: entries);
      });
    });
  }

  Future<List<RemoteEntry>> _transferListing(
    String command,
    String normalized, {
    required bool machine,
  }) async {
    final Socket data = await _openPassive();
    final Completer<List<int>> body = Completer<List<int>>();
    final List<int> chunks = <int>[];
    late StreamSubscription<List<int>> subscription;
    subscription = data.listen(
      chunks.addAll,
      onError: (Object error) {
        if (!body.isCompleted) body.completeError(RemoteFailure.from(error));
      },
      onDone: () {
        if (!body.isCompleted) body.complete(List<int>.of(chunks));
      },
    );
    bool started = false;
    try {
      final _FtpReply reply = await _send(command);
      if (reply.code >= 400) _fail(reply);
      started = true;
      final List<int> bytes = await body.future.timeout(_timeout);
      await subscription.cancel();
      await _closeSocket(data);
      await _finishTransfer();
      final String text = utf8.decode(bytes, allowMalformed: true);
      return machine
          ? parseFtpMlsd(text, normalized)
          : parseFtpList(text, normalized);
    } catch (_) {
      await subscription.cancel();
      await _closeSocket(data);
      if (started) {
        try {
          await _finishTransfer(timeout: const Duration(seconds: 3));
        } catch (_) {}
      }
      rethrow;
    }
  }

  @override
  Future<RemoteEntry?> stat(String path) async {
    final String normalized = remoteNormalize(path);
    if (normalized == '/') {
      return const RemoteEntry(name: '/', path: '/', isDirectory: true);
    }
    return guardRemote(() async {
      return _exclusive(() async {
        await _ensureConnected();
        final String absolute = absolutePath(normalized);
        int? size;
        DateTime? modified;
        final _FtpReply sizeReply = await _send('SIZE $absolute');
        if (sizeReply.code == 213) {
          size = int.tryParse(sizeReply.lines.join().trim());
        }
        final _FtpReply mdtm = await _send('MDTM $absolute');
        if (mdtm.code == 213) {
          modified = parseFtpTimestamp(mdtm.lines.join().trim());
        }
        if (size != null) {
          return RemoteEntry(
            name: remoteName(normalized),
            path: normalized,
            isDirectory: false,
            size: size,
            modifiedAt: modified,
          );
        }
        // Not a plain file: ask whether it is a directory. MLST is preferred
        // because it also reports the modification time.
        final _FtpReply mlst = await _send('MLST $absolute');
        if (mlst.code == 250) {
          final List<RemoteEntry> entries = parseFtpMlsd(
            mlst.lines.join('\n'),
            remoteParent(normalized),
          );
          if (entries.isNotEmpty) {
            return entries.first.copyWith(
              path: normalized,
              name: remoteName(normalized),
            );
          }
        }
        final _FtpReply cwd = await _send('CWD $absolute');
        if (cwd.code == 250) {
          return RemoteEntry(
            name: remoteName(normalized),
            path: normalized,
            isDirectory: true,
            modifiedAt: modified,
          );
        }
        return null;
      });
    });
  }

  @override
  Future<RemoteRead> open(String path, {int start = 0, int? end}) async {
    final String normalized = remoteNormalize(path);
    return guardRemote(() async {
      await _ensureConnected();
      final Completer<void> gate = await _acquire();
      Socket? data;
      bool released = false;
      // Whether the server actually opened a transfer. A refused RETR (550),
      // a rejected REST or a failed passive connect owes no 226; waiting for
      // one there costs the timeout, drops the session and slows every error.
      bool transferStarted = false;
      Future<void> release() async {
        if (released) return;
        released = true;
        await _closeSocket(data);
        data = null;
        if (transferStarted) {
          try {
            await _finishTransfer(timeout: const Duration(seconds: 5));
          } catch (_) {
            // The transfer ended abnormally (the listener seeked away); the
            // channel is already drained as far as it can be.
          }
        }
        if (!gate.isCompleted) gate.complete();
      }

      try {
        final String absolute = absolutePath(normalized);
        data = await _openPassive();
        bool skipStart = false;
        if (start > 0) {
          final _FtpReply rest = await _send('REST $start');
          if (rest.code == 350) {
            // Positioned by the server.
          } else if (rest.code == 530) {
            _fail(rest);
          } else {
            // No REST support: read from the beginning and drop the prefix.
            skipStart = true;
          }
        }
        final _FtpReply reply = await _send('RETR $absolute');
        if (reply.code >= 400) _fail(reply);
        transferStarted = true;
        final Socket dataSocket = data!;
        Stream<List<int>> stream = dataSocket;
        if (skipStart) stream = skipBytes(stream, start);
        if (end != null) stream = limitedBytes(stream, end - start + 1);
        return RemoteRead.fromStream(stream, release: release);
      } catch (_) {
        await release();
        rethrow;
      }
    });
  }

  Future<Socket> _openPassive() async {
    final _FtpReply epsv = await _send('EPSV');
    if (epsv.code == 229) {
      final RegExpMatch? match = RegExp(
        r'\((.)\1\1(\d+)\1\)',
      ).firstMatch(epsv.lines.join(' '));
      final int? port = int.tryParse(match?.group(2) ?? '');
      if (port != null && port > 0) return _connectData(port);
    }
    final _FtpReply pasv = await _send('PASV');
    if (pasv.code != 227) _fail(pasv);
    final RegExpMatch? match = RegExp(
      r'(\d+),(\d+),(\d+),(\d+),(\d+),(\d+)',
    ).firstMatch(pasv.lines.join(' '));
    if (match == null) {
      throw RemoteFailure(
        RemoteFailureKind.protocol,
        detail: 'FTP 227 ${pasv.lines.join(' ')}',
      );
    }
    final int port =
        int.parse(match.group(5)!) * 256 + int.parse(match.group(6)!);
    // The address in a PASV reply is routinely a private interface the client
    // cannot reach through NAT; the control connection's host is the one that
    // actually works.
    return _connectData(port);
  }

  Future<Socket> _connectData(int port) async {
    try {
      return await _connect(_host, port, _timeout);
    } catch (error) {
      throw RemoteFailure.from(error);
    }
  }

  /// Consumes the final reply of a data transfer. 426 (connection closed
  /// early) is followed by 226 and is not the last word.
  Future<void> _finishTransfer({Duration? timeout}) async {
    for (var i = 0; i < 4; i++) {
      final _FtpReply reply = await _readReply(
        timeout ?? const Duration(seconds: 20),
      );
      if (reply.code == 426 || reply.code == 451) continue;
      if (reply.code >= 400) _fail(reply);
      return;
    }
    throw const RemoteFailure(
      RemoteFailureKind.protocol,
      detail: 'FTP transfer did not finish',
    );
  }

  void _dropConnection() {
    _ready = false;
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(_closeSocket(_control));
    _control = null;
    _replies.clear();
    _buffer.clear();
    _replyLines.clear();
    _multiline = false;
  }

  static Future<void> _closeSocket(Socket? socket) async {
    if (socket == null) return;
    try {
      await socket.close();
    } catch (_) {}
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _ready = false;
    try {
      await _subscription?.cancel();
    } catch (_) {}
    _subscription = null;
    try {
      if (_control != null) {
        _control!.write('QUIT\r\n');
        await _control!.flush();
      }
    } catch (_) {}
    await _closeSocket(_control);
    _control = null;
    final Completer<_FtpReply>? waiting = _waiting;
    _waiting = null;
    waiting?.completeError(const RemoteFailure(RemoteFailureKind.cancelled));
  }
}

/// Parses `MLSD` output: `type=file;size=123;modify=20240101120000; name`.
List<RemoteEntry> parseFtpMlsd(String text, String normalized) {
  final List<RemoteEntry> entries = <RemoteEntry>[];
  for (final String rawLine in const LineSplitter().convert(text)) {
    final String raw = rawLine.trim();
    final int space = raw.indexOf(' ');
    if (space <= 0) continue;
    final String facts = raw.substring(0, space).trim();
    String name = raw.substring(space + 1).trim();
    if (name.isEmpty || name == '.' || name == '..') continue;
    final Map<String, String> values = <String, String>{};
    for (final String fact in facts.split(';')) {
      final int equals = fact.indexOf('=');
      if (equals <= 0) continue;
      values[fact.substring(0, equals).toLowerCase()] = fact.substring(
        equals + 1,
      );
    }
    final String type = (values['type'] ?? 'file').toLowerCase();
    final bool isDirectory =
        type == 'dir' || type == 'cdir' || type == 'pdir';
    if (name.endsWith('/')) name = name.substring(0, name.length - 1);
    entries.add(
      RemoteEntry(
        name: name,
        path: remoteJoin(normalized, name),
        isDirectory: isDirectory,
        size: isDirectory ? null : int.tryParse(values['size'] ?? ''),
        modifiedAt: parseFtpTimestamp(values['modify'] ?? ''),
      ),
    );
  }
  return entries;
}

/// Parses `LIST` output: the UNIX form most servers send, and the MS-DOS form
/// IIS sends. A malformed line is skipped instead of failing the listing.
List<RemoteEntry> parseFtpList(String text, String normalized) {
  final List<RemoteEntry> entries = <RemoteEntry>[];
  for (final String raw in const LineSplitter().convert(text)) {
    final String line = raw.trimRight();
    if (line.isEmpty) continue;
    final RegExpMatch? unix = RegExp(
      r'^([bcdlps-][rwxStTs-]{9}[+.@]?)\s+\d+\s+\S+\s+\S+\s+(\d+)\s+'
      r'(\w{3})\s+(\d{1,2})\s+(\d{1,2}:\d{2}|\d{4})\s+(.*)$',
      caseSensitive: false,
    ).firstMatch(line);
    if (unix != null) {
      final String name = unix.group(6) ?? '';
      if (name.isEmpty || name == '.' || name == '..') continue;
      final bool isDirectory = unix.group(1)!.startsWith('d');
      entries.add(
        RemoteEntry(
          name: name,
          path: remoteJoin(normalized, name),
          isDirectory: isDirectory,
          size: isDirectory ? null : int.tryParse(unix.group(2) ?? ''),
          modifiedAt: _unixDate(
            unix.group(3) ?? '',
            unix.group(4) ?? '',
            unix.group(5) ?? '',
          ),
        ),
      );
      continue;
    }
    final RegExpMatch? dos = RegExp(
      r'^(\d{2})-(\d{2})-(\d{2,4})\s+(\d{1,2}):(\d{2})\s*(AM|PM)\s+'
      r'(<DIR>|\d+)\s+(.*)$',
      caseSensitive: false,
    ).firstMatch(line);
    if (dos != null) {
      final String name = dos.group(8) ?? '';
      if (name.isEmpty || name == '.' || name == '..') continue;
      final bool isDirectory = (dos.group(7) ?? '').toUpperCase() == '<DIR>';
      entries.add(
        RemoteEntry(
          name: name,
          path: remoteJoin(normalized, name),
          isDirectory: isDirectory,
          size: isDirectory ? null : int.tryParse(dos.group(7) ?? ''),
          modifiedAt: _dosDate(
            dos.group(1) ?? '',
            dos.group(2) ?? '',
            dos.group(3) ?? '',
            dos.group(4) ?? '',
            dos.group(5) ?? '',
            dos.group(6) ?? '',
          ),
        ),
      );
    }
  }
  return entries;
}

const List<String> _months = <String>[
  'jan',
  'feb',
  'mar',
  'apr',
  'may',
  'jun',
  'jul',
  'aug',
  'sep',
  'oct',
  'nov',
  'dec',
];

DateTime? _unixDate(String month, String day, String timeOrYear) {
  final int monthIndex = _months.indexOf(month.toLowerCase());
  final int? dayNumber = int.tryParse(day);
  if (monthIndex < 0 || dayNumber == null) return null;
  final int year;
  int hour = 0;
  int minute = 0;
  if (timeOrYear.contains(':')) {
    final List<String> parts = timeOrYear.split(':');
    hour = int.tryParse(parts.first) ?? 0;
    minute = int.tryParse(parts.last) ?? 0;
    year = DateTime.now().year;
  } else {
    year = int.tryParse(timeOrYear) ?? DateTime.now().year;
  }
  try {
    return DateTime(year, monthIndex + 1, dayNumber, hour, minute);
  } catch (_) {
    return null;
  }
}

DateTime? _dosDate(
  String month,
  String day,
  String year,
  String hour,
  String minute,
  String meridiem,
) {
  final int? monthNumber = int.tryParse(month);
  final int? dayNumber = int.tryParse(day);
  final int? parsedYear = int.tryParse(year);
  if (monthNumber == null || dayNumber == null || parsedYear == null) {
    return null;
  }
  final int yearNumber = parsedYear < 100
      ? parsedYear + (parsedYear < 70 ? 2000 : 1900)
      : parsedYear;
  int hourNumber = int.tryParse(hour) ?? 0;
  final int minuteNumber = int.tryParse(minute) ?? 0;
  if (meridiem.toUpperCase() == 'PM' && hourNumber < 12) hourNumber += 12;
  if (meridiem.toUpperCase() == 'AM' && hourNumber == 12) hourNumber = 0;
  try {
    return DateTime(
      yearNumber,
      monthNumber,
      dayNumber,
      hourNumber,
      minuteNumber,
    );
  } catch (_) {
    return null;
  }
}

/// Parses `YYYYMMDDHHMMSS[.sss]` (UTC, as `MDTM` and `MLSD` report it).
DateTime? parseFtpTimestamp(String value) {
  final String trimmed = value.trim();
  final RegExpMatch? match = RegExp(
    r'^(\d{4})(\d{2})(\d{2})(\d{2})?(\d{2})?(\d{2})?',
  ).firstMatch(trimmed);
  if (match == null) return null;
  final int year = int.parse(match.group(1)!);
  final int month = int.parse(match.group(2)!);
  final int day = int.parse(match.group(3)!);
  final int hour = int.tryParse(match.group(4) ?? '') ?? 0;
  final int minute = int.tryParse(match.group(5) ?? '') ?? 0;
  final int second = int.tryParse(match.group(6) ?? '') ?? 0;
  try {
    return DateTime.utc(year, month, day, hour, minute, second).toLocal();
  } catch (_) {
    return null;
  }
}

class _FtpReply {
  const _FtpReply(this.code, this.lines);
  final int code;
  final List<String> lines;
}
