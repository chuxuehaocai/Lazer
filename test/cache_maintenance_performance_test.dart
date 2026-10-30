import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/cache/disk_cache.dart';

final class _CountingIo extends IOOverrides {
  int scans = 0;
  int stats = 0;
  Completer<void>? scanStarted;
  Completer<void>? resumeScan;

  @override
  Directory createDirectory(String path) =>
      _Directory(super.createDirectory(path), this);
}

class _Directory implements Directory {
  _Directory(this.original, this.io);
  final Directory original;
  final _CountingIo io;

  @override
  String get path => original.path;

  @override
  Future<Directory> create({bool recursive = false}) async {
    await original.create(recursive: recursive);
    return this;
  }

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) async* {
    io.scans++;
    if (io.scans == 1 && io.scanStarted != null) {
      io.scanStarted!.complete();
      await io.resumeScan!.future;
    }
    yield* original
        .list(recursive: recursive, followLinks: followLinks)
        .map((entry) => entry is File ? _File(entry, io) : entry);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _File implements File {
  _File(this.original, this.io);
  final File original;
  final _CountingIo io;

  @override
  String get path => original.path;

  @override
  Uri get uri => original.uri;

  @override
  Future<FileStat> stat() {
    io.stats++;
    return original.stat();
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      original.delete(recursive: recursive);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'a write during maintenance triggers a follow-up and keeps the newest file',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lazer-cache-maintenance-race-',
      );
      addTearDown(() => root.delete(recursive: true));
      final io = _CountingIo()
        ..scanStarted = Completer<void>()
        ..resumeScan = Completer<void>();
      final cache = DiskCache(
        directory: () async => root,
        limits: {CacheBucket.artwork: 2048},
      );
      await IOOverrides.runWithIOOverrides(() async {
        await cache.put(
          CacheBucket.artwork,
          'first',
          () => Stream.value(List<int>.filled(1024, 1)),
        );
        await io.scanStarted!.future;
        try {
          for (var i = 0; i < 4; i++) {
            await cache.put(
              CacheBucket.artwork,
              'later-$i',
              () => Stream.value(List<int>.filled(1024, i)),
            );
          }
        } finally {
          io.resumeScan!.complete();
        }
        await cache.settle();
      }, io);
      expect(io.scans, 2);
      expect(await cache.find(CacheBucket.artwork, 'later-3'), isNotNull);
      final files = await Directory('${root.path}/artwork').list().toList();
      var bytes = 0;
      for (final file in files) {
        bytes += (await file.stat()).size;
      }
      expect(bytes, lessThanOrEqualTo(2048));
    },
  );

  test('profiles a burst of covers without retaining a scan per write', () async {
    final root = await Directory.systemTemp.createTemp(
      'lazer-cache-maintenance-',
    );
    addTearDown(() => root.delete(recursive: true));
    final io = _CountingIo();
    final cache = DiskCache(
      directory: () async => root,
      limits: {CacheBucket.artwork: 32 * 1024},
    );
    final watch = Stopwatch()..start();
    await IOOverrides.runWithIOOverrides(() async {
      await Future.wait([
        for (var i = 0; i < 80; i++)
          cache.put(
            CacheBucket.artwork,
            'cover-$i',
            () => Stream.value(List<int>.filled(1024, i)),
          ),
      ]);
      await cache.settle();
    }, io);
    final result = {
      'writes': 80,
      'scans': io.scans,
      'file_stats': io.stats,
      'total_ms': watch.elapsedMicroseconds / 1000,
    };
    // ignore: avoid_print
    print('CACHE_MAINTENANCE_PROFILE ${jsonEncode(result)}');
    const output = String.fromEnvironment('CACHE_PROFILE_OUTPUT');
    if (output.isNotEmpty) await File(output).writeAsString(jsonEncode(result));
    final files = await Directory(
      '${root.path}/artwork',
    ).list().where((entry) => !entry.path.endsWith('.part')).toList();
    var bytes = 0;
    for (final file in files) {
      bytes += (await file.stat()).size;
    }
    expect(bytes, lessThanOrEqualTo(32 * 1024));
    expect(
      io.scans,
      lessThan(10),
      reason:
          'a cover burst shares maintenance instead of scanning once per write',
    );
  });
}
