import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/lyrics/imported_lyrics_store.dart';
import 'package:lazer_nextgen/state/app_state.dart';

Track _track(String id) => Track(
  id: id,
  title: id,
  artist: 'Artist',
  album: 'Album',
  duration: const Duration(minutes: 3),
  coverSeed: 1,
);

class _Catalog extends Catalog {
  final calls = <String, int>{};
  final payloads = <String, GatewayLyrics>{};
  final pending = <String, Completer<GatewayLyrics?>>{};
  final audio = Completer<String?>();
  int invalidations = 0;
  bool offline = false;

  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async {
    calls.update(track.id, (value) => value + 1, ifAbsent: () => 1);
    if (offline) throw const SocketException('offline');
    if (pending[track.id] case final request?) return request.future;
    return payloads[track.id] ??
        GatewayLyrics(
          yrc: '[1000,800](1000,400,0)First (1400,400,0)${track.id}',
          tlyric: '[00:01]Translation ${track.id}',
        );
  }

  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
    bool Function()? isCancelled,
  }) => audio.future;

  @override
  Future<void> invalidateLyrics(String trackId) async => invalidations++;
}

class _Imported extends ImportedLyricsStore {
  final values = <String, String>{};
  final pending = <String, Completer<String?>>{};

  @override
  Future<String?> read(Track track) =>
      pending[track.id]?.future ?? Future.value(values[track.id]);

  @override
  Future<bool> save(Track track, String content) async {
    values[track.id] = content;
    return true;
  }

  @override
  Future<void> delete(Track track) async => values.remove(track.id);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'selection caches parsed lyrics before audio and player are ready',
    () async {
      final catalog = _Catalog();
      final state = AppState(catalog: catalog, importedLyrics: _Imported());
      addTearDown(state.dispose);
      final first = _track('lyric-a');
      final second = _track('lyric-b');
      state.playQueue([first, second]);
      state.pause();
      await state.ensureCurrentLyrics();
      final cached = state.lyrics;
      expect(catalog.audio.isCompleted, isFalse);
      expect(cached.single.words, hasLength(2));
      expect(cached.single.translation, 'Translation lyric-a');

      await state.ensureCurrentLyrics();
      expect(state.lyrics, same(cached));
      expect(catalog.calls[first.id], 1);
      state.next();
      await state.ensureCurrentLyrics();
      catalog.offline = true;
      state.previous();
      // No asynchronous read, parser or loading spinner is needed on return.
      expect(state.lyrics, same(cached));
      expect(state.lyricsLoading, isFalse);
      expect(state.currentLyricsSettled, isTrue);
      expect(catalog.calls[first.id], 1);
    },
  );

  test(
    'opening joins the selection request and ignores late older lyrics',
    () async {
      final catalog = _Catalog();
      final first = _track('pending-a');
      final second = _track('pending-b');
      final old = catalog.pending[first.id] = Completer<GatewayLyrics?>();
      final selected = catalog.pending[second.id] = Completer<GatewayLyrics?>();
      final state = AppState(catalog: catalog, importedLyrics: _Imported());
      addTearDown(state.dispose);
      state.playQueue([first, second]);
      state.pause();
      final previousOpen = state.ensureCurrentLyrics();
      state.next();
      final opening = state.ensureCurrentLyrics();
      expect(catalog.calls, {first.id: 1, second.id: 1});
      selected.complete(const GatewayLyrics(lrc: '[00:01]Selected'));
      await opening;
      expect(state.lyrics.single.text, 'Selected');
      old.complete(const GatewayLyrics(lrc: '[00:01]Outdated'));
      await previousOpen;
      expect(state.current, second);
      expect(state.lyrics.single.text, 'Selected');
      expect(state.lyricsLoading, isFalse);
    },
  );

  test(
    'force refresh and imported edits replace the cached snapshot',
    () async {
      final catalog = _Catalog();
      final imported = _Imported();
      final state = AppState(catalog: catalog, importedLyrics: imported);
      addTearDown(state.dispose);
      final track = _track('refresh');
      state.playQueue([track]);
      state.pause();
      await state.ensureCurrentLyrics();
      final old = state.lyrics;
      catalog.payloads[track.id] = const GatewayLyrics(lrc: '[00:01]Fresh');
      await state.ensureCurrentLyrics(force: true);
      expect(catalog.invalidations, 1);
      expect(state.lyrics, isNot(same(old)));
      expect(state.lyrics.single.text, 'Fresh');
      await state.saveImportedLyrics(track, '[00:01]Imported');
      expect(state.lyrics.single.text, 'Imported');
      expect(state.lyricsImported, isTrue);
      await state.clearImportedLyrics(track);
      expect(state.lyrics.single.text, 'Fresh');
      expect(state.lyricsImported, isFalse);
    },
  );

  test(
    'a late imported copy still wins after returning to a warm cloud copy',
    () async {
      final catalog = _Catalog();
      final imported = _Imported();
      final first = _track('imported-a');
      final delayed = imported.pending[first.id] = Completer<String?>();
      final state = AppState(catalog: catalog, importedLyrics: imported);
      addTearDown(state.dispose);
      state.playQueue([first, _track('imported-b')]);
      state.pause();
      await state.ensureCurrentLyrics();
      state.next();
      await state.ensureCurrentLyrics();
      state.previous();
      expect(state.lyricsImported, isFalse);
      delayed.complete('[00:01]User copy');
      await Future<void>.delayed(Duration.zero);
      expect(state.lyrics.single.text, 'User copy');
      expect(state.lyricsImported, isTrue);
      expect(catalog.calls[first.id], 1);
    },
  );

  test(
    'ready imported lyrics never wait for an unfinished cloud request',
    () async {
      final track = _track('local-priority');
      final catalog = _Catalog()
        ..pending[track.id] = Completer<GatewayLyrics?>();
      final imported = _Imported()..values[track.id] = '[00:01]User copy';
      final state = AppState(catalog: catalog, importedLyrics: imported);
      addTearDown(state.dispose);
      state.playQueue([track]);
      state.pause();
      await Future<void>.delayed(Duration.zero);
      expect(state.lyricsImported, isTrue);
      await state.ensureCurrentLyrics().timeout(const Duration(seconds: 1));
      expect(state.lyrics.single.text, 'User copy');
      catalog.pending[track.id]!.complete(
        const GatewayLyrics(lrc: '[00:01]Cloud'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(state.lyrics.single.text, 'User copy');
    },
  );

  test('the decoded lyric cache stays bounded across a long queue', () async {
    final catalog = _Catalog();
    final tracks = List.generate(12, (index) => _track('bounded-$index'));
    final state = AppState(catalog: catalog, importedLyrics: _Imported());
    addTearDown(state.dispose);
    state.playQueue(tracks);
    state.pause();
    for (var index = 0; index < tracks.length; index++) {
      state.playTrackAt(index);
      state.pause();
      await state.ensureCurrentLyrics();
    }
    state.playTrackAt(10);
    state.pause();
    expect(state.lyricsLoading, isFalse);
    expect(catalog.calls[tracks[10].id], 1);
    state.playTrackAt(0);
    state.pause();
    await state.ensureCurrentLyrics();
    expect(catalog.calls[tracks.first.id], 2);
  });

  test(
    'instrumental and confirmed empty lyrics do not reload on every open',
    () async {
      final catalog = _Catalog()
        ..payloads['instrumental'] = const GatewayLyrics(pureMusic: true)
        ..payloads['empty'] = const GatewayLyrics();
      final state = AppState(catalog: catalog, importedLyrics: _Imported());
      addTearDown(state.dispose);
      state.playQueue([_track('instrumental'), _track('empty')]);
      state.pause();
      for (var index = 0; index < 2; index++) {
        state.playTrackAt(index);
        state.pause();
        await state.ensureCurrentLyrics();
        await state.ensureCurrentLyrics();
        expect(state.lyrics, isEmpty);
        expect(state.lyricsError, isNull);
      }
      expect(catalog.calls, {'instrumental': 1, 'empty': 1});
    },
  );
}
