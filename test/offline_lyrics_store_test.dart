import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/music_models.dart';
import 'package:lazer_nextgen/lyrics/cached_lyrics_store.dart';
import 'package:lazer_nextgen/lyrics/imported_lyrics_store.dart';
import 'package:lazer_nextgen/state/app_state.dart';

const song = Track(
  id: 'fixture:connection:song:opaque',
  title: 'Song',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 3),
  coverSeed: 1,
);
const payload = GatewayLyrics(
  yrc: '[1000,800](1000,400,0)First (1400,400,0)line',
  tlyric: '[00:01]译文',
);

class _LocalCatalog extends Catalog {
  _LocalCatalog(CachedLyricsStore cache) : super(lyricsCache: cache);
  int requests = 0;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async {
    requests++;
    throw const SocketException('offline');
  }

  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => null;
}

class _DelayedStore extends CachedLyricsStore {
  final readGate=Completer<GatewayLyrics?>(),writeGate=Completer<void>();
  @override Future<GatewayLyrics?> read(Track track,{String? audioPath})=>readGate.future;
  @override Future<void> save(Track track,GatewayLyrics payload,{String? audioPath})=>writeGate.future;
}
class _PayloadCatalog extends Catalog {
  _PayloadCatalog(CachedLyricsStore store,this.response):super(lyricsCache:store);
  final Future<GatewayLyrics?> response;
  @override Future<GatewayLyrics?> lyricsFor(Track track)=>response;
  @override Future<String?> audioUrlFor(Track track,{AudioQuality quality=AudioQuality.exhigh})async=>null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('lazer-offline-lyrics-');
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'a scanned cached file restores word timings and translation without a provider',
    () async {
      final audio = await File('${root.path}/song.flac').writeAsBytes([1]);
      final store = CachedLyricsStore(supportDirectory: () async => root);
      await store.save(song, payload, audioPath: audio.path);
      final restarted = CachedLyricsStore(supportDirectory: () async => root);
      final scanned = Track(
        id: 'local:rescanned',
        title: song.title,
        artist: song.artist,
        album: song.album,
        duration: song.duration,
        coverSeed: 1,
        localPath: audio.path,
      );
      final catalog = _LocalCatalog(restarted);
      final app = AppState(
        catalog: catalog,
        importedLyrics: ImportedLyricsStore(supportDirectory: () async => root),
      );
      try {
        app.playQueue([scanned]);
        app.pause();
        await app.ensureCurrentLyrics();
        expect(app.lyrics.single.words, hasLength(2));
        expect(app.lyrics.single.translation, '译文');
        expect(app.lyrics.single.words.first.start, const Duration(seconds: 1));
        expect(catalog.requests, 0);
        expect(app.lyricsImported, isFalse);
      } finally {
        app.dispose();
      }
    },
  );

  test('ready lyrics paint while disk reads and writes are still blocked',()async {
    final store=_DelayedStore();final app=AppState(catalog:_PayloadCatalog(store,Future.value(payload)),
      importedLyrics:ImportedLyricsStore(supportDirectory:()async=>throw const FileSystemException('disabled')));
    try {
      app.playQueue([song]);app.pause();await app.ensureCurrentLyrics().timeout(const Duration(seconds:2));
      expect(app.lyrics.single.text,'First line');expect(app.lyricsLoading,isFalse);expect(store.readGate.isCompleted,isFalse);expect(store.writeGate.isCompleted,isFalse);
    } finally {store.readGate.complete(null);store.writeGate.complete();app.dispose();}
  });
  test('cached lyrics paint without waiting for a slow provider',()async {
    final store=_DelayedStore()..readGate.complete(payload);final remote=Completer<GatewayLyrics?>();
    final app=AppState(catalog:_PayloadCatalog(store,remote.future),
      importedLyrics:ImportedLyricsStore(supportDirectory:()async=>throw const FileSystemException('disabled')));
    try {
      app.playQueue([song]);app.pause();await app.ensureCurrentLyrics().timeout(const Duration(seconds:2));
      expect(app.lyrics.single.text,'First line');expect(app.lyricsLoading,isFalse);expect(remote.isCompleted,isFalse);
      remote.complete(const GatewayLyrics(lrc:'[00:01]Updated'));await Future<void>.delayed(Duration.zero);expect(app.lyrics.single.text,'Updated');
    } finally {if(!remote.isCompleted)remote.complete(null);store.writeGate.complete();app.dispose();}
  });
  test(
    'an imported copy survives deletion of the original and a store restart',
    () async {
      final original = await File(
        '${root.path}/original.lrc',
      ).writeAsString('[00:01]Imported');
      final support = Directory('${root.path}/application');
      final store = ImportedLyricsStore(supportDirectory: () async => support);
      expect(await store.save(song, await original.readAsString()), isTrue);
      final copy = (await store.fileFor(song))!;
      expect(copy.path.startsWith(support.path), isTrue);
      await original.delete();
      final restarted = ImportedLyricsStore(
        supportDirectory: () async => support,
      );
      expect(await restarted.read(song), '[00:01]Imported');
    },
  );
}
