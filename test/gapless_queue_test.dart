import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Engine with both transport and the queue capability.
class _QueueEngine implements AudioEngine, QueueAudioEngine {
  final StreamController<int> _indexes = StreamController<int>.broadcast();
  final StreamController<void> _completed = StreamController<void>.broadcast();

  /// URLs passed to [setQueue], in call order.
  final List<String> loads = <String>[];

  /// URLs appended for a gapless hand-off, in call order.
  final List<String> appends = <String>[];

  int jumps = 0;
  int playCalls = 0;
  int stops = 0;
  int _queueId = 0;
  bool _active = false;
  bool _hasQueuedNext = false;
  bool queueJumpSucceeds = true;
  bool failResumeAfterJump = false;
  String? failUrl;

  @override
  Duration position = Duration.zero;

  @override
  bool get active => _active;

  @override
  Duration? get duration => const Duration(minutes: 3);

  @override
  Future<int> setQueue(List<String> urls, {int startIndex = 0}) async {
    if (urls[startIndex] == failUrl) {
      throw StateError('source failed');
    }
    loads.add(urls[startIndex]);
    _active = true;
    return ++_queueId;
  }

  @override
  Future<bool> appendToQueue(int queueId, String url) async {
    if (queueId != _queueId) return false;
    appends.add(url);
    _hasQueuedNext = true;
    return true;
  }

  @override
  Future<bool> playQueuedNext() async {
    jumps++;
    if (!_hasQueuedNext || !queueJumpSucceeds) return false;
    _hasQueuedNext = false;
    return true;
  }

  @override
  Stream<int> get indexStream => _indexes.stream;

  @override
  Stream<void> get completed => _completed.stream;

  /// Simulates the platform crossing into the queued item on its own.
  void crossIntoNext() {
    _hasQueuedNext = false;
    _indexes.add(1);
  }

  /// Simulates the platform running out of material.
  void finish() => _completed.add(null);

  @override
  Future<void> setUrl(String url) async {
    if (url == failUrl) throw StateError('source failed');
    loads.add(url);
    _active = true;
  }

  @override
  Future<void> play() async {
    playCalls++;
    if (failResumeAfterJump && jumps > 0) {
      throw StateError('output stayed paused after the jump');
    }
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration value) async {
    position = value;
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> stop() async {
    stops++;
    _active = false;
  }

  @override
  void dispose() {}
}

/// Engine without the queue capability: the completion-driven path.
class _PlainEngine implements AudioEngine {
  final StreamController<void> _completed = StreamController<void>.broadcast();
  final List<String> loads = <String>[];

  bool _active = false;

  @override
  bool get active => _active;

  @override
  Duration position = Duration.zero;

  @override
  Duration? get duration => const Duration(minutes: 3);

  @override
  Stream<void> get completed => _completed.stream;

  void finish() => _completed.add(null);

  @override
  Future<void> setUrl(String url) async {
    loads.add(url);
    _active = true;
  }

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration value) async {
    position = value;
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> stop() async {
    _active = false;
  }

  @override
  void dispose() {}
}

class _Gateway extends NeteaseGateway {
  @override
  Future<List<GatewaySong>> songDetails(List<int> ids) async => [];
}

class _Catalog extends Catalog {
  _Catalog() : super(gateway: _Gateway());

  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => 'url-${track.id}';

  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => const GatewayLyrics();
}

Track _track(String id) => Track(
  id: id,
  title: 'Track $id',
  artist: 'Artist',
  album: 'Album',
  duration: const Duration(minutes: 3),
  coverSeed: 1,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the following track is queued and adopted without reloading', (
    tester,
  ) async {
    final engine = _QueueEngine();
    final state = AppState(catalog: _Catalog(), audioEngine: engine);
    state.playQueue(<Track>[_track('1'), _track('2'), _track('3')]);
    await tester.pump();

    expect(engine.loads, <String>['url-1']);
    expect(engine.appends, <String>['url-2']);

    engine.crossIntoNext();
    await tester.pump();

    expect(state.queueIndex, 1);
    expect(state.current?.id, '2');
    // The hand-off must not load anything: the engine was already playing it.
    expect(engine.loads, <String>['url-1']);
    // ...and the new current track queues the one after it.
    expect(engine.appends, <String>['url-2', 'url-3']);

    state.dispose();
  });

  testWidgets('manual next crosses into the queued track', (tester) async {
    final engine = _QueueEngine();
    final state = AppState(catalog: _Catalog(), audioEngine: engine);
    state.playQueue(<Track>[_track('1'), _track('2')]);
    await tester.pump();

    state.next();
    await tester.pump();

    expect(state.queueIndex, 1);
    expect(engine.jumps, 1);
    expect(engine.playCalls, 2);
    expect(engine.loads, <String>['url-1']);

    state.dispose();
  });

  testWidgets('a failed resume after a queue jump is reported to the user', (
    tester,
  ) async {
    final engine = _QueueEngine();
    final state = AppState(catalog: _Catalog(), audioEngine: engine);
    state.playQueue(<Track>[_track('1'), _track('2')]);
    await tester.pump();

    engine.failResumeAfterJump = true;
    state.next();
    await tester.pump();

    expect(state.current?.id, '2');
    expect(state.playing, isFalse);
    expect(state.playbackError, '播放中断，请重试。');
    state.dispose();
  });

  testWidgets('manual next reloads when the platform queue cannot advance', (
    tester,
  ) async {
    final engine = _QueueEngine();
    final state = AppState(catalog: _Catalog(), audioEngine: engine);
    state.playQueue(<Track>[_track('1'), _track('2')]);
    await tester.pump();

    engine.queueJumpSucceeds = false;
    state.next();
    await tester.pump();

    expect(state.current?.id, '2');
    expect(state.playing, isTrue);
    expect(engine.loads, <String>['url-1', 'url-2']);
    expect(state.playbackError, isNull);
    state.dispose();
  });

  testWidgets('failed fallback stops playback and reports an error', (
    tester,
  ) async {
    final engine = _QueueEngine();
    final state = AppState(catalog: _Catalog(), audioEngine: engine);
    state.playQueue(<Track>[_track('1'), _track('2')]);
    await tester.pump();

    engine
      ..queueJumpSucceeds = false
      ..failUrl = 'url-2';
    state.next();
    await tester.pump();

    expect(state.current?.id, '2');
    expect(state.playing, isFalse);
    expect(state.playbackError, '音频加载失败，请重试。');
    state.dispose();
  });

  testWidgets('next during a pending queue hand-off plays the requested song', (
    tester,
  ) async {
    final engine = _QueueEngine();
    final state = AppState(catalog: _Catalog(), audioEngine: engine);
    state.playQueue(<Track>[_track('1'), _track('2'), _track('3')]);
    await tester.pump();

    // The engine has already crossed the boundary, but AppState has not yet
    // received its asynchronous index notification.
    engine.crossIntoNext();
    state.next();
    await tester.pump();

    expect(state.current?.id, '2');
    expect(state.queueIndex, 1);
    expect(state.playing, isTrue);
    expect(engine.loads, <String>['url-1', 'url-2']);
    expect(state.playbackError, isNull);
    state.dispose();
  });

  testWidgets('successful playback is recorded in the local recent list', (
    tester,
  ) async {
    final engine = _QueueEngine();
    final state = AppState(catalog: _Catalog(), audioEngine: engine);

    state.playQueue(<Track>[_track('1'), _track('2')]);
    await tester.pump();

    expect(state.recentTracks.map((track) => track.id), <String>['1']);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('lazer_recent_tracks_v1'), contains('Track 1'));
    state.dispose();
  });

  testWidgets('a station appends another recommendation batch near its tail', (
    tester,
  ) async {
    final engine = _QueueEngine();
    final state = AppState(catalog: _Catalog(), audioEngine: engine);
    var loads = 0;

    state.playStationQueue(
      <Track>[_track('1'), _track('2'), _track('3')],
      loadMore: () async {
        loads++;
        return <Track>[_track('4'), _track('5'), _track('6')];
      },
    );
    await tester.pump();

    expect(loads, 1);
    expect(state.queue.map((track) => track.id), <String>[
      '1',
      '2',
      '3',
      '4',
      '5',
      '6',
    ]);
    state.dispose();
  });

  testWidgets('repeat one queues the same track again', (tester) async {
    final engine = _QueueEngine();
    final state = AppState(catalog: _Catalog(), audioEngine: engine);
    state.cycleRepeat();
    state.cycleRepeat();
    expect(state.repeat, LoopMode.one);
    state.playQueue(<Track>[_track('1'), _track('2')]);
    await tester.pump();

    expect(engine.appends, <String>['url-1']);

    engine.crossIntoNext();
    await tester.pump();

    expect(state.queueIndex, 0);
    expect(engine.loads, <String>['url-1']);

    state.dispose();
  });

  testWidgets('the last track still stops when the queue runs out', (
    tester,
  ) async {
    final engine = _QueueEngine();
    final state = AppState(catalog: _Catalog(), audioEngine: engine);
    state.playQueue(<Track>[_track('1')]);
    await tester.pump();

    // Nothing follows, so nothing is queued.
    expect(engine.appends, isEmpty);

    engine.finish();
    await tester.pump();

    expect(state.playing, false);
    expect(engine.stops, greaterThan(0));

    state.dispose();
  });

  testWidgets('an engine without a queue keeps the setUrl path', (
    tester,
  ) async {
    final engine = _PlainEngine();
    final state = AppState(catalog: _Catalog(), audioEngine: engine);
    state.playQueue(<Track>[_track('1'), _track('2')]);
    await tester.pump();
    expect(engine.loads, <String>['url-1']);

    engine.finish();
    await tester.pump();

    expect(state.queueIndex, 1);
    expect(engine.loads, <String>['url-1', 'url-2']);

    state.dispose();
  });
}
