import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/local/local_library.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/playback_queue_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

Track _track(String id) => Track(
  id: id,
  title: 'Song $id',
  artist: 'Artist',
  album: 'Album',
  duration: const Duration(minutes: 3),
  coverSeed: 1,
);

class _Catalog extends Catalog {
  @override
  Future<HomeFeed?> loadHome({int? userId}) async => null;
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
    bool Function()? isCancelled,
  }) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => const GatewayLyrics();
}

class _Library extends LocalLibrary {}

/// Builds a state whose queue plays through the service catalogue only, so the
/// tests exercise queue bookkeeping without an audio engine.
({AppState state, _Library library}) _booted() {
  final library = _Library();
  final state = AppState(
    catalog: _Catalog(),
    localLibrary: library,
    queueStore: PlaybackQueueStore(read: () async => null, write: (_) async {}),
  );
  return (state: state, library: library);
}

List<String> _ids(AppState state) =>
    state.queue.map((Track track) => track.id).toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('queueNext puts the song straight after the current one', () {
    final booted = _booted();
    final state = booted.state;
    state.playQueue(<Track>[_track('a'), _track('b'), _track('c')]);

    expect(state.queueNext(_track('x')), isTrue);

    expect(_ids(state), <String>['a', 'x', 'b', 'c']);
    state.dispose();
    booted.library.dispose();
  });

  test(
    'queueNext moves a song queued further ahead instead of repeating it',
    () {
      final booted = _booted();
      final state = booted.state;
      state.playQueue(<Track>[
        _track('a'),
        _track('b'),
        _track('c'),
        _track('d'),
      ]);

      expect(state.queueNext(_track('d')), isTrue);
      expect(_ids(state), <String>['a', 'd', 'b', 'c']);
      // Asked for again while it is already the successor: nothing to move.
      expect(state.queueNext(_track('d')), isFalse);
      expect(_ids(state), <String>['a', 'd', 'b', 'c']);
      state.dispose();
      booted.library.dispose();
    },
  );

  test('queueNext ignores the current song and an empty queue', () {
    final booted = _booted();
    final state = booted.state;

    expect(state.queueNext(_track('a')), isFalse);
    state.playQueue(<Track>[_track('a'), _track('b')]);
    expect(state.queueNext(_track('a')), isFalse);
    expect(_ids(state), <String>['a', 'b']);
    state.dispose();
    booted.library.dispose();
  });

  test('enqueueTrack appends and keeps duplicate entries', () {
    final booted = _booted();
    final state = booted.state;
    state.playQueue(<Track>[_track('a'), _track('b')]);

    expect(state.enqueueTrack(_track('b')), isTrue);
    expect(state.enqueueTrack(_track('c')), isTrue);

    expect(_ids(state), <String>['a', 'b', 'b', 'c']);
    state.dispose();
    booted.library.dispose();
  });

  test('removeQueuedAt drops a later entry and refuses earlier ones', () {
    final booted = _booted();
    final state = booted.state;
    state.playQueue(<Track>[
      _track('a'),
      _track('b'),
      _track('c'),
      _track('d'),
    ]);
    state.playTrackAt(1);

    expect(_ids(state), <String>['a', 'b', 'c', 'd']);
    expect(state.removeQueuedAt(2), isTrue);
    expect(_ids(state), <String>['a', 'b', 'd']);

    // The playing song and everything before it are not queue edits.
    expect(state.removeQueuedAt(1), isFalse);
    expect(state.removeQueuedAt(0), isFalse);
    expect(state.removeQueuedAt(7), isFalse);
    expect(_ids(state), <String>['a', 'b', 'd']);
    state.dispose();
    booted.library.dispose();
  });
}
