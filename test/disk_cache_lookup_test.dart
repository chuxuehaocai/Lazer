import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/cache/disk_cache.dart';
import 'package:lazer_nextgen/cache/media_cache.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';

void main() {
  late Directory directory;
  late DiskCache disk;
  final DateTime stale = DateTime(2020);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lazer-cache-lookup-');
    disk = DiskCache(directory: () async => directory);
  });
  tearDown(() async {
    await disk.settle();
    await directory.delete(recursive: true);
  });

  Future<File> store(String key, String extension, {List<int>? bytes}) async {
    final File? file = await disk.put(
      CacheBucket.audio,
      key,
      () => Stream<List<int>>.value(bytes ?? <int>[1, 2, 3]),
      extension: extension,
    );
    await file!.setLastModified(stale);
    return file;
  }

  test('a miss and a removal do not create the bucket directory', () async {
    expect(await disk.find(CacheBucket.audio, 'missing'), isNull);
    expect(
      await disk.findFirst(CacheBucket.audio, 'missing', <String>[
        'mp3',
        'flac',
      ]),
      isNull,
    );
    await disk.remove(CacheBucket.artwork, 'missing');
    await disk.settle();
    expect(await directory.list().isEmpty, isTrue);
  });

  test('a hit returns the stored file and refreshes its recency', () async {
    final File stored = await store('song', 'mp3');
    final File? found = await disk.find(
      CacheBucket.audio,
      'song',
      extension: 'mp3',
    );
    expect(found!.path, stored.path);
    expect(await found.readAsBytes(), <int>[1, 2, 3]);
    expect((await found.lastModified()).isAfter(DateTime(2021)), isTrue);
    expect(
      await disk.find(CacheBucket.audio, 'song', extension: 'flac'),
      isNull,
    );
  });

  test('an empty file is not a cache hit', () async {
    final File stored = await store('song', 'mp3');
    await stored.writeAsBytes(const <int>[]);
    expect(
      await disk.find(CacheBucket.audio, 'song', extension: 'mp3'),
      isNull,
    );
    expect(
      await disk.findFirst(CacheBucket.audio, 'song', <String>['mp3']),
      isNull,
    );
  });

  test('the first listed format wins and only it is touched', () async {
    final File flac = await store('song', 'flac');
    final File mp3 = await store('song', 'mp3');
    final File? found = await disk.findFirst(
      CacheBucket.audio,
      'song',
      <String>['aac', 'mp3', 'flac'],
    );
    expect(found!.path, mp3.path);
    expect((await mp3.lastModified()).isAfter(DateTime(2021)), isTrue);
    expect((await flac.lastModified()).isBefore(DateTime(2021)), isTrue);
  });

  test('audio lookups keep their format and legacy-key rules', () async {
    final AudioCache audio = AudioCache(disk: disk);
    final File lossless = await store(
      AudioCache.cacheKey('track', AudioQuality.lossless),
      'flac',
    );
    final File legacy = await store('track', 'mp3');

    expect(
      (await audio.find('track', quality: AudioQuality.lossless))!.path,
      lossless.path,
    );
    expect(
      (await audio.find('track', quality: AudioQuality.exhigh))!.path,
      legacy.path,
    );
    expect(await audio.find('track', quality: AudioQuality.standard), isNull);
    expect((await audio.findAny('track'))!.path, lossless.path);
    expect(await audio.findAny('other'), isNull);
  });
}
