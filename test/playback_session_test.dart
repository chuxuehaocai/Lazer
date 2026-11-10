import 'support/music_gateway.dart';
import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as audio;
import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/audio/playback_session.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Session implements AudioSession {
  final interruptions = StreamController<AudioInterruptionEvent>.broadcast();
  final noisy = StreamController<void>.broadcast();
  final activations = <bool>[];
  int configurations = 0;
  Completer<bool>? pendingActivation;
  Completer<void>? pendingConfiguration;
  bool activationAccepted = true;

  @override
  Stream<AudioInterruptionEvent> get interruptionEventStream =>
      interruptions.stream;
  @override
  Stream<void> get becomingNoisyEventStream => noisy.stream;
  @override
  AndroidAudioAttributes? get androidAudioAttributes => null;
  @override
  Future<void> configure(AudioSessionConfiguration configuration) async {
    configurations++;
    await pendingConfiguration?.future;
  }

  @override
  Future<bool> setActive(
    bool active, {
    AVAudioSessionSetActiveOptions? avAudioSessionSetActiveOptions,
    AndroidAudioFocusGainType? androidAudioFocusGainType,
    AndroidAudioAttributes? androidAudioAttributes,
    bool? androidWillPauseWhenDucked,
    AudioSessionConfiguration fallbackConfiguration =
        const AudioSessionConfiguration.music(),
  }) async {
    activations.add(active);
    if (active && pendingActivation != null) return pendingActivation!.future;
    return activationAccepted;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  Future<void> close() async {
    await interruptions.close();
    await noisy.close();
  }
}

class _PreparingEngine extends JustAudioEngine
    implements SessionPreparingAudioEngine {
  _PreparingEngine({required super.player});

  @override
  Future<void> Function()? prepareSession;

  bool outputOpened = false;

  @override
  Future<void> setUrl(String url) async {
    await prepareSession?.call();
    outputOpened = true;
    await super.setUrl(url);
  }
}

class _Player implements audio.AudioPlayer {
  final states = StreamController<audio.ProcessingState>.broadcast();
  final List<String> urls = <String>[];
  int plays = 0;
  int pauses = 0;
  int stops = 0;
  Duration? sought;
  @override
  Stream<audio.ProcessingState> get processingStateStream => states.stream;
  @override
  audio.ProcessingState get processingState => audio.ProcessingState.ready;
  @override
  Duration position = Duration.zero;
  @override
  Duration get bufferedPosition => duration ?? Duration.zero;
  @override
  int? get currentIndex => 0;
  @override
  Duration? get duration => const Duration(seconds: 30);
  @override
  Future<Duration?> setUrl(
    String url, {
    Map<String, String>? headers,
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) async {
    urls.add(url);
    return duration;
  }
  @override
  Future<void> play() async {
    plays++;
  }

  @override
  Future<void> pause() async {
    pauses++;
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    sought = position;
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> dispose() => states.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A backend that holds the output device itself, like the native engine: an
/// interruption has to close it rather than park a stream the platform takes.
class _YieldingEngine extends JustAudioEngine
    implements InterruptionYieldingAudioEngine {
  _YieldingEngine({required super.player});
}

class _Gateway extends TestMusicGateway {}

class _Catalog extends Catalog {
  _Catalog() : super(gateway: _Gateway());
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => 'https://audio.test/${track.id}';
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => const GatewayLyrics();
}

const _track = Track(
  id: '1',
  title: 'Track',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(seconds: 30),
  coverSeed: 1,
);

const _track2 = Track(
  id: '2',
  title: 'Next Track',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(seconds: 30),
  coverSeed: 2,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'paused next opens the selected track when playback resumes',
    (tester) async {
      final player = _Player();
      final engine = JustAudioEngine(player: player);
      final state = AppState(
        catalog: _Catalog(),
        audioEngine: engine,
        startupBufferTarget: Duration.zero,
        startupByteTarget: 0,
      );

      state.playQueue(<Track>[_track, _track2]);
      await tester.pump();
      expect(player.urls.last, 'https://audio.test/1');

      state.pause();
      state.next();
      await tester.pump();
      expect(state.current?.id, '2');

      state.play();
      await tester.pump();
      expect(player.urls.last, 'https://audio.test/2');
      await tester.pump(const Duration(seconds: 1));
      state.dispose();
      engine.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'independent playback never opens an OS session and normal mode honors interruptions',
    (tester) async {
      final player = _Player();
      final engine = JustAudioEngine(player: player);
      final state = AppState(
        catalog: _Catalog(),
        audioEngine: engine,
        independentPlayback: true,
      );
      final session = _Session();
      var requests = 0;
      final policy = PlaybackSession(
        state,
        engine,
        sessionFactory: () async {
          requests++;
          return session;
        },
      );
      state.playQueue([_track]);
      await tester.pump();
      expect(player.plays, 1);
      expect(requests, 0);
      expect(session.activations, isEmpty);
      await state.setIndependentPlayback(false);
      await policy.settled;
      expect(requests, 1);
      expect(session.configurations, 1);
      expect(session.activations, [true]);
      session.interruptions.add(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      await tester.pump();
      expect(state.playing, false);
      session.interruptions.add(
        AudioInterruptionEvent(true, AudioInterruptionType.unknown),
      );
      await tester.pump();
      expect(state.playing, false);
      session.interruptions.add(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      await tester.pump();
      expect(state.playing, true);
      await state.setIndependentPlayback(true);
      await policy.settled;
      expect(session.activations.last, false);
      final activations = session.activations.length;
      session.noisy.add(null);
      session.interruptions.add(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      await tester.pump();
      expect(state.playing, true);
      state.pause();
      state.play();
      await tester.pump();
      expect(session.activations, hasLength(activations));
      policy.close();
      await policy.settled;
      state.dispose();
      engine.dispose();
      await session.close();
      await tester.pump();
    },
  );

  testWidgets(
    'output opening waits for one configuration without taking focus',
    (tester) async {
      final player = _Player();
      final engine = _PreparingEngine(player: player);
      final state = AppState(catalog: _Catalog(), audioEngine: engine);
      final configuration = Completer<void>();
      final session = _Session()
        ..pendingConfiguration = configuration
        ..activationAccepted = false;
      final policy = PlaybackSession(
        state,
        engine,
        sessionFactory: () async => session,
      );
      final opening = engine.setUrl('https://audio.test/first');
      await tester.pump();
      expect(session.configurations, 1);
      expect(engine.outputOpened, isFalse);
      expect(session.activations, isEmpty);
      configuration.complete();
      await opening;
      expect(engine.outputOpened, isTrue);
      expect(engine.active, isTrue);
      expect(session.activations, isEmpty);
      await engine.setUrl('https://audio.test/second');
      expect(session.configurations, 1);
      expect(session.activations, isEmpty);
      expect(await engine.activateSession!(), isFalse);
      expect(engine.active, isTrue);
      expect(player.plays, 0);
      policy.close();
      await policy.settled;
      state.dispose();
      engine.dispose();
      await session.close();
      await tester.pump();
    },
  );

  testWidgets('independent preload skips OS configuration and activation', (
    tester,
  ) async {
    final player = _Player();
    final engine = _PreparingEngine(player: player);
    final state = AppState(
      catalog: _Catalog(),
      audioEngine: engine,
      independentPlayback: true,
    );
    var requests = 0;
    final policy = PlaybackSession(
      state,
      engine,
      sessionFactory: () async {
        requests++;
        throw StateError('An independent preload must not open a session');
      },
    );
    await engine.setUrl('https://audio.test/first');
    expect(engine.outputOpened, isTrue);
    expect(requests, 0);
    policy.close();
    await policy.settled;
    state.dispose();
    engine.dispose();
    await tester.pump();
  });

  testWidgets('closing during configuration prevents a late output open', (
    tester,
  ) async {
    final player = _Player();
    final engine = _PreparingEngine(player: player);
    final state = AppState(catalog: _Catalog(), audioEngine: engine);
    final configuration = Completer<void>();
    final session = _Session()..pendingConfiguration = configuration;
    final policy = PlaybackSession(
      state,
      engine,
      sessionFactory: () async => session,
    );
    final opening = engine.setUrl('https://audio.test/first');
    final rejected = expectLater(opening, throwsStateError);
    await tester.pump();
    policy.close();
    configuration.complete();
    await rejected;
    await policy.settled;
    expect(engine.outputOpened, isFalse);
    expect(session.activations, isEmpty);
    state.dispose();
    engine.dispose();
    await session.close();
    await tester.pump();
  });

  testWidgets('interruption end never resumes a replacement paused track', (
    tester,
  ) async {
    final player = _Player();
    final engine = JustAudioEngine(player: player);
    final state = AppState(catalog: _Catalog(), audioEngine: engine);
    final session = _Session();
    final policy = PlaybackSession(
      state,
      engine,
      sessionFactory: () async => session,
    );
    state.playQueue([_track]);
    await tester.pump();
    session.interruptions.add(
      AudioInterruptionEvent(true, AudioInterruptionType.unknown),
    );
    await tester.pump();
    state.playQueue([
      const Track(
        id: '2',
        title: 'Replacement',
        artist: 'Artist',
        album: 'Album',
        duration: Duration(seconds: 30),
        coverSeed: 2,
      ),
    ]);
    state.pause();
    await tester.pump();
    session.interruptions.add(
      AudioInterruptionEvent(false, AudioInterruptionType.pause),
    );
    await tester.pump();
    expect(state.current?.id, '2');
    expect(state.playing, isFalse);
    policy.close();
    await policy.settled;
    state.dispose();
    engine.dispose();
    await session.close();
    await tester.pump();
  });

  testWidgets('pause cancels an engine play waiting for focus', (tester) async {
    final player = _Player();
    final pending = Completer<bool>();
    final engine = JustAudioEngine(
      player: player,
      activateSession: () => pending.future,
    );
    await engine.setUrl('https://audio.test/track');
    final playing = engine.play();
    await engine.pause();
    pending.complete(true);
    await playing;
    expect(player.plays, 0);
    engine.dispose();
    await tester.pump();
  });

  testWidgets('rapid mode changes release stale focus before reacquiring', (
    tester,
  ) async {
    final player = _Player();
    final engine = JustAudioEngine(player: player);
    final state = AppState(catalog: _Catalog(), audioEngine: engine);
    final session = _Session()..pendingActivation = Completer<bool>();
    final policy = PlaybackSession(
      state,
      engine,
      sessionFactory: () async => session,
    );
    state.playQueue([_track]);
    await tester.pump();
    expect(session.activations, [true]);
    await state.setIndependentPlayback(true);
    await state.setIndependentPlayback(false);
    session.pendingActivation!.complete(true);
    session.pendingActivation = null;
    await policy.settled;
    await tester.pump();
    expect(session.activations.last, true);
    expect(session.activations.where((active) => !active), isNotEmpty);
    expect(state.playing, true);
    policy.close();
    await policy.settled;
    state.dispose();
    engine.dispose();
    await session.close();
    await tester.pump();
  });

  testWidgets(
    'an interruption gives the device back and reopens it at the position',
    (tester) async {
      final player = _Player();
      final engine = _YieldingEngine(player: player);
      final state = AppState(
        catalog: _Catalog(),
        audioEngine: engine,
        startupByteTarget: 0,
      );
      final session = _Session();
      final policy = PlaybackSession(
        state,
        engine,
        sessionFactory: () async => session,
      );
      state.playQueue([_track]);
      await tester.pump();
      expect(player.plays, 1);
      expect(session.activations, [true]);

      // Seven seconds in, a call (or another player) takes the output.
      player.position = const Duration(seconds: 7);
      await tester.pump();
      session.interruptions.add(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      await tester.pump();
      await tester.pump();

      expect(state.playing, isFalse);
      expect(
        player.stops,
        1,
        reason: 'the device is given back instead of parked in PAUSED',
      );

      session.interruptions.add(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(state.playing, isTrue);
      expect(state.playbackError, isNull);
      expect(
        player.sought,
        const Duration(seconds: 7),
        reason: 'the reopened source resumes where the interruption stopped',
      );
      expect(player.plays, 2, reason: 'the reopened device plays again');
      // The grant is re-asserted on resume (a no-op while the platform still
      // holds it) and never released: giving the device back is not giving up
      // audio focus.
      expect(session.activations, isNotEmpty);
      expect(session.activations.last, isTrue);
      expect(
        session.activations.where((active) => !active),
        isEmpty,
        reason: 'a transient interruption keeps the focus grant',
      );

      policy.close();
      await policy.settled;
      state.dispose();
      engine.dispose();
      await session.close();
      await tester.pump();
    },
  );
}
