import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/network/ftp_source.dart';
import 'package:lazer_nextgen/network/remote_source.dart';

/// A scripted FTP server: control channel, passive data sockets and the small
/// command set the adapter uses.
class _FakeFtpServer {
  late ServerSocket _control;
  final List<ServerSocket> _dataServers = <ServerSocket>[];
  final List<Socket> _sockets = <Socket>[];
  final Map<String, List<int>> files = <String, List<int>>{
    '/music/song.flac': List<int>.generate(40, (int i) => i),
    '/music/Album/second.mp3': utf8.encode('second'),
  };
  final Map<String, List<String>> folders = <String, List<String>>{
    '/': <String>['music'],
    '/music': <String>['song.flac', 'Album'],
    '/music/Album': <String>['second.mp3'],
  };

  bool mlsdSupported = true;
  bool restSupported = true;
  bool validCredentials = true;
  String? lastRest;
  String? lastCommand;

  int get port => _control.port;

  Future<void> start() async {
    _control = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _control.listen(_accept);
  }

  Future<void> close() async {
    for (final Socket socket in _sockets) {
      socket.destroy();
    }
    for (final ServerSocket server in _dataServers) {
      await server.close();
    }
    await _control.close();
  }

  void _accept(Socket socket) {
    _sockets.add(socket);
    socket.write('220 fake ftp ready\r\n');
    String buffer = '';
    String user = '';
    int offset = 0;
    socket.listen((List<int> data) {
      buffer += utf8.decode(data);
      while (true) {
        final int end = buffer.indexOf('\r\n');
        if (end < 0) break;
        final String line = buffer.substring(0, end);
        buffer = buffer.substring(end + 2);
        final int space = line.indexOf(' ');
        final String command = (space < 0 ? line : line.substring(0, space))
            .toUpperCase();
        final String argument = space < 0 ? '' : line.substring(space + 1);
        lastCommand = command;
        switch (command) {
          case 'USER':
            user = argument;
            socket.write('331 password please\r\n');
          case 'PASS':
            if (validCredentials && user == 'user' && argument == 'pass') {
              socket.write('230 logged in\r\n');
            } else {
              socket.write('530 login incorrect\r\n');
            }
          case 'TYPE':
            socket.write('200 type set\r\n');
          case 'REST':
            offset = int.tryParse(argument) ?? 0;
            lastRest = argument;
            socket.write('350 restart at $offset\r\n');
          case 'SIZE':
            final List<int>? data = _file(argument);
            socket.write(
              data == null ? '550 no such file\r\n' : '213 ${data.length}\r\n',
            );
          case 'MDTM':
            socket.write('213 20240506070809\r\n');
          case 'CWD':
            socket.write(
              folders.containsKey(argument)
                  ? '250 directory changed\r\n'
                  : '550 not a directory\r\n',
            );
          case 'MLSD':
            _transfer(socket, argument, offset, mlsd: true);
            offset = 0;
          case 'LIST':
            _transfer(socket, argument, offset, mlsd: false);
            offset = 0;
          case 'RETR':
            _retrieve(socket, argument, offset);
            offset = 0;
          case 'MLST':
            if (!mlsdSupported) {
              socket.write('502 command not implemented\r\n');
              break;
            }
            final List<String>? names = folders[argument];
            if (names != null) {
              socket.write('250-Listing\r\n');
              socket.write(' type=dir;modify=20240506070809; ${_name(argument)}\r\n');
              socket.write('250 End\r\n');
              break;
            }
            final List<int>? data = _file(argument);
            if (data == null) {
              socket.write('550 no such file\r\n');
              break;
            }
            socket.write('250-Listing\r\n');
            socket.write(
              ' type=file;size=${data.length};modify=20240506070809; ${_name(argument)}\r\n',
            );
            socket.write('250 End\r\n');
          case 'ABOR':
            socket.write('226 abort ok\r\n');
          case 'EPSV':
            _openData(socket).then((int port) {
              socket.write('229 Entering Extended Passive Mode (|||$port|)\r\n');
            });
          case 'PASV':
            _openData(socket).then((int port) {
              final int p1 = port ~/ 256;
              final int p2 = port % 256;
              socket.write('227 Entering Passive Mode (127,0,0,1,$p1,$p2)\r\n');
            });
          case 'QUIT':
            socket.write('221 bye\r\n');
            socket.destroy();
          default:
            socket.write('502 not implemented\r\n');
        }
      }
    }, onError: (Object _) {}, onDone: () {});
  }

  Future<int> _openData(Socket control) async {
    final ServerSocket server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    _dataServers.add(server);
    _pendingServers.add(server);
    return server.port;
  }

  Future<void> _transfer(
    Socket control,
    String path,
    int offset, {
    required bool mlsd,
  }) async {
    if (mlsd && !mlsdSupported) {
      // The client already connected to the passive port after EPSV; take the
      // connection down before refusing, exactly like a real server would.
      final Socket pending = await _nextData();
      await pending.close();
      control.write('502 command not implemented\r\n');
      return;
    }
    if (!folders.containsKey(path)) {
      control.write('550 no such directory\r\n');
      return;
    }
    final Socket data = await _nextData();
    control.write('150 opening data connection\r\n');
    final StringBuffer payload = StringBuffer();
    for (final String name in folders[path]!) {
      final String child = path == '/' ? '/$name' : '$path/$name';
      if (mlsd) {
        final bool folder = folders.containsKey(child);
        payload.write(
          folder
              ? 'type=dir;modify=20240506070809; $name\r\n'
              : 'type=file;size=${_file(child)!.length};modify=20240506070809; $name\r\n',
        );
      } else {
        final bool folder = folders.containsKey(child);
        payload.write(
          folder
              ? 'drwxr-xr-x 1 ftp ftp 0 May 06 07:08 $name\r\n'
              : '-rw-r--r-- 1 ftp ftp ${_file(child)!.length} May 06 07:08 $name\r\n',
        );
      }
    }
    data.add(utf8.encode(payload.toString()));
    await data.flush();
    await data.close();
    control.write('226 transfer complete\r\n');
  }

  Future<void> _retrieve(Socket control, String path, int offset) async {
    final List<int>? data = _file(path);
    if (data == null) {
      control.write('550 no such file\r\n');
      return;
    }
    final Socket socket = await _nextData();
    control.write('150 opening data connection\r\n');
    final List<int> slice = data.sublist(offset.clamp(0, data.length));
    socket.add(slice);
    await socket.flush();
    await socket.close();
    control.write('226 transfer complete\r\n');
  }

  Future<Socket> _nextData() async {
    // The data server accepts exactly one connection per EPSV.
    final ServerSocket server = _pendingServers.removeAt(0);
    final Completer<Socket> completer = Completer<Socket>();
    final StreamSubscription<Socket> subscription = server.listen(
      (Socket socket) {
        _sockets.add(socket);
        if (!completer.isCompleted) completer.complete(socket);
      },
      onError: (Object error) {
        if (!completer.isCompleted) completer.completeError(error);
      },
    );
    final Socket socket = await completer.future;
    await subscription.cancel();
    await server.close();
    return socket;
  }

  final List<ServerSocket> _pendingServers = <ServerSocket>[];

  List<int>? _file(String path) => files[path];

  String _name(String path) {
    final List<String> parts = path.split('/').where((String p) => p.isNotEmpty).toList();
    return parts.isEmpty ? '/' : parts.last;
  }
}

Future<List<int>> _collect(Stream<List<int>> stream) async {
  final List<int> bytes = <int>[];
  await for (final List<int> chunk in stream) {
    bytes.addAll(chunk);
  }
  return bytes;
}

void main() {
  late _FakeFtpServer server;
  late FtpSourceClient client;

  setUp(() async {
    server = _FakeFtpServer();
    await server.start();
    client = FtpSourceClient(
      host: InternetAddress.loopbackIPv4.address,
      port: server.port,
      username: 'user',
      password: 'pass',
      timeout: const Duration(seconds: 5),
    );
  });

  tearDown(() async {
    await client.close();
    await server.close();
  });

  test('logs in and maps a base directory onto the server', () async {
    final FtpSourceClient scoped = FtpSourceClient(
      host: InternetAddress.loopbackIPv4.address,
      port: server.port,
      username: 'user',
      password: 'pass',
      basePath: '/music',
      timeout: const Duration(seconds: 5),
    );
    addTearDown(scoped.close);
    expect(scoped.absolutePath('/'), '/music');
    expect(scoped.absolutePath('/Album/x.mp3'), '/music/Album/x.mp3');
    expect(scoped.relativePath('/music/Album/x.mp3'), '/Album/x.mp3');
    final RemoteListing listing = await scoped.list('/');
    expect(listing.entries.map((RemoteEntry e) => e.name), <String>[
      'Album',
      'song.flac',
    ]);
    expect(listing.entries.last.path, '/song.flac');
    expect(listing.entries.last.size, 40);
  });

  test('falls back to LIST when the server has no MLSD', () async {
    server.mlsdSupported = false;
    final RemoteListing listing = await client.list('/music');
    expect(listing.entries.map((RemoteEntry e) => e.name), <String>[
      'Album',
      'song.flac',
    ]);
    expect(server.lastCommand, 'LIST');
  });

  test('resumes with REST and stops at the requested byte', () async {
    final RemoteRead read = await client.open(
      '/music/song.flac',
      start: 4,
      end: 9,
    );
    expect(server.lastRest, '4');
    expect(await _collect(read.bytes), <int>[4, 5, 6, 7, 8, 9]);
    await read.close();
  });

  test('a cancelled transfer does not desynchronise the next command', () async {
    final RemoteRead read = await client.open('/music/song.flac', start: 0);
    await read.close();
    final RemoteListing listing = await client.list('/music');
    expect(listing.entries, isNotEmpty);
    final RemoteEntry? stat = await client.stat('/music/song.flac');
    expect(stat?.size, 40);
  });

  test('stat recognises files and directories', () async {
    final RemoteEntry? file = await client.stat('/music/song.flac');
    expect(file?.isDirectory, isFalse);
    expect(file?.size, 40);
    expect(file?.modifiedAt, isNotNull);
    final RemoteEntry? folder = await client.stat('/music/Album');
    expect(folder?.isDirectory, isTrue);
    expect(await client.stat('/music/missing'), isNull);
  });

  test('a server without REST still serves a seeked read', () async {
    server.restSupported = false;
    final RemoteRead read = await client.open(
      '/music/song.flac',
      start: 4,
      end: 9,
    );
    expect(await _collect(read.bytes), <int>[4, 5, 6, 7, 8, 9]);
    await read.close();
  });

  test('a refused login surfaces as an auth failure', () async {
    server.validCredentials = false;
    final FtpSourceClient refused = FtpSourceClient(
      host: InternetAddress.loopbackIPv4.address,
      port: server.port,
      username: 'user',
      password: 'wrong',
      timeout: const Duration(seconds: 5),
    );
    addTearDown(refused.close);
    await expectLater(
      refused.list('/music'),
      throwsA(
        isA<RemoteFailure>().having(
          (RemoteFailure failure) => failure.kind,
          'kind',
          RemoteFailureKind.auth,
        ),
      ),
    );
  });
}
