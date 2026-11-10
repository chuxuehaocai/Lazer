import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/lyrics/imported_lyrics_store.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Track _track = Track(
  id: '42',
  title: '夜に駆ける',
  artist: 'YOASOBI',
  album: 'THE BOOK',
  duration: Duration(seconds: 261),
  coverSeed: 3,
);

class _LyricsCatalog extends Catalog {
  _LyricsCatalog(this.cloud);

  final GatewayLyrics cloud;
  int cloudRequests = 0;

  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async {
    cloudRequests++;
    return cloud;
  }

  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
    bool Function()? isCancelled,
  }) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late ImportedLyricsStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    root = await Directory.systemTemp.createTemp('lazer-lyrics-priority-');
    store = ImportedLyricsStore(supportDirectory: () async => root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<void> waitForLyrics(AppState state) async {
    for (int attempt = 0; attempt < 200 && state.lyricsLoading; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(state.lyricsLoading, isFalse);
  }

  Future<void> waitForImported(AppState state) async {
    for (int attempt = 0; attempt < 200 && !state.lyricsImported; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(state.lyricsImported, isTrue);
  }

  test('imported lyrics win over the cloud and removal restores it', () async {
    final _LyricsCatalog catalog = _LyricsCatalog(
      const GatewayLyrics(lrc: '[00:01.00]cloud line'),
    );
    expect(await store.save(_track, '[00:01.00]imported line'), isTrue);
    final AppState state = AppState(catalog: catalog, importedLyrics: store);
    addTearDown(state.dispose);

    state.playQueue(const <Track>[_track]);
    await waitForLyrics(state);
    await waitForImported(state);

    expect(state.lyrics.single.text, 'imported line');

    await state.clearImportedLyrics(_track);
    await waitForLyrics(state);

    expect(state.lyricsImported, isFalse);
    expect(state.lyrics.single.text, 'cloud line');
    expect(catalog.cloudRequests, greaterThanOrEqualTo(1));
  });

  test('a local track without imported lyrics skips the cloud', () async {
    const Track local = Track(
      id: 'local:abc',
      title: 'song',
      artist: 'artist',
      album: 'album',
      duration: Duration.zero,
      coverSeed: 1,
      localPath: '/tmp/song.mp3',
    );
    final _LyricsCatalog catalog = _LyricsCatalog(
      const GatewayLyrics(lrc: '[00:01.00]cloud line'),
    );
    final AppState state = AppState(catalog: catalog, importedLyrics: store);
    addTearDown(state.dispose);

    state.playQueue(const <Track>[local]);
    await waitForLyrics(state);

    expect(state.lyrics, isEmpty);
    expect(state.lyricsError, isNull);
    expect(catalog.cloudRequests, 0);
  });
}
