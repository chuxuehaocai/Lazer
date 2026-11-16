import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/gateway/gateway.dart';
// ignore: unnecessary_import
import 'package:lazer_nextgen/gateway/lua_music_gateway.dart';
import 'package:lazer_nextgen/plugins/lua_plugin_runtime.dart';

/// Answers `lyrics` with whatever the test queued, so the gateway mapping is
/// exercised without a Lua VM.
class _Runtime extends Fake implements LuaPluginRuntime {
  _Runtime(this.reply);

  final Object? reply;

  @override
  Future<Object?> invoke(
    String operation, [
    Map<String, dynamic> args = const {},
    Duration? budget,
  ]) async => operation == 'lyrics' ? reply : null;
}

LuaMusicGateway _gateway(Object? reply) => LuaMusicGateway(
  runtime: _Runtime(reply),
  provider: const MusicProvider(id: 'fixture', name: 'Fixture'),
  connectionId: 'fixture',
);

void main() {
  const song = MusicId(
    provider: 'fixture',
    connection: 'fixture',
    kind: MusicEntityKind.song,
    value: 'song-1',
  );

  test('an empty reply is retryable, not an instrumental verdict', () async {
    final lyrics = await _gateway(const <Object?>[]).lyrics(song);

    expect(lyrics, isEmpty);
  });

  test('a plugin that states pure music is honoured', () async {
    final lyrics = await _gateway(<Object?>[
      <String, Object?>{'pureMusic': true},
    ]).lyrics(song);

    expect(lyrics, hasLength(1));
    expect(lyrics.single.pureMusic, isTrue);
  });

  test('word-by-word timing and translation survive the mapping', () async {
    final lyrics = await _gateway(<Object?>[
      <String, Object?>{
        'wordByWord': '[1000,500](1000,500,0)Hello',
        'translation': '[00:01]Ni hao',
        'lrc': '[00:01]Hello',
        'synced': true,
        'lines': <Object?>[
          <String, Object?>{'text': 'Hello', 'startMs': 1000},
        ],
      },
    ]).lyrics(song);

    expect(lyrics, hasLength(1));
    final entry = lyrics.single;
    expect(entry.pureMusic, isFalse);
    expect(entry.wordByWord, '[1000,500](1000,500,0)Hello');
    expect(entry.translation, '[00:01]Ni hao');
    expect(entry.lrc, '[00:01]Hello');
    expect(entry.synced, isTrue);
  });

  test('a reply without a pureMusic flag is not instrumental', () async {
    final lyrics = await _gateway(<Object?>[
      <String, Object?>{'lrc': '[00:01]Hello', 'synced': true},
    ]).lyrics(song);

    expect(lyrics.single.pureMusic, isFalse);
  });
}
