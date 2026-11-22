import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/listening/listening_statistics.dart';

class _CountingTrack extends Track {
  _CountingTrack(String id, {super.localPath})
    : super(
        id: id,
        title: 'Song "$id"',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(minutes: 3),
        coverSeed: 7,
        coverUrl: 'https://images.test/$id.jpg',
      );

  int encodes = 0;

  @override
  Map<String, dynamic> toJson() {
    encodes++;
    return super.toJson();
  }
}

void main() {
  late DateTime now;
  late List<String> writes;
  String? stored;

  ListeningStatisticsController controller() => ListeningStatisticsController(
    now: () => now,
    read: () async => stored,
    write: (String raw) async {
      writes.add(raw);
      stored = raw;
    },
  );

  void listen(
    ListeningStatisticsController statistics,
    Track track, {
    int seconds = 2,
  }) {
    statistics.begin(track, Duration.zero);
    for (var second = 1; second <= seconds; second++) {
      now = now.add(const Duration(seconds: 1));
      statistics.sample(Duration(seconds: second));
    }
    statistics.end();
  }

  setUp(() {
    now = DateTime(2026, 11, 20, 10);
    writes = <String>[];
    stored = null;
  });

  test('a save keeps the version 1 snapshot schema', () async {
    final statistics = controller();
    addTearDown(statistics.dispose);
    await statistics.ready;
    final first = _CountingTrack('1', localPath: '/music/1.flac');
    final second = _CountingTrack('2');
    listen(statistics, first, seconds: 3);
    listen(statistics, second);
    statistics.begin(first, Duration.zero);
    now = now.add(const Duration(seconds: 1));
    statistics.sample(const Duration(seconds: 1));
    statistics.recordSkipTo(second);
    await statistics.flush();

    final hours = List<int>.filled(24, 0)..[10] = 6000;
    expect(jsonDecode(writes.last), <String, Object?>{
      'version': 1,
      'firstRecordedAt': DateTime(2026, 11, 20, 10).toIso8601String(),
      'tracks': <String, Object?>{
        '1': (Track.fromJson(first.toJson()).toJson())..remove('localPath'),
        '2': (Track.fromJson(second.toJson()).toJson())..remove('localPath'),
      },
      'days': <String, Object?>{
        '2026-11-20': <String, Object?>{
          'hours': hours,
          'tracks': <String, Object?>{
            '1': <int>[4000, 2, 1],
            '2': <int>[2000, 1, 0],
          },
        },
      },
    });
  });

  test('a save encodes only what changed since the previous one', () async {
    final statistics = controller();
    addTearDown(statistics.dispose);
    await statistics.ready;
    final tracks = <_CountingTrack>[
      for (var index = 0; index < 6; index++) _CountingTrack('$index'),
    ];
    for (final track in tracks) {
      listen(statistics, track);
    }
    await statistics.flush();
    expect(tracks.map((track) => track.encodes), everyElement(1));

    now = now.add(const Duration(days: 1));
    listen(statistics, tracks.first, seconds: 4);
    await statistics.flush();
    now = now.add(const Duration(days: 1));
    listen(statistics, tracks.last);
    await statistics.flush();
    expect(tracks.map((track) => track.encodes), everyElement(1));

    final saved = jsonDecode(writes.last) as Map<String, dynamic>;
    final days = saved['days'] as Map<String, dynamic>;
    expect(days.keys, <String>['2026-11-20', '2026-11-21', '2026-11-22']);
    expect((saved['tracks'] as Map<String, dynamic>).keys, <String>[
      for (final track in tracks) track.id,
    ]);
    expect(days['2026-11-20']['tracks']['0'], <int>[2000, 1, 0]);
    expect(days['2026-11-21']['tracks'], <String, Object?>{
      '0': <int>[4000, 1, 0],
    });
    expect(days['2026-11-22']['tracks'], <String, Object?>{
      '5': <int>[2000, 1, 0],
    });
  });

  test('a restored history is saved again with new listening', () async {
    final seed = controller();
    final first = _CountingTrack('1');
    final second = _CountingTrack('2');
    await seed.ready;
    listen(seed, first, seconds: 3);
    listen(seed, second);
    await seed.flush();
    seed.dispose();
    final String before = stored!;

    now = DateTime(2026, 11, 23, 23, 59, 59);
    final statistics = controller();
    addTearDown(statistics.dispose);
    await statistics.ready;
    final replayed = _CountingTrack('1');
    final added = _CountingTrack('3');
    listen(statistics, replayed);
    listen(statistics, added);
    await statistics.flush();

    final previous = jsonDecode(before) as Map<String, dynamic>;
    final saved = jsonDecode(stored!) as Map<String, dynamic>;
    expect(saved['firstRecordedAt'], previous['firstRecordedAt']);
    expect(saved['days']['2026-11-20'], previous['days']['2026-11-20']);
    expect(saved['tracks']['1'], previous['tracks']['1']);
    expect(saved['tracks']['2'], previous['tracks']['2']);
    expect(saved['tracks']['3']['title'], 'Song "3"');
    expect(saved['days']['2026-11-23']['tracks'], <String, Object?>{
      '1': <int>[1000, 0, 0],
    });
    expect(saved['days']['2026-11-24']['tracks'], <String, Object?>{
      '1': <int>[1000, 1, 0],
      '3': <int>[2000, 1, 0],
    });
    expect(replayed.encodes, 0);
    expect(added.encodes, 1);

    final reopened = controller();
    addTearDown(reopened.dispose);
    await reopened.ready;
    final total = reopened.snapshot(ListeningRange.allTime);
    expect(total.totalDuration, const Duration(seconds: 9));
    expect(total.playCount, 4);
    expect(total.mostPlayed.first.track.id, '1');
    expect(total.mostPlayed.first.playCount, 2);
  });

  test('a large history is encoded across turns and stays complete', () async {
    final statistics = controller();
    addTearDown(statistics.dispose);
    await statistics.ready;
    final tracks = <_CountingTrack>[
      for (var index = 0; index < 700; index++) _CountingTrack('$index'),
    ];
    for (final track in tracks) {
      listen(statistics, track, seconds: 1);
    }
    final Future<void> saving = statistics.flush();
    await Future<void>.delayed(Duration.zero);
    final late = _CountingTrack('late');
    listen(statistics, late, seconds: 1);
    await saving;
    await statistics.flush();

    final saved = jsonDecode(writes.last) as Map<String, dynamic>;
    expect((saved['tracks'] as Map).length, 701);
    expect((saved['days'] as Map).values.single['tracks']['late'], <int>[
      1000,
      1,
      0,
    ]);
    expect(tracks.map((track) => track.encodes), everyElement(1));
    expect(late.encodes, 1);
  });
}
