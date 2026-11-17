import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/native/audio_stream_cache.dart';

class _CanceledRequest implements HttpClientRequest {
  final _done = Completer<HttpClientResponse>();

  @override
  Future<HttpClientResponse> get done => _done.future;

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    if (!_done.isCompleted) {
      _done.completeError(
        exception ?? const HttpException('request aborted'),
        stackTrace,
      );
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HeldConnectClient implements HttpClient {
  final HttpClientRequest request = _CanceledRequest();
  final ready = Completer<void>();
  final release = Completer<void>();

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    ready.complete();
    await release.future;
    return request;
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory root;
  setUp(
    () async =>
        root = await Directory.systemTemp.createTemp('lazer-stream-cache-'),
  );
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'cancel after headers stops a stalled body without waiting for idle timeout',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.bufferOutput = false;
        request.response.contentLength = 1024;
        request.response.add([1, 2, 3, 4]);
        await request.response.flush();
      });
      final cache = AudioStreamCache(() async => root);
      try {
        final entry = await cache.open(
          'http://${server.address.host}:${server.port}/body',
        );
        final appended = Completer<void>();
        entry.onAppended = () {
          if (!appended.isCompleted) appended.complete();
        };
        if (entry.downloadedBytes == 0) await appended.future;
        entry.cancel();
        await entry.done.timeout(const Duration(seconds: 2));
        expect(entry.cancelled, isTrue);
        expect(entry.failure, isNull);
        await entry.file.delete();
      } finally {
        cache.close();
        await server.close(force: true);
      }
    },
  );

  test('concurrent same URL opens share the entry and request', () async {
    final directory = Completer<Directory>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    server.listen((request) async {
      requests++;
      request.response.add([1, 2, 3, 4]);
      await request.response.close();
    });
    final cache = AudioStreamCache(() => directory.future);
    try {
      final url = 'http://${server.address.host}:${server.port}/same';
      final first = cache.open(url);
      final second = cache.open(url);
      expect(identical(first, second), isTrue);
      directory.complete(root);
      final entries = await Future.wait([first, second]);
      expect(identical(entries[0], entries[1]), isTrue);
      await entries[0].done;
      expect(requests, 1);
      expect(await entries[0].file.readAsBytes(), [1, 2, 3, 4]);
    } finally {
      cache.close();
      await server.close(force: true);
    }
  });

  test('eviction preserves an audible growing-file reader', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.bufferOutput = false;
      request.response.contentLength = 1024;
      request.response.add([1, 2, 3, 4]);
      try {
        await request.response.flush();
      } catch (_) {}
    });
    final cache = AudioStreamCache(() async => root, maximumEntries: 2);
    try {
      final base = 'http://${server.address.host}:${server.port}';
      final reader = await cache.acquire('$base/audible');
      final audible = reader.entry;
      final appended = Completer<void>();
      final finished = <bool>[];
      reader.bindReader(
        appended: () {
          if (audible.downloadedBytes > 0 && !appended.isCompleted) {
            appended.complete();
          }
        },
        finished: finished.add,
      );
      await appended.future.timeout(const Duration(seconds: 2));
      await expectLater(
        cache.open('$base/audible', force: true),
        throwsStateError,
      );
      await cache.open('$base/next-1');
      await cache.open('$base/next-2');
      expect(audible.cancelled, isFalse);
      expect(finished, isEmpty);
      expect(await audible.file.exists(), isTrue);
      reader.release();
    } finally {
      cache.close();
      await server.close(force: true);
    }
  });

  test('full pinned cache rejects new work and force replacement', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    server.listen((request) async {
      requests++;
      request.response.add([1, 2, 3, 4]);
      await request.response.close();
    });
    final cache = AudioStreamCache(() async => root, maximumEntries: 2);
    try {
      final base = 'http://${server.address.host}:${server.port}';
      final first = await cache.acquire('$base/a');
      final second = await cache.acquire('$base/b');
      await Future.wait([first.entry.done, second.entry.done]);
      await expectLater(cache.open('$base/c'), throwsStateError);
      await expectLater(cache.open('$base/a', force: true), throwsStateError);
      expect(requests, 2);
      expect(await first.entry.file.readAsBytes(), [1, 2, 3, 4]);
      first.release();
      final third = await cache.open('$base/c');
      await third.done;
      expect(await first.entry.file.exists(), isFalse);
      expect(await second.entry.file.exists(), isTrue);
      second.release();
    } finally {
      cache.close();
      await server.close(force: true);
    }
  });

  test(
    'same URL reader leases receive independent terminal notifications',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final finish = Completer<void>();
      server.listen((request) async {
        request.response.bufferOutput = false;
        request.response.contentLength = 8;
        request.response.add([1, 2, 3, 4]);
        await request.response.flush();
        await finish.future;
        request.response.add([5, 6, 7, 8]);
        await request.response.close();
      });
      final cache = AudioStreamCache(() async => root, maximumEntries: 1);
      try {
        final url = 'http://${server.address.host}:${server.port}/shared';
        final first = await cache.acquire(url);
        final second = await cache.acquire(url);
        expect(identical(first.entry, second.entry), isTrue);
        final firstFinished = <bool>[];
        final secondFinished = <bool>[];
        first.bindReader(appended: () {}, finished: firstFinished.add);
        second.bindReader(appended: () {}, finished: secondFinished.add);
        first.release();
        first.release();
        expect(second.entry.leased, isTrue);
        expect(second.entry.cancelled, isFalse);
        finish.complete();
        await second.entry.done;
        expect(firstFinished, isEmpty);
        expect(secondFinished, [false]);
        second.release();
        expect(second.entry.leased, isFalse);
      } finally {
        if (!finish.isCompleted) finish.complete();
        cache.close();
        await server.close(force: true);
      }
    },
  );

  test('acquire pins before a queued eviction can run', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.add([1, 2, 3, 4]);
      await request.response.close();
    });
    final cache = AudioStreamCache(() async => root, maximumEntries: 2);
    try {
      final base = 'http://${server.address.host}:${server.port}';
      final acquiring = cache.acquire('$base/held');
      final other = cache.open('$base/other');
      final held = await acquiring;
      await other;
      await cache.open('$base/newest');
      expect(held.entry.cancelled, isFalse);
      expect(await held.entry.file.exists(), isTrue);
      held.release();
    } finally {
      cache.close();
      await server.close(force: true);
    }
  });

  test(
    'reader leases have a fixed limit and release restores capacity',
    () async {
      final file = await File('${root.path}/leased').writeAsBytes([1]);
      final entry = AudioStreamEntry(url: 'fixture', file: file, key: 1);
      final leases = [
        for (var i = 0; i < AudioStreamEntry.maximumReaders; i++)
          entry.retain(),
      ];
      expect(entry.retain, throwsStateError);
      leases.removeLast().release();
      final replacement = entry.retain();
      expect(entry.leased, isTrue);
      for (final lease in leases) {
        lease.release();
      }
      expect(entry.leased, isTrue);
      replacement.release();
      expect(entry.leased, isFalse);
    },
  );

  test('disk cache stays bounded across process lifetimes', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.add([1, 2, 3, 4]);
      await request.response.close();
    });
    final directory = await Directory('${root.path}/audio-cache').create();
    final unrelated = await File(
      '${directory.path}/keep.txt',
    ).writeAsString('keep');
    try {
      for (var i = 0; i < 12; i++) {
        final cache = AudioStreamCache(() async => root, maximumEntries: 2);
        try {
          final entry = await cache.open(
            'http://${server.address.host}:${server.port}/song-$i',
          );
          await entry.done;
          expect(entry.complete, isTrue);
          expect(await entry.file.exists(), isTrue);
          final files = await directory
              .list()
              .where((file) => file.path.endsWith('.audio'))
              .length;
          expect(files, lessThanOrEqualTo(2));
        } finally {
          cache.close();
        }
      }
      expect(await unrelated.readAsString(), 'keep');
    } finally {
      await server.close(force: true);
    }
  });

  test(
    'close during directory lookup rejects late open without a request',
    () async {
      final directory = Completer<Directory>();
      final entered = Completer<void>();
      final cache = AudioStreamCache(() {
        entered.complete();
        return directory.future;
      });
      final opening = cache.open('http://127.0.0.1:1/late');
      final rejected = expectLater(opening, throwsStateError);
      await entered.future;
      cache.close();
      directory.complete(root);
      await rejected;
      expect(await Directory('${root.path}/audio-cache').exists(), isFalse);
    },
  );

  test(
    'pending opens have a strict capacity and duplicate opens share slots',
    () async {
      final directory = Completer<Directory>();
      final cache = AudioStreamCache(() => directory.future, maximumEntries: 2);
      final first = cache.open('http://127.0.0.1:1/a');
      final duplicate = cache.open('http://127.0.0.1:1/a');
      final second = cache.open('http://127.0.0.1:1/b');
      final rejectedFirst = expectLater(first, throwsStateError);
      final rejectedSecond = expectLater(second, throwsStateError);
      expect(identical(first, duplicate), isTrue);
      await expectLater(cache.open('http://127.0.0.1:1/c'), throwsStateError);
      cache.close();
      directory.complete(root);
      await Future.wait([rejectedFirst, rejectedSecond]);
    },
  );

  test(
    'failed entry is retried without force and cache hits refresh eviction',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server.listen((request) async {
        requests++;
        if (requests == 1) {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          request.response.add([1, 2, 3]);
        }
        await request.response.close();
      });
      final cache = AudioStreamCache(() async => root, maximumEntries: 2);
      try {
        final base = 'http://${server.address.host}:${server.port}';
        final failed = await cache.open('$base/a');
        await failed.done;
        expect(failed.failure, isNotNull);
        final first = await cache.open('$base/a');
        await first.done;
        expect(first.complete, isTrue);
        final second = await cache.open('$base/b');
        await second.done;
        expect(identical(await cache.open('$base/a'), first), isTrue);
        final third = await cache.open('$base/c');
        await third.done;
        expect(await first.file.exists(), isTrue);
        expect(await second.file.exists(), isFalse);
      } finally {
        cache.close();
        await server.close(force: true);
      }
    },
  );

  test(
    'cancel aborts a response waiting for headers and settles its sink',
    () async {
      final received = Completer<void>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        if (!received.isCompleted) received.complete();
      });
      final cache = AudioStreamCache(() async => root);
      try {
        final entry = await cache.open(
          'http://${server.address.host}:${server.port}/held',
        );
        await received.future;
        entry.cancel();
        await entry.done.timeout(const Duration(seconds: 2));
        expect(entry.cancelled, isTrue);
        expect(entry.failure, isNull);
        // A cancelled entry must also wake a caller waiting for response length.
        expect(
          await entry.expectedLengthWithin(const Duration(seconds: 10)),
          isNull,
        );
        await entry.file.delete();
      } finally {
        cache.close();
        await server.close(force: true);
      }
    },
  );

  test(
    'cancel during connection setup observes the aborted response future',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = _HeldConnectClient();
      final cache = AudioStreamCache(() async => root, client: client);
      try {
        final entry = await cache.open(
          'http://${server.address.host}:${server.port}/connecting',
        );
        await client.ready.future;
        entry.cancel();
        client.release.complete();
        await entry.done.timeout(const Duration(seconds: 2));
        await Future<void>.delayed(Duration.zero);
        expect(entry.cancelled, isTrue);
        expect(entry.failure, isNull);
      } finally {
        if (!client.release.isCompleted) client.release.complete();
        cache.close();
        await server.close(force: true);
      }
    },
  );

  test(
    'range response with a mismatched offset cannot corrupt a partial file',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final range = request.headers.value(HttpHeaders.rangeHeader);
        request.response.contentLength = 4;
        if (range != null) {
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 0-3/8',
          );
        }
        request.response.add([1, 2, 3, 4]);
        await request.response.close();
      });
      final cache = AudioStreamCache(() async => root);
      try {
        final url = 'http://${server.address.host}:${server.port}/range';
        final initial = await cache.open(url);
        await initial.done;
        final resumed = await cache.open(url, force: true);
        await resumed.done;
        expect(resumed.complete, isFalse);
        expect(resumed.failure, isNotNull);
        expect(await resumed.file.readAsBytes(), [1, 2, 3, 4]);
      } finally {
        cache.close();
        await server.close(force: true);
      }
    },
  );
}
