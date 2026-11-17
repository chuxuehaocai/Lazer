import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/audio/automix_audio_engine.dart';

class _Player implements AudioPlayer {
  final states = StreamController<ProcessingState>.broadcast();
  final indexes = StreamController<int?>.broadcast();
  final buffers = StreamController<Duration>.broadcast();
  final urls = <String>[];
  ConcatenatingAudioSource? source;
  Completer<void>? pendingLoad;
  Completer<void>? pendingSeek;
  int loads = 0;
  int stops = 0;
  int seeks = 0;
  int plays = 0;
  int disposals = 0;
  final disposed = Completer<void>();

  @override
  Duration position = Duration.zero;
  @override
  Duration get duration => const Duration(seconds: 20);
  @override
  Duration get bufferedPosition => duration;
  @override
  bool playing = false;
  AudioSource? _currentSource;
  int _currentIndex = 0;
  @override
  int get currentIndex {
    final current = _currentSource;
    final sources = source?.children;
    return current != null && sources != null
        ? sources.indexOf(current)
        : _currentIndex;
  }

  set currentIndex(int value) {
    _currentIndex = value;
    _currentSource =
        source != null && value >= 0 && value < source!.children.length
        ? source!.children[value]
        : null;
  }

  @override
  ProcessingState get processingState => ProcessingState.ready;
  @override
  Stream<ProcessingState> get processingStateStream => states.stream;
  @override
  Stream<int?> get currentIndexStream => indexes.stream;
  @override
  Stream<Duration> get bufferedPositionStream => buffers.stream;

  @override
  Future<Duration?> setAudioSource(
    AudioSource source, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    loads++;
    await pendingLoad?.future;
    this.source = source as ConcatenatingAudioSource;
    currentIndex = initialIndex ?? 0;
    position = initialPosition ?? Duration.zero;
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
    loads++;
    urls.add(url);
    await pendingLoad?.future;
    return duration;
  }

  @override
  Future<void> play() async {
    plays++;
    playing = true;
  }

  @override
  Future<void> pause() async => playing = false;
  @override
  Future<void> stop() async {
    stops++;
    playing = false;
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    seeks++;
    await pendingSeek?.future;
    this.position = position ?? Duration.zero;
    if (index != null) currentIndex = index;
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> dispose() async {
    disposals++;
    if (!disposed.isCompleted) disposed.complete();
    await states.close();
    await indexes.close();
    await buffers.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'fallback disposal drains a pending load and disposes only once',
    () async {
      final player = _Player();
      final engine = JustAudioEngine(player: player);
      final pending = Completer<void>();
      player.pendingLoad = pending;
      final opening = engine.setUrl('a');
      await Future<void>.delayed(Duration.zero);
      expect(player.loads, 1);
      engine.dispose();
      engine.dispose();
      expect(player.disposals, 0);
      pending.complete();
      await opening;
      await player.disposed.future;
      expect(player.disposals, 1);
      expect(engine.active, isFalse);
      await engine.setUrl('b');
      await engine.play();
      expect(player.loads, 1);
      expect(player.plays, 0);
    },
  );

  test(
    'fallback empty queue stops output and clamps invalid indexes',
    () async {
      final player = _Player();
      final engine = JustAudioEngine(player: player);
      try {
        await engine.setQueue(['a', 'b'], startIndex: 99);
        expect(player.currentIndex, 1);
        await engine.play();
        expect(player.playing, isTrue);
        await engine.setQueue([]);
        expect(engine.active, isFalse);
        expect(player.playing, isFalse);
        expect(player.stops, 1);
        expect(player.loads, 1);
      } finally {
        engine.dispose();
      }
    },
  );

  test(
    'fallback merges a thousand source changes while an open is blocked',
    () async {
      final player = _Player();
      final engine = JustAudioEngine(player: player);
      final gate = Completer<void>();
      player.pendingLoad = gate;
      final first = engine.setQueue(['first']);
      await Future<void>.delayed(Duration.zero);
      final pending = [
        for (var index = 0; index < 1000; index++)
          engine.setQueue(['track-$index']),
      ];
      gate.complete();
      await first;
      final ids = await Future.wait(pending);
      expect(ids.toSet(), hasLength(1000));
      expect(player.loads, 2);
      expect(
        (player.source!.children.single as UriAudioSource).uri.toString(),
        'track-999',
      );
      expect(engine.active, isTrue);
      engine.dispose();
    },
  );

  for (final action in ['replace', 'stop', 'dispose']) {
    test('late platform append cannot cross $action', () async {
      final player = _Player();
      final engine = JustAudioEngine(player: player);
      final id = await engine.setQueue(['https://audio.test/a']);
      final source = player.source!;
      final appended = engine.appendToQueue(id, 'file:///stale.flac');
      for (var turn = 0; source.children.length < 2 && turn < 20; turn++) {
        await Future<void>.value();
      }
      expect(source.children, hasLength(2));
      late final Future<void> changed;
      if (action == 'replace') {
        changed = engine.setUrl('https://audio.test/replacement');
      } else if (action == 'stop') {
        changed = engine.stop();
      } else {
        engine.dispose();
        changed = player.disposed.future;
      }
      expect(await appended, isFalse);
      await changed;
      expect(engine.queuedSourceUrl, isNull);
      expect(engine.seekIsLimitedByBuffer, action == 'replace');
      engine.dispose();
    });
  }

  test('late manual queue seek cannot rewrite a replacement source', () async {
    final player = _Player();
    final engine = JustAudioEngine(player: player);
    await engine.setQueue(['https://audio.test/a', 'file:///stale.flac']);
    final gate = Completer<void>();
    player.pendingSeek = gate;
    final next = engine.playQueuedNext();
    await Future<void>.delayed(Duration.zero);
    final replacement = engine.setUrl('https://audio.test/replacement');
    gate.complete();
    expect(await next, isFalse);
    await replacement;
    expect(engine.seekIsLimitedByBuffer, isTrue);
    engine.dispose();
  });

  test(
    'platform queue releases consumed sources while keeping logical indexes',
    () async {
      final player = _Player();
      final engine = JustAudioEngine(player: player);
      final indexes = <int>[];
      final subscription = engine.indexStream.listen(indexes.add);
      try {
        final id = await engine.setQueue(['0']);
        await engine.appendToQueue(id, '1');
        for (var track = 1; track <= 200; track++) {
          player.currentIndex = 1;
          player.indexes.add(1);
          await Future<void>.delayed(Duration.zero);
          expect(indexes.last, track);
          expect(await engine.appendToQueue(id, '${track + 1}'), isTrue);
          expect(player.currentIndex, 0);
          expect(player.source!.children, hasLength(2));
          expect(engine.queuedSourceUrl, '${track + 1}');
        }
        // An index queued before pruning cannot invent another hand-off.
        player.indexes.add(1);
        await Future<void>.delayed(Duration.zero);
        expect(indexes, List.generate(200, (index) => index + 1));
      } finally {
        await subscription.cancel();
        engine.dispose();
      }
    },
  );

  test('platform queue clear preserves current item and transport', () async {
    final player = _Player();
    final engine = JustAudioEngine(player: player);
    addTearDown(engine.dispose);
    final id = await engine.setQueue(['a', 'b', 'c'], startIndex: 1);
    player.position = const Duration(seconds: 7);
    expect(await engine.clearQueued(id), isTrue);
    expect(player.source!.children, hasLength(2));
    expect(player.currentIndex, 1);
    expect(engine.position, const Duration(seconds: 7));
    expect(engine.queuedSourceUrl, isNull);
    expect(player.loads, 1);
    expect(player.stops, 0);
    expect(player.seeks, 0);
    expect(player.plays, 0);
    expect(await engine.appendToQueue(id, 'd'), isTrue);
    expect(engine.queuedSourceUrl, 'd');
  });

  test(
    'platform queue rejects a clear requested for a replaced queue',
    () async {
      final player = _Player();
      final engine = JustAudioEngine(player: player);
      addTearDown(engine.dispose);
      final old = await engine.setQueue(['a', 'b']);
      final loading = engine.setQueue(['c', 'd']);
      final clearing = engine.clearQueued(old);
      await loading;
      expect(await clearing, isFalse);
      expect(engine.queuedSourceUrl, 'd');
      expect(player.source!.children, hasLength(2));
    },
  );

  testWidgets(
    'AutoMix merges a thousand source changes behind an active decoder',
    (tester) async {
      final players = [_Player(), _Player()];
      var created = 0;
      final engine = AutoMixAudioEngine(
        playerFactory: () => players[created++],
      );
      final gate = Completer<void>();
      try {
        players[0].pendingLoad = gate;
        final first = engine.setQueue(['first']);
        await tester.pump();
        expect(players[0].loads, 1);
        final pending = [
          for (var index = 0; index < 1000; index++)
            engine.setQueue(['track-$index']),
        ];
        gate.complete();
        await first;
        final ids = await Future.wait(pending);
        expect(ids.toSet(), hasLength(1000));
        expect(players[0].urls, ['first', 'track-999']);
        expect(players[1].loads, 0);
      } finally {
        if (!gate.isCompleted) gate.complete();
        engine.dispose();
        await tester.pump();
      }
    },
  );

  testWidgets('AutoMix replaces only its silent decoder', (tester) async {
    final players = [_Player(), _Player()];
    var created = 0;
    final engine = AutoMixAudioEngine(playerFactory: () => players[created++]);
    try {
      final id = await engine.setQueue(['a']);
      await engine.appendToQueue(id, 'b');
      await engine.play();
      players[0].position = const Duration(seconds: 7);
      final stops = players[0].stops;
      expect(await engine.clearQueued(id), isTrue);
      expect(await engine.appendToQueue(id, 'c'), isTrue);
      expect(engine.queuedSourceUrl, 'c');
      expect(players[0].loads, 1);
      expect(players[0].stops, stops);
      expect(players[0].seeks, 0);
      expect(players[0].playing, isTrue);
      expect(engine.position, const Duration(seconds: 7));
    } finally {
      engine.dispose();
      await tester.pump();
    }
  });

  testWidgets(
    'AutoMix clear waits for preparation and rejects stale queue IDs',
    (tester) async {
      final players = [_Player(), _Player()];
      var created = 0;
      final engine = AutoMixAudioEngine(
        playerFactory: () => players[created++],
      );
      final pending = Completer<void>();
      try {
        final id = await engine.setQueue(['a']);
        players[1].pendingLoad = pending;
        final append = engine.appendToQueue(id, 'b');
        await tester.pump();
        final clear = engine.clearQueued(id);
        pending.complete();
        expect(await append, isTrue);
        expect(await clear, isTrue);
        expect(engine.queuedSourceUrl, isNull);
        players[1].pendingLoad = null;
        final next = await engine.setQueue(['c']);
        await engine.appendToQueue(next, 'd');
        expect(await engine.clearQueued(id), isFalse);
        expect(engine.queuedSourceUrl, 'd');
      } finally {
        if (!pending.isCompleted) pending.complete();
        engine.dispose();
        await tester.pump();
      }
    },
  );

  testWidgets(
    'AutoMix keeps an incoming song already presented in an overlap',
    (tester) async {
      final players = [_Player(), _Player()];
      var created = 0;
      final engine = AutoMixAudioEngine(
        playerFactory: () => players[created++],
      );
      try {
        final id = await engine.setQueue(['a']);
        await engine.appendToQueue(id, 'b');
        await engine.play();
        players[0].position = const Duration(seconds: 19);
        await tester.pump(const Duration(milliseconds: 40));
        expect(engine.mixPresented, isTrue);
        final stops = players[1].stops;
        expect(await engine.clearQueued(id), isFalse);
        expect(engine.mixPresented, isTrue);
        expect(players[1].stops, stops);
        expect(players[1].playing, isTrue);
        expect(players[0].playing, isTrue);
      } finally {
        engine.dispose();
        await tester.pump();
      }
    },
  );
}
