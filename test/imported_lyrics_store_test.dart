import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/lyrics/imported_lyrics_store.dart';

const Track _track = Track(
  id: '12345',
  title: '夜に駆ける',
  artist: 'YOASOBI',
  album: 'THE BOOK',
  duration: Duration(seconds: 261),
  coverSeed: 7,
);

void main() {
  late Directory root;
  late ImportedLyricsStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lazer-lyrics-test-');
    store = ImportedLyricsStore(supportDirectory: () async => root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('decodes UTF-8 with and without a BOM', () {
    const String text = '[00:01.00]夜に駆ける';
    expect(decodeLyricsBytes(utf8.encode(text)), text);
    expect(
      decodeLyricsBytes(<int>[0xEF, 0xBB, 0xBF, ...utf8.encode(text)]),
      text,
    );
  });

  test('decodes UTF-16 little and big endian', () {
    const String text = '[00:01.00]你好';
    List<int> units({required bool little}) => <int>[
      for (final int unit in text.codeUnits) ...<int>[
        little ? unit & 0xFF : (unit >> 8) & 0xFF,
        little ? (unit >> 8) & 0xFF : unit & 0xFF,
      ],
    ];
    expect(decodeLyricsBytes(<int>[0xFF, 0xFE, ...units(little: true)]), text);
    expect(decodeLyricsBytes(<int>[0xFE, 0xFF, ...units(little: false)]), text);
  });

  test('rejects bytes that are not valid UTF-8', () {
    expect(
      () => decodeLyricsBytes(<int>[0xC3, 0x28]),
      throwsA(isA<FormatException>()),
    );
  });

  test('saves, reads and deletes timed lyrics', () async {
    const String content = '[00:01.00]first line\n[00:02.50]second line';
    expect(await store.has(_track), isFalse);
    expect(await store.save(_track, content), isTrue);
    expect(await store.has(_track), isTrue);
    expect(await store.read(_track), content);
    await store.delete(_track);
    expect(await store.has(_track), isFalse);
    expect(await store.read(_track), isNull);
  });

  test('rejects lyrics without a single timed line', () async {
    expect(await store.save(_track, 'plain text only'), isFalse);
    expect(await store.has(_track), isFalse);
  });

  test('finds a sidecar .lrc next to a local file', () async {
    final File audio = File('${root.path}/song.flac');
    await audio.writeAsBytes(<int>[0x66, 0x4C, 0x61, 0x43]);
    await File('${root.path}/song.lrc').writeAsString('[00:01.00]hello');
    expect(await ImportedLyricsStore.sidecarFor(audio.path), '[00:01.00]hello');
  });

  test('ignores an empty sidecar', () async {
    final File audio = File('${root.path}/song.mp3');
    await audio.writeAsBytes(<int>[0x49, 0x44, 0x33]);
    await File('${root.path}/song.lrc').writeAsString('metadata only');
    expect(await ImportedLyricsStore.sidecarFor(audio.path), isNull);
  });

  test('stores each track id in its own file', () async {
    const Track other = Track(
      id: '999',
      title: 'other',
      artist: '',
      album: '',
      duration: Duration.zero,
      coverSeed: 1,
    );
    expect(await store.save(_track, '[00:01.00]a'), isTrue);
    expect(await store.save(other, '[00:01.00]b'), isTrue);
    final File first = (await store.fileFor(_track))!;
    final File second = (await store.fileFor(other))!;
    expect(first.path, isNot(second.path));
    expect(Uint8List.fromList(await first.readAsBytes()), isNotEmpty);
  });
}
