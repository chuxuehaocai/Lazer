import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/network/network_stream_gate.dart';
import 'package:lazer_nextgen/network/remote_source.dart';

final Map<String, List<int>> _files = <String, List<int>>{
  '/Music/song.flac': List<int>.generate(200, (int i) => i % 251),
  '/音乐/歌.mp3': <int>[7, 8, 9],
  '/100% Pure.mp3': <int>[1, 2],
};

/// A source that cannot report sizes. The gate must serve it whole rather than
/// invent a `Content-Range`.
const String _unknownSize = '/Music/unknown-size.flac';

Future<RemoteEntry?> _stat(String sourceId, String path) async {
  final List<int>? data = path == _unknownSize
      ? List<int>.generate(30, (int i) => 100 + i)
      : _files[path];
  if (data == null) return null;
  return RemoteEntry(
    name: path.split('/').last,
    path: path,
    isDirectory: false,
    size: path == _unknownSize ? null : data.length,
    modifiedAt: DateTime.utc(2024, 1, 2, 3, 4, 5),
  );
}

Future<RemoteRead> _open(
  String sourceId,
  String path,
  int start,
  int? end,
) async {
  final List<int>? data = path == _unknownSize
      ? List<int>.generate(30, (int i) => 100 + i)
      : _files[path];
  if (data == null) throw const RemoteFailure(RemoteFailureKind.notFound);
  final int last = (end ?? (data.length - 1)).clamp(0, data.length - 1);
  final List<int> slice = data.sublist(start, last + 1);
  return RemoteRead.fromStream(
    Stream<List<int>>.fromIterable(<List<int>>[slice]),
    totalBytes: data.length,
  );
}

Future<Uri?> _relay(String relayId) async {
  if (relayId != 'station') return null;
  return Uri.parse('http://127.0.0.1:${_relayServer!.port}/live');
}

HttpServer? _relayServer;

void main() {
  late NetworkStreamGate gate;
  late HttpClient client;

  setUp(() async {
    _relayServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _relayServer!.listen((HttpRequest request) async {
      final List<int> body = utf8.encode('live-stream-bytes');
      final String? range = request.headers.value(HttpHeaders.rangeHeader);
      if (range == null) {
        request.response.headers.contentType = ContentType('audio', 'mpeg');
        request.response.add(body);
      } else {
        final RegExpMatch match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
        final int start = int.parse(match.group(1)!);
        final int end = match.group(2)!.isEmpty
            ? body.length - 1
            : int.parse(match.group(2)!);
        final List<int> slice = body.sublist(start, end + 1);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${body.length}',
        );
        request.response.add(slice);
      }
      await request.response.close();
    });
    gate = NetworkStreamGate(
      openRemote: _open,
      statRemote: _stat,
      resolveRelay: _relay,
      token: 'test-token',
    );
    await gate.ensureStarted();
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await gate.close();
    await _relayServer?.close(force: true);
    _relayServer = null;
  });

  Future<HttpClientResponse> get(
    Uri uri, {
    String? range,
    String method = 'GET',
  }) async {
    final HttpClientRequest request = await client.openUrl(method, uri);
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    return request.close();
  }

  Future<List<int>> readBody(HttpClientResponse response) async {
    final List<int> bytes = <int>[];
    await for (final List<int> chunk in response) {
      bytes.addAll(chunk);
    }
    return bytes;
  }

  test('serves a whole file with a size and an audio type', () async {
    final HttpClientResponse response = await get(
      gate.urlForFile('ns', '/Music/song.flac'),
    );
    expect(response.statusCode, HttpStatus.ok);
    expect(response.headers.contentType?.mimeType, 'audio/flac');
    expect(response.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
    expect(response.headers.contentLength, 200);
    expect(await readBody(response), _files['/Music/song.flac']);
  });

  test('a range becomes 206 with the exact slice', () async {
    final HttpClientResponse response = await get(
      gate.urlForFile('ns', '/Music/song.flac'),
      range: 'bytes=10-19',
    );
    expect(response.statusCode, HttpStatus.partialContent);
    expect(
      response.headers.value(HttpHeaders.contentRangeHeader),
      'bytes 10-19/200',
    );
    expect(await readBody(response), _files['/Music/song.flac']!.sublist(10, 20));
  });

  test('HEAD reports the headers without a body', () async {
    final HttpClientResponse response = await get(
      gate.urlForFile('ns', '/Music/song.flac'),
      method: 'HEAD',
    );
    expect(response.statusCode, HttpStatus.ok);
    expect(response.headers.contentLength, 200);
    expect(await readBody(response), isEmpty);
  });

  test('an impossible range is 416 with the size', () async {
    final HttpClientResponse response = await get(
      gate.urlForFile('ns', '/Music/song.flac'),
      range: 'bytes=500-',
    );
    expect(response.statusCode, HttpStatus.requestedRangeNotSatisfiable);
    expect(response.headers.value(HttpHeaders.contentRangeHeader), 'bytes */200');
    await response.drain<void>();
  });

  test('a file with no known size ignores ranges instead of pretending', () async {
    final HttpClientResponse response = await get(
      gate.urlForFile('ns', _unknownSize),
      range: 'bytes=4-',
    );
    expect(response.statusCode, HttpStatus.ok);
    expect(response.headers.value(HttpHeaders.contentRangeHeader), isNull);
    expect(
      await readBody(response),
      List<int>.generate(30, (int i) => 100 + i),
    );
  });

  test('non-ASCII and percent signs in names survive the gate', () async {
    final HttpClientResponse music = await get(
      gate.urlForFile('ns', '/音乐/歌.mp3'),
    );
    expect(music.statusCode, HttpStatus.ok);
    expect(await readBody(music), <int>[7, 8, 9]);
    final HttpClientResponse percent = await get(
      gate.urlForFile('ns', '/100% Pure.mp3'),
    );
    expect(percent.statusCode, HttpStatus.ok);
    expect(await readBody(percent), <int>[1, 2]);
  });

  test('a missing file is 404 and a wrong token is 403', () async {
    final HttpClientResponse missing = await get(
      gate.urlForFile('ns', '/Music/missing.flac'),
    );
    expect(missing.statusCode, HttpStatus.notFound);
    await missing.drain<void>();

    final HttpClientResponse forbidden = await get(
      Uri.parse(
        'http://127.0.0.1:${gate.port}/wrong/file/ns/Music/song.flac',
      ),
    );
    expect(forbidden.statusCode, HttpStatus.forbidden);
    await forbidden.drain<void>();
  });

  test('a relay forwards the upstream stream and its ranges', () async {
    final HttpClientResponse whole = await get(gate.urlForRelay('station'));
    expect(whole.statusCode, HttpStatus.ok);
    expect(whole.headers.contentType?.mimeType, 'audio/mpeg');
    expect(utf8.decode(await readBody(whole)), 'live-stream-bytes');

    final HttpClientResponse partial = await get(
      gate.urlForRelay('station'),
      range: 'bytes=0-3',
    );
    expect(partial.statusCode, HttpStatus.partialContent);
    expect(utf8.decode(await readBody(partial)), 'live');
    expect(
      partial.headers.value(HttpHeaders.contentRangeHeader),
      'bytes 0-3/17',
    );
  });

  test('an unknown relay id is 404', () async {
    final HttpClientResponse response = await get(gate.urlForRelay('nope'));
    expect(response.statusCode, HttpStatus.notFound);
    await response.drain<void>();
  });

  test('a closed gate stops accepting requests', () async {
    final int port = gate.port!;
    await gate.close();
    await expectLater(
      HttpClient()
          .getUrl(Uri.parse('http://127.0.0.1:$port/test-token/file/ns/Music/song.flac'))
          .then((HttpClientRequest request) => request.close()),
      throwsA(isA<SocketException>()),
    );
  });
}
