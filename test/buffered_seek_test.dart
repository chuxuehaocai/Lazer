import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/state/app_state.dart';

const Track _track = Track(
  id: 'buffered-seek',
  title: 'Buffered seek',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 4),
  coverSeed: 1,
);

class _Catalog extends Catalog {
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
    bool Function()? isCancelled,
  }) async => 'https://cdn.test/${track.id}.mp3';

  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => null;
}

/// An incomplete network source: seeking is bounded by the buffer, and the
/// engine keeps reporting the pre-seek position until the demuxer applies it.
class _BufferedNetworkEngine
    implements
        AudioEngine,
        BufferedAudioEngine,
        StartupBufferReportingAudioEngine,
        SeekBoundaryReportingAudioEngine,
        SeekRangeReportingAudioEngine,
        StreamingBufferHealthAudioEngine {
  /// Whether a seek past the buffered part is refused: the download is the only
  /// source of bytes, so a position it has not reached cannot be reached.
  @override
  bool canSeekTo(Duration position) => position <= bufferedPosition;

  @override
  bool active = false;

  @override
  Duration position = Duration.zero;

  @override
  Duration? get duration => Duration.zero;

  Duration _buffered = Duration.zero;
  final List<Duration> seekRequests = <Duration>[];

  set buffered(Duration value) => _buffered = value;

  @override
  Duration get bufferedPosition => _buffered;

  @override
  bool get seekIsLimitedByBuffer => true;

  @override
  Duration? get startupBufferedPosition => bufferedPosition;

  @override
  int? get streamedBytes => 4096;

  /// The recovery path under test drives these; the failing-stream case turns
  /// them on so the watchdog reloads the source.
  @override
  bool streamFailed = false;

  @override
  bool streamStalled = false;
  bool restartable = false;
  int restarts = 0;

  @override
  bool restartStream() {
    restarts++;
    return restartable;
  }

  @override
  Future<void> setUrl(String url) async => active = true;

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration value) async {
    seekRequests.add(value);
    // Deliberately does not move `position`: a growing file is applied by the
    // demuxer later, which is the window this test is about.
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> stop() async => active = false;

  @override
  Stream<void> get completed => const Stream<void>.empty();

  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'a seek past the buffer is clamped, and the rail holds the target until the engine applies it',
    () async {
      final engine = _BufferedNetworkEngine();
      final state = AppState(
        catalog: _Catalog(),
        audioEngine: engine,
        startupByteTarget: 0,
        startupBufferTarget: Duration.zero,
      );
      addTearDown(state.dispose);
      state.playQueue(<Track>[_track]);
      await Future<void>.delayed(Duration.zero);
      expect(state.audioReady, isTrue);

      // Twenty seconds in, with 75 % of the track on disk.
      engine.position = const Duration(seconds: 20);
      engine.buffered = _track.duration * 0.75;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(state.position, const Duration(seconds: 20));

      // The listener drags past what has been buffered.
      state.seek(0.9);
      expect(
        state.position,
        _track.duration * 0.75,
        reason: 'the seek is clamped to the buffered region',
      );
      expect(engine.seekRequests, <Duration>[_track.duration * 0.75]);

      // The demuxer has not applied it yet: the engine still reports 20 s, and
      // it keeps doing so for long enough that a heuristic which gives up after
      // a moment would publish that value. The rail must not snap back there —
      // that reads as "从头开始".
      engine.position = const Duration(seconds: 20);
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      expect(
        state.precisePosition,
        _track.duration * 0.75,
        reason:
            'the pre-seek position must not be published while a seek lands',
      );
      expect(state.seekInFlight, isTrue);
      expect(state.progress, closeTo(0.75, 1e-9));

      // Once the engine's clock lands on the target, its own value wins.
      engine.position = _track.duration * 0.75;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(state.precisePosition, _track.duration * 0.75);
      expect(state.position, _track.duration * 0.75);
      expect(state.seekInFlight, isFalse);
    },
  );

  test(
    'a seek past the buffer is refused by the engine and the rail snaps back',
    () async {
      final engine = _BufferedNetworkEngine();
      final state = AppState(
        catalog: _Catalog(),
        audioEngine: engine,
        startupByteTarget: 0,
        startupBufferTarget: Duration.zero,
      );
      addTearDown(state.dispose);
      state.playQueue(<Track>[_track]);
      await Future<void>.delayed(Duration.zero);
      expect(state.audioReady, isTrue);

      engine.position = const Duration(seconds: 20);
      engine.buffered = _track.duration * 0.75;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(state.seekLimitFraction, closeTo(0.75, 1e-9));

      // The engine is the one that knows how far its download has reached: a
      // position inside the cached part is seekable, one past it is not.
      expect(engine.canSeekTo(_track.duration * 0.5), isTrue);
      expect(engine.canSeekTo(_track.duration * 0.9), isFalse);

      // The rail clamps to the cached part, and the request that reaches the
      // engine is the clamped one — never the unreachable position.
      state.seek(0.9);
      expect(state.position, _track.duration * 0.75);
      expect(engine.seekRequests, <Duration>[_track.duration * 0.75]);
    },
  );

  test(
    'a stream that dies while a seek is being applied resumes at the target',
    () async {
      final engine = _BufferedNetworkEngine();
      final state = AppState(
        catalog: _Catalog(),
        audioEngine: engine,
        startupByteTarget: 0,
        startupBufferTarget: Duration.zero,
      );
      addTearDown(state.dispose);
      state.playQueue(<Track>[_track]);
      await Future<void>.delayed(Duration.zero);

      engine.position = const Duration(seconds: 20);
      engine.buffered = _track.duration * 0.75;
      await Future<void>.delayed(const Duration(milliseconds: 150));

      final Duration target = _track.duration * 0.75;
      state.seek(0.75);
      expect(engine.seekRequests, <Duration>[target]);

      // The download dies while the demuxer is still applying the jump. The
      // engine keeps reporting the pre-seek position throughout.
      engine.streamStalled = true;
      engine.restartable = true;
      await Future<void>.delayed(const Duration(milliseconds: 1800));

      expect(engine.restarts, greaterThan(0));
      expect(
        engine.seekRequests.last,
        target,
        reason:
            'the reload must resume at the requested position, not at where '
            'the decode thread still was',
      );
      expect(engine.seekRequests.length, greaterThan(1));
    },
  );

  test(
    'a fresh load never inherits the previous track\'s seek target',
    () async {
      final engine = _BufferedNetworkEngine();
      final state = AppState(
        catalog: _Catalog(),
        audioEngine: engine,
        startupByteTarget: 0,
        startupBufferTarget: Duration.zero,
      );
      addTearDown(state.dispose);
      state.playQueue(<Track>[_track]);
      await Future<void>.delayed(Duration.zero);

      engine.position = const Duration(seconds: 20);
      engine.buffered = _track.duration * 0.75;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      state.seek(0.5);
      expect(state.precisePosition, _track.duration * 0.5);

      // The engine never applied it, and the next track starts at zero.
      engine.position = Duration.zero;
      state.playQueue(<Track>[
        Track(
          id: 'next',
          title: 'Next',
          artist: 'Artist',
          album: 'Album',
          duration: const Duration(minutes: 4),
          coverSeed: 1,
        ),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(
        state.position,
        Duration.zero,
        reason:
            'a new source starts where it starts, not at a stale seek target',
      );
    },
  );
}
