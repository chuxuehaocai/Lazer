import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/network/remote_source.dart';
import 'package:lazer_nextgen/network/webdav_source.dart';

/// A tiny DAV server: enough PROPFIND and GET to exercise the adapter.
class _DavServer {
  HttpServer? _server;
  int requests = 0;
  bool requireAuth = false;
  bool ignoreRange = false;
  bool redirectCollections = false;

  final Map<String, List<int>> files = <String, List<int>>{
    '/dav/Music/song one.flac': List<int>.generate(64, (int i) => i),
    '/dav/Music/中文歌.mp3': <int>[1, 2, 3, 4],
  };

  final Map<String, DateTime> modified = <String, DateTime>{
    '/dav/Music/song one.flac': DateTime.utc(2024, 5, 6, 7, 8, 9),
  };

  Uri get base => Uri.parse('http://127.0.0.1:${_server!.port}/dav');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handle);
  }

  Future<void> close() => _server?.close(force: true) ?? Future<void>.value();

  bool _authorised(HttpRequest request) {
    if (!requireAuth) return true;
    final String? header = request.headers.value(HttpHeaders.authorizationHeader);
    return header == 'Basic ${base64Encode(utf8.encode('user:pass'))}';
  }

  Future<void> _handle(HttpRequest request) async {
    requests++;
    if (!_authorised(request)) {
      request.response.statusCode = HttpStatus.unauthorized;
      await request.response.close();
      return;
    }
    final String rawPath = Uri.decodeFull(request.uri.path);
    final String path =
        rawPath.length > 1 && rawPath.endsWith('/')
        ? rawPath.substring(0, rawPath.length - 1)
        : rawPath;
    if (request.method == 'PROPFIND') {
      if (serverRedirects(rawPath)) {
        request.response.statusCode = HttpStatus.movedPermanently;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          '$rawPath/',
        );
        await request.response.close();
        return;
      }
      await _propfind(request, path);
      return;
    }
    if (request.method == 'GET') {
      await _get(request, path);
      return;
    }
    request.response.statusCode = HttpStatus.methodNotAllowed;
    await request.response.close();
  }

  bool serverRedirects(String path) =>
      redirectCollections && path == '/dav/Music';

  Future<void> _propfind(HttpRequest request, String path) async {
    final int depth = int.tryParse(
          request.headers.value('depth') ?? '0',
        ) ??
        0;
    final List<String> targets = <String>[];
    if (files.containsKey(path)) {
      targets.add(path);
    } else if (depth > 0 && _isFolder(path)) {
      targets.add(path);
      for (final String file in files.keys) {
        if (file.startsWith('$path/') &&
            !file.substring(path.length + 1).contains('/')) {
          targets.add(file);
        }
      }
    } else if (depth == 0 && _isFolder(path)) {
      targets.add(path);
    }
    if (targets.isEmpty) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final StringBuffer body = StringBuffer(
      '<?xml version="1.0" encoding="utf-8"?><d:multistatus xmlns:d="DAV:">',
    );
    for (final String target in targets) {
      final bool folder = _isFolder(target);
      final String href = Uri.encodeFull(target) + (folder ? '/' : '');
      body.write('<d:response><d:href>$href</d:href><d:propstat><d:prop>');
      body.write(folder ? '<d:resourcetype><d:collection/></d:resourcetype>' : '<d:resourcetype/>');
      if (!folder) {
        body.write('<d:getcontentlength>${files[target]!.length}</d:getcontentlength>');
      }
      final DateTime? time = modified[target];
      if (time != null) {
        body.write('<d:getlastmodified>${HttpDate.format(time)}</d:getlastmodified>');
      }
      body.write('</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>');
    }
    body.write('</d:multistatus>');
    final List<int> bytes = utf8.encode(body.toString());
    request.response.statusCode = 207;
    request.response.headers.contentType = ContentType('application', 'xml');
    request.response.headers.contentLength = bytes.length;
    request.response.add(bytes);
    await request.response.close();
  }

  Future<void> _get(HttpRequest request, String path) async {
    final List<int>? data = files[path];
    if (data == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final String? range = request.headers.value(HttpHeaders.rangeHeader);
    if (ignoreRange || range == null) {
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentLength = data.length;
      request.response.add(data);
      await request.response.close();
      return;
    }
    final RegExpMatch? match = RegExp(
      r'bytes=(\d+)-(\d*)',
    ).firstMatch(range);
    final int start = int.parse(match!.group(1)!);
    final int end = match.group(2)!.isEmpty
        ? data.length - 1
        : int.parse(match.group(2)!);
    final List<int> slice = data.sublist(start, end + 1);
    request.response.statusCode = HttpStatus.partialContent;
    request.response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes $start-$end/${data.length}',
    );
    request.response.headers.contentLength = slice.length;
    request.response.add(slice);
    await request.response.close();
  }

  bool _isFolder(String path) {
    if (path == '/dav' || path == '/dav/Music') return true;
    return files.keys.any((String file) => file.startsWith('$path/'));
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
  late _DavServer server;
  late WebDavSourceClient client;

  setUp(() async {
    server = _DavServer();
    await server.start();
    client = WebDavSourceClient(baseUri: server.base);
  });

  tearDown(() async {
    await client.close();
    await server.close();
  });

  test('lists a collection relative to the configured base', () async {
    final RemoteListing listing = await client.list('/Music');
    expect(listing.path, '/Music');
    expect(
      listing.entries.map((RemoteEntry entry) => entry.name),
      <String>['song one.flac', '中文歌.mp3'],
    );
    final RemoteEntry song = listing.entries.first;
    expect(song.path, '/Music/song one.flac');
    expect(song.isDirectory, isFalse);
    expect(song.size, 64);
    expect(song.isAudio, isTrue);
    expect(
      song.modifiedAt!.toUtc(),
      DateTime.utc(2024, 5, 6, 7, 8, 9),
    );
  });

  test('a missing path is null from stat and an error from list', () async {
    expect(await client.stat('/nope'), isNull);
    await expectLater(
      client.list('/nope'),
      throwsA(
        isA<RemoteFailure>().having(
          (RemoteFailure failure) => failure.kind,
          'kind',
          RemoteFailureKind.notFound,
        ),
      ),
    );
  });

  test('ranges are forwarded and the total size comes from the response', () async {
    final RemoteRead read = await client.open(
      '/Music/song one.flac',
      start: 8,
      end: 15,
    );
    expect(read.totalBytes, 64);
    expect(await _collect(read.bytes), <int>[
      for (int i = 8; i <= 15; i++) i,
    ]);
    await read.close();
  });

  test('a server ignoring Range still yields the requested slice', () async {
    server.ignoreRange = true;
    final RemoteRead read = await client.open(
      '/Music/song one.flac',
      start: 4,
      end: 9,
    );
    expect(read.totalBytes, 64);
    expect(await _collect(read.bytes), <int>[4, 5, 6, 7, 8, 9]);
    await read.close();
  });

  test('credentials are sent and a refusal maps to auth', () async {
    server.requireAuth = true;
    final WebDavSourceClient anonymous = WebDavSourceClient(
      baseUri: server.base,
    );
    await expectLater(
      anonymous.list('/Music'),
      throwsA(
        isA<RemoteFailure>().having(
          (RemoteFailure failure) => failure.kind,
          'kind',
          RemoteFailureKind.auth,
        ),
      ),
    );
    await anonymous.close();
    final WebDavSourceClient authenticated = WebDavSourceClient(
      baseUri: server.base,
      username: 'user',
      password: 'pass',
    );
    expect((await authenticated.list('/Music')).entries, isNotEmpty);
    await authenticated.close();
  });

  test('a 301 on a collection is followed like a browser would', () async {
    server.redirectCollections = true;
    final RemoteListing listing = await client.list('/Music');
    expect(listing.entries, isNotEmpty);
    expect(listing.entries.first.name, 'song one.flac');
  });

  test('urlFor and relativePathFor agree', () {
    final Uri url = client.urlFor('/Music/中文 歌.mp3');
    expect(url.pathSegments.last, '中文 歌.mp3');
    expect(client.relativePathFor(url), '/Music/中文 歌.mp3');
  });
}
