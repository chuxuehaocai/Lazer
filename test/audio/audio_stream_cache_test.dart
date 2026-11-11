// CI wrapper for the audio cache checks.
//
// The scenarios themselves live in `tool/native/cache_checks.dart` so they also
// run without a Flutter toolchain (`dart tool/native_cache_check.dart`) on hosts
// that cannot build the app, which is how the download logic was verified while
// the engine itself was still uncompiled.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/native/audio_stream_cache.dart';

import '../../tool/native/cache_checks.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lazer-cache-test');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('the streaming cache downloads, resumes and reports failures', () async {
    expect(await verifyAudioStreamCache(root), isEmpty);
  });

  test(
    'late readers receive completion instead of waiting for another chunk',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final body = [1, 2, 3, 4];
      server.listen((request) async {
        request.response
          ..contentLength = body.length
          ..add(body);
        await request.response.close();
      });
      final cache = AudioStreamCache(() async => root);
      addTearDown(cache.close);
      addTearDown(() => server.close(force: true));
      final entry = await cache.open(
        'http://127.0.0.1:${server.port}/complete',
      );
      await entry.done;
      var appends = 0;
      final finished = <bool>[];
      entry.bindReader(appended: () => appends++, finished: finished.add);
      expect(appends, 1);
      expect(finished, [false]);
      final cancelled = AudioStreamEntry(
        url: 'unused',
        file: entry.file,
        key: 1,
      )..cancel();
      cancelled.bindReader(appended: () {}, finished: finished.add);
      expect(finished, [false, true]);
    },
  );

  test('a server that never sends headers fails the download', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // Accept the connection and the request, then never answer. The connect
    // timeout does not cover this: the socket is up, so without a header
    // deadline the entry stays "busy" with failure == null forever, which is
    // exactly the state the engine's stall recovery cannot escape.
    server.listen((request) {});
    final cache = AudioStreamCache(
      () async => root,
      responseHeaderTimeout: const Duration(milliseconds: 300),
    );
    addTearDown(cache.close);
    addTearDown(() => server.close(force: true));
    final entry = await cache.open('http://127.0.0.1:${server.port}/silent');
    await entry.done.timeout(const Duration(seconds: 5));
    expect(entry.failure, isA<TimeoutException>());
    expect(entry.complete, isFalse);
  });
}
