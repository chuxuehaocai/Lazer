import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as audio;
import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/local/local_library.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Platform player that records every call and can hold a load open.
///
/// Media_kit crashes when the native player is released or re-targeted while
/// an earlier `open` is still running, so the interesting assertions are the
/// order of [events] and [maxInFlight].
class _RecordingPlayer implements audio.AudioPlayer {
  final StreamController<audio.ProcessingState> _states =
      StreamController<audio.ProcessingState>.broadcast();
  final StreamController<int?> _indexes = StreamController<int?>.broadcast();

  /// Everything the engine asked the platform to do, in call-start order.
  final List<String> events = <String>[];

  /// URLs each load call targeted.
  final List<String> opened = <String>[];

  /// Held by the next load only; cleared as soon as that load starts.
  Completer<void>? gate;

  int stopCalls = 0;
  int _inFlight = 0;
  int maxInFlight = 0;

  void _enter() {
    _inFlight++;
    if (_inFlight > maxInFlight) maxInFlight = _inFlight;
  }

  Future<void> _hold() async {
    final Completer<void>? held = gate;
    gate = null;
    if (held != null) await held.future;
  }

  @override
  Stream<audio.ProcessingState> get processingStateStream => _states.stream;
  @override
  audio.ProcessingState get processingState => audio.ProcessingState.ready;
  @override
  Stream<int?> get currentIndexStream => _indexes.stream;
  @override
  int? get currentIndex => 0;
  @override
  Duration position = Duration.zero;
  @override
  Duration get bufferedPosition => Duration.zero;
  @override
  Duration? get duration => const Duration(minutes: 3);

  @override
  Future<Duration?> setAudioSource(
    audio.AudioSource source, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    _enter();
    final audio.UriAudioSource first =
        (source as audio.ConcatenatingAudioSource).children.first
            as audio.UriAudioSource;
    final String url = first.uri.toString();
    opened.add(url);
    events.add('queue:$url');
    await _hold();
    _inFlight--;
    return duration;
  }

  @override
  Future<Duration?> setUrl(
    String url, {
    Map<String, String>? headers,
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) async {
    _enter();
    opened.add(url);
    events.add('single:$url');
    await _hold();
    _inFlight--;
    return duration;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    events.add('stop');
  }

  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> seek(Duration? position, {int? index}) async {}
  @override
  Future<void> dispose() async {
    await _states.close();
    await _indexes.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Queue engine whose first load is aborted by the platform, the way a
/// superseded stream open fails during a fast next/previous burst.
class _InterruptingEngine implements AudioEngine, QueueAudioEngine {
  final StreamController<int> _indexes = StreamController<int>.broadcast();
  final StreamController<void> _completed = StreamController<void>.broadcast();

  final Completer<void> firstGate = Completer<void>();

  /// Queue loads that reached the platform (the aborted one excluded).
  final List<String> queueLoads = <String>[];

  /// Loads that fell back to the single-source path.
  final List<String> singleLoads = <String>[];

  int queueCalls = 0;
  int _queueId = 0;
  bool _active = false;

  @override
  bool get active => _active;
  @override
  Duration position = Duration.zero;
  @override
  Duration? get duration => const Duration(minutes: 3);
  @override
  Stream<void> get completed => _completed.stream;
  @override
  Stream<int> get indexStream => _indexes.stream;

  @override
  Future<int> setQueue(List<String> urls, {int startIndex = 0}) async {
    queueCalls++;
    if (queueCalls == 1) {
      await firstGate.future;
      throw StateError('load interrupted');
    }
    queueLoads.add(urls[startIndex]);
    _active = true;
    return ++_queueId;
  }

  @override
  Future<bool> appendToQueue(int queueId, String url) async =>
      queueId == _queueId;

  @override
  Future<bool> playQueuedNext() async => false;

  @override
  Future<void> setUrl(String url) async {
    singleLoads.add(url);
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

/// Queue engine that cannot build a queue at all, so every track has to use
/// the single-source fallback.
class _QueueRefusingEngine implements AudioEngine, QueueAudioEngine {
  final StreamController<int> _indexes = StreamController<int>.broadcast();
  final StreamController<void> _completed = StreamController<void>.broadcast();

  final List<String> singleLoads = <String>[];

  @override
  bool get active => true;
  @override
  Duration position = Duration.zero;
  @override
  Duration? get duration => const Duration(minutes: 3);
  @override
  Stream<void> get completed => _completed.stream;
  @override
  Stream<int> get indexStream => _indexes.stream;

  @override
  Future<int> setQueue(List<String> urls, {int startIndex = 0}) async {
    throw StateError('no queue support');
  }

  @override
  Future<bool> appendToQueue(int queueId, String url) async => false;
  @override
  Future<bool> playQueuedNext() async => false;

  @override
  Future<void> setUrl(String url) async {
    singleLoads.add(url);
  }

  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration value) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> stop() async {}
  @override
  void dispose() {}
}

class _Gateway extends NeteaseGateway {
  @override
  Future<List<GatewaySong>> songDetails(List<int> ids) async => [];
}

class _Catalog extends Catalog {
  _Catalog() : super(gateway: _Gateway());
  final List<String> requests = <String>[];

  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async {
    requests.add(track.id);
    return 'url-${track.id}';
  }

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

class _SlowLocalLibrary extends LocalLibrary {
  final Completer<File?> first = Completer<File?>();
  @override
  Future<File?> localFileFor(Track track, {AudioQuality? quality}) =>
      track.id == '1' ? first.future : Future<File?>.value();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'a slow local file lookup cannot block or overwrite a newer song',
    (tester) async {
      final library = _SlowLocalLibrary();
      final engine = _QueueRefusingEngine();
      final catalog = _Catalog();
      final state = AppState(
        catalog: catalog,
        audioEngine: engine,
        localLibrary: library,
      );
      state.playQueue([_track('1'), _track('2')]);
      await tester.pump();
      expect(engine.singleLoads, isEmpty);
      state.next();
      await tester.pump();
      expect(engine.singleLoads, ['url-2']);
      library.first.complete(null);
      await tester.pump();
      expect(engine.singleLoads, ['url-2']);
      expect(catalog.requests, ['2']);
      expect(state.current?.id, '2');
      state.dispose();
      library.dispose();
      await tester.pump();
    },
  );

  testWidgets('rapid switches persist the final index in a large queue', (
    tester,
  ) async {
    final engine = _QueueRefusingEngine();
    final state = AppState(catalog: _Catalog(), audioEngine: engine);
    await tester.runAsync(() async {
      state.playQueue(List<Track>.generate(1000, (i) => _track('${i + 1}')));
      state.playTrackAt(100);
      state.playTrackAt(700);
      final prefs = await SharedPreferences.getInstance();
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (true) {
        final raw = prefs.getString('lazer_playback_queue_v1');
        if (raw != null &&
            (jsonDecode(raw) as Map<String, dynamic>)['index'] == 700) {
          final saved = jsonDecode(raw) as Map<String, dynamic>;
          expect((saved['tracks'] as List), hasLength(1000));
          expect(saved['tracks'][700]['id'], '701');
          break;
        }
        if (DateTime.now().isAfter(deadline)) fail('Queue was not saved');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    state.dispose();
    await tester.pump();
  });

  testWidgets('a burst of queue loads only opens the newest stream', (
    tester,
  ) async {
    final player = _RecordingPlayer();
    final engine = JustAudioEngine(player: player);
    final held = Completer<void>();
    player.gate = held;

    final first = engine.setQueue(<String>['https://audio.test/a']);
    await tester.pump();
    expect(player.opened, <String>['https://audio.test/a']);

    final second = engine.setQueue(<String>['https://audio.test/b']);
    final third = engine.setQueue(<String>['https://audio.test/c']);
    await tester.pump();
    expect(player.opened, <String>[
      'https://audio.test/a',
    ], reason: 'superseded loads queue behind the one already opening');

    held.complete();
    await tester.pump();
    await Future.wait(<Future<int>>[first, second, third]);

    expect(player.opened, <String>[
      'https://audio.test/a',
      'https://audio.test/c',
    ]);
    expect(player.maxInFlight, 1);
    expect(engine.active, isTrue);
    engine.dispose();
    await tester.pump();
  });

  testWidgets('the single-source fallback never overlaps a queue load', (
    tester,
  ) async {
    final player = _RecordingPlayer();
    final engine = JustAudioEngine(player: player);
    final held = Completer<void>();
    player.gate = held;

    final queueLoad = engine.setQueue(<String>['https://audio.test/a']);
    await tester.pump();
    final fallback = engine.setUrl('https://audio.test/b');
    await tester.pump();

    expect(player.maxInFlight, 1);
    expect(player.opened, <String>['https://audio.test/a']);

    held.complete();
    await tester.pump();
    await Future.wait(<Future<Object?>>[queueLoad, fallback]);

    expect(player.opened, <String>[
      'https://audio.test/a',
      'https://audio.test/b',
    ]);
    expect(player.maxInFlight, 1);
    engine.dispose();
    await tester.pump();
  });

  testWidgets('stop waits for the opening stream before releasing mpv', (
    tester,
  ) async {
    final player = _RecordingPlayer();
    final engine = JustAudioEngine(player: player);
    final held = Completer<void>();
    player.gate = held;

    final load = engine.setQueue(<String>['https://audio.test/a']);
    await tester.pump();
    final stopped = engine.stop();
    await tester.pump();

    expect(
      player.stopCalls,
      0,
      reason: 'the native player must not be released while it is opening',
    );
    expect(engine.active, isFalse);

    held.complete();
    await tester.pump();
    await Future.wait(<Future<Object?>>[load, stopped]);

    expect(player.events, <String>['queue:https://audio.test/a', 'stop']);
    expect(player.maxInFlight, 1);
    engine.dispose();
    await tester.pump();
  });

  testWidgets('a superseded load never falls back to the single-source path', (
    tester,
  ) async {
    final engine = _InterruptingEngine();
    final state = AppState(catalog: _Catalog(), audioEngine: engine);
    state.playQueue(<Track>[_track('1'), _track('2')]);
    await tester.pump();
    expect(engine.queueCalls, 1);

    // The listener already moved on while the first stream was opening.
    state.next();
    await tester.pump();
    expect(engine.queueLoads, <String>['url-2']);

    // The platform then aborts the stale load. It must not take over the
    // player with a second, concurrent `setUrl`.
    engine.firstGate.complete();
    await tester.pump();

    expect(engine.singleLoads, isEmpty);
    expect(state.current?.id, '2');
    expect(state.playing, isTrue);
    expect(state.playbackError, isNull);
    state.dispose();
    await tester.pump();
  });

  testWidgets('a live load still falls back when the queue is refused', (
    tester,
  ) async {
    final engine = _QueueRefusingEngine();
    final state = AppState(catalog: _Catalog(), audioEngine: engine);
    state.playQueue(<Track>[_track('1')]);
    await tester.pump();

    expect(engine.singleLoads, <String>['url-1']);
    expect(state.playbackError, isNull);
    state.dispose();
    await tester.pump();
  });
}
