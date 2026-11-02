import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/cache/disk_cache.dart';
import 'package:lazer_nextgen/cache/media_cache.dart';
import 'package:lazer_nextgen/widgets/artwork_image.dart';

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

class _NetworkHttpOverrides extends HttpOverrides {}

Future<void> _imageFile(File file, int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawPaint(ui.Paint()..color = const ui.Color(0xffb4465a));
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    await file.writeAsBytes(bytes.buffer.asUint8List());
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Future<ui.Image> _decode(ArtworkImage provider) {
  final result = Completer<ui.Image>();
  final stream = provider.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener((info, _) {
    result.complete(info.image.clone());
    info.dispose();
    stream.removeListener(listener);
  }, onError: result.completeError);
  stream.addListener(listener);
  return result.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lazer-artwork-memory-');
  });
  tearDown(() => directory.delete(recursive: true));

  test('thumbnail decodes preserve crop detail and never upscale', () async {
    for (final (width, height, expectedWidth, expectedHeight) in [
      (2048, 1024, 192, 96),
      (1024, 2048, 96, 192),
      (2048, 2048, 96, 96),
      (32, 16, 32, 16),
      (2048, 1, 384, 1),
      (1, 2048, 1, 384),
    ]) {
      final file = File('${directory.path}/$width-$height.png');
      await _imageFile(file, width, height);
      final provider = ArtworkImage.forSize(
        file.uri.toString(),
        logicalEdge: 44,
        devicePixelRatio: 2,
      );
      final image = await _decode(provider);
      expect((image.width, image.height), (expectedWidth, expectedHeight));
      image.dispose();
      await provider.evict();
    }
  });

  test('panoramic artwork cannot bypass the thumbnail decode budget', () async {
    for (final (width, height) in [(8192, 256), (256, 8192)]) {
      final file = File('${directory.path}/panorama-$width-$height.png');
      await _imageFile(file, width, height);
      final provider = ArtworkImage.forSize(
        file.uri.toString(),
        logicalEdge: 44,
        devicePixelRatio: 2,
      );
      final image = await _decode(provider);
      try {
        expect(
          image.width * image.height,
          lessThanOrEqualTo(4 * 96 * 96),
          reason: 'a thin original must not retain a full-width decode',
        );
        expect(image.width, lessThanOrEqualTo(4 * 96));
        expect(image.height, lessThanOrEqualTo(4 * 96));
        expect(image.width / image.height, closeTo(width / height, .001));
      } finally {
        image.dispose();
        await provider.evict();
      }
    }
  });

  test('nearby thumbnail sizes share one decoded cache entry', () async {
    final cache = PaintingBinding.instance.imageCache;
    cache.clear();
    cache.clearLiveImages();
    addTearDown(cache.clear);
    addTearDown(cache.clearLiveImages);
    final file = File('${directory.path}/large-cover.png');
    await _imageFile(file, 2048, 2048);
    final first = ArtworkImage.forSize(file.uri.toString(), logicalEdge: 80);
    final nearby = ArtworkImage.forSize(file.uri.toString(), logicalEdge: 90);
    expect(first, nearby);
    expect(
      ArtworkImage.forSize(file.uri.toString(), logicalEdge: 120),
      isNot(first),
      reason: 'larger display requirements have a distinct decode',
    );
    final initial = await _decode(first);
    final second = await _decode(nearby);
    try {
      expect((initial.width, initial.height), (96, 96));
      expect((second.width, second.height), (96, 96));
      expect(cache.currentSize, 1);
      expect(cache.currentSizeBytes, 96 * 96 * 4);
      expect(cache.currentSizeBytes, lessThan(2048 * 2048 * 4 ~/ 400));
    } finally {
      initial.dispose();
      second.dispose();
    }
  });

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
    final buffer = await HttpOverrides.runWithHttpOverrides(
      () => cache.buffer('https://example.com/missing.jpg'),
      _NetworkHttpOverrides(),
    );
    expect(buffer.length, 4);
    buffer.dispose();
    expect(requests, 1, reason: 'an unavailable disk must not download twice');
  });
}
