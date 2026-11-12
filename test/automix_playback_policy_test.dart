import 'support/music_gateway.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/data/track_transition.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Engine implements AudioEngine {
  final volumes = <double>[];
  final completions = StreamController<void>.broadcast();
  bool loaded = false;

  @override
  bool get active => loaded;

  @override
  Duration position = Duration.zero;

  @override
  Duration? get duration => const Duration(minutes: 3);

  @override
  Stream<void> get completed => completions.stream;

  @override
  Future<void> setUrl(String url) async => loaded = true;

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration value) async => position = value;

  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);

  @override
  Future<void> stop() async => loaded = false;

  @override
  void dispose() => unawaited(completions.close());
}

class _MixQueueEngine extends _Engine
    implements
        QueueAudioEngine,
        AutoMixConfigurableAudioEngine,
        QueuedSourceReportingAudioEngine,
        MixPresentingAudioEngine {
  final configurations = <bool>[];
  final queueLoads = <String>[];
  final prepared = <String>[];
  final indexes = StreamController<int>.broadcast();
  int _queueId = 0;
  bool rejectConfiguration = false;
  bool presented = false;
  bool rejectAppendWhilePresented = false;

  /// The successor the engine holds: it survives the start of an overlap and is
  /// consumed by the hand-off, exactly like a real second decoder.
  String? _successor;

  @override
  String? get queuedSourceUrl => _successor;

  @override
  bool get mixPresented => presented;

  @override
  Future<void> setAutoMixEnabled(bool enabled) async {
    if (rejectConfiguration) throw UnsupportedError('No overlap mixer');
    configurations.add(enabled);
  }

  @override
  Stream<int> get indexStream => indexes.stream;

  @override
  Future<int> setQueue(List<String> urls, {int startIndex = 0}) async {
    loaded = true;
    queueLoads.add(urls[startIndex]);
    _successor = null;
    return ++_queueId;
  }

  @override
  Future<bool> appendToQueue(int queueId, String url) async {
    if (queueId != _queueId || (presented && rejectAppendWhilePresented)) {
      return false;
    }
    prepared.add(url);
    _successor = url;
    return true;
  }

  @override
  Future<bool> playQueuedNext() async => false;

  @override
  Future<void> seek(Duration value) async {
    // A real engine drops the incoming side of an overlap when it seeks and
    // keeps the successor queued.
    presented = false;
    position = value;
  }

  /// The overlap starts: the incoming decoder is audible, the outgoing one is
  /// still the active source until the hand-off.
  void advanceAt(Duration incomingPosition) {
    presented = true;
    position = incomingPosition;
    indexes.add(1);
  }

  /// The outgoing source ended: the incoming decoder is promoted.
  void finishMix() {
    presented = false;
    _successor = null;
    indexes.add(1);
  }

  /// A preparation that lost its race: the successor is gone.
  void dropSuccessor() {
    presented = false;
    _successor = null;
  }

  /// The engine crossed into its queued successor by itself, without an overlap:
  /// a gapless hand-off inside an album.
  void crossIntoNext() {
    _successor = null;
    indexes.add(1);
  }

  @override
  void dispose() {
    unawaited(indexes.close());
    super.dispose();
  }
}

class _Gateway extends TestMusicGateway {}

class _Catalog extends Catalog {
  _Catalog() : super(gateway: _Gateway());

  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
    bool Function()? isCancelled,
  }) async => 'url-${track.id}';

  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => const GatewayLyrics();
}

Track _track(
  String id, {
  String album = 'Album',
  String artist = 'Artist',
  int albumId = 0,
  String? albumKey,
  String? localPath,
}) => Track(
  id: id,
  title: 'Track $id',
  artist: artist,
  album: album,
  duration: const Duration(minutes: 3),
  coverSeed: 1,
  albumId: albumId,
  albumKey: albumKey,
  localPath: localPath,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final enabledAtStart in <bool>[true, false]) {
    testWidgets(
      'AutoMix ${enabledAtStart ? 'at startup' : 'enabled during playback'} '
      'never fades a lone decoder into silence',
      (tester) async {
        final engine = _Engine();
        final state = AppState(
          catalog: _Catalog(),
          audioEngine: engine,
          autoMixEnabled: enabledAtStart,
        );
        addTearDown(engine.dispose);
        state.playQueue(<Track>[_track('1'), _track('2')]);
        await tester.pump();
        if (!enabledAtStart) await state.setAutoMixEnabled(true);
        expect(state.playing, isTrue);

        engine.volumes.clear();
        engine.position = const Duration(seconds: 178);
        await tester.pump(AppState.playbackInterval);

        // Only an engine with both sources running may own a mix envelope.
        // AppState must never mute the playing song on a backend that cannot
        // supply the other half of that envelope.
        expect(engine.volumes, everyElement(1.0));
        expect(state.current?.id, '1');
        expect(state.playing, isTrue);
        state.dispose();
      },
    );
  }

  testWidgets('AutoMix settings reach any backend with mixing capability', (
    tester,
  ) async {
    final engine = _MixQueueEngine();
    final state = AppState(catalog: _Catalog(), audioEngine: engine);
    addTearDown(engine.dispose);
    state.playQueue(<Track>[_track('1'), _track('2')]);
    await tester.pump();

    await state.setAutoMixEnabled(true);
    await tester.pump();
    await state.setAutoMixEnabled(false);
    await tester.pump();

    expect(engine.configurations, containsAllInOrder(<bool>[true, false]));
    expect(state.current?.id, '1');
    expect(state.playing, isTrue);
    expect(engine.queueLoads, <String>['url-1']);
    state.dispose();
  });

  testWidgets('handoff retains the already audible incoming song position', (
    tester,
  ) async {
    final engine = _MixQueueEngine();
    final state = AppState(
      catalog: _Catalog(),
      audioEngine: engine,
      autoMixEnabled: true,
    );
    addTearDown(engine.dispose);
    state.playQueue(<Track>[_track('1'), _track('2'), _track('3')]);
    await tester.pump();
    expect(engine.prepared, <String>['url-2']);

    engine.advanceAt(const Duration(seconds: 6));
    await tester.pump();

    expect(state.current?.id, '2');
    expect(state.position, const Duration(seconds: 6));
    expect(engine.queueLoads, <String>['url-1']);
    // Track 3 is prepared by the hand-off, not by the announcement: the engine
    // refuses a second successor while the prepared one is being mixed in, and
    // the preparation that loses that race clears the queued reader — which fades
    // the song that is supposed to be fading *in* back out.
    expect(engine.prepared, <String>['url-2']);
    expect(state.playing, isTrue);
    state.dispose();
  });

  testWidgets(
    'manual next during an AutoMix overlap reloads the requested song',
    (tester) async {
      final engine = _MixQueueEngine()..rejectAppendWhilePresented = true;
      final state = AppState(
        catalog: _Catalog(),
        audioEngine: engine,
        autoMixEnabled: true,
      );
      addTearDown(state.dispose);
      state.playQueue(<Track>[_track('1'), _track('2'), _track('3')]);
      await tester.pump();
      expect(engine.prepared, <String>['url-2']);

      engine.advanceAt(const Duration(seconds: 6));
      await tester.pump();
      expect(state.current?.id, '2');

      // The second decoder is the presented track, so it cannot also serve as
      // the next successor. The manual skip must reload track 3 rather than
      // promoting the audible overlapping track again.
      state.next();
      await tester.pump();
      expect(state.current?.id, '3');
      expect(engine.queueLoads, <String>['url-1', 'url-3']);
      expect(state.playing, isTrue);
      state.pause();
      await tester.pump();
    },
  );

  testWidgets('a refused AutoMix change preserves the healthy playback', (
    tester,
  ) async {
    final engine = _MixQueueEngine()..rejectConfiguration = true;
    final state = AppState(catalog: _Catalog(), audioEngine: engine);
    addTearDown(engine.dispose);
    state.playQueue(<Track>[_track('1'), _track('2')]);
    await tester.pump();
    engine.position = const Duration(seconds: 40);

    await state.setAutoMixEnabled(true);
    await tester.pump();

    expect(state.autoMixEnabled, isFalse);
    expect(state.autoMixError, isNotEmpty);
    expect(state.playbackError, isNull);
    expect(state.playing, isTrue);
    expect(engine.position, const Duration(seconds: 40));
    expect(engine.queueLoads, <String>['url-1']);
    expect(
      (await SharedPreferences.getInstance()).getBool('lazer_automix_enabled'),
      isNot(true),
    );
    state.dispose();
  });

  testWidgets('the successor is not replaced while the overlap is audible', (
    tester,
  ) async {
    final engine = _MixQueueEngine();
    final state = AppState(
      catalog: _Catalog(),
      audioEngine: engine,
      autoMixEnabled: true,
    );
    addTearDown(engine.dispose);
    state.playQueue(<Track>[_track('1'), _track('2'), _track('3')]);
    await tester.pump();
    expect(engine.prepared, <String>['url-2']);

    // The overlap starts. Preparing track 3 now would ask the engine for a
    // second successor, which fails and clears the queued reader — the song
    // being mixed in would fade back out.
    engine.advanceAt(const Duration(seconds: 6));
    await tester.pump();
    await tester.pump();
    expect(state.current?.id, '2');

    // The hand-off completes: the incoming decoder is the active source, so the
    // successor is prepared then.
    engine.finishMix();
    await tester.pump();
    await tester.pump();
    expect(state.current?.id, '2');
    expect(engine.prepared.last, 'url-3');
    state.dispose();
  });

  testWidgets('a seek during the overlap returns to the outgoing song', (
    tester,
  ) async {
    final engine = _MixQueueEngine();
    final state = AppState(
      catalog: _Catalog(),
      audioEngine: engine,
      autoMixEnabled: true,
    );
    addTearDown(engine.dispose);
    state.playQueue(<Track>[_track('1'), _track('2'), _track('3')]);
    await tester.pump();
    engine.advanceAt(const Duration(seconds: 6));
    await tester.pump();
    expect(state.current?.id, '2');

    // The engine cancels the overlap when it seeks, so the outgoing song is what
    // is heard again: the queue must follow it back instead of running a song
    // ahead of the audio.
    state.seek(0.5);
    await tester.pump();
    expect(state.current?.id, '1');
    expect(engine.position, _track('1').duration * 0.5);
    expect(state.playing, isTrue);
    // The song that was being mixed in is still the engine's successor.
    expect(engine.queuedSourceUrl, 'url-2');
    state.dispose();
  });

  testWidgets(
    'a dropped successor cannot leave playback waiting for a handoff',
    (tester) async {
      final engine = _MixQueueEngine();
      final state = AppState(
        catalog: _Catalog(),
        audioEngine: engine,
        autoMixEnabled: true,
      );
      addTearDown(engine.dispose);
      state.playQueue(<Track>[_track('1'), _track('2')]);
      await tester.pump();
      expect(engine.prepared, <String>['url-2']);

      // The preparation loses its race: the engine holds no successor, so the
      // hand-off the app expects can never arrive. Reaching the end of the track
      // must advance the queue instead of standing still in silence.
      engine.dropSuccessor();
      engine.position = _track('1').duration;
      await tester.pump(AppState.playbackInterval);
      await tester.pump();

      expect(state.current?.id, '2');
      expect(state.playing, isTrue);
      state.dispose();
    },
  );

  testWidgets('changing to single repeat replaces the pending mix successor', (
    tester,
  ) async {
    final engine = _MixQueueEngine();
    final state = AppState(
      catalog: _Catalog(),
      audioEngine: engine,
      autoMixEnabled: true,
    );
    addTearDown(engine.dispose);
    state.playQueue(<Track>[_track('1'), _track('2')]);
    await tester.pump();
    expect(engine.prepared.last, 'url-2');
    engine.position = const Duration(seconds: 40);
    await tester.pump(AppState.playbackInterval);

    state.cycleRepeat();
    state.cycleRepeat();
    await tester.pump();

    expect(engine.prepared.last, 'url-1');
    expect(state.current?.id, '1');
    expect(engine.position, const Duration(seconds: 40));
    expect(state.playing, isTrue);
    state.dispose();
  });

  test('album identity follows the catalogue, then the tags', () {
    expect(
      _track('a', albumId: 7).continuesInto(_track('b', albumId: 7)),
      isTrue,
    );
    expect(
      _track('a', albumId: 7).continuesInto(_track('b', albumId: 8)),
      isFalse,
    );
    expect(
      _track(
        'a',
        albumKey: 'netmusic:user:album:12',
      ).continuesInto(_track('b', albumKey: 'netmusic:user:album:12')),
      isTrue,
    );
    // A downloaded file keeps the album of the release it came from, so the
    // catalogue identity still decides.
    expect(
      _track('a', albumId: 7).continuesInto(
        _track('b', albumId: 7, localPath: '/music/b.flac'),
      ),
      isTrue,
    );
    // A scanned file only kept the tags: album name and performer stand in.
    expect(
      _track('a', album: 'Kind of Blue', artist: 'Miles Davis').continuesInto(
        _track('b', album: 'Kind of Blue', artist: 'Miles Davis'),
      ),
      isTrue,
    );
    expect(
      _track('a', album: 'Kind of Blue', artist: 'Miles Davis').continuesInto(
        _track('b', album: 'Kind of Blue', artist: 'Bill Evans'),
      ),
      isFalse,
    );
    // Untagged files would otherwise all count as one album.
    expect(
      _track('a', album: Track.unknownAlbum).continuesInto(
        _track('b', album: Track.unknownAlbum),
      ),
      isFalse,
    );
    // One known and one unknown album never share an identity.
    expect(
      _track('a', albumId: 7).continuesInto(
        _track('b', album: 'Kind of Blue', artist: 'Miles Davis'),
      ),
      isFalse,
    );
    expect(_track('a', albumId: 7).continuesInto(null), isFalse);
  });

  testWidgets('album gapless playback prepares only the next song of the album', (
    tester,
  ) async {
    final engine = _MixQueueEngine();
    final state = AppState(catalog: _Catalog(), audioEngine: engine);
    addTearDown(engine.dispose);
    state.playQueue(<Track>[
      _track('1', albumId: 7),
      _track('2', albumId: 7),
      _track('3', albumId: 9),
    ]);
    await tester.pump();

    expect(state.trackTransition, TrackTransition.albumGapless);
    expect(state.nextTrackContinuesAlbum, isTrue);
    expect(state.successorPrepared, isTrue);
    expect(engine.prepared, <String>['url-2']);

    // The engine runs join to join inside the album: no reload, no gap.
    engine.crossIntoNext();
    await tester.pump();
    expect(state.current?.id, '2');
    expect(engine.queueLoads, <String>['url-1']);

    // The following song is another album, so the engine is given nothing to
    // cross into and the queue advances by loading it.
    expect(state.nextTrackContinuesAlbum, isFalse);
    expect(state.successorPrepared, isFalse);
    expect(engine.prepared, <String>['url-2']);

    engine.completions.add(null);
    await tester.pump();
    expect(state.current?.id, '3');
    expect(engine.queueLoads, <String>['url-1', 'url-3']);
    expect(state.playing, isTrue);
    state.dispose();
  });

  testWidgets('AutoMix replaces album gapless playback across albums', (
    tester,
  ) async {
    final engine = _MixQueueEngine();
    final state = AppState(
      catalog: _Catalog(),
      audioEngine: engine,
      autoMixEnabled: true,
    );
    addTearDown(engine.dispose);
    state.playQueue(<Track>[
      _track('1', albumId: 7),
      _track('2', albumId: 7),
      _track('3', albumId: 9),
    ]);
    await tester.pump();
    expect(state.trackTransition, TrackTransition.autoMix);
    expect(engine.prepared, <String>['url-2']);

    engine.crossIntoNext();
    await tester.pump();

    expect(state.current?.id, '2');
    // AutoMix keeps the hand-off going even though the next song belongs to
    // another album: that is what it replaces album gapless playback with.
    expect(state.nextTrackContinuesAlbum, isFalse);
    expect(engine.prepared, <String>['url-2', 'url-3']);
    state.dispose();
  });

  testWidgets('leaving AutoMix takes back a successor from another album', (
    tester,
  ) async {
    final engine = _MixQueueEngine();
    final state = AppState(
      catalog: _Catalog(),
      audioEngine: engine,
      autoMixEnabled: true,
    );
    addTearDown(engine.dispose);
    state.playQueue(<Track>[_track('1', albumId: 7), _track('2', albumId: 9)]);
    await tester.pump();
    expect(engine.prepared, <String>['url-2']);

    await state.setAutoMixEnabled(false);
    await tester.pump();

    expect(state.trackTransition, TrackTransition.albumGapless);
    // Only reopening the source takes a prepared successor back from the engine,
    // and the boundary then cuts as a different album should.
    expect(engine.queueLoads, <String>['url-1', 'url-1']);
    expect(engine.queuedSourceUrl, isNull);
    expect(state.successorPrepared, isFalse);
    expect(state.playing, isTrue);
    state.dispose();
  });
}
