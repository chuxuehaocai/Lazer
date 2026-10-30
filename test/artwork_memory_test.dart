import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/cache/disk_cache.dart';
import 'package:lazer_nextgen/cache/media_cache.dart';

class _TrackedFile implements File {
  _TrackedFile(this.original);
  final File original;
  int byteReads = 0;

  @override
  String get path => original.path;

  @override
  Future<Uint8List> readAsBytes() {
    byteReads++;
    return original.readAsBytes();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HitCache extends DiskCache {
  _HitCache(this.hit);
  final File hit;

  @override
  Future<File?> find(
    CacheBucket bucket,
    String key, {
    String extension = 'bin',
  }) async => hit;
}

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lazer-artwork-memory-');
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'warm image buffers and file lookups never read a Dart byte array',
    () async {
      final original = await File(
        '${directory.path}/cover.bin',
      ).writeAsBytes(List<int>.filled(1024 * 1024, 42));
      final tracked = _TrackedFile(original);
      final cache = ArtworkCache(disk: _HitCache(tracked));
      const url = 'https://example.com/cover.jpg';
      final buffer = await cache.buffer(url);
      expect(buffer.length, 1024 * 1024);
      buffer.dispose();
      expect(await cache.file(url), same(tracked));
      expect(tracked.byteReads, 0);
      expect((await cache.bytes(url)).length, 1024 * 1024);
      expect(
        tracked.byteReads,
        1,
        reason: 'export still receives encoded bytes',
      );
    },
  );

  test(
    'local artwork opens an engine buffer without a network request',
    () async {
      final original = await File(
        '${directory.path}/local.bin',
      ).writeAsBytes([1, 2, 3, 4]);
      final cache = ArtworkCache(
        candidates: (_) => throw StateError('network used'),
      );
      final buffer = await cache.buffer(original.uri.toString());
      expect(buffer.length, 4);
      buffer.dispose();
      expect((await cache.file(original.uri.toString()))?.uri, original.uri);
    },
  );

  test('a cache miss still decodes when persistence is unavailable', () async {
    final blocker = await File(
      '${directory.path}/blocked',
    ).writeAsString('not a directory');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    server.listen((request) async {
      requests++;
      request.response.contentLength = 4;
      request.response.add([1, 2, 3, 4]);
      await request.response.close();
    });
    final cache = ArtworkCache(
      disk: DiskCache(directory: () async => Directory(blocker.path)),
      candidates: (_) => ['http://127.0.0.1:${server.port}/cover'],
    );
    final buffer = await cache.buffer('https://example.com/missing.jpg');
    expect(buffer.length, 4);
    buffer.dispose();
    expect(requests, 1, reason: 'an unavailable disk must not download twice');
  });
}
