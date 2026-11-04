// The random-access half of "seek anywhere": a byte range requested ahead of the
// sequential download must land in the cache file, be reported as readable, and
// leave the sequential download able to carry on.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/native/audio_stream_cache.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lazer-window-test');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('a requested range lands ahead of the sequential download', () async {
    final Uint8List payload = Uint8List.fromList(
      List<int>.generate(256 * 1024, (int i) => i & 0xff),
    );
    final List<String?> ranges = <String?>[];
    final Completer<void> hold = Completer<void>();
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    server.listen((HttpRequest request) async {
      final String? range = request.headers.value(HttpHeaders.rangeHeader);
      ranges.add(range);
      if (range == null) {
        // The sequential download: first quarter only, then held open so the
        // file stays short.
        final int end = payload.length ~/ 4;
        request.response.contentLength = payload.length;
        request.response.bufferOutput = false;
        request.response.add(payload.sublist(0, end));
        await request.response.flush();
        await hold.future;
        request.response.add(payload.sublist(end));
        await request.response.close();
        return;
      }
      final int start = int.parse(
        RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!,
      );
      final int end = payload.length;
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-${payload.length - 1}/${payload.length}',
      );
      request.response.contentLength = end - start;
      request.response.add(payload.sublist(start, end));
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));
    addTearDown(() {
      if (!hold.isCompleted) hold.complete();
    });

    final AudioStreamCache cache = AudioStreamCache(() async => root);
    addTearDown(cache.close);
    final AudioStreamEntry entry = await cache.open(
      'http://127.0.0.1:${server.port}/a.mp3',
      expectedBytes: payload.length,
    );
    final int prefix = payload.length ~/ 4;
    for (var i = 0; i < 100 && entry.sequentialBytes < prefix; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(entry.complete, isFalse);

    // Where a seek would send the decoder: past everything that has landed.
    const int wanted = 192 * 1024;
    expect(entry.downloadedBytes, lessThan(wanted));

    final int landed = await cache.fetchAhead(
      entry,
      wanted,
      maxBytes: 64 * 1024,
    );
    expect(landed, payload.length - wanted);
    expect(
      ranges.last,
      'bytes=$wanted-${payload.length - 1}',
      reason: 'the fetch asks for exactly the region the decoder wants',
    );
    expect(
      entry.downloadedBytes,
      greaterThanOrEqualTo(payload.length),
      reason: 'the range is reported readable as soon as it lands',
    );

    // The bytes really are in the file at the right offset.
    final Uint8List fileBytes = await entry.file.readAsBytes();
    expect(
      fileBytes.sublist(wanted),
      payload.sublist(wanted),
      reason: 'the fetched region is byte-identical, at the right offset',
    );
    expect(
      fileBytes.sublist(0, prefix),
      payload.sublist(0, prefix),
      reason: 'the sequential prefix is untouched',
    );

    // And the sequential download still works after a random-access write.
    hold.complete();
    await entry.done;
    expect(entry.complete, isTrue);
    expect(await entry.file.length(), payload.length);
  });

  test('a server that ignores the range is refused rather than corrupting', () async {
    final Uint8List payload = Uint8List.fromList(
      List<int>.generate(32 * 1024, (int i) => i & 0xff),
    );
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    server.listen((HttpRequest request) async {
      // Always a full 200 body, even for a range request.
      request.response.statusCode = HttpStatus.ok;
      request.response.contentLength = payload.length;
      request.response.add(payload);
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));

    final AudioStreamCache cache = AudioStreamCache(() async => root);
    addTearDown(cache.close);
    final AudioStreamEntry entry = await cache.open(
      'http://127.0.0.1:${server.port}/b.mp3',
      expectedBytes: payload.length,
    );
    await entry.done;

    final int landed = await cache.fetchAhead(entry, 4096, maxBytes: 4096);
    expect(landed, 0, reason: 'a body from zero must not be written at offset');
    final Uint8List bytes = await entry.file.readAsBytes();
    expect(bytes.length, payload.length);
    expect(bytes.sublist(0, 16), payload.sublist(0, 16));
  });
}
