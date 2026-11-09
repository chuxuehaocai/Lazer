import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/network/remote_source.dart';
import 'package:lazer_nextgen/network/sftp_source.dart';
import 'package:lazer_nextgen/network/smb_source.dart';

class _FakeSftpSession implements SftpSession {
  final List<String> listPaths = <String>[];
  final List<(String, int, int?)> reads = <(String, int, int?)>[];
  bool closed = false;
  Object? failure;

  @override
  Future<List<SftpEntry>> list(String path) async {
    listPaths.add(path);
    if (failure != null) throw failure!;
    return const <SftpEntry>[
      SftpEntry(name: 'song.flac', isDirectory: false, size: 42),
      SftpEntry(name: 'Album', isDirectory: true),
    ];
  }

  @override
  Future<SftpEntry?> stat(String path) async {
    if (path.endsWith('missing.flac')) return null;
    return SftpEntry(
      name: path.split('/').last,
      isDirectory: path.endsWith('Album'),
      size: path.endsWith('Album') ? null : 42,
      modifiedAt: DateTime.utc(2024),
    );
  }

  @override
  Future<SftpRead> read(String path, {required int start, int? end}) async {
    reads.add((path, start, end));
    return SftpRead(
      bytes: Stream<List<int>>.value(
        utf8.encode('0123456789').sublist(start, (end ?? 9) + 1),
      ),
      totalBytes: 10,
      close: () async {},
    );
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

class _FakeSmbSession implements SmbSession {
  final List<String> listPaths = <String>[];
  final List<(String, int, int?)> reads = <(String, int, int?)>[];
  bool closed = false;

  @override
  Future<List<SmbEntry>> list(String path) async {
    listPaths.add(path);
    return const <SmbEntry>[
      SmbEntry(name: 'b.mp3', isDirectory: false, size: 7),
      SmbEntry(name: 'A', isDirectory: true),
    ];
  }

  @override
  Future<List<SmbEntry>> listShares() async =>
      const <SmbEntry>[SmbEntry(name: 'Music', isDirectory: true)];

  @override
  Future<SmbEntry?> stat(String path) async =>
      path.endsWith('missing') ? null : SmbEntry(name: path, isDirectory: false, size: 9);

  @override
  Future<SmbRead> read(String path, {required int start, int? end}) async {
    reads.add((path, start, end));
    return SmbRead(
      bytes: Stream<List<int>>.value(<int>[1, 2, 3]),
      totalBytes: 3,
      close: () async {},
    );
  }

  @override
  Future<void> close() async {
    closed = true;
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
  group('SFTP adapter', () {
    test('maps a base path onto the server and sorts folders first', () async {
      final _FakeSftpSession session = _FakeSftpSession();
      final SftpSourceClient client = SftpSourceClient(
        session: session,
        basePath: '/music',
      );
      expect(client.absolutePath('/'), '/music');
      expect(client.absolutePath('/Album/x.flac'), '/music/Album/x.flac');
      expect(client.relativePath('/music/Album/x.flac'), '/Album/x.flac');

      final RemoteListing listing = await client.list('/');
      expect(session.listPaths.single, '/music');
      expect(
        listing.entries.map((RemoteEntry entry) => entry.name),
        <String>['Album', 'song.flac'],
      );
      expect(listing.entries.first.isDirectory, isTrue);
      expect(listing.entries.last.size, 42);
      expect(listing.entries.last.path, '/song.flac');
    });

    test('reads pass offsets through and expose the total size', () async {
      final _FakeSftpSession session = _FakeSftpSession();
      final SftpSourceClient client = SftpSourceClient(
        session: session,
        basePath: '/music',
      );
      final RemoteRead read = await client.open(
        '/song.flac',
        start: 2,
        end: 5,
      );
      expect(session.reads.single, ('/music/song.flac', 2, 5));
      expect(read.totalBytes, 10);
      expect(utf8.decode(await _collect(read.bytes)), '2345');
      await read.close();
    });

    test('stat reports null for a missing file and maps folders', () async {
      final _FakeSftpSession session = _FakeSftpSession();
      final SftpSourceClient client = SftpSourceClient(
        session: session,
        basePath: '/music',
      );
      expect(await client.stat('/missing.flac'), isNull);
      final RemoteEntry? folder = await client.stat('/Album');
      expect(folder?.isDirectory, isTrue);
      expect(folder?.size, isNull);
    });

    test('closing the client closes the session', () async {
      final _FakeSftpSession session = _FakeSftpSession();
      final SftpSourceClient client = SftpSourceClient(
        session: session,
        basePath: '/',
      );
      await client.close();
      expect(session.closed, isTrue);
    });

    test('host keys print like ssh-keygen', () {
      expect(
        DartSftpSession.formatHostKey(
          'ssh-ed25519',
          Uint8List.fromList(utf8.encode('SHA256:abc123')),
        ),
        'SSH-ED25519 SHA256:abc123',
      );
    });
  });

  group('SMB adapter', () {
    test('joins the share and base folder into the server path', () {
      final SmbSourceClient client = SmbSourceClient(
        session: _FakeSmbSession(),
        share: 'Music',
        basePath: '/Albums',
      );
      expect(client.absolutePath('/'), '/Music/Albums');
      expect(client.absolutePath('/A/b.mp3'), '/Music/Albums/A/b.mp3');
    });

    test('lists a folder with folders first and sizes on files', () async {
      final _FakeSmbSession session = _FakeSmbSession();
      final SmbSourceClient client = SmbSourceClient(
        session: session,
        share: 'Music',
        basePath: '/',
      );
      final RemoteListing listing = await client.list('/Albums');
      expect(session.listPaths.single, '/Music/Albums');
      expect(
        listing.entries.map((RemoteEntry entry) => entry.name),
        <String>['A', 'b.mp3'],
      );
      expect(listing.entries.last.size, 7);
      expect(listing.entries.last.path, '/Albums/b.mp3');
    });

    test('reads and stat reach the mapped path', () async {
      final _FakeSmbSession session = _FakeSmbSession();
      final SmbSourceClient client = SmbSourceClient(
        session: session,
        share: 'Music',
        basePath: '/',
      );
      final RemoteRead read = await client.open('/b.mp3', start: 1);
      expect(session.reads.single, ('/Music/b.mp3', 1, null));
      expect(await _collect(read.bytes), <int>[1, 2, 3]);
      await read.close();
      expect(await client.stat('/missing'), isNull);
    });

    test('the inclusive range becomes a byte count for smb_connect', () {
      // smb_connect reads `end - start` bytes, so the last byte must not be
      // dropped and a single-byte range must still ask for one byte.
      expect(smbReadLength(start: 10, end: 19, total: 100), 10);
      expect(smbReadLength(start: 10, end: 10, total: 100), 1);
      expect(smbReadLength(start: 10, end: null, total: 100), 90);
      expect(smbReadLength(start: 0, end: null, total: 0), -1);
    });

    test('errors from the session keep their kind', () async {
      final SmbSourceClient client = SmbSourceClient(
        session: _ThrowingSmbSession(),
        share: 'Music',
        basePath: '/',
      );
      await expectLater(
        client.list('/'),
        throwsA(
          isA<RemoteFailure>().having(
            (RemoteFailure failure) => failure.kind,
            'kind',
            RemoteFailureKind.auth,
          ),
        ),
      );
    });
  });
}

class _ThrowingSmbSession implements SmbSession {
  @override
  Future<List<SmbEntry>> list(String path) async =>
      throw const RemoteFailure(RemoteFailureKind.auth, detail: 'logon failure');

  @override
  Future<List<SmbEntry>> listShares() async => const <SmbEntry>[];

  @override
  Future<SmbEntry?> stat(String path) async => null;

  @override
  Future<SmbRead> read(String path, {required int start, int? end}) async =>
      throw const RemoteFailure(RemoteFailureKind.auth);

  @override
  Future<void> close() async {}
}
