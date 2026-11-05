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
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => 'https://cdn.test/${track.id}.mp3';

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

/// A network engine that can be made to stop delivering, the way a dead
/// download parks the decoder.
class _StreamingEngine
    implements
        AudioEngine,
        BufferedAudioEngine,
        StartupBufferReportingAudioEngine,
        StreamingBufferHealthAudioEngine,
        QueueAudioEngine {
  final StreamController<void> _completed = StreamController<void>.broadcast();
  final StreamController<int> _indexes = StreamController<int>.broadcast();
  final List<String> loaded = <String>[];

  @override
  bool active = false;

  @override
  Duration position = Duration.zero;

  /// Unknown on purpose: the app must not treat a missing duration as the end
  /// of the track.
  @override
  Duration? get duration => null;

  @override
  int? streamedBytes = 0;

  @override
  bool streamFailed = false;

  @override
  bool streamStalled = false;

  int restarts = 0;
  bool restartable = false;
  int plays = 0;
  int seeks = 0;
  int _queueId = 0;
  Duration? lastSeek;

  @override
  Future<void> setUrl(String url) async {
    loaded.add(url);
    active = true;
  }

  @override
  Future<int> setQueue(List<String> urls, {int startIndex = 0}) async {
    await setUrl(urls[startIndex]);
    return ++_queueId;
  }

  @override
  Future<bool> appendToQueue(int queueId, String url) async => false;

  @override
  Future<bool> playQueuedNext() async => false;

  @override
  Stream<int> get indexStream => _indexes.stream;

  @override
  Future<void> play() async => plays++;

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration value) async {
    seeks++;
    lastSeek = value;
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> stop() async => active = false;

  @override
  Duration get bufferedPosition => position;

  /// Unknown: the fraction cannot be measured, so the app must fall back to
  /// [streamedBytes] before starting playback.
  @override
  Duration? get startupBufferedPosition => null;

  @override
  bool restartStream() {
    restarts++;
    return restartable;
  }

  @override
  Stream<void> get completed => _completed.stream;

  @override
  void dispose() {
    _completed.close();
    _indexes.close();
  }
}

/// Lets the load path and the transport tick run.
Future<void> _settle([int turns = 10]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Waits for a condition the transport clock drives, instead of guessing a
/// duration: the app only notices a stall on its own 100 ms tick.
Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 6),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'a stream that dies under the decoder is reloaded from its position',
    () async {
      final engine = _StreamingEngine();
      final state = AppState(
        catalog: _Catalog(),
        audioEngine: engine,
        startupByteTarget: 0,
      );
      addTearDown(state.dispose);
      state.playQueue(<Track>[_track('a')]);
      await _settle();
      expect(engine.loaded, <String>['https://cdn.test/a.mp3']);
      expect(state.audioReady, isTrue);

      // Ten seconds in, the download dies: no bytes, no progress, and the
      // downloader's own failure report has not reached the app yet.
      engine.position = const Duration(seconds: 10);
      await _until(() => state.position == const Duration(seconds: 10));
      engine.streamStalled = true;
      engine.restartable = true;
      await _until(() => engine.restarts > 0);
      // The recovery reload is asynchronous. Wait for the seek it ends in rather
      // than for the stall flag to clear, which the reload itself does part-way
      // through and so can let the assertions below run ahead of the seek.
      await _until(() => engine.lastSeek != null);
      await _until(() => state.streamStalled == false);

      expect(
        engine.restarts,
        1,
        reason: 'the parked decoder must be released before the reload',
      );
      expect(engine.loaded, <String>[
        'https://cdn.test/a.mp3',
        'https://cdn.test/a.mp3',
      ], reason: 'the same source is reopened');
      expect(engine.lastSeek, const Duration(seconds: 10));
      expect(state.streamStalled, isFalse);
      expect(state.playbackError, isNull);
    },
  );

  test(
    'a stall that never recovers ends in a named error, not a dead player',
    () async {
      final engine = _StreamingEngine();
      final state = AppState(
        catalog: _Catalog(),
        audioEngine: engine,
        startupByteTarget: 0,
      );
      addTearDown(state.dispose);
      state.playQueue(<Track>[_track('a')]);
      await _settle();

      // The download is dead and stays dead: the retry budget runs out.
      engine.streamFailed = true;
      engine.restartable = true;
      await _until(() => !state.playing, timeout: const Duration(seconds: 12));

      expect(engine.restarts, AppState.maxStreamRetries);
      expect(state.playing, isFalse);
      expect(state.playbackError, isNotNull);
    },
  );

  test('a healthy stream is never restarted', () async {
    final engine = _StreamingEngine();
    final state = AppState(
      catalog: _Catalog(),
      audioEngine: engine,
      startupByteTarget: 0,
    );
    addTearDown(state.dispose);
    state.playQueue(<Track>[_track('a')]);
    await _settle();

    // The playhead keeps moving, so the watchdog must leave the stream alone
    // even though the download reports no measurable progress.
    for (var second = 1; second <= 4; second++) {
      engine.position = Duration(seconds: second);
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }

    expect(engine.restarts, 0);
    expect(state.streamStalled, isFalse);
    expect(state.playbackError, isNull);
  });
}
