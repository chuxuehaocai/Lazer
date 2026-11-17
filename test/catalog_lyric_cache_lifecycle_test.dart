import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/lyrics/cached_lyrics_store.dart';

class _LyricsStore extends CachedLyricsStore {
  final pending = Completer<GatewayLyrics?>();
  int reads = 0, saves = 0;
  @override
  Future<GatewayLyrics?> read(Track track, {String? audioPath}) {
    reads++;
    return pending.future;
  }

  @override
  Future<void> save(
    Track track,
    GatewayLyrics payload, {
    String? audioPath,
  }) async {
    saves++;
  }
}

class _Catalog extends Catalog {
  _Catalog(_LyricsStore store) : super(lyricsCache: store);
  int foregroundReads = 0;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async {
    foregroundReads++;
    return const GatewayLyrics(lrc: '[00:00]Foreground');
  }
}

Track _track(int id) => Track(
  id: '$id',
  title: 'Track $id',
  artist: '',
  album: '',
  duration: const Duration(minutes: 3),
  coverSeed: 0,
);

void main() {
  test(
    'the owner can join a cached playback lyric task before disk operations begin',
    () async {
      final store = _LyricsStore();
      final catalog = _Catalog(store);
      final first = catalog.cacheLyrics(_track(1), audioPath: 'cached.mp3');
      final joined = catalog.cacheLyrics(_track(1), audioPath: 'cached.mp3');
      final sameTask = identical(first, joined);
      await Future<void>.delayed(Duration.zero);
      final readsBeforeRelease = store.reads;
      store.pending.complete(const GatewayLyrics(lrc: '[00:00]Cached'));
      await Future.wait([first, joined]);
      expect(sameTask, isTrue);
      expect(readsBeforeRelease, 1);
      expect(store.saves, 1);
      expect(catalog.foregroundReads, 0);
      await catalog.cacheLyrics(_track(1), audioPath: 'cached.mp3');
      expect(store.reads, 2); // completed jobs release their map entry
    },
  );

  test(
    '32 pending cache jobs bound optional work while foreground lyrics still run',
    () async {
      final store = _LyricsStore();
      final catalog = _Catalog(store);
      final jobs = [
        for (var i = 0; i < 40; i++) catalog.cacheLyrics(_track(i)),
      ];
      await Future<void>.delayed(Duration.zero);
      final readsBeforeRelease = store.reads;
      final foreground = await catalog.lyricsFor(_track(99));
      store.pending.complete(const GatewayLyrics(lrc: '[00:00]Cached'));
      await Future.wait(jobs);
      expect(readsBeforeRelease, 32);
      expect(store.saves, 32);
      expect(foreground!.lrc, '[00:00]Foreground');
      await catalog.cacheLyrics(_track(40));
      expect(store.reads, 33);
    },
  );
}
