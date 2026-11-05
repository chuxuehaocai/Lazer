import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/audio/automix_audio_engine.dart';

/// Matches just_audio's play contract: the Future stays pending until stopped.
class _Player implements AudioPlayer {
  final StreamController<ProcessingState> _states =
      StreamController<ProcessingState>.broadcast();
  final StreamController<Duration> _buffers =
      StreamController<Duration>.broadcast();
  final List<String> loaded = <String>[];
  final List<Completer<void>> _playbacks = <Completer<void>>[];
  final Map<String, Duration> lengths = <String, Duration>{
    'https://audio.test/a': const Duration(seconds: 40),
    'https://audio.test/b': const Duration(seconds: 100),
    'file:///c.mp3': const Duration(seconds: 60),
  };
  Completer<void>? loadBarrier;
  bool rejectLoad = false;
  @override
  bool playing = false;
  @override
  Duration position = Duration.zero;
  @override
  Duration? duration;
  @override
  Duration bufferedPosition = Duration.zero;
  double gain = 1;
  int stops = 0;
  int plays = 0;

  @override
  Stream<ProcessingState> get processingStateStream => _states.stream;
  @override
  Stream<Duration> get bufferedPositionStream => _buffers.stream;

  @override
  Future<Duration?> setUrl(
    String url, {
    Map<String, String>? headers,
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) async {
    await loadBarrier?.future;
    if (rejectLoad) throw StateError('successor is unavailable');
    loaded.add(url);
    position = Duration.zero;
    duration = lengths[url] ?? const Duration(seconds: 100);
    bufferedPosition = duration!;
    return duration;
  }

  @override
  Future<Duration?> setFilePath(
    String path, {
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) => setUrl(Uri.file(path).toString());

  @override
  Future<void> play() {
    playing = true;
    plays++;
    final Completer<void> playback = Completer<void>();
    _playbacks.add(playback);
    return playback.future;
  }

  void advance(Duration elapsed) {
    if (playing) position += elapsed;
  }

  void finish() {
    position = duration!;
    _states.add(ProcessingState.completed);
    _endPlayback();
  }

  void _endPlayback() {
    playing = false;
    for (final Completer<void> playback in _playbacks) {
      if (!playback.isCompleted) playback.complete();
    }
    _playbacks.clear();
  }

  @override
  Future<void> pause() async => _endPlayback();
  @override
  Future<void> stop() async {
    stops++;
    _endPlayback();
  }

  @override
  Future<void> seek(Duration? value, {int? index}) async =>
      position = value ?? position;
  @override
  Future<void> setVolume(double value) async => gain = value;
  @override
  Future<void> dispose() async {
    _endPlayback();
    await _states.close();
    await _buffers.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Fixture {
  _Fixture({bool enabled = true}) {
    _fixtures.add(this);
    int created = 0;
    engine = AutoMixAudioEngine(
      enabled: enabled,
      playerFactory: () => created++ == 0 ? a : b,
    );
  }
  final _Player a = _Player();
  final _Player b = _Player();
  late final AutoMixAudioEngine engine;
  late int queueId;
  final List<int> indexes = <int>[];
  final List<AudioFailure> failures = <AudioFailure>[];

  Future<void> load() async {
    engine.indexStream.listen(indexes.add);
    engine.failures.listen(failures.add);
    queueId = await engine.setQueue(<String>['https://audio.test/a']);
    expect(await engine.appendToQueue(queueId, 'https://audio.test/b'), isTrue);
    await engine.play();
  }
}

final List<_Fixture> _fixtures = <_Fixture>[];

void _engineTest(String description, Future<void> Function(WidgetTester) body) {
  testWidgets(description, (tester) async {
    try {
      await body(tester);
    } finally {
      for (final fixture in _fixtures) {
        fixture.engine.dispose();
      }
      _fixtures.clear();
      await tester.pump();
    }
  });
}

void main() {
  _engineTest('both decoders play audibly before outgoing ends', (
    tester,
  ) async {
    final f = _Fixture();
    addTearDown(f.engine.dispose);
    await f.load();
    expect(f.a.playing, isTrue);
    expect(f.b.playing, isFalse);
    f.a.advance(const Duration(seconds: 32));
    await tester.pump(const Duration(milliseconds: 40));
    expect(f.a.playing, isTrue);
    expect(f.b.playing, isTrue);
    f.a.advance(const Duration(seconds: 2));
    f.b.advance(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 40));
    expect(f.a.position, lessThan(f.a.duration!));
    expect(f.a.gain, closeTo(math.cos(math.pi / 8), .0001));
    expect(f.b.gain, closeTo(math.sin(math.pi / 8), .0001));
    // The metadata boundary is announced as soon as B contributes its first
    // audible samples, while A continues underneath the overlap.
    expect(f.indexes, <int>[1]);

    f.a.advance(const Duration(seconds: 6));
    f.b.advance(const Duration(seconds: 6));
    await tester.pump(const Duration(milliseconds: 40));
    expect(f.indexes, <int>[1]);
    expect(f.engine.position, const Duration(seconds: 8));
    expect(f.engine.duration, const Duration(seconds: 100));
    expect(f.engine.bufferedPosition, const Duration(seconds: 100));
    expect(f.a.playing, isFalse);
    expect(f.b.playing, isTrue);
    expect(f.b.gain, 1);
  });

  _engineTest('pause freezes overlap and resume starts both players', (
    tester,
  ) async {
    final f = _Fixture();
    addTearDown(f.engine.dispose);
    await f.load();
    f.a.advance(const Duration(seconds: 32));
    await tester.pump(const Duration(milliseconds: 40));
    f.a.advance(const Duration(seconds: 2));
    f.b.advance(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 40));
    final double outgoingGain = f.a.gain;
    final double incomingGain = f.b.gain;
    await f.engine.pause();
    await tester.pump(const Duration(seconds: 30));
    expect(f.a.gain, outgoingGain);
    expect(f.b.gain, incomingGain);
    expect(f.indexes, <int>[1]);
    await f.engine.play();
    expect(f.a.playing, isTrue);
    expect(f.b.playing, isTrue);
    await tester.pump(const Duration(milliseconds: 40));
    expect(f.a.gain, outgoingGain);
    expect(f.b.gain, incomingGain);
    f.b.advance(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 40));
    expect(f.b.gain, greaterThan(incomingGain));
    expect(f.indexes, <int>[1]);
  });

  _engineTest('waits for enough successor buffer to cover the full overlap', (
    tester,
  ) async {
    final f = _Fixture();
    await f.load();
    f.b.bufferedPosition = const Duration(milliseconds: 500);
    f.a.advance(const Duration(seconds: 32));
    await tester.pump(const Duration(milliseconds: 40));
    expect(f.a.playing, isTrue);
    expect(f.a.gain, 1);
    expect(f.b.playing, isFalse);
    expect(f.b.gain, 0);
    f.b.bufferedPosition = const Duration(seconds: 8);
    await tester.pump(const Duration(milliseconds: 40));
    expect(f.a.playing, isTrue);
    expect(f.b.playing, isTrue);
    f.b.advance(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 40));
    expect(f.b.gain, greaterThan(0));
    expect(f.a.gain, lessThan(1));
  });

  _engineTest('stalled incoming decoder never fades outgoing to silence', (
    tester,
  ) async {
    final f = _Fixture();
    addTearDown(f.engine.dispose);
    await f.load();
    f.b.bufferedPosition = Duration.zero;
    f.a.advance(const Duration(seconds: 32));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump(const Duration(seconds: 20));
    expect(f.a.gain, 1);
    expect(f.b.gain, 0);
    expect(f.indexes, isEmpty);
  });

  _engineTest(
    'manual handoff returns while play remains pending and emits no index',
    (tester) async {
      final f = _Fixture();
      addTearDown(f.engine.dispose);
      await f.load();
      expect(await f.engine.playQueuedNext(), isTrue);
      await tester.pump();
      expect(f.a.playing, isFalse);
      expect(f.b.playing, isTrue);
      expect(f.b.gain, 1);
      expect(f.indexes, isEmpty);
      expect(await f.engine.playQueuedNext(), isFalse);
    },
  );

  _engineTest(
    'successor appended during announced overlap is not treated as prepared',
    (tester) async {
      final f = _Fixture();
      addTearDown(f.engine.dispose);
      await f.load();
      f.a.advance(const Duration(seconds: 32));
      await tester.pump(const Duration(milliseconds: 40));
      expect(f.indexes, <int>[1]);
      expect(f.b.playing, isTrue);

      // The second decoder is already the presented track; there is no free
      // slot for a third song. A false answer sends AppState down its normal
      // reload path instead of pointing a manual skip at the wrong decoder.
      expect(await f.engine.appendToQueue(f.queueId, 'file:///c.mp3'), isFalse);
      expect(await f.engine.playQueuedNext(), isFalse);
      expect(f.engine.duration, const Duration(seconds: 100));

      // Once B owns the output, a fresh successor can be prepared normally.
      f.a.advance(const Duration(seconds: 10));
      f.b.advance(const Duration(seconds: 10));
      await tester.pump(const Duration(milliseconds: 80));
      expect(await f.engine.appendToQueue(f.queueId, 'file:///c.mp3'), isTrue);
      expect(await f.engine.playQueuedNext(), isTrue);
      expect(f.engine.duration, const Duration(seconds: 60));
    },
  );

  _engineTest('seek during announced overlap lands on the audible track', (
    tester,
  ) async {
    final f = _Fixture();
    addTearDown(f.engine.dispose);
    await f.load();
    f.a.advance(const Duration(seconds: 32));
    await tester.pump(const Duration(milliseconds: 40));
    expect(f.indexes, <int>[1]);
    expect(f.b.playing, isTrue);

    // The outgoing decoder has no queued URL to prepare during the overlap.
    // A seek must therefore reach the audible incoming track immediately
    // instead of waiting on a speculative load for the song after it.
    final barrier = Completer<void>();
    f.a.loadBarrier = barrier;
    final seek = f.engine.seek(const Duration(seconds: 10));
    await tester.pump();
    expect(f.b.position, const Duration(seconds: 10));
    barrier.complete();
    await seek;
  });

  _engineTest('seek resets overlap but retains the accepted next track', (
    tester,
  ) async {
    final f = _Fixture();
    addTearDown(f.engine.dispose);
    await f.load();
    f.a.advance(const Duration(seconds: 32));
    await tester.pump(const Duration(milliseconds: 40));
    f.b.advance(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 40));
    await f.engine.seek(const Duration(seconds: 10));
    expect(f.b.position, const Duration(seconds: 10));
    expect(f.a.playing, isFalse);
    expect(f.b.playing, isTrue);
    expect(await f.engine.playQueuedNext(), isFalse);
    expect(f.b.loaded, <String>['https://audio.test/b']);
    expect(f.b.playing, isTrue);
    expect(f.indexes, <int>[1]);
  });

  _engineTest('disable preserves successor for automatic completion handoff', (
    tester,
  ) async {
    final f = _Fixture();
    addTearDown(f.engine.dispose);
    await f.load();
    f.a.advance(const Duration(seconds: 32));
    await tester.pump(const Duration(milliseconds: 40));
    f.b.advance(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 40));
    await f.engine.setAutoMixEnabled(false);
    expect(f.a.playing, isFalse);
    expect(f.b.gain, 1);
    expect(f.b.playing, isTrue);
    await tester.pump(const Duration(seconds: 1));
    expect(f.b.playing, isTrue);
    f.b.finish();
    await tester.pump();
    expect(f.b.playing, isFalse);
    expect(f.indexes, <int>[1]);
    expect(f.b.position, const Duration(seconds: 100));
  });

  _engineTest('enable during playback starts an already prepared overlap', (
    tester,
  ) async {
    final f = _Fixture(enabled: false);
    addTearDown(f.engine.dispose);
    await f.load();
    f.a.advance(const Duration(seconds: 32));
    await tester.pump(const Duration(milliseconds: 40));
    expect(f.b.playing, isFalse);
    await f.engine.setAutoMixEnabled(true);
    await tester.pump(const Duration(milliseconds: 40));
    expect(f.a.playing, isTrue);
    expect(f.b.playing, isTrue);
  });

  _engineTest(
    'failed prefetch keeps healthy source playing without terminal failure',
    (tester) async {
      final f = _Fixture();
      addTearDown(f.engine.dispose);
      f.engine.failures.listen(f.failures.add);
      final int queueId = await f.engine.setQueue(<String>[
        'https://audio.test/a',
      ]);
      await f.engine.play();
      f.b.rejectLoad = true;
      expect(
        await f.engine.appendToQueue(queueId, 'https://audio.test/b'),
        isFalse,
      );
      await tester.pump();
      expect(f.a.playing, isTrue);
      expect(f.engine.active, isTrue);
      expect(f.a.gain, 1);
      expect(f.failures, isEmpty);
      f.b.rejectLoad = false;
      expect(
        await f.engine.appendToQueue(queueId, 'https://audio.test/b'),
        isTrue,
      );
      expect(await f.engine.playQueuedNext(), isTrue);
    },
  );

  _engineTest('pause cancels focus activation that has not finished', (
    tester,
  ) async {
    final f = _Fixture();
    addTearDown(f.engine.dispose);
    await f.engine.setUrl('https://audio.test/a');
    final Completer<bool> focus = Completer<bool>();
    f.engine.activateSession = () => focus.future;
    final Future<void> play = f.engine.play();
    await f.engine.pause();
    focus.complete(true);
    await play;
    expect(f.a.playing, isFalse);
  });

  _engineTest(
    'pause at a completion boundary defers queue advance until resume',
    (tester) async {
      final f = _Fixture(enabled: false);
      await f.load();
      f.a.finish();
      await f.engine.pause();
      await tester.pump();
      expect(f.indexes, isEmpty);
      expect(f.b.playing, isFalse);
      await f.engine.play();
      await tester.pump();
      expect(f.indexes, <int>[1]);
      expect(f.b.playing, isTrue);
    },
  );

  _engineTest('loaded queues retain later successors and final completion', (
    tester,
  ) async {
    final f = _Fixture(enabled: false);
    addTearDown(f.engine.dispose);
    f.engine.indexStream.listen(f.indexes.add);
    int completed = 0;
    f.engine.completed.listen((_) => completed++);
    await f.engine.setQueue(<String>[
      'https://audio.test/a',
      'https://audio.test/b',
      'file:///c.mp3',
    ]);
    await f.engine.play();
    f.a.finish();
    await tester.pump();
    expect(f.indexes, <int>[1]);
    expect(f.b.playing, isTrue);
    f.b.finish();
    await tester.pump();
    expect(f.indexes, <int>[1, 2]);
    expect(f.a.playing, isTrue);
    expect(f.engine.seekIsLimitedByBuffer, isFalse);
    f.a.finish();
    await tester.pump();
    expect(completed, 1);
    expect(f.engine.active, isFalse);
  });

  _engineTest(
    'completed source repeats through seek and play without reloading',
    (tester) async {
      final f = _Fixture();
      await f.engine.setUrl('https://audio.test/a');
      await f.engine.play();
      f.a.finish();
      await tester.pump();
      expect(f.engine.active, isFalse);
      await f.engine.seek(Duration.zero);
      expect(f.engine.active, isTrue);
      await f.engine.play();
      expect(f.a.playing, isTrue);
      expect(f.a.position, Duration.zero);
      expect(f.a.loaded, <String>['https://audio.test/a']);

      await f.engine.stop();
      await f.engine.seek(Duration.zero);
      await f.engine.play();
      expect(f.engine.active, isFalse);
      expect(f.a.playing, isFalse);
    },
  );
}
