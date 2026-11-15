import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/l10n/app_language.dart';
import 'package:lazer_nextgen/local/local_library.dart';
import 'package:lazer_nextgen/platform/system_widgets.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/playback_queue_store.dart';

Track _track(String id, {String? cover}) => Track(
  id: id,
  title: 'Song $id',
  artist: 'Artist $id',
  album: 'Album $id',
  coverUrl: cover,
  coverSeed: 1,
  duration: const Duration(minutes: 3),
);

Future<void> _flush() => Future<void>.delayed(Duration.zero);

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

class _Library extends LocalLibrary {
  @override
  Future<void> load() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'identical reports are deduplicated while language and play state update',
    () async {
      final published = <Map<String, Object?>>[];
      final bridge = SystemWidgetsBridge(
        publish: (data) async => published.add(data),
      );
      addTearDown(bridge.dispose);
      final track = _track('a');
      for (var report = 0; report < 10; report++) {
        await bridge.update(track: track, playing: true, language: 'en');
      }
      expect(published, hasLength(1));
      await bridge.update(track: track, playing: false, language: 'en');
      await bridge.update(track: track, playing: false, language: 'ja');
      expect(published, hasLength(3));
      expect(published.last['language'], 'ja');
      expect(published.last['playing'], false);
      await bridge.update(track: null, playing: true, language: 'ja');
      expect(published.last['hasTrack'], false);
      expect(published.last['playing'], false);
      expect(published.last['title'], '');
    },
  );

  test(
    'slow artwork never blocks titles and rapid skips load only the latest cover',
    () async {
      final published = <Map<String, Object?>>[];
      final loads = <String>[];
      final gates = <String, Completer<Uint8List?>>{};
      final bridge = SystemWidgetsBridge(
        publish: (data) async => published.add(data),
        loadArtwork: (source) {
          loads.add(source);
          return (gates[source] = Completer<Uint8List?>()).future;
        },
      );
      addTearDown(bridge.dispose);
      await bridge.update(
        track: _track('a', cover: 'a'),
        playing: true,
        language: 'en',
      );
      await bridge.update(
        track: _track('b', cover: 'b'),
        playing: true,
        language: 'en',
      );
      await bridge.update(
        track: _track('c', cover: 'c'),
        playing: true,
        language: 'ja',
      );
      expect(published.map((data) => data['trackId']), ['a', 'b', 'c']);
      expect(loads, ['a']);
      gates['a']!.complete(Uint8List.fromList([1]));
      await _flush();
      expect(loads, ['a', 'c']);
      expect(
        published,
        hasLength(3),
        reason: 'an obsolete cover must not publish',
      );
      gates['c']!.complete(Uint8List.fromList([3]));
      await _flush();
      expect(published.last['trackId'], 'c');
      expect(published.last['language'], 'ja');
      expect(published.last['artwork'], [3]);
    },
  );

  test(
    'a shared album cover publishes with the latest metadata and is reused',
    () async {
      final published = <Map<String, Object?>>[];
      final gate = Completer<Uint8List?>();
      var loads = 0;
      final bridge = SystemWidgetsBridge(
        publish: (data) async => published.add(data),
        loadArtwork: (_) {
          loads++;
          return gate.future;
        },
      );
      addTearDown(bridge.dispose);
      await bridge.update(
        track: _track('a', cover: 'album'),
        playing: true,
        language: 'en',
      );
      await bridge.update(
        track: _track('b', cover: 'album'),
        playing: false,
        language: 'ja',
      );
      gate.complete(Uint8List.fromList([4]));
      await _flush();
      expect(published.last['trackId'], 'b');
      expect(published.last['playing'], false);
      expect(published.last['language'], 'ja');
      expect(published.last['artwork'], [4]);
      await bridge.update(
        track: _track('c', cover: 'album'),
        playing: true,
        language: 'ja',
      );
      expect(loads, 1);
      expect(published.last['artwork'], [4]);
    },
  );

  test(
    'dispose rejects updates and releases queued covers after an in-flight read',
    () async {
      final published = <Map<String, Object?>>[];
      final gate = Completer<Uint8List?>();
      var loads = 0;
      final bridge = SystemWidgetsBridge(
        publish: (data) async => published.add(data),
        loadArtwork: (_) {
          loads++;
          return gate.future;
        },
      );
      await bridge.update(
        track: _track('a', cover: 'a'),
        playing: true,
        language: 'en',
      );
      await bridge.update(
        track: _track('b', cover: 'b'),
        playing: true,
        language: 'en',
      );
      bridge.dispose();
      gate.complete(Uint8List.fromList([1]));
      await _flush();
      await bridge.update(track: _track('c'), playing: false, language: 'en');
      expect(published, hasLength(2));
      expect(loads, 1);
    },
  );

  test(
    'slow native writes coalesce pending metadata and publish failures stay optional',
    () async {
      final published = <String>[];
      final gate = Completer<void>();
      final bridge = SystemWidgetsBridge(
        publish: (data) async {
          published.add(data['trackId']! as String);
          if (published.length == 1) {
            await gate.future;
            throw StateError('native unavailable');
          }
        },
      );
      addTearDown(bridge.dispose);
      final first = bridge.update(
        track: _track('a'),
        playing: true,
        language: 'en',
      );
      bridge.update(track: _track('b'), playing: true, language: 'en');
      final latest = bridge.update(
        track: _track('c'),
        playing: false,
        language: 'ja',
      );
      gate.complete();
      await Future.wait([first, latest]);
      expect(published, ['a', 'c']);
    },
  );

  for (final (restoreCurrent, restoreHistory) in [
    (false, false),
    (false, true),
    (true, true),
  ]) {
    test(
      'AppState publishes ${restoreCurrent
          ? 'restored current track'
          : restoreHistory
          ? 'restored recent history'
          : 'empty initial history'} and language changes',
      () async {
        SharedPreferences.setMockInitialValues({
          if (restoreHistory)
            'lazer_recent_tracks_v1': jsonEncode([_track('recent').toJson()]),
        });
        final published = <Map<String, Object?>>[];
        final bridge = SystemWidgetsBridge(
          publish: (data) async => published.add(data),
        );
        final library = _Library();
        final state = AppState(
          systemWidgets: bridge,
          catalog: _Catalog(),
          localLibrary: library,
          queueStore: PlaybackQueueStore(
            read: () async => restoreCurrent
                ? jsonEncode({
                    'index': 0,
                    'tracks': [_track('20').toJson()],
                  })
                : null,
            write: (_) async {},
          ),
        );
        var disposed = false;
        addTearDown(() {
          if (!disposed) {
            state.dispose();
            library.dispose();
          }
        });
        await state.bootstrap();
        await _flush();
        expect(state.current?.id, restoreCurrent ? '20' : isNull);
        expect(
          published.last['trackId'],
          restoreCurrent
              ? '20'
              : restoreHistory
              ? 'recent'
              : '',
        );
        expect(published.last['hasTrack'], restoreCurrent || restoreHistory);
        expect(published.last['playing'], false);
        await state.setLanguage(AppLanguage.japanese);
        await _flush();
        expect(published.last['language'], 'ja');
        final count = published.length;
        await state.setLanguage(AppLanguage.japanese);
        await _flush();
        expect(published, hasLength(count));
        state.dispose();
        library.dispose();
        disposed = true;
        await bridge.update(
          track: _track('late'),
          playing: true,
          language: 'en',
        );
        expect(published, hasLength(count));
      },
    );
  }
}
