import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/cache/disk_cache.dart';
import 'package:lazer_nextgen/cache/media_cache.dart';
import 'package:lazer_nextgen/cache/playback_cache.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/local/local_library.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _CountingTrack extends Track {
  _CountingTrack(String id, {String title = 'Song'})
    : super(
        id: id,
        title: '$title "$id"',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(minutes: 3),
        coverSeed: 1,
      );

  int encodes = 0;

  @override
  Map<String, dynamic> toJson() {
    encodes++;
    return super.toJson();
  }
}

void main() {
  late Directory root;
  late DiskCache disk;
  late LocalLibrary library;
  late PlaybackCacheController controller;
  late DateTime now;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    root = await Directory.systemTemp.createTemp('lazer-playback-history-');
    now = DateTime.utc(2026, 11, 1);
    disk = DiskCache(directory: () async => Directory('${root.path}/cache'));
    library = LocalLibrary(
      supportDirectory: () async => Directory('${root.path}/support'),
      documentsDirectory: () async => Directory('${root.path}/documents'),
    );
    controller = PlaybackCacheController(
      audioCache: AudioCache(disk: disk),
      library: library,
      supportDirectory: () async => Directory('${root.path}/support'),
      now: () => now,
    );
  });

  tearDown(() async {
    controller.dispose();
    library.dispose();
    await disk.settle();
    await root.delete(recursive: true);
  });

  Future<Map<String, dynamic>> manifest() async =>
      jsonDecode(
            await File(
              '${root.path}/support/playback_cache.json',
            ).readAsString(),
          )
          as Map<String, dynamic>;

  test(
    'each song is encoded once however often the history is saved',
    () async {
      final tracks = <_CountingTrack>[
        for (var index = 1; index <= 6; index++) _CountingTrack('$index'),
      ];
      for (final track in tracks) {
        now = now.add(const Duration(minutes: 1));
        await controller.recordPlayed(track);
      }
      now = now.add(const Duration(minutes: 1));
      await controller.recordPlayed(tracks.first);
      await controller.flushHistory();
      expect(tracks.map((track) => track.encodes), everyElement(1));

      final saved = await manifest();
      expect(saved['version'], 1);
      expect(saved['pendingDeletes'], isEmpty);
      final history = saved['history'] as List<dynamic>;
      expect(history.map((entry) => entry['track']['id']), <String>[
        for (final track in tracks) track.id,
      ]);
      expect(
        history.first['track'],
        Track.fromJson(tracks.first.toJson()).toJson(),
      );
      expect(history.first['plays'], hasLength(2));
      expect(history.first['lastPlayed'], now.millisecondsSinceEpoch);
      expect(history[1]['plays'], hasLength(1));
    },
  );

  test('refreshed metadata for a song replaces its stored entry', () async {
    final original = _CountingTrack('1');
    await controller.recordPlayed(original);
    now = now.add(const Duration(minutes: 1));
    final renamed = _CountingTrack('1', title: 'Renamed');
    await controller.recordPlayed(renamed);
    await controller.flushHistory();

    final history = (await manifest())['history'] as List<dynamic>;
    expect(history.single['track']['title'], 'Renamed "1"');
    expect(renamed.encodes, 1);
  });
}
