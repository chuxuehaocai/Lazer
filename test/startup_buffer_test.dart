import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/state/app_state.dart';

class _Catalog extends Catalog {
  _Catalog({this.url});
  final String? url;
  @override
  Future<HomeFeed?> loadHome({int? userId}) async => null;
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => url ?? 'https://cdn.test/${track.id}.mp3';
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => null;
}

Track _track(String id) => Track(
  id: id,
  title: id,
  artist: 'Artist',
  album: 'Album',
  duration: const Duration(minutes: 3),
  coverSeed: 1,
);

/// Transport whose buffer only grows when the test says so.
class _BufferingEngine implements AudioEngine, BufferedAudioEngine {
  final StreamController<void> _completed = StreamController<void>.broadcast();
  final List<String> loaded = <String>[];
  Duration buffered = Duration.zero;
  int plays = 0;
  @override
  bool active = false;

  @override
  Future<void> setUrl(String url) async {
    loaded.add(url);
    active = true;
  }

  @override
  Future<void> play() async => plays++;

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> stop() async {
    active = false;
  }

  @override
  Duration get position => Duration.zero;

  @override
  Duration? get duration => const Duration(minutes: 3);

  @override
  Duration get bufferedPosition => buffered;

  @override
  Stream<void> get completed => _completed.stream;

  @override
  void dispose() {
    _completed.close();
  }
}

class _QueueBufferingEngine extends _BufferingEngine
    implements SerialQueueAudioEngine {
  int appends = 0;
  bool preparedBeforePlay = false;

  @override
  Future<int> setQueue(List<String> urls, {int startIndex = 0}) async {
    await setUrl(urls[startIndex]);
    return 1;
  }

  @override
  Future<bool> appendToQueue(int queueId, String url) async {
    appends++;
    if (plays == 0) preparedBeforePlay = true;
    return true;
  }

  @override
  Future<void> play() async {
    if (preparedBeforePlay) {
      throw StateError('successor probe is blocking the transport worker');
    }
    await super.play();
  }

  @override
  Future<bool> playQueuedNext() async => false;
  @override
  Stream<int> get indexStream => const Stream.empty();
}

class _UnknownBufferEngine extends _BufferingEngine
    implements StartupBufferReportingAudioEngine {
  @override
  Duration? get startupBufferedPosition => null;
}

/// Lets the load path run to the point where it is waiting on the buffer.
Future<void> _settle([int turns = 8]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  AppState stateFor(
    _BufferingEngine engine, {
    Duration target = const Duration(seconds: 5),
    Duration deadline = const Duration(seconds: 5),
  }) => AppState(
    catalog: _Catalog(),
    audioEngine: engine,
    startupBufferTarget: target,
    startupBufferDeadline: deadline,
  );

  test(
    'first play precedes a successor probe on the shared native worker',
    () async {
      final engine = _QueueBufferingEngine();
      final state = stateFor(engine);
      addTearDown(state.dispose);
      state.playQueue([_track('first'), _track('successor')]);
      await _settle();
      expect(engine.plays, 0);
      expect(
        engine.appends,
        0,
        reason: 'no blocking queue work before first play',
      );
      engine.buffered = const Duration(seconds: 5);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(engine.plays, 1);
      expect(engine.appends, 1);
      expect(engine.preparedBeforePlay, isFalse);
      expect(state.playbackError, isNull);
      expect(state.audioReady, isTrue);
    },
  );

  test(
    'an uncached track waits for its opening seconds before playing',
    () async {
      final engine = _BufferingEngine();
      final state = stateFor(engine);
      addTearDown(state.dispose);
      state.playQueue(<Track>[_track('a')]);
      await _settle();

      expect(engine.loaded, <String>['https://cdn.test/a.mp3']);
      expect(engine.plays, 0, reason: 'ten seconds of stream must land first');
      expect(state.startupBuffering, isTrue);
      expect(state.audioReady, isFalse);

      engine.buffered = const Duration(seconds: 5);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(engine.plays, 1);
      expect(state.startupBuffering, isFalse);
      expect(state.audioReady, isTrue);
    },
  );

  test('an already buffered stream starts without waiting', () async {
    final engine = _BufferingEngine()..buffered = const Duration(seconds: 30);
    final state = stateFor(engine);
    addTearDown(state.dispose);
    state.playQueue(<Track>[_track('a')]);
    await _settle();
    expect(engine.plays, 1);
    expect(state.startupBuffering, isFalse);
  });

  test(
    'a native stream with unknown length starts on the first request',
    () async {
      final engine = _UnknownBufferEngine();
      final state = stateFor(engine);
      addTearDown(state.dispose);
      state.playQueue([_track('unknown-length')]);
      await _settle();
      expect(engine.plays, 1);
      expect(state.startupBuffering, isFalse);
      expect(state.audioReady, isTrue);
    },
  );

  test('a local or cached file starts immediately', () async {
    final engine = _BufferingEngine();
    final state = AppState(
      catalog: _Catalog(url: 'file:///music/a.mp3'),
      audioEngine: engine,
    );
    addTearDown(state.dispose);
    state.playQueue(<Track>[_track('a')]);
    await _settle();
    expect(engine.plays, 1);
    expect(state.startupBuffering, isFalse);
    expect(state.audioReady, isTrue);
  });

  test(
    'a stream that cannot fill the buffer starts anyway, at the deadline',
    () async {
      final engine = _BufferingEngine();
      final state = stateFor(
        engine,
        deadline: const Duration(milliseconds: 200),
      );
      addTearDown(state.dispose);
      state.playQueue(<Track>[_track('a')]);
      await _settle();
      expect(engine.plays, 0);

      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(
        engine.plays,
        1,
        reason: 'a slow CDN must not hold the track hostage',
      );
      expect(state.startupBuffering, isFalse);
    },
  );

  test(
    'pausing during the wait parks the track instead of starting it',
    () async {
      final engine = _BufferingEngine();
      final state = stateFor(engine);
      addTearDown(state.dispose);
      state.playQueue(<Track>[_track('a')]);
      await _settle();
      expect(state.startupBuffering, isTrue);

      state.pause();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(engine.plays, 0);
      expect(state.startupBuffering, isFalse);

      state.play();
      await _settle();
      expect(
        engine.plays,
        1,
        reason: 'the listener asked for sound, not more buffer',
      );
    },
  );

  test('a track change during the wait does not start the old track', () async {
    final engine = _BufferingEngine();
    final state = stateFor(engine);
    addTearDown(state.dispose);
    state.playQueue(<Track>[_track('a')]);
    await _settle();
    expect(state.startupBuffering, isTrue);

    state.playQueue(<Track>[_track('b')]);
    await _settle();
    engine.buffered = const Duration(seconds: 5);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(engine.loaded.last, 'https://cdn.test/b.mp3');
    expect(engine.plays, 1);
    expect(state.startupBuffering, isFalse);
  });
}
