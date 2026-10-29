import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/state/playback_queue_store.dart';
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
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'index changes reuse the encoded tracks and retain the existing schema',
    () async {
      var encodes = 0;
      final writes = <String>[];
      final store = PlaybackQueueStore(
        encode: (tracks) async {
          encodes++;
          return jsonEncode([
            for (final t in tracks) {'id': t.id},
          ]);
        },
        write: (value) async => writes.add(value),
      );
      final tracks = [track('1'), track('2')];
      await store.save(tracks, 0, 1);
      await store.save(tracks, 1, 1);
      expect(encodes, 1);
      expect(jsonDecode(writes.last), {
        'index': 1,
        'tracks': [
          {'id': '1'},
          {'id': '2'},
        ],
      });
      tracks.add(track('3'));
      await store.save(tracks, 2, 2);
      expect(encodes, 2);
      expect((jsonDecode(writes.last)['tracks'] as List).length, 3);
    },
  );

  test('coalesces stale encodes and writes the newest queue', () async {
    final gate = Completer<String>();
    final writes = <String>[];
    var encodes = 0;
    final store = PlaybackQueueStore(
      encode: (tracks) {
        encodes++;
        return encodes == 1
            ? gate.future
            : Future.value(
                jsonEncode([
                  for (final t in tracks) {'id': t.id},
                ]),
              );
      },
      write: (value) async => writes.add(value),
    );
    final first = store.save([track('old')], 0, 1);
    final latest = store.save([track('new'), track('next')], 1, 2);
    gate.complete('[{"id":"old"}]');
    await Future.wait([first, latest]);
    expect(encodes, 2);
    expect(writes, hasLength(1));
    expect(jsonDecode(writes.single), {
      'index': 1,
      'tracks': [
        {'id': 'new'},
        {'id': 'next'},
      ],
    });
  });

  test('a pending old write is followed by the latest index', () async {
    final gate = Completer<void>();
    final writes = <String>[];
    final store = PlaybackQueueStore(
      encode: (tracks) async => '[]',
      write: (value) async {
        writes.add(value);
        if (writes.length == 1) await gate.future;
      },
    );
    final first = store.save([], 0, 1);
    await Future<void>.delayed(Duration.zero);
    final latest = store.save([], 5, 1);
    gate.complete();
    await Future.wait([first, latest]);
    expect(writes.map((value) => jsonDecode(value)['index']), [0, 5]);
  });

  test(
    'large queues encode off thread and preserve their complete content',
    () async {
      final store = PlaybackQueueStore();
      await store.save(List<Track>.generate(1000, (i) => track('$i')), 999, 1);
      final prefs = await SharedPreferences.getInstance();
      final saved = jsonDecode(prefs.getString(playbackQueueKey)!);
      expect(saved['index'], 999);
      expect((saved['tracks'] as List), hasLength(1000));
      expect(saved['tracks'][999]['id'], '999');
    },
  );

  test('restores a large saved queue and handles corrupt data', () async {
    final store = PlaybackQueueStore();
    await store.save(
      List<Track>.generate(1000, (i) => track('${i + 1}')),
      750,
      1,
    );
    final restored = await store.load();
    expect(restored?.tracks, hasLength(1000));
    expect(restored?.index, 750);
    expect(restored?.tracks[750].title, 'Song 751');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(playbackQueueKey, '{not json');
    expect(await store.load(), isNull);
  });

  test('default encoder preserves metadata in preferences', () async {
    final store = PlaybackQueueStore();
    await store.save([track('10')], 0, 1);
    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(prefs.getString(playbackQueueKey)!);
    expect(saved['index'], 0);
    expect(saved['tracks'][0]['title'], 'Song 10');
    expect(saved['tracks'][0]['durationMs'], 180000);
  });
}
