import 'support/music_gateway.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart' show Colors;
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/track_transition.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
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
  Completer<void>? playPending;
  Completer<bool>? jumpPending;
  int stops = 0;
  int _queueId = 0;
  bool _active = false;
  bool _hasQueuedNext = false;
  bool queueJumpSucceeds = true;
  bool clearAccepted = true;
  int clears = 0;
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
  Future<bool> clearQueued(int queueId) async {
    if (queueId != _queueId || !clearAccepted) return false;
    clears++;
    _hasQueuedNext = false;
    return true;
  }

  @override
  Future<bool> playQueuedNext() async {
    jumps++;
    if (!_hasQueuedNext || !queueJumpSucceeds) return false;
    _hasQueuedNext = false;
    return await jumpPending?.future ?? true;
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
    await playPending?.future;
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

class _FlakyCatalog extends _Catalog {
  int resolves = 0;

  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
    bool Function()? isCancelled,
  }) async {
    resolves++;
    if (resolves == 1) throw const SocketException('temporary network miss');
    return super.audioUrlFor(track, quality: quality, isCancelled: isCancelled);
  }
}

class _HeartCatalog extends _Catalog {
  final requests = <Completer<List<Track>>>[];
  final seeds = <String?>[];
  @override
  Future<List<Track>> heartModeTracks(
    Playlist liked, {
    int? seedSongId,
    String? seedTrackId,
    int count = 30,
  }) {
    seeds.add(seedTrackId);
    final request = Completer<List<Track>>();
    requests.add(request);
    return request.future;
  }
}

Track _track(String id, {Duration duration = const Duration(minutes: 3)}) =>
    Track(
      id: id,
      title: 'Track $id',
      artist: 'Artist',
      album: 'Album',
      duration: duration,
      coverSeed: 1,
    );

class _ConfigQueueEngine extends _QueueEngine
    implements AutoMixConfigurableAudioEngine {
  final configurations = <(bool, Duration?)>[];
  Completer<void>? nextConfiguration;
  bool rejectConfiguration = false;
  @override
  Future<void> setAutoMixEnabled(bool enabled, {Duration? duration}) async {
    configurations.add((enabled, duration));
    final gate = nextConfiguration;
    nextConfiguration = null;
    await gate?.future;
    if (rejectConfiguration) throw StateError('unsupported mix configuration');
  }
}

class _MixQueueEngine extends _QueueEngine implements MixPresentingAudioEngine {
  @override
  bool mixPresented = false;

  @override
  Future<void> seek(Duration value) async {
    mixPresented = false;
    await super.seek(value);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('heart mode carries complete song IDs between batches', (
    tester,
  ) async {
    final catalog = _HeartCatalog();
    final state = AppState(catalog: catalog, audioEngine: _PlainEngine());
    addTearDown(state.dispose);
    state.collections = const UserCollections(
      liked: Playlist(id: 'liked', name: 'Liked', trackIds: [], coverSeed: 0),
    );
    state.playQueue([_track('fixture:test:song:alpha')]);
    await tester.pump();
    final started = state.startHeartMode();
    catalog.requests.single.complete([_track('fixture:test:song:beta')]);
    await tester.pump();
    expect(await started, isTrue);
    expect(catalog.seeds, [
      'fixture:test:song:alpha',
      'fixture:test:song:beta',
    ]);
    catalog.requests.last.complete([_track('fixture:test:song:gamma')]);
    await tester.pump();
    state.pause();
    await tester.pump();
  });

  testWidgets(
    'fractional seek uses the outgoing duration when cancelling a mix',
    (tester) async {
      final engine = _MixQueueEngine();
      final state = AppState(catalog: _Catalog(), audioEngine: engine);
      addTearDown(state.dispose);
      state.playQueue([
        _track('outgoing', duration: const Duration(seconds: 60)),
        _track('incoming', duration: const Duration(seconds: 600)),
      ]);
      await tester.pump();
      expect(engine.appends, ['url-incoming']);
      engine.mixPresented = true;
      engine.crossIntoNext();
      await tester.pump();
      expect(state.current?.id, 'incoming');
      state.seek(0.5);
      await tester.pump();
      expect(state.current?.id, 'outgoing');
      expect(engine.position, const Duration(seconds: 30));
      expect(state.position, const Duration(seconds: 30));
      state.pause();
      await tester.pump();
    },
  );

  for (final leave in ['queue', 'dispose', 'pause']) {
    testWidgets('a late heart-mode result cannot override $leave', (
      tester,
    ) async {
      final catalog = _HeartCatalog();
      final state = AppState(catalog: catalog, audioEngine: _PlainEngine());
      state.collections = const UserCollections(
        liked: Playlist(id: 'liked', name: 'Liked', trackIds: [], coverSeed: 0),
      );
      state.playQueue([_track('old')]);
      await tester.pump();
      final pending = state.startHeartMode();
      switch (leave) {
        case 'queue':
          state.playQueue([_track('new')]);
        case 'dispose':
          state.dispose();
        case 'pause':
          state.pause();
      }
      await tester.pump();
      catalog.requests.single.complete([_track('late')]);
      await tester.pump();
      expect(await pending, isFalse);
      expect(catalog.requests, hasLength(1));
      if (leave != 'dispose') {
        expect(state.current?.id, leave == 'queue' ? 'new' : 'old');
        state.dispose();
      }
    });
  }

  testWidgets('absolute seek can return to the start of the current source', (
    tester,
  ) async {
    final engine = _PlainEngine();
    final state = AppState(catalog: _Catalog(), audioEngine: engine);
    addTearDown(state.dispose);
    state.playQueue([_track('one')]);
    await tester.pump();
    await state.seekTo(const Duration(seconds: 20));
    expect(engine.position, const Duration(seconds: 20));
    await state.seekTo(Duration.zero);
    expect(engine.position, Duration.zero);
    expect(state.position, Duration.zero);
    state.pause();
    await tester.pump();
  });

  testWidgets(
    'Next at a paused station tail selects the refilled track without playing',
    (tester) async {
      final response = Completer<List<Track>>();
      final engine = _PlainEngine();
      final state = AppState(catalog: _Catalog(), audioEngine: engine);
      addTearDown(state.dispose);
      state.playStationQueue([_track('old')], loadMore: () => response.future);
      await tester.pump();
      state.pause();
      state.next();
      response.complete([_track('new')]);
      await tester.pump();
      expect(state.current?.id, 'new');
      expect(state.playing, isFalse);
      expect(engine.loads, ['url-old']);
    },
  );

  testWidgets('station trim preserves a shuffled successor in older history', (
    tester,
  ) async {
    final response = Completer<List<Track>>();
    final engine = _QueueEngine();
    final state = AppState(
      catalog: _Catalog(),
      audioEngine: engine,
      shuffleRandom: Random(7),
    );
    addTearDown(state.dispose);
    state.playStationQueue([
      for (var i = 0; i < 256; i++) _track('$i'),
    ], loadMore: () => response.future);
    await tester.pump();
    state.playTrackAt(251);
    await tester.pump();
    state.toggleShuffle();
    await tester.pump();
    expect(engine.appends.last, 'url-28');
    response.complete([for (var i = 256; i < 286; i++) _track('$i')]);
    await tester.pump();
    expect(state.queueLength, 256);
    expect(state.current?.id, '251');
    engine.crossIntoNext();
    await tester.pump();
    expect(state.current?.id, '28');
    state.pause();
    await tester.pump();
  });

  testWidgets('station history trim does not cancel a pending queue handoff', (
    tester,
  ) async {
    final response = Completer<List<Track>>();
    final engine = _QueueEngine();
    final state = AppState(catalog: _Catalog(), audioEngine: engine);
    addTearDown(state.dispose);
    state.playStationQueue([
      for (var i = 0; i < 256; i++) _track('$i'),
    ], loadMore: () => response.future);
    await tester.pump();
    state.playTrackAt(250);
    await tester.pump();
    final calls = engine.playCalls;
    final gate = engine.jumpPending = Completer<bool>();
    state.next();
    await tester.pump();
    expect(engine.jumps, 1);
    response.complete([for (var i = 256; i < 286; i++) _track('$i')]);
    await tester.pump();
    expect(state.queueLength, 256);
    expect(state.current?.id, '251');
    expect(state.queueIndex, 221);
    gate.complete(true);
    await tester.pump();
    expect(engine.playCalls, calls + 1);
    expect(state.current?.id, '251');
    state.pause();
    await tester.pump();
  });

  testWidgets(
    'shuffle prefetch and engine handoffs follow one non-repeating round',
    (tester) async {
      final engine = _QueueEngine();
      final state = AppState(
        catalog: _Catalog(),
        audioEngine: engine,
        shuffleRandom: Random(27),
      );
      addTearDown(state.dispose);
      state.toggleShuffle();
      state.playQueue([for (var i = 0; i < 8; i++) _track('$i')]);
      await tester.pump();
      final visited = {state.current!.id};
      for (var i = 0; i < 7; i++) {
        final prepared = engine.appends.last;
        if (i.isEven) {
          state.next();
        } else {
          engine.crossIntoNext();
        }
        await tester.pump();
        expect('url-${state.current!.id}', prepared);
        expect(visited.add(state.current!.id), isTrue);
      }
      expect(visited, hasLength(8));
      state.pause();
      await tester.pump();
    },
  );

  testWidgets('a transient source resolve retries before showing an error', (
    tester,
  ) async {
    final _FlakyCatalog catalog = _FlakyCatalog();
    final state = AppState(catalog: catalog, audioEngine: _PlainEngine());
    addTearDown(state.dispose);

    state.playQueue(<Track>[_track('retry')]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(catalog.resolves, 2);
    expect(state.playbackError, isNull);
    expect(state.playing, isTrue);
    state.pause();
  });

  testWidgets(
    'shuffle Previous follows history and Next resumes the shuffled round',
    (tester) async {
      final engine = _QueueEngine();
      final state = AppState(
        catalog: _Catalog(),
        audioEngine: engine,
        shuffleRandom: Random(27),
      );
      addTearDown(state.dispose);
      state.toggleShuffle();
      state.playQueue([for (var i = 0; i < 8; i++) _track('$i')]);
      await tester.pump();
      final history = [state.current!.id];
      for (var i = 0; i < 3; i++) {
        state.next();
        await tester.pump();
        history.add(state.current!.id);
      }
      final pending = engine.appends.last;
      state.previous();
      await tester.pump();
      expect(state.current!.id, history[2]);
      expect(state.shuffle, isTrue);
      state.previous();
      await tester.pump();
      expect(state.current!.id, history[1]);
      for (final expected in history.skip(2)) {
        expect(engine.appends.last, 'url-$expected');
        state.next();
        await tester.pump();
        expect(state.current!.id, expected);
      }
      expect(engine.appends.last, pending);
      final heard = history.toSet();
      while (heard.length < 8) {
        final prepared = engine.appends.last;
        state.next();
        await tester.pump();
        expect('url-${state.current!.id}', prepared);
        expect(heard.add(state.current!.id), isTrue);
        expect(state.shuffle, isTrue);
      }
      state.pause();
      await tester.pump();
    },
  );

  testWidgets('radio order does not overwrite the preferred playlist mode', (
    tester,
  ) async {
    final state = AppState(catalog: _Catalog(), audioEngine: _QueueEngine());
    addTearDown(state.dispose);
    state.toggleShuffle();
    state.playStationQueue([
      _track('1'),
      _track('2'),
    ], loadMore: () async => []);
    await tester.pump();
    expect(state.shuffle, isFalse);
    state.playQueue([_track('3'), _track('4')]);
    await tester.pump();
    expect(state.shuffle, isTrue);
    expect(state.repeat, LoopMode.off);
    state.pause();
    await tester.pump();
  });

  testWidgets(
    'changing mode replaces a successor prepared under the previous mode',
    (tester) async {
      final engine = _QueueEngine();
      final state = AppState(
        catalog: _Catalog(),
        audioEngine: engine,
        shuffleRandom: Random(7),
      );
      addTearDown(state.dispose);
      state.playQueue([for (var i = 0; i < 8; i++) _track('$i')]);
      await tester.pump();
      expect(engine.appends.last, 'url-1');
      state.toggleShuffle();
      await tester.pump();
      final shuffled = engine.appends.last;
      state.next();
      await tester.pump();
      expect('url-${state.current!.id}', shuffled);
      state.cycleRepeat();
      await tester.pump();
      final sequential = engine.appends.last;
      state.next();
      await tester.pump();
      expect('url-${state.current!.id}', sequential);
      state.pause();
      await tester.pump();
    },
  );

  testWidgets(
    'platform queues prefetch even when play lasts until completion',
    (tester) async {
      final pending = Completer<void>();
      final engine = _QueueEngine()..playPending = pending;
      final state = AppState(catalog: _Catalog(), audioEngine: engine);
      addTearDown(state.dispose);
      state.playQueue([_track('1'), _track('2')]);
      await tester.pump();
      expect(engine.playCalls, 1);
      expect(engine.appends, ['url-2']);
      expect(pending.isCompleted, isFalse);
      state.pause();
      pending.complete();
      await tester.pump();
    },
  );

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

  testWidgets('manual gapless next updates the artwork accent', (tester) async {
    final engine = _QueueEngine();
    final requested = <String?>[];
    final state = AppState(
      catalog: _Catalog(),
      audioEngine: engine,
      artworkSeedLoader: (url) async {
        requested.add(url);
        return url!.endsWith('/1') ? Colors.red : Colors.blue;
      },
    );
    addTearDown(state.dispose);
    state.paletteMode = AppPaletteMode.nowPlaying;
    state.playQueue([
      _track('1').copyWith(coverUrl: 'https://cover.test/1'),
      _track('2').copyWith(coverUrl: 'https://cover.test/2'),
    ]);
    await tester.pump();
    expect(state.accentSeed, Colors.red);

    state.next();
    await tester.pump();
    // Artwork is requested once the hand-off has been adopted, so the metadata
    // call no longer competes with the track the listener is waiting for.
    await tester.pump();

    expect(state.playing, isTrue);
    expect(engine.jumps, 1);
    expect(engine.loads, ['url-1']);
    expect(state.accentSeed, Colors.blue);
    expect(requested, ['https://cover.test/1', 'https://cover.test/2']);
    state.pause();
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

    state.playQueue([
      const Track(
        id: 'fixture:test:song:1',
        title: 'Track 1',
        artist: '',
        album: '',
        duration: Duration(minutes: 3),
        coverSeed: 0,
      ),
    ]);
    await tester.pump();

    expect(state.recentTracks.map((track) => track.id), <String>[
      'fixture:test:song:1',
    ]);
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

  testWidgets(
    'a station rolls played history without changing the audible track',
    (tester) async {
      final engine = _PlainEngine();
      final state = AppState(catalog: _Catalog(), audioEngine: engine);
      var nextId = 256;
      state.playStationQueue(
        [for (var i = 0; i < 256; i++) _track('$i')],
        loadMore: () async => [
          for (var i = 0; i < 30; i++) _track('${nextId++}'),
        ],
      );
      await tester.pump();
      state.playTrackAt(255);
      await tester.pump();
      state.next();
      await tester.pump();
      expect(state.queueLength, lessThanOrEqualTo(256));
      expect(state.current?.id, '256');
      expect(engine.loads.last, 'url-256');
      expect(state.queue.first.id, '30');
      // Continue across several rolling windows, not just the first trim.
      for (var i = 0; i < 12; i++) {
        state.playTrackAt(state.queueLength - 1);
        await tester.pump();
        final expected = int.parse(state.current!.id) + 1;
        state.next();
        await tester.pump();
        expect(state.queueLength, lessThanOrEqualTo(256));
        expect(state.current?.id, '$expected');
        expect(engine.loads.last, 'url-$expected');
      }
      state.dispose();
    },
  );

  testWidgets(
    'a late old station response cannot append or unlock its replacement',
    (tester) async {
      final engine = _PlainEngine();
      final state = AppState(catalog: _Catalog(), audioEngine: engine);
      final old = Completer<List<Track>>();
      final replacement = Completer<List<Track>>();
      var calls = 0;
      Future<List<Track>> loader() =>
          ++calls == 1 ? old.future : replacement.future;
      state.playStationQueue([_track('old')], loadMore: loader);
      await tester.pump();
      state.playStationQueue([_track('new')], loadMore: loader);
      await tester.pump();
      old.complete([_track('stale')]);
      await tester.pump();
      state.next();
      await tester.pump();
      expect(calls, 2);
      expect(state.queue.map((track) => track.id), ['new']);
      replacement.complete([_track('fresh')]);
      await tester.pump();
      expect(state.current?.id, 'fresh');
      expect(state.queue.map((track) => track.id), ['new', 'fresh']);
      state.dispose();
    },
  );

  testWidgets(
    'ordinary playlists retain every track beyond the station budget',
    (tester) async {
      final state = AppState(catalog: _Catalog(), audioEngine: _PlainEngine());
      state.playQueue([
        for (var i = 0; i < 1000; i++) _track('$i'),
      ], startIndex: 999);
      await tester.pump();
      expect(state.queueLength, 1000);
      expect(state.current?.id, '999');
      state.dispose();
    },
  );

  testWidgets(
    'disposing a pending station cancels its refill deadline immediately',
    (tester) async {
      final state = AppState(catalog: _Catalog(), audioEngine: _PlainEngine());
      final response = Completer<List<Track>>();
      state.playStationQueue([
        _track('pending'),
      ], loadMore: () => response.future);
      await tester.pump();
      state.dispose();
      await tester.pump();
      response.complete([_track('late')]);
      await tester.pump();
    },
  );

  testWidgets('an old tail request cannot advance a replacement playlist', (
    tester,
  ) async {
    final engine = _PlainEngine();
    final state = AppState(catalog: _Catalog(), audioEngine: engine);
    final response = Completer<List<Track>>();
    state.playStationQueue([_track('old')], loadMore: () => response.future);
    await tester.pump();
    state.next();
    await tester.pump();
    state.playQueue([_track('new0'), _track('new1'), _track('new2')]);
    await tester.pump();
    response.complete([_track('late')]);
    await tester.pump(const Duration(milliseconds: 50));
    expect(state.current?.id, 'new0');
    expect(engine.loads.last, 'url-new0');
    expect(state.playbackError, isNull);
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

  testWidgets(
    'track transition supports off, albumGapless and autoMix with custom duration',
    (tester) async {
      final engine = _QueueEngine();
      final state = AppState(catalog: _Catalog(), audioEngine: engine);
      addTearDown(state.dispose);

      expect(state.trackTransition, TrackTransition.albumGapless);
      expect(state.autoMixDurationSeconds, 5);

      // Clamps to min (1) and max (13)
      await state.setAutoMixDurationSeconds(0);
      expect(state.autoMixDurationSeconds, 1);
      await state.setAutoMixDurationSeconds(20);
      expect(state.autoMixDurationSeconds, 13);
      await state.setAutoMixDurationSeconds(8);
      expect(state.autoMixDurationSeconds, 8);

      // TrackTransition.off skips prefetching
      await state.setTrackTransition(TrackTransition.off);
      expect(state.trackTransition, TrackTransition.off);
      state.playQueue(<Track>[_track('1'), _track('2')]);
      await tester.pump();
      expect(engine.appends, isEmpty);
      expect(state.successorPrepared, isFalse);

      // TrackTransition.autoMix enables mixing
      await state.setTrackTransition(TrackTransition.autoMix);
      expect(state.trackTransition, TrackTransition.autoMix);
      expect(state.autoMixEnabled, isTrue);
      state.pause();
      await tester.pump();
    },
  );

  testWidgets(
    'shuffle and repeat edits replace the successor without reopening the active source',
    (tester) async {
      final engine = _QueueEngine();
      final state = AppState(
        catalog: _Catalog(),
        audioEngine: engine,
        shuffleRandom: Random(7),
      );
      addTearDown(state.dispose);
      state.playQueue([for (var i = 0; i < 5; i++) _track('$i')]);
      await tester.pump();
      state.toggleShuffle();
      await tester.pump();
      state.cycleRepeat();
      await tester.pump();
      state.cycleRepeat();
      await tester.pump();
      expect(state.repeat, LoopMode.one);
      expect(engine.appends.last, 'url-0');
      expect(engine.loads, ['url-0']);
      expect(engine.clears, 3);
      state.pause();
      await tester.pump();
    },
  );

  testWidgets(
    'off clears an accepted successor and natural completion still advances normally',
    (tester) async {
      final engine = _ConfigQueueEngine();
      final state = AppState(catalog: _Catalog(), audioEngine: engine);
      addTearDown(state.dispose);
      state.playQueue([_track('1'), _track('2')]);
      await tester.pump();
      expect(state.successorPrepared, isTrue);
      await state.setTrackTransition(TrackTransition.off);
      await tester.pump();
      expect(state.successorPrepared, isFalse);
      expect(engine.clears, 1);
      expect(engine.loads, ['url-1']);
      engine.finish();
      await tester.pump();
      expect(state.current!.id, '2');
      expect(engine.loads, ['url-1', 'url-2']);
      state.pause();
      await tester.pump();
    },
  );

  testWidgets(
    'a clear that preserves an audible successor retains its index binding',
    (tester) async {
      final engine = _QueueEngine()..clearAccepted = false;
      final state = AppState(catalog: _Catalog(), audioEngine: engine);
      addTearDown(state.dispose);
      state.playQueue([_track('1'), _track('2')]);
      await tester.pump();
      state.toggleShuffle();
      await tester.pump();
      engine.crossIntoNext();
      await tester.pump();
      expect(state.current!.id, '2');
      expect(engine.loads, ['url-1']);
      state.pause();
      await tester.pump();
    },
  );

  testWidgets('mix duration and mode changes share one bounded ordered lane', (
    tester,
  ) async {
    final gate = Completer<void>();
    final engine = _ConfigQueueEngine()..nextConfiguration = gate;
    final state = AppState(catalog: _Catalog(), audioEngine: engine);
    addTearDown(state.dispose);
    final enabling = state.setTrackTransition(TrackTransition.autoMix);
    await tester.pump();
    final pending = <Future<void>>[];
    for (var index = 0; index < 1000; index++) {
      pending.add(state.setAutoMixDurationSeconds(index % 13 + 1));
    }
    pending.add(state.setAutoMixDurationSeconds(13));
    pending.add(state.setTrackTransition(TrackTransition.off));
    expect(engine.configurations, [(true, const Duration(seconds: 5))]);
    gate.complete();
    await enabling;
    await Future.wait(pending);
    expect(state.trackTransition, TrackTransition.off);
    expect(state.autoMixDurationSeconds, 13);
    expect(engine.configurations.last.$1, isFalse);
    expect(engine.configurations.length, lessThanOrEqualTo(3));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('lazer_automix_duration_seconds'), 13);
    expect(prefs.getString('lazer_track_transition'), 'off');
  });

  testWidgets(
    'a rejected duration remains visible and late configuration cannot mutate disposed state',
    (tester) async {
      final engine = _ConfigQueueEngine();
      final state = AppState(catalog: _Catalog(), audioEngine: engine);
      await state.setTrackTransition(TrackTransition.autoMix);
      engine.rejectConfiguration = true;
      await state.setAutoMixDurationSeconds(8);
      expect(state.autoMixError, isNotNull);
      engine.rejectConfiguration = false;
      final gate = engine.nextConfiguration = Completer<void>();
      final changing = state.setTrackTransition(TrackTransition.off);
      await tester.pump();
      state.dispose();
      gate.complete();
      await changing;
      expect(state.trackTransition, TrackTransition.autoMix);
      expect(tester.takeException(), isNull);
    },
  );
}
