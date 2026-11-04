// A track that has not finished downloading cannot be seeked into audio that has
// not arrived.
//
// The rail stops at what has landed, and a drag past that point says so instead of
// being clamped in silence — a silent clamp leaves the rail short of where the
// listener dropped it, and the attempt used to end with the sound restarting
// somewhere else entirely.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/state/app_state.dart';

const Track _track = Track(
  id: 'seek-limit',
  title: 'Seek limit',
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
  }) async => 'https://cdn.test/${track.id}.mp3';

  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => null;
}

/// A network source whose download has reached [buffered] and no further.
class _GrowingEngine
    implements
        AudioEngine,
        BufferedAudioEngine,
        SeekBoundaryReportingAudioEngine {
  _GrowingEngine({required this.buffered, this.limited = true});

  @override
  bool active = false;

  @override
  Duration position = Duration.zero;

  @override
  Duration? get duration => Duration.zero;

  Duration buffered;

  /// Whether seeking is bounded by the download, as it is for a growing file.
  final bool limited;

  final List<Duration> seekRequests = <Duration>[];

  @override
  Duration get bufferedPosition => buffered;

  @override
  bool get seekIsLimitedByBuffer => limited;

  @override
  Future<void> setUrl(String url) async => active = true;

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration value) async => seekRequests.add(value);

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> stop() async => active = false;

  @override
  Stream<void> get completed => const Stream<void>.empty();

  @override
  void dispose() {}
}

Future<AppState> _stateFor(_GrowingEngine engine) async {
  final AppState state = AppState(
    catalog: _Catalog(),
    audioEngine: engine,
    startupByteTarget: 0,
    startupBufferTarget: Duration.zero,
  );
  state.playQueue(<Track>[_track]);
  await Future<void>.delayed(Duration.zero);
  engine.position = const Duration(seconds: 20);
  await Future<void>.delayed(const Duration(milliseconds: 150));
  return state;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a drag past the downloaded part is refused, and says so', () async {
    final engine = _GrowingEngine(buffered: _track.duration * 0.6);
    final state = await _stateFor(engine);
    addTearDown(state.dispose);

    // The listener drags to the end of a track that is 60 % on disk.
    state.seek(0.95);

    expect(
      state.seekNotice.value,
      '还没加载完，无法跳转进度',
      reason: 'the refusal is stated instead of being applied somewhere else',
    );
    expect(
      engine.seekRequests,
      isEmpty,
      reason: 'nothing is asked of the engine: there is no audio there yet',
    );
    expect(
      state.position,
      const Duration(seconds: 20),
      reason: 'and the playhead stays exactly where the listener was',
    );
  });

  test('a drag to the edge of what has loaded still seeks', () async {
    final engine = _GrowingEngine(buffered: _track.duration * 0.6);
    final state = await _stateFor(engine);
    addTearDown(state.dispose);

    // Right on the edge, and a hair past it: both mean "the loaded part".
    state.seek(0.6);
    expect(state.seekNotice.value, isNull);
    expect(engine.seekRequests, <Duration>[_track.duration * 0.6]);

    state.seek(0.605);
    expect(state.seekNotice.value, isNull);
    expect(
      engine.seekRequests.last,
      _track.duration * 0.6,
      reason: 'a hair past the edge is the edge, not a jump into missing audio',
    );
  });

  test(
    'the message is not repeated for every pointer move of one drag',
    () async {
      final engine = _GrowingEngine(buffered: _track.duration * 0.6);
      final state = await _stateFor(engine);
      addTearDown(state.dispose);

      // A drag produces one call per pointer move; the first reports, the rest are
      // the same complaint and would only stack messages.
      state.seek(0.95);
      expect(state.seekNotice.value, isNotNull);
      state.seekNotice.value = null; // as the UI does once it has shown it
      state.seek(0.97);
      state.seek(0.99);
      expect(state.seekNotice.value, isNull);
    },
  );

  test('a seek inside the downloaded part is not refused', () async {
    final engine = _GrowingEngine(buffered: _track.duration * 0.6);
    final state = await _stateFor(engine);
    addTearDown(state.dispose);

    state.seek(0.4);

    expect(state.seekNotice.value, isNull);
    expect(engine.seekRequests, <Duration>[_track.duration * 0.4]);
    expect(state.position, _track.duration * 0.4);
  });

  test('a fully downloaded track seeks anywhere', () async {
    final engine = _GrowingEngine(buffered: _track.duration, limited: false);
    final state = await _stateFor(engine);
    addTearDown(state.dispose);

    expect(state.seekLimitFraction, 1);
    state.seek(0.95);

    expect(state.seekNotice.value, isNull);
    expect(engine.seekRequests, <Duration>[_track.duration * 0.95]);
    expect(state.position, _track.duration * 0.95);
  });
}
