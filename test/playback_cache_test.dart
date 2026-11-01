import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/cache/disk_cache.dart';
import 'package:lazer_nextgen/cache/media_cache.dart';
import 'package:lazer_nextgen/cache/playback_cache.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/local/local_library.dart';
import 'package:shared_preferences/shared_preferences.dart';

Track track(String id) => Track(
  id: id,
  title: 'Song $id',
  artist: 'Artist',
  album: 'Album',
  duration: const Duration(minutes: 3),
  coverSeed: 1,
);

void main() {
  late Directory root;
  late DiskCache disk;
  late AudioCache audio;
  late LocalLibrary library;
  late PlaybackCacheController controller;
  late DateTime now;

  PlaybackCacheController createController() => PlaybackCacheController(
    audioCache: audio,
    library: library,
    supportDirectory: () async => Directory('${root.path}/support'),
    now: () => now,
  );

  Future<void> listen(String id, {bool createFile = true}) async {
    now = now.add(const Duration(minutes: 1));
    if (createFile) {
      await disk.put(
        CacheBucket.audio,
        AudioCache.cacheKey(id, AudioQuality.exhigh),
        () => Stream<List<int>>.value(<int>[1, 2, 3, 4]),
        extension: 'mp3',
      );
    }
    await controller.recordPlayed(track(id));
  }

  Set<String> cachedIds() => library.tracks
      .where((entry) => entry.isCache)
      .map((entry) => entry.id)
      .toSet();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    root = await Directory.systemTemp.createTemp('lazer-playback-cache-');
    now = DateTime.utc(2026, 11, 1);
    disk = DiskCache(directory: () async => Directory('${root.path}/cache'));
    audio = AudioCache(disk: disk);
    library = LocalLibrary(
      supportDirectory: () async => Directory('${root.path}/support'),
      documentsDirectory: () async => Directory('${root.path}/documents'),
    );
    controller = createController();
  });

  tearDown(() async {
    controller.dispose();
    library.dispose();
    await disk.settle();
    await root.delete(recursive: true);
  });

  test('defaults to 50 complete songs and evicts the oldest file', () async {
    for (int id = 1; id <= 51; id++) {
      await listen('$id');
    }
    expect(controller.maximumTracks, 50);
    expect(controller.mode, PlaybackCacheMode.recent);
    expect(controller.cachedCount, 50);
    expect(cachedIds(), isNot(contains('1')));
    expect(cachedIds(), contains('51'));
    expect(await audio.findAny('1'), isNull);
    final File? local = await library.localFileFor(track('51'));
    expect(local, isNotNull);
    expect(await local!.readAsBytes(), <int>[1, 2, 3, 4]);
  });

  test(
    'replaying a cached song refreshes LRU and preserves manual downloads',
    () async {
      await controller.setMaximumTracks(2);
      await listen('1');
      await listen('2');
      await listen('1', createFile: false);
      final File download = File('${root.path}/download.mp3');
      await download.writeAsBytes(<int>[8, 9]);
      await library.addTracks(<LocalTrack>[
        LocalTrack(
          track: track('999'),
          path: download.path,
          source: LocalTrackSource.download,
          modifiedAt: now,
          addedAt: now,
        ),
      ]);
      await listen('3');
      expect(cachedIds(), <String>{'1', '3'});
      expect(await audio.findAny('2'), isNull);
      await controller.clear();
      expect(cachedIds(), isEmpty);
      expect(library.tracks.single.id, '999');
      expect(await download.exists(), isTrue);
    },
  );

  test(
    'intelligent mode restores recent play counts across launches',
    () async {
      await controller.setMaximumTracks(2);
      await controller.setMode(PlaybackCacheMode.intelligent);
      await listen('1');
      await listen('1', createFile: false);
      await listen('2');
      controller.dispose();
      controller = createController();
      await controller.load();
      expect(controller.maximumTracks, 2);
      expect(controller.mode, PlaybackCacheMode.intelligent);
      await listen('3');
      expect(cachedIds(), <String>{'1', '3'});
      // Old favourites lose their frequency advantage after the recent window.
      now = now.add(const Duration(days: 31));
      await listen('4');
      expect(cachedIds(), <String>{'3', '4'});
    },
  );

  test('does not expose an in-progress or incomplete audio file', () async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final Completer<void> requested = Completer<void>();
    final Completer<void> finish = Completer<void>();
    server.listen((request) async {
      request.response.headers.contentType = ContentType('audio', 'mpeg');
      request.response.contentLength = 4;
      request.response.add(<int>[1, 2]);
      await request.response.flush();
      requested.complete();
      await finish.future;
      request.response.add(<int>[3, 4]);
      await request.response.close();
    });
    final Future<File?> download = audio.store(
      '1',
      'http://127.0.0.1:${server.port}/song.mp3',
    );
    final Future<void> playing = controller.recordPlayed(track('1'));
    await requested.future;
    expect(cachedIds(), isEmpty);
    finish.complete();
    await download;
    await playing;
    expect(cachedIds(), <String>{'1'});
    await server.close(force: true);
  });

  test(
    'switching quality keeps the replacement complete and playable',
    () async {
      await listen('1');
      final File old = (await audio.findAny('1'))!;
      await disk.put(
        CacheBucket.audio,
        AudioCache.cacheKey('1', AudioQuality.lossless),
        () => Stream.value(<int>[102, 76, 97, 67]),
        extension: 'flac',
      );
      await controller.recordPlayed(track('1'), quality: AudioQuality.lossless);
      expect(controller.cachedCount, 1);
      expect(library.tracks.single.quality, AudioQuality.lossless);
      final File replacement = (await library.localFileFor(track('1')))!;
      expect(replacement.path, endsWith('.flac'));
      expect(await replacement.readAsBytes(), <int>[102, 76, 97, 67]);

      // A previous decoder rendition is deleted after the source changes.
      await controller.recordPlayed(track('local:imported'));
      expect(await old.exists(), isFalse);
      expect(await replacement.exists(), isTrue);
    },
  );

  test('clearing an open song defers its file until local playback', () async {
    await listen('1');
    final File opened = (await audio.findAny('1'))!;
    await controller.clear();
    expect(cachedIds(), isEmpty);
    expect(await opened.exists(), isTrue);
    await controller.recordPlayed(track('local:imported'));
    expect(await opened.exists(), isFalse);
    expect(await audio.findAny('1'), isNull);
  });

  test(
    'deferred deletion is restored after restarting the controller',
    () async {
      await listen('1');
      final File opened = (await audio.findAny('1'))!;
      await controller.clear();
      controller.dispose();
      controller = createController();
      await controller.load();
      expect(await opened.exists(), isFalse);
      expect(cachedIds(), isEmpty);
    },
  );

  test('intelligent mode favours frequent songs over a new one', () async {
    await controller.setMaximumTracks(2);
    await controller.setMode(PlaybackCacheMode.intelligent);
    await listen('1');
    await listen('1', createFile: false);
    await listen('1', createFile: false);
    await listen('2');
    await listen('2', createFile: false);
    await listen('3');
    expect(cachedIds(), <String>{'1', '2'});
    final File opened = (await audio.findAny('3'))!;
    expect(await opened.exists(), isTrue);
    await controller.recordPlayed(track('local:imported'));
    expect(await opened.exists(), isFalse);
    expect(await library.localFileFor(track('1')), isNotNull);
    expect(await library.localFileFor(track('2')), isNotNull);
  });

  test('cache source survives the local-library manifest', () async {
    await listen('1');
    final LocalLibrary restored = LocalLibrary(
      supportDirectory: () async => Directory('${root.path}/support'),
      documentsDirectory: () async => Directory('${root.path}/documents'),
    );
    await restored.load();
    expect(restored.tracks.single.source, LocalTrackSource.cache);
    expect(await restored.localFileFor(track('1')), isNotNull);
    restored.dispose();
  });
}
