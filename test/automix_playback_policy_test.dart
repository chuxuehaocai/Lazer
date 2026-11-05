import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
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
    implements QueueAudioEngine, AutoMixConfigurableAudioEngine {
  final configurations = <bool>[];
  final queueLoads = <String>[];
  final prepared = <String>[];
  final indexes = StreamController<int>.broadcast();
  int _queueId = 0;
  bool rejectConfiguration = false;
  bool presented = false;
  bool rejectAppendWhilePresented = false;

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
    return ++_queueId;
  }

  @override
  Future<bool> appendToQueue(int queueId, String url) async {
    if (queueId != _queueId || (presented && rejectAppendWhilePresented)) {
      return false;
    }
    prepared.add(url);
    return true;
  }

  @override
  Future<bool> playQueuedNext() async => false;

  void advanceAt(Duration incomingPosition) {
    presented = true;
    position = incomingPosition;
    indexes.add(1);
  }

  @override
  void dispose() {
    unawaited(indexes.close());
    super.dispose();
  }
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
    expect(engine.prepared.last, 'url-3');
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
}
