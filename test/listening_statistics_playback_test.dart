import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/audio/system_media_handler.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/listening/listening_statistics.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _tracks = [
  Track(
    id: 'one',
    title: 'One',
    artist: 'Artist',
    album: 'Album',
    duration: Duration(seconds: 8),
    coverSeed: 1,
  ),
  Track(
    id: 'two',
    title: 'Two',
    artist: 'Artist',
    album: 'Album',
    duration: Duration(seconds: 8),
    coverSeed: 2,
  ),
];

class _Catalog extends Catalog {
  bool unavailable = false;
  @override
  Future<HomeFeed?> loadHome({int? userId}) async => null;
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => unavailable ? null : 'file:///${track.id}.mp3';
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => const GatewayLyrics();
}

class _Engine implements AudioEngine, FailureReportingAudioEngine {
  final completion = StreamController<void>.broadcast(sync: true);
  final failure = StreamController<AudioFailure>.broadcast(sync: true);
  final seekGates = <Completer<void>>[];
  bool holdSeeks = false;
  bool failSeeks = false;
  @override
  bool active = false;
  @override
  Duration position = Duration.zero;
  @override
  Duration? duration = const Duration(seconds: 8);
  @override
  Stream<void> get completed => completion.stream;
  @override
  Stream<AudioFailure> get failures => failure.stream;
  @override
  AudioFailure? get pendingFailure => null;
  @override
  Future<void> setUrl(String url) async {
    position = Duration.zero;
    active = true;
  }

  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration target) async {
    if (holdSeeks) {
      final gate = Completer<void>();
      seekGates.add(gate);
      await gate.future;
    }
    if (failSeeks) throw StateError('seek rejected');
    position = target;
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> stop() async {
    active = false;
  }

  @override
  void dispose() {
    completion.close();
    failure.close();
  }
}

class _QueueEngine extends _Engine implements QueueAudioEngine {
  final advances = StreamController<int>.broadcast(sync: true);
  int queueId = 0;
  bool appended = false;
  @override
  Future<int> setQueue(List<String> urls, {int startIndex = 0}) async {
    await setUrl(urls[startIndex]);
    appended = false;
    return ++queueId;
  }

  @override
  Future<bool> appendToQueue(int queueId, String url) async {
    appended = true;
    return true;
  }

  @override
  Future<bool> playQueuedNext() async {
    position = Duration.zero;
    return true;
  }

  @override
  Stream<int> get indexStream => advances.stream;
  @override
  void dispose() {
    advances.close();
    super.dispose();
  }
}

class _Harness {
  static final activeHarnesses = <_Harness>{};
  _Harness({_Engine? engine}) : engine = engine ?? _Engine() {
    statistics = ListeningStatisticsController(
      now: () => now,
      read: () async => null,
      write: (_) async {},
    );
    state = AppState(
      catalog: catalog,
      audioEngine: this.engine,
      listeningStatistics: statistics,
    );
    activeHarnesses.add(this);
  }
  final _Engine engine;
  final catalog = _Catalog();
  DateTime now = DateTime(2026, 11, 6, 12);
  late final ListeningStatisticsController statistics;
  late final AppState state;
  void close() {
    state.dispose();
    engine.dispose();
    activeHarnesses.remove(this);
  }

  ListeningStatisticsSnapshot get all =>
      statistics.snapshot(ListeningRange.allTime);
  Future<void> start(
    WidgetTester tester, {
    List<Track> tracks = _tracks,
  }) async {
    await statistics.ready;
    state.playQueue(tracks);
    await tester.pump();
    expect(state.audioReady, isTrue);
  }

  Future<void> hear(WidgetTester tester, Duration duration) async {
    now = now.add(duration);
    engine.position += duration;
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void _testPlayback(
  String description,
  Future<void> Function(WidgetTester) body,
) {
  testWidgets(description, (tester) async {
    try {
      await body(tester);
    } finally {
      for (final harness in _Harness.activeHarnesses.toList()) {
        harness.close();
      }
      await tester.pump();
    }
  });
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  _testPlayback('system next counts 200 ms audible skip before first tick', (
    tester,
  ) async {
    final h = _Harness();
    await h.start(tester);
    final media = LazerMediaHandler(h.state, artwork: (_) async => null);
    addTearDown(media.close);
    h.now = h.now.add(const Duration(milliseconds: 200));
    h.engine.position = const Duration(milliseconds: 200);
    await media.skipToNext();
    await tester.pump();
    expect(h.state.current?.id, 'two');
    expect(h.all.totalDuration, const Duration(milliseconds: 200));
    expect(h.all.skipCount, 1);
    expect(h.all.playCount, 0);
    await h.hear(tester, const Duration(seconds: 1));
    await media.pause();
    expect(h.all.playCount, 1);
    expect(h.all.mostSkipped.single.track.id, 'one');
  });

  _testPlayback(
    'pause, resume, seek and audio quality reload count only heard progress',
    (tester) async {
      final h = _Harness();
      await h.start(tester);
      await h.hear(tester, const Duration(seconds: 1));
      h.state.pause();
      h.now = h.now.add(const Duration(hours: 2));
      await tester.pump(const Duration(seconds: 30));
      h.state.play();
      await tester.pump();
      await h.hear(tester, const Duration(seconds: 1));
      h.state.seek(0.5);
      await tester.pump();
      await h.hear(tester, const Duration(seconds: 1));
      await h.state.setPlaybackQuality(AudioQuality.lossless);
      await tester.pump();
      await h.hear(tester, const Duration(seconds: 1));
      expect(h.all.totalDuration, const Duration(seconds: 4));
      expect(h.all.playCount, 1);
      expect(h.all.skipCount, 0);
      h.state.pause();
      h.now = h.now.add(const Duration(hours: 1));
      h.state.next();
      expect(h.all.skipCount, 1);
    },
  );

  _testPlayback('natural completion and repeat-one replay never count a skip', (
    tester,
  ) async {
    final h = _Harness();
    await h.start(tester);
    h.now = h.now.add(const Duration(seconds: 8));
    h.engine.position = const Duration(seconds: 8);
    h.engine.completion.add(null);
    await tester.pump();
    expect(h.state.current?.id, 'two');
    expect(h.all.totalDuration, const Duration(seconds: 8));
    h.state.cycleRepeat();
    h.state.cycleRepeat();
    h.now = h.now.add(const Duration(seconds: 8));
    h.engine.position = const Duration(seconds: 8);
    h.engine.completion.add(null);
    await tester.pump();
    expect(h.engine.position, Duration.zero);
    await h.hear(tester, const Duration(seconds: 1));
    expect(h.all.totalDuration, const Duration(seconds: 17));
    expect(h.all.playCount, 3);
    expect(h.all.skipCount, 0);
  });

  _testPlayback(
    'previous restarts heard song and duplicate queue recordings are not skips',
    (tester) async {
      final h = _Harness();
      await h.start(tester, tracks: [_tracks.first, _tracks.first]);
      await h.hear(tester, const Duration(seconds: 4));
      h.state.previous();
      await tester.pump();
      expect(h.engine.position, Duration.zero);
      await h.hear(tester, const Duration(seconds: 1));
      h.state.playTrackAt(1);
      await tester.pump();
      await h.hear(tester, const Duration(seconds: 1));
      expect(h.all.totalDuration, const Duration(seconds: 6));
      expect(h.all.playCount, 3);
      expect(h.all.skipCount, 0);
    },
  );

  _testPlayback(
    'buffering, unavailable track, terminal failure and stop add no invented progress',
    (tester) async {
      final h = _Harness();
      await h.start(tester);
      h.now = h.now.add(const Duration(seconds: 30));
      await tester.pump(const Duration(seconds: 1));
      expect(h.all.totalDuration, Duration.zero);
      // A source failure, not a device one: the app reopens the output for a lost
      // device, so only a non-recoverable kind is terminal here.
      h.engine.failure.add(
        const AudioFailure(
          'the source could not be read',
          AudioFailureKind.source,
        ),
      );
      expect(h.state.playing, isFalse);
      expect(h.all.playCount, 0);
      h.catalog.unavailable = true;
      h.state.next();
      h.state.play();
      await tester.pump();
      expect(h.state.playbackError, isNotNull);
      expect(h.all.skipCount, 0);
      h.catalog.unavailable = false;
      h.state.play();
      await tester.pump();
      await h.hear(tester, const Duration(seconds: 1));
      h.state.stop();
      expect(h.all.totalDuration, const Duration(seconds: 1));
      expect(h.all.playCount, 1);
      expect(h.all.skipCount, 0);
    },
  );

  _testPlayback(
    'automatic gapless handoff counts new song without a manual skip',
    (tester) async {
      final engine = _QueueEngine();
      final h = _Harness(engine: engine);
      await h.start(tester);
      expect(engine.appended, isTrue);
      await h.hear(tester, const Duration(seconds: 2));
      engine.position = Duration.zero;
      engine.advances.add(1);
      await tester.pump();
      await h.hear(tester, const Duration(seconds: 1));
      expect(h.state.current?.id, 'two');
      expect(h.all.totalDuration, const Duration(seconds: 3));
      expect(h.all.playCount, 2);
      expect(h.all.skipCount, 0);
    },
  );

  _testPlayback(
    'seek completion from the old song cannot reset next song sampling',
    (tester) async {
      final h = _Harness();
      await h.start(tester);
      await h.hear(tester, const Duration(seconds: 1));
      h.engine.holdSeeks = true;
      h.state.seek(0.5);
      h.state.next();
      await tester.pump();
      await h.hear(tester, const Duration(seconds: 1));
      h.engine.seekGates.single.complete();
      await tester.pump();
      // Ignore the stale backend seek too, then listen to the successor normally.
      h.engine.position = const Duration(seconds: 1);
      await h.hear(tester, const Duration(seconds: 1));
      expect(h.all.totalDuration, const Duration(seconds: 3));
      expect(h.all.playCount, 2);
      expect(h.all.skipCount, 1);
    },
  );

  _testPlayback('rejected seeks resume sampling actual playback', (
    tester,
  ) async {
    final h = _Harness();
    await h.start(tester);
    await h.hear(tester, const Duration(seconds: 1));
    h.engine.failSeeks = true;
    h.state.seek(0.5);
    await tester.pump();
    await h.hear(tester, const Duration(seconds: 1));
    expect(h.all.totalDuration, const Duration(seconds: 2));
    expect(h.all.playCount, 1);
  });

  _testPlayback(
    'completion samples final actual position after the engine becomes inactive',
    (tester) async {
      final h = _Harness();
      await h.start(tester, tracks: [_tracks.first]);
      h.now = h.now.add(const Duration(seconds: 8));
      h.engine.position = const Duration(seconds: 8);
      h.engine.active = false;
      h.engine.completion.add(null);
      await tester.pump();
      expect(h.all.totalDuration, const Duration(seconds: 8));
      expect(h.all.playCount, 1);
      expect(h.all.skipCount, 0);
      expect(h.state.playing, isFalse);
    },
  );

  _testPlayback('a rejected previous restart preserves the existing play', (
    tester,
  ) async {
    final h = _Harness();
    await h.start(tester);
    await h.hear(tester, const Duration(seconds: 4));
    h.engine.failSeeks = true;
    h.state.previous();
    await tester.pump();
    await h.hear(tester, const Duration(seconds: 1));
    expect(h.all.totalDuration, const Duration(seconds: 5));
    expect(h.all.playCount, 1);
    expect(h.all.skipCount, 0);
  });

  _testPlayback(
    'pause and resume cannot acknowledge a seek that is still pending',
    (tester) async {
      final h = _Harness();
      await h.start(tester);
      await h.hear(tester, const Duration(seconds: 1));
      h.engine.holdSeeks = true;
      h.state.seek(0.5);
      h.state.pause();
      h.state.play();
      await tester.pump();
      await h.hear(tester, const Duration(seconds: 1));
      expect(h.all.totalDuration, const Duration(seconds: 1));
      h.engine.seekGates.single.complete();
      await tester.pump();
      await h.hear(tester, const Duration(seconds: 1));
      expect(h.all.totalDuration, const Duration(seconds: 2));
      expect(h.all.playCount, 1);
    },
  );

  _testPlayback('a stale seek cannot rebase a manual gapless successor', (
    tester,
  ) async {
    final h = _Harness(engine: _QueueEngine());
    await h.start(tester);
    await h.hear(tester, const Duration(seconds: 1));
    h.engine.holdSeeks = true;
    h.state.seek(0.5);
    h.state.next();
    await tester.pump();
    await h.hear(tester, const Duration(seconds: 1));
    h.engine.seekGates.single.complete();
    await tester.pump();
    h.engine.position = const Duration(seconds: 1);
    await h.hear(tester, const Duration(seconds: 1));
    expect(h.all.totalDuration, const Duration(seconds: 3));
    expect(h.all.playCount, 2);
    expect(h.all.skipCount, 1);
  });

  _testPlayback(
    'overlapping seeks only acknowledge the latest requested position',
    (tester) async {
      final h = _Harness();
      await h.start(tester);
      await h.hear(tester, const Duration(seconds: 1));
      h.engine.holdSeeks = true;
      h.state.seek(0.5);
      h.state.seek(0.75);
      h.engine.seekGates[1].complete();
      await tester.pump();
      await h.hear(tester, const Duration(milliseconds: 500));
      h.engine.seekGates[0].complete();
      await tester.pump();
      h.engine.position = const Duration(milliseconds: 6500);
      await h.hear(tester, const Duration(milliseconds: 500));
      expect(h.all.totalDuration, const Duration(seconds: 2));
      expect(h.all.playCount, 1);
    },
  );

  _testPlayback(
    'signing out ends the old session without a skip on the next selection',
    (tester) async {
      final h = _Harness();
      await h.start(tester);
      await h.hear(tester, const Duration(seconds: 1));
      await h.state.signOut();
      h.state.playQueue([_tracks.last]);
      await tester.pump();
      await h.hear(tester, const Duration(seconds: 1));
      expect(h.all.totalDuration, const Duration(seconds: 2));
      expect(h.all.playCount, 2);
      expect(h.all.skipCount, 0);
    },
  );
}
