import 'support/music_gateway.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/local/local_library.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/playback_queue_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _savedTrack = Track(
  id: '1',
  title: 'Restored song',
  artist: 'Artist',
  album: 'Album',
  duration: const Duration(minutes: 3),
  coverSeed: 1,
);

class _Library extends LocalLibrary {
  _Library(this.ready);
  final Future<void> ready;

  @override
  Future<void> load() => ready;
}

class _Gateway extends TestMusicGateway {
  _Gateway({this.sessionReady});
  final Completer<FixtureLoginStatus>? sessionReady;
  final sessionRequested = Completer<void>();

  @override
  Future<FixtureLoginStatus> fixtureLoginStatus() {
    sessionRequested.complete();
    return sessionReady!.future;
  }
}

class _Catalog extends Catalog {
  _Catalog({this.ready, TestMusicGateway? gateway})
    : super(gateway: gateway ?? _Gateway());
  final Completer<HomeFeed?>? ready;
  final requested = Completer<int?>();

  @override
  Future<HomeFeed?> loadHome({int? userId}) {
    requested.complete(userId);
    return ready?.future ?? Future<HomeFeed?>.value(null);
  }

  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => const GatewayLyrics();
}

class _Engine implements AudioEngine {
  final volumeApplied = Completer<void>();
  final volumeReady = Completer<void>();

  @override
  Future<void> setVolume(double volume) {
    volumeApplied.complete();
    return volumeReady.future;
  }

  @override
  bool get active => false;
  @override
  Duration get position => Duration.zero;
  @override
  Duration? get duration => null;
  @override
  Stream<void> get completed => const Stream.empty();
  @override
  Future<void> setUrl(String url) async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> stop() async {}
  @override
  void dispose() {}
}

PlaybackQueueStore _queueStore() => PlaybackQueueStore(
  read: () async => jsonEncode({
    'index': 0,
    'tracks': [_savedTrack.toJson()],
  }),
  write: (_) async {},
);

Future<void> _until(bool Function() ready) async {
  for (var attempts = 0; attempts < 100 && !ready(); attempts++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(ready(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => SharedPreferences.setMockInitialValues({
      'lazer_theme_mode': 'dark',
      'lazer_volume': 0.3,
      'lazer_independent_playback': true,
    }),
  );

  test(
    'local index and audio device cannot hold home or queue restoration',
    () async {
      final libraryReady = Completer<void>();
      final library = _Library(libraryReady.future);
      final catalog = _Catalog();
      final engine = _Engine();
      final state = AppState(
        catalog: catalog,
        localLibrary: library,
        queueStore: _queueStore(),
        audioEngine: engine,
        artworkSeedLoader: (_) async => null,
      );
      var bootFinished = false;
      final boot = state.bootstrap().then((_) => bootFinished = true);
      try {
        await catalog.requested.future.timeout(const Duration(seconds: 2));
        await _until(() => state.current != null);
        expect(state.current?.id, _savedTrack.id);
        expect(state.themeMode, ThemeMode.dark);
        expect(state.volume, 0.3);
        expect(state.independentPlayback, isTrue);
        expect(state.playing, isFalse);
        expect(libraryReady.isCompleted, isFalse);
        expect(engine.volumeReady.isCompleted, isFalse);
        expect(bootFinished, isFalse);
      } finally {
        libraryReady.complete();
        engine.volumeReady.complete();
        await boot;
        state.dispose();
        library.dispose();
      }
    },
  );

  test('a slow home request leaves restored local queue available', () async {
    final homeReady = Completer<HomeFeed?>();
    final catalog = _Catalog(ready: homeReady);
    final library = _Library(Future<void>.value());
    final state = AppState(
      catalog: catalog,
      localLibrary: library,
      queueStore: _queueStore(),
      artworkSeedLoader: (_) async => null,
    );
    final boot = state.bootstrap();
    try {
      await catalog.requested.future;
      await _until(() => state.current != null);
      expect(homeReady.isCompleted, isFalse);
      expect(state.current?.title, _savedTrack.title);
    } finally {
      homeReady.complete(null);
      await boot;
      state.dispose();
      library.dispose();
    }
  });

  test(
    'a cold boot only requests home after the saved session is validated',
    () async {
      SharedPreferences.setMockInitialValues({
        'lazer_gateway_cookie': 'MUSIC_U=saved',
      });
      final sessionReady = Completer<FixtureLoginStatus>();
      final gateway = _Gateway(sessionReady: sessionReady);
      final catalog = _Catalog(gateway: gateway);
      final library = _Library(Future<void>.value());
      final state = AppState(
        catalog: catalog,
        localLibrary: library,
        queueStore: _queueStore(),
        artworkSeedLoader: (_) async => null,
      );
      final boot = state.bootstrap();
      try {
        await gateway.sessionRequested.future.timeout(
          const Duration(seconds: 2),
        );
        await _until(() => state.current != null);
        expect(catalog.requested.isCompleted, isFalse);
        sessionReady.complete(
          const FixtureLoginStatus(
            profile: FixtureProfile(userId: 42, nickname: 'Saved account'),
          ),
        );
        expect(await catalog.requested.future, 42);
      } finally {
        if (!sessionReady.isCompleted) {
          sessionReady.complete(const FixtureLoginStatus());
        }
        await boot;
        state.dispose();
        library.dispose();
      }
    },
  );

  test(
    'cold startup keeps home and queue independent of a slow local index',
    () async {
      final homeTimes = <int>[];
      final queueTimes = <int>[];
      final completeTimes = <int>[];
      for (var sample = 0; sample < 5; sample++) {
        final clock = Stopwatch()..start();
        final library = _Library(
          Future<void>.delayed(const Duration(milliseconds: 400)),
        );
        final catalog = _Catalog();
        final state = AppState(
          catalog: catalog,
          localLibrary: library,
          queueStore: _queueStore(),
          artworkSeedLoader: (_) async => null,
        );
        int? queueReadyAt;
        state.addListener(() {
          if (state.current != null) queueReadyAt ??= clock.elapsedMilliseconds;
        });
        final homeReady = catalog.requested.future.then((_) {
          homeTimes.add(clock.elapsedMilliseconds);
        });
        await state.bootstrap();
        await homeReady;
        queueTimes.add(queueReadyAt!);
        completeTimes.add(clock.elapsedMilliseconds);
        state.dispose();
        library.dispose();
      }
      // Keep the measurement reproducible against the pre-optimization pipeline
      // without weakening the normal regression check.
      const measuringBaseline = bool.fromEnvironment('LAZER_STARTUP_BASELINE');
      // ignore: avoid_print
      print(
        'cold_start local=400ms home=$homeTimes queue=$queueTimes complete=$completeTimes',
      );
      if (!measuringBaseline) {
        expect(homeTimes, everyElement(lessThan(200)));
        expect(queueTimes, everyElement(lessThan(200)));
        expect(completeTimes, everyElement(greaterThanOrEqualTo(390)));
      }
    },
  );
}
