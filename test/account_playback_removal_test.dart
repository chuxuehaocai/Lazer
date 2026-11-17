import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/local/local_library.dart';
import 'package:lazer_nextgen/state/app_state.dart';

import 'support/music_gateway.dart';

class _Gateway extends TestMusicGateway {
  bool signedIn = true;
  Completer<Map<String, dynamic>>? leaving;
  int leaveCalls = 0;
  @override
  MusicUser? get user => signedIn
      ? MusicUser(id: id(MusicEntityKind.user, '7'), name: 'Listener')
      : null;
  @override
  void clearSession() => signedIn = false;
  @override
  Future<Map<String, dynamic>> listenTogether(
    String operation, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (operation == 'leave') {
      leaveCalls++;
      return leaving?.future ?? {'code': 200};
    }
    return operation == 'create' || operation == 'createMulti'
        ? {'roomId': 'room', 'inviterId': '7'}
        : {'code': 200};
  }
}

class _Catalog extends Catalog {
  _Catalog(_Gateway gateway) : super(gateway: gateway);
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
    bool Function()? isCancelled,
  }) async => 'fixture://${track.id}';
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => const GatewayLyrics();
  @override
  Future<HomeFeed?> loadHome({int? userId}) async => null;
}

class _Library extends LocalLibrary {
  @override
  Future<String?> playbackUrl(Track track, {AudioQuality? quality}) async =>
      track.localPath == null ? null : 'file:///${track.localPath}';
}

class _Engine implements AudioEngine {
  Completer<void>? stopGate;
  int stops = 0;
  bool running = false;
  final loads = <String>[];
  @override
  bool get active => running;
  @override
  Duration position = Duration.zero;
  @override
  Duration? get duration => const Duration(minutes: 3);
  @override
  Stream<void> get completed => const Stream.empty();
  @override
  Future<void> setUrl(String url) async {
    loads.add(url);
    running = true;
  }

  @override
  Future<void> play() async => running = true;
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration value) async => position = value;
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> stop() async {
    stops++;
    running = false;
    await stopGate?.future;
  }

  @override
  void dispose() {}
}

Track _track(String id, {bool local = false}) => Track(
  id: id,
  title: id,
  artist: '',
  album: '',
  coverSeed: 0,
  duration: const Duration(minutes: 3),
  localPath: local ? '$id.mp3' : null,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final stage in ['leave', 'stop']) {
    testWidgets('a late account $stage cannot replace a new local queue', (
      tester,
    ) async {
      final gateway = _Gateway();
      final engine = _Engine();
      final library = _Library();
      final state = AppState(
        catalog: _Catalog(gateway),
        audioEngine: engine,
        localLibrary: library,
      );
      addTearDown(() {
        state.dispose();
        library.dispose();
      });
      final old = _track(gateway.id(MusicEntityKind.song, 'old').cacheKey);
      final staleRetained = _track('stale-local', local: true);
      state.playQueue([old, staleRetained]);
      await tester.pump();
      if (stage == 'leave') {
        expect(await state.listenTogether.create(), isTrue);
        gateway.leaving = Completer<Map<String, dynamic>>();
      } else {
        engine.stopGate = Completer<void>();
      }
      final removing = state.signOut();
      await tester.pump();
      expect(stage == 'leave' ? gateway.leaveCalls : engine.stops, 1);
      final latest = _track('latest-local', local: true);
      state.playQueue([latest]);
      await tester.pump();
      final stops = engine.stops;
      gateway.leaving?.complete({'code': 200});
      engine.stopGate?.complete();
      await tester.pump();
      await removing;
      await tester.pump();
      expect(state.current, same(latest));
      expect(state.queue, [latest]);
      expect(state.playing, isTrue);
      expect(engine.stops, stops);
      expect(engine.loads.last, contains('latest-local'));
      expect(gateway.signedIn, isFalse);
      state.pause();
      await tester.pump();
    });
  }

  testWidgets('account cleanup re-evaluates a replacement mixed queue', (
    tester,
  ) async {
    final gateway = _Gateway();
    final engine = _Engine()..stopGate = Completer<void>();
    final library = _Library();
    final state = AppState(
      catalog: _Catalog(gateway),
      audioEngine: engine,
      localLibrary: library,
    );
    addTearDown(() {
      state.dispose();
      library.dispose();
    });
    final old = _track(gateway.id(MusicEntityKind.song, 'old').cacheKey);
    state.playQueue([old]);
    await tester.pump();
    final removing = state.signOut();
    await tester.pump();
    expect(engine.stops, 1);
    final latest = _track('latest-local', local: true);
    state.playQueue([latest, old]);
    await tester.pump();
    engine.stopGate!.complete();
    await tester.pump();
    await removing;
    await tester.pump();
    expect(state.current, same(latest));
    expect(state.queue, [latest]);
    expect(state.playing, isTrue);
    state.pause();
    await tester.pump();
  });

  testWidgets('ordinary account cleanup retains unrelated queued songs', (
    tester,
  ) async {
    final gateway = _Gateway();
    final engine = _Engine();
    final library = _Library();
    final state = AppState(
      catalog: _Catalog(gateway),
      audioEngine: engine,
      localLibrary: library,
    );
    addTearDown(() {
      state.dispose();
      library.dispose();
    });
    final old = _track(gateway.id(MusicEntityKind.song, 'old').cacheKey);
    final retained = _track('retained-local', local: true);
    state.playQueue([old, retained]);
    await tester.pump();
    await state.signOut();
    expect(state.queue, [retained]);
    expect(state.playing, isFalse);
    expect(gateway.signedIn, isFalse);
  });
}
