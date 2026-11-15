import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/music_models.dart';
import 'package:lazer_nextgen/lyrics/cached_lyrics_store.dart';

Track _track(String id) => Track(
  id: id,
  title: id,
  artist: 'Artist',
  album: 'Album',
  duration: const Duration(minutes: 3),
  coverSeed: 1,
);

/// Writes a cache row the way an older build did: no `savedAt` field.
File _legacyRow(Directory directory, Track track, Map<String, Object?> extra) {
  final key = 'song:${track.id}';
  final name = _sha256(key);
  final file = File('${directory.path}/cached_lyrics/$name.json');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(jsonEncode(<String, Object?>{'version': 1, ...extra}));
  return file;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  late CachedLyricsStore store;

  setUp(() {
    support = Directory.systemTemp.createTempSync('lazer-lyrics-');
    store = CachedLyricsStore(supportDirectory: () async => support);
  });

  tearDown(() {
    if (support.existsSync()) support.deleteSync(recursive: true);
  });

  test('a fresh no-lyrics verdict is served from the cache', () async {
    final track = _track('song:fresh');
    await store.save(track, const GatewayLyrics(pureMusic: true));

    final cached = await store.read(track);

    expect(cached, isNotNull);
    expect(cached!.pureMusic, isTrue);
  });

  test('an expired no-lyrics verdict is ignored so the provider is asked', () async {
    final track = _track('song:expired');
    final file = _legacyRow(support, track, <String, Object?>{
      'pureMusic': true,
      'savedAt': DateTime.now()
          .toUtc()
          .subtract(CachedLyricsStore.pureMusicTtl + const Duration(hours: 1))
          .toIso8601String(),
    });

    expect(await store.read(track), isNull);
    expect(file.existsSync(), isTrue, reason: 'read must not delete the row');
  });

  test('a no-lyrics row written before savedAt existed is ignored', () async {
    final track = _track('song:legacy');
    _legacyRow(support, track, <String, Object?>{'pureMusic': true});

    expect(await store.read(track), isNull);
  });

  test('timed lyrics never expire', () async {
    final track = _track('song:timed');
    _legacyRow(support, track, <String, Object?>{
      'pureMusic': false,
      'yrc': '[1000,500](1000,500,0)Hello',
      'savedAt': DateTime.now()
          .toUtc()
          .subtract(const Duration(days: 30))
          .toIso8601String(),
    });

    final cached = await store.read(track);

    expect(cached, isNotNull);
    expect(cached!.yrc, '[1000,500](1000,500,0)Hello');
  });

  test('save records savedAt so the ttl can be measured later', () async {
    final track = _track('song:stamp');
    await store.save(track, const GatewayLyrics(pureMusic: true));

    final file = File(
      '${support.path}/cached_lyrics/${_sha256('song:${track.id}')}.json',
    );
    final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

    expect(data['savedAt'], isA<String>());
    expect(DateTime.tryParse(data['savedAt'] as String), isNotNull);
  });

  test('clear removes every row and reports the count', () async {
    for (var i = 0; i < 3; i++) {
      await store.save(
        _track('song:clear$i'),
        const GatewayLyrics(pureMusic: true),
      );
    }

    expect(await store.clear(), 3);
    expect(
      Directory('${support.path}/cached_lyrics')
          .listSync()
          .whereType<File>()
          .length,
      0,
    );
    expect(await store.read(_track('song:clear0')), isNull);
  });

  test('clear on a missing directory reports zero instead of throwing', () async {
    expect(await store.clear(), 0);
  });
}

String _sha256(String value) {
  // Mirrors CachedLyricsStore._file without importing its private members.
  return sha256.convert(utf8.encode(value)).toString();
}
