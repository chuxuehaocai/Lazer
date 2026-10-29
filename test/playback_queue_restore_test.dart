import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/local/local_library.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/playback_queue_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

Track track(String id) => Track(
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
  }) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => const GatewayLyrics();
}

class _Library extends LocalLibrary {
  _Library({this.gate});
  final Completer<void>? gate;
  @override
  Future<void> load() async {
    await gate?.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('new playback wins over a pending restored queue', () async {
    final readStarted = Completer<void>();
    final readGate = Completer<String?>();
    final store = PlaybackQueueStore(
      read: () {
        readStarted.complete();
        return readGate.future;
      },
      write: (_) async {},
    );
    final library = _Library();
    final state = AppState(
      catalog: _Catalog(),
      localLibrary: library,
      queueStore: store,
    );
    {
      final boot = state.bootstrap();
      await readStarted.future.timeout(const Duration(seconds: 5));
      state.playQueue([track('20')]);
      readGate.complete(
        jsonEncode({
          'index': 0,
          'tracks': [track('10').toJson()],
        }),
      );
      await boot;
      expect(state.current?.id, '20');
    }
    state.dispose();
    library.dispose();
  });

  test('sign-out prevents an in-flight queue restore from returning', () async {
    final started = Completer<void>();
    final gate = Completer<String?>();
    final store = PlaybackQueueStore(
      read: () {
        started.complete();
        return gate.future;
      },
      write: (_) async {},
    );
    final library = _Library();
    final state = AppState(
      catalog: _Catalog(),
      localLibrary: library,
      queueStore: store,
    );
    final boot = state.bootstrap();
    await started.future.timeout(const Duration(seconds: 5));
    await state.signOut();
    gate.complete(
      jsonEncode({
        'index': 0,
        'tracks': [track('10').toJson()],
      }),
    );
    await boot;
    expect(state.queue, isEmpty);
    state.dispose();
    library.dispose();
  });

  test('playback before queue restoration skips the old queue read', () async {
    final loadGate = Completer<void>();
    final library = _Library(gate: loadGate);
    var reads = 0;
    final store = PlaybackQueueStore(
      read: () async {
        reads++;
        return null;
      },
      write: (_) async {},
    );
    final state = AppState(
      catalog: _Catalog(),
      localLibrary: library,
      queueStore: store,
    );
    {
      final boot = state.bootstrap();
      state.playQueue([track('30')]);
      loadGate.complete();
      await boot;
      expect(reads, 0);
      expect(state.current?.id, '30');
    }
    state.dispose();
    library.dispose();
  });
}
