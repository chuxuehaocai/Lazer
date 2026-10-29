import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/cache/disk_cache.dart';
import 'package:lazer_nextgen/cache/media_cache.dart';

class _GatedJsonCache extends DiskCache {
  _GatedJsonCache(Directory directory)
    : super(directory: () async => directory);
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  bool gateFirst = true;
  @override
  Future<File?> put(
    CacheBucket bucket,
    String key,
    Stream<List<int>> Function() source, {
    String extension = 'bin',
    int? expectedLength,
    int? maxBytes,
  }) async {
    if (bucket == CacheBucket.data && key == 'race' && gateFirst) {
      gateFirst = false;
      started.complete();
      await release.future;
    }
    return super.put(
      bucket,
      key,
      source,
      extension: extension,
      expectedLength: expectedLength,
      maxBytes: maxBytes,
    );
  }
}

void main() {
  late Directory directory;
  late DiskCache cache;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lazer-cache-test-');
    cache = DiskCache(directory: () async => directory);
  });
  tearDown(() async => directory.delete(recursive: true));

  test(
    'partial, oversized and failed downloads never become cache hits',
    () async {
      expect(
        await cache.put(
          CacheBucket.audio,
          'short',
          () => Stream.value([1, 2]),
          expectedLength: 4,
        ),
        isNull,
      );
      expect(
        await cache.put(
          CacheBucket.audio,
          'large',
          () => Stream.value([1, 2, 3]),
          maxBytes: 2,
        ),
        isNull,
      );
      expect(
        await cache.put(
          CacheBucket.audio,
          'broken',
          () => Stream.error(const SocketException('interrupted')),
        ),
        isNull,
      );
      for (final key in ['short', 'large', 'broken']) {
        expect(await cache.find(CacheBucket.audio, key), isNull);
      }
      expect(
        await Directory('${directory.path}/audio').list().toList(),
        isEmpty,
      );
    },
  );

  test(
    'concurrent downloads share a writer and survive a new cache instance',
    () async {
      final chunks = StreamController<List<int>>();
      final first = cache.put(CacheBucket.audio, 'song', () => chunks.stream);
      final duplicate = cache.put(
        CacheBucket.audio,
        'song',
        () => throw StateError('duplicate writer'),
      );
      expect(identical(first, duplicate), isTrue);
      chunks.add([1, 2, 3]);
      await chunks.close();
      expect(await first, isNotNull);
      final restarted = DiskCache(directory: () async => directory);
      expect(
        await (await restarted.find(CacheBucket.audio, 'song'))!.readAsBytes(),
        [1, 2, 3],
      );
    },
  );

  test('LRU removes older files and retains recently read files', () async {
    cache = DiskCache(
      directory: () async => directory,
      limits: {CacheBucket.audio: 6},
    );
    final old = (await cache.put(
      CacheBucket.audio,
      'old',
      () => Stream.value([1, 2, 3]),
    ))!;
    final recent = (await cache.put(
      CacheBucket.audio,
      'recent',
      () => Stream.value([4, 5, 6]),
    ))!;
    await old.setLastModified(DateTime(2020));
    await recent.setLastModified(DateTime(2021));
    await cache.find(CacheBucket.audio, 'recent');
    await cache.put(CacheBucket.audio, 'new', () => Stream.value([7, 8, 9]));
    // Pruning runs after the write returns; wait for the shared LRU pass.
    await cache.settle();
    expect(await old.exists(), isFalse);
    expect(await recent.exists(), isTrue);
    expect(await cache.find(CacheBucket.audio, 'new'), isNotNull);
  });

  test('JSON expiry retains stale data and corrupt JSON is removed', () async {
    await cache.writeJson('playlist', {
      'tracks': ['1', '2'],
    });
    expect(
      (await cache.readJson('playlist'))!.fresh(const Duration(minutes: 10)),
      isTrue,
    );
    await cache.expireJson('playlist');
    final stale = (await cache.readJson('playlist'))!;
    expect(stale.fresh(const Duration(minutes: 10)), isFalse);
    expect(stale.data['tracks'], ['1', '2']);
    final file = (await cache.find(
      CacheBucket.data,
      'playlist',
      extension: 'json',
    ))!;
    await file.writeAsString('{broken');
    expect(await cache.readJson('playlist'), isNull);
    expect(await file.exists(), isFalse);
  });

  test(
    'invalidation waits for an in-flight JSON write and survives restart',
    () async {
      final gated = _GatedJsonCache(directory);
      final first = gated.writeJson('race', {
        'tracks': List<String>.generate(10000, (i) => 'song-$i'),
      });
      await gated.started.future;
      final expire = gated.expireJson('race');
      gated.release.complete();
      await Future.wait([first, expire]);
      final restarted = DiskCache(directory: () async => directory);
      final saved = await restarted.readJson('race');
      expect(saved?.invalidated, isTrue);
      expect((saved!.data['tracks'] as List), hasLength(10000));
      await restarted.writeJson('race', {
        'tracks': ['new'],
      });
      expect((await restarted.readJson('race'))?.data['tracks'], ['new']);
      await gated.settle();
      await restarted.settle();
    },
  );

  test('JSON removal follows an in-flight write for the same key', () async {
    final gated = _GatedJsonCache(directory);
    final write = gated.writeJson('race', {'old': true});
    await gated.started.future;
    final removal = gated.remove(CacheBucket.data, 'race', extension: 'json');
    gated.release.complete();
    await Future.wait([write, removal]);
    expect(await gated.readJson('race'), isNull);
    await gated.settle();
  });

  test(
    'queued JSON writes capture small and large data at call time',
    () async {
      for (final count in [1, 300]) {
        final gated = _GatedJsonCache(directory);
        final first = gated.writeJson('race', {'old': true});
        await gated.started.future;
        final entries = List<Map<String, dynamic>>.generate(
          count,
          (i) => {
            'name': 'original-$i',
            'nested': {'value': i},
          },
        );
        final write = gated.writeJson('race', {'tracks': entries});
        entries.first['name'] = 'mutated';
        (entries.first['nested'] as Map<String, dynamic>)['value'] = -1;
        entries.add({'name': 'added'});
        gated.release.complete();
        await Future.wait([first, write]);
        final saved = (await gated.readJson('race'))!.data['tracks'] as List;
        expect(saved, hasLength(count));
        expect(saved.first['name'], 'original-0');
        expect(saved.first['nested']['value'], 0);
        await gated.settle();
      }
    },
  );

  test('an invalid JSON write fails without blocking later writes', () async {
    final cyclic = <String, dynamic>{};
    cyclic['self'] = cyclic;
    await expectLater(cache.writeJson('cycle', cyclic), throwsA(isA<Error>()));
    await cache.writeJson('cycle', {'ok': true});
    expect((await cache.readJson('cycle'))?.data['ok'], true);
    await cache.settle();
  });

  test('unwritable cache fails quietly', () async {
    final blocked = File('${directory.path}/blocked');
    await blocked.writeAsString('file, not a directory');
    final unavailable = DiskCache(
      directory: () async => Directory(blocked.path),
    );
    expect(await unavailable.find(CacheBucket.audio, 'song'), isNull);
    expect(
      await unavailable.put(CacheBucket.audio, 'song', () => Stream.value([1])),
      isNull,
    );
  });

  test(
    'audio cache coalesces downloads, keeps format and works offline',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.headers.contentType = ContentType('audio', 'flac');
        request.response.contentLength = 4;
        request.response.add([102, 76, 97, 67]);
        await request.response.close();
      });
      final audio = AudioCache(disk: cache);
      final url = 'http://${server.address.host}:${server.port}/song.flac';
      final files = await Future.wait([
        audio.store('42', url, format: 'flac'),
        audio.store('42', url),
      ]);
      expect(files.first!.path, endsWith('.flac'));
      expect(files.last!.path, files.first!.path);
      expect(requests, 1);
      await server.close(force: true);
      final restarted = AudioCache(
        disk: DiskCache(directory: () async => directory),
      );
      final offline = await restarted.store('42', url);
      expect(await offline!.readAsBytes(), [102, 76, 97, 67]);
    },
  );

  test(
    'artwork bytes and media files share the persistent store and CDN headers',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      String? agent;
      String? referer;
      server.listen((request) async {
        requests++;
        agent = request.headers.value(HttpHeaders.userAgentHeader);
        referer = request.headers.value(HttpHeaders.refererHeader);
        request.response.add([137, 80, 78, 71]);
        await request.response.close();
      });
      final source = 'http://${server.address.host}:${server.port}/cover';
      const artworkUrl = 'https://p1.music.126.net/real-cover.jpg';
      final artwork = ArtworkCache(disk: cache, candidates: (_) => [source]);
      final result = await Future.wait([
        artwork.bytes(artworkUrl),
        artwork.bytes(artworkUrl),
      ]);
      expect(result.first, [137, 80, 78, 71]);
      expect(requests, 1);
      expect(agent, 'LazerDesktop/1.0');
      expect(referer, 'https://music.163.com/');
      await server.close(force: true);
      final restarted = ArtworkCache(
        disk: DiskCache(directory: () async => directory),
      );
      final file = await restarted.file(artworkUrl);
      expect(await file!.readAsBytes(), result.first);
      expect(requests, 1);
    },
  );

  test(
    'artwork tries the next candidate after a CDN rejection and caches the result',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final paths = <String>[];
      server.listen((request) async {
        paths.add(request.uri.path);
        if (request.uri.path == '/rejected') {
          request.response.statusCode = HttpStatus.forbidden;
        } else {
          request.response.add([137, 80, 78, 71]);
        }
        await request.response.close();
      });
      final base = 'http://${server.address.host}:${server.port}';
      final artwork = ArtworkCache(
        disk: cache,
        candidates: (_) => ['$base/rejected', '$base/original'],
      );
      const url = 'https://p1.music.126.net/fallback.jpg';
      expect(await artwork.bytes(url), [137, 80, 78, 71]);
      expect(paths, ['/rejected', '/original']);
      expect(await artwork.bytes(url), [137, 80, 78, 71]);
      expect(paths.length, 2);
      await server.close(force: true);
    },
  );
}
