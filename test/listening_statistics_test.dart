import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/listening/listening_statistics.dart';
import 'package:lazer_nextgen/storage/listening_statistics_store.dart';

const _first = Track(
  id: 'one',
  title: 'One',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 3),
  coverSeed: 1,
);
const _second = Track(
  id: 'two',
  title: 'Two',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 3),
  coverSeed: 2,
);

class _History {
  DateTime now = DateTime(2026, 11, 6, 13);
  String? stored;
  late final ListeningStatisticsController controller;

  _History({String? initial}) {
    stored = initial;
    controller = ListeningStatisticsController(
      now: () => now,
      read: () async => stored,
      write: (raw) async => stored = raw,
    );
    addTearDown(controller.dispose);
  }

  ListeningStatisticsSnapshot get all =>
      controller.snapshot(ListeningRange.allTime);

  void step(Duration elapsed, Duration position) {
    now = now.add(elapsed);
    controller.sample(position);
  }

  void play(Track track, {Duration duration = const Duration(seconds: 2)}) {
    controller.begin(track, Duration.zero);
    step(duration, duration);
    controller.end();
  }
}

void main() {
  test('loading, no progress, and failed selections record nothing', () async {
    final history = _History();
    await history.controller.ready;
    history.controller.begin(_first, Duration.zero);
    history.step(const Duration(seconds: 20), Duration.zero);
    history.controller.recordSkipTo(_second);
    history.controller.end();
    expect(history.all.totalDuration, Duration.zero);
    expect(history.all.playCount, 0);
    expect(history.all.skipCount, 0);
    expect(history.all.mostPlayed, isEmpty);
    expect(history.all.peakHour, isNull);
  });

  test('a short audible skip is counted before the play threshold', () async {
    final history = _History();
    await history.controller.ready;
    history.controller.begin(_first, Duration.zero);
    history.step(
      const Duration(milliseconds: 200),
      const Duration(milliseconds: 200),
    );
    history.controller.recordSkipTo(_second);
    history.controller.end();
    expect(history.all.totalDuration, const Duration(milliseconds: 200));
    expect(history.all.playCount, 0);
    expect(history.all.skipCount, 1);
    expect(history.all.mostSkipped.single.track.id, _first.id);
    expect(history.all.mostPlayed, isEmpty);
  });

  test(
    'pause, quality reload, and explicit seek preserve one qualified play',
    () async {
      final history = _History();
      await history.controller.ready;
      history.controller.begin(_first, Duration.zero);
      history.step(const Duration(seconds: 2), const Duration(seconds: 2));
      history.controller.suspend();
      history.step(const Duration(hours: 2), const Duration(seconds: 2));
      history.controller.begin(_first, const Duration(seconds: 2));
      history.step(const Duration(seconds: 1), const Duration(seconds: 3));
      history.controller.suspend();
      history.step(const Duration(seconds: 1), const Duration(minutes: 2));
      history.controller.rebase(const Duration(minutes: 2));
      history.step(
        const Duration(seconds: 1),
        const Duration(minutes: 2, seconds: 1),
      );
      expect(history.all.totalDuration, const Duration(seconds: 4));
      expect(history.all.playCount, 1);
      expect(history.all.skipCount, 0);
      history.controller.suspend();
      history.now = history.now.add(const Duration(hours: 4));
      history.controller.recordSkipTo(_second);
      expect(history.all.skipCount, 1);
    },
  );

  test(
    'buffering and unexpected jumps are excluded; background progress counts',
    () async {
      final history = _History();
      await history.controller.ready;
      history.controller.begin(_first, Duration.zero);
      history.step(const Duration(seconds: 1), const Duration(seconds: 50));
      history.step(const Duration(seconds: 1), const Duration(seconds: 51));
      history.step(const Duration(seconds: 20), const Duration(seconds: 51));
      history.step(const Duration(seconds: 60), const Duration(seconds: 111));
      history.step(const Duration(seconds: 1), const Duration(seconds: 10));
      expect(history.all.totalDuration, const Duration(seconds: 61));
      expect(history.all.playCount, 1);
      expect(history.all.skipCount, 0);
    },
  );

  test(
    'natural replay counts a new play without a skip; same song is not a skip',
    () async {
      final history = _History();
      await history.controller.ready;
      history.play(_first);
      history.controller.begin(_first, Duration.zero);
      history.step(const Duration(seconds: 2), const Duration(seconds: 2));
      history.controller.recordSkipTo(_first);
      history.controller.end();
      expect(history.all.playCount, 2);
      expect(history.all.totalDuration, const Duration(seconds: 4));
      expect(history.all.skipCount, 0);
    },
  );

  test('listening splits across local hours and midnight', () async {
    final history = _History();
    await history.controller.ready;
    history.now = DateTime(2026, 11, 5, 23, 59, 59, 500);
    history.play(_first);
    expect(history.all.hourlyDuration[23], const Duration(milliseconds: 500));
    expect(history.all.hourlyDuration[0], const Duration(milliseconds: 1500));
    expect(history.all.peakHour, 0);
    expect(
      history.controller.snapshot(ListeningRange.today).totalDuration,
      const Duration(milliseconds: 1500),
    );
    expect(history.all.firstRecordedAt, DateTime(2026, 11, 5, 23, 59, 59, 500));
  });

  test('date ranges use calendar days including today', () async {
    final history = _History();
    await history.controller.ready;
    for (final daysAgo in [0, 6, 7, 29, 30]) {
      history.now = DateTime(2026, 11, 6 - daysAgo, 12);
      history.play(_first);
    }
    history.now = DateTime(2026, 11, 6, 18);
    expect(history.controller.snapshot(ListeningRange.today).playCount, 1);
    expect(history.controller.snapshot(ListeningRange.last7Days).playCount, 2);
    expect(history.controller.snapshot(ListeningRange.last30Days).playCount, 4);
    expect(history.all.playCount, 5);
  });

  test('history restores and merges progress heard while loading', () async {
    final original = _History();
    await original.controller.ready;
    original.play(_first);
    await original.controller.flush();
    final read = Completer<String?>();
    var now = DateTime(2026, 11, 6, 15);
    String? saved;
    final restored = ListeningStatisticsController(
      now: () => now,
      read: () => read.future,
      write: (raw) async => saved = raw,
    );
    addTearDown(restored.dispose);
    restored.begin(_second, Duration.zero);
    now = now.add(const Duration(seconds: 3));
    restored.sample(const Duration(seconds: 3));
    restored.recordSkipTo(_first);
    read.complete(original.stored);
    await restored.ready;
    await restored.flush();
    final snapshot = restored.snapshot(ListeningRange.allTime);
    expect(snapshot.totalDuration, const Duration(seconds: 5));
    expect(snapshot.playCount, 2);
    expect(snapshot.skipCount, 1);
    final restarted = _History(initial: saved);
    await restarted.controller.ready;
    expect(restarted.all.totalDuration, snapshot.totalDuration);
    expect(restarted.all.mostSkipped.single.track.title, 'Two');
  });

  test(
    'failed writes retry, and concurrent checkpoints preserve latest progress',
    () async {
      var now = DateTime(2026, 11, 6, 15);
      var fail = true;
      var writes = 0;
      String? saved;
      Completer<void>? gate;
      final controller = ListeningStatisticsController(
        now: () => now,
        read: () async => null,
        write: (raw) async {
          writes++;
          if (fail) throw const FileSystemException('Unavailable');
          await gate?.future;
          gate = null;
          saved = raw;
        },
      );
      addTearDown(controller.dispose);
      await controller.ready;
      controller.begin(_first, Duration.zero);
      now = now.add(const Duration(seconds: 1));
      controller.sample(const Duration(seconds: 1));
      await controller.flush();
      expect(saved, isNull);
      fail = false;
      gate = Completer<void>();
      final pending = controller.flush();
      await Future<void>.delayed(Duration.zero);
      now = now.add(const Duration(seconds: 1));
      controller.sample(const Duration(seconds: 2));
      final latest = controller.flush();
      gate!.complete();
      await Future.wait([pending, latest]);
      expect(writes, 3);
      final restarted = _History(initial: saved);
      await restarted.controller.ready;
      expect(restarted.all.totalDuration, const Duration(seconds: 2));
    },
  );

  test('one malformed day does not discard other history', () async {
    final original = _History();
    await original.controller.ready;
    original.play(_first);
    await original.controller.flush();
    final raw = jsonDecode(original.stored!) as Map<String, dynamic>;
    (raw['days'] as Map)['2026-11-05'] = {
      'hours': [1],
      'tracks': {},
    };
    final restored = _History(initial: jsonEncode(raw));
    await restored.controller.ready;
    expect(restored.all.totalDuration, const Duration(seconds: 2));
    expect(restored.all.playCount, 1);
  });

  test('file history survives replacement and restarting offline', () async {
    final directory = await Directory.systemTemp.createTemp('lazer-listening-');
    addTearDown(() => directory.delete(recursive: true));
    final store = ListeningStatisticsStore(
      supportDirectory: () async => directory,
    );
    expect(await store.read(), isNull);
    await store.write('first complete snapshot');
    await store.write('replacement snapshot');
    expect(await store.read(), 'replacement snapshot');
    expect(
      await File(
        '${directory.path}/${ListeningStatisticsStore.fileName}.tmp',
      ).exists(),
      isFalse,
    );
    var now = DateTime(2026, 11, 6, 13);
    // Start with an unreadable old snapshot; it must not break new playback.
    final controller = ListeningStatisticsController(
      store: store,
      now: () => now,
    );
    await controller.ready;
    controller.begin(_first, Duration.zero);
    now = now.add(const Duration(seconds: 2));
    controller.sample(const Duration(seconds: 2));
    await controller.flush();
    controller.dispose();
    final restarted = ListeningStatisticsController(
      store: store,
      now: () => now,
    );
    await restarted.ready;
    expect(restarted.snapshot(ListeningRange.allTime).playCount, 1);
    expect(
      restarted.snapshot(ListeningRange.allTime).totalDuration,
      const Duration(seconds: 2),
    );
    restarted.dispose();
  });
}
