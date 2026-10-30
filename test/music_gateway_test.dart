import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:lazer_nextgen/gateway/gateway.dart';

NavidromeGateway _navidrome(String server, String username) => NavidromeGateway(
  serverUrl: server,
  username: username,
  client: MockClient(
    (_) async => http.Response('{"subsonic-response":{"status":"ok"}}', 200),
  ),
);

void main() {
  test('music references round-trip arbitrary opaque IDs without coercion', () {
    const id = MusicId(
      provider: 'platform:one',
      connection: 'server/account',
      kind: MusicEntityKind.song,
      value: 'uuid + & / : \u591c',
    );
    final restored = MusicId.fromJson(
      jsonDecode(jsonEncode(id.toJson())) as Map<String, dynamic>,
    );
    expect(restored, id);
    expect(restored.hashCode, id.hashCode);
    expect({id, restored}, hasLength(1));
    expect(id.cacheKey.split(':'), hasLength(4));
    expect(id.cacheKey, isNot(contains('uuid + &')));
  });

  test(
    'references and caches distinguish platform, connection and entity kind',
    () {
      const song = MusicId(
        provider: 'a',
        connection: 'b',
        kind: MusicEntityKind.song,
        value: 'same',
      );
      for (final other in [
        const MusicId(
          provider: 'other',
          connection: 'b',
          kind: MusicEntityKind.song,
          value: 'same',
        ),
        const MusicId(
          provider: 'a',
          connection: 'other',
          kind: MusicEntityKind.song,
          value: 'same',
        ),
        const MusicId(
          provider: 'a',
          connection: 'b',
          kind: MusicEntityKind.album,
          value: 'same',
        ),
      ]) {
        expect(song, isNot(other));
        expect(song.cacheKey, isNot(other.cacheKey));
      }
    },
  );

  test(
    'registry selects multiple servers and routes saved IDs to their owner',
    () async {
      final registry = GatewayRegistry();
      addTearDown(registry.close);
      final first = _navidrome('https://a.example', 'alice');
      final second = _navidrome('https://b.example', 'alice');
      final otherUser = _navidrome('https://a.example', 'bob');
      final netease = NeteaseMusicGateway(connectionId: 'netease-main');
      registry.add(first);
      registry.add(second);
      registry.add(otherUser);
      registry.add(netease);
      expect(registry.connections, hasLength(4));
      expect(registry.active, same(first));
      final song = first.id(MusicEntityKind.song, 'same');
      registry.select(GatewayRegistry.keyOf(second));
      expect(registry.active, same(second));
      expect(registry.resolve(song), same(first));
      expect(
        registry.resolve(otherUser.id(MusicEntityKind.song, 'same')),
        same(otherUser),
      );
      final guestNamespace = first.cacheNamespace;
      await first.login('password');
      await second.login('password');
      expect(first.cacheNamespace, isNot(guestNamespace));
      expect(first.cacheNamespace, isNot(second.cacheNamespace));
      expect(registry.resolve(song), same(first));
      expect(() => registry.connections.clear(), throwsUnsupportedError);
    },
  );

  test(
    'registry handles duplicates, detachment, missing IDs and disposal',
    () async {
      final registry = GatewayRegistry();
      final first = _navidrome('https://a.example', 'alice');
      final duplicate = _navidrome('https://a.example/', 'alice');
      final second = _navidrome('https://b.example', 'alice');
      addTearDown(duplicate.close);
      registry.add(first);
      registry.add(first);
      expect(() => registry.add(duplicate), throwsStateError);
      expect(registry.active, same(first));
      registry.add(second, select: true);
      registry.remove(GatewayRegistry.keyOf(second), close: false);
      expect(registry.active, same(first));
      expect(await second.login('still-open'), isA<MusicUser>());
      second.close();
      expect(() => registry.select('missing'), throwsArgumentError);
      expect(
        () => registry.resolve(second.id(MusicEntityKind.song, 'same')),
        throwsStateError,
      );
      registry.close();
      expect(registry.active, isNull);
      expect(registry.connections, isEmpty);
      await expectLater(first.login('closed'), throwsStateError);
      registry.close();
    },
  );

  test('Navidrome is explicitly experimental in the provider catalogue', () {
    expect(GatewayRegistry.providers.map((provider) => provider.id), [
      'netease',
      'navidrome',
    ]);
    expect(MusicProvider.netease.experimental, isFalse);
    expect(MusicProvider.navidrome.experimental, isTrue);
  });

  test('song, album, lyric and page collections are immutable snapshots', () {
    const id = MusicId(
      provider: 'a',
      connection: 'b',
      kind: MusicEntityKind.song,
      value: 'c',
    );
    final artists = <MusicArtist>[];
    final song = MusicSong(
      id: id,
      title: 'Song',
      artists: artists,
      duration: Duration.zero,
    );
    final album = MusicAlbum(id: id, title: 'Album', artists: artists);
    artists.add(const MusicArtist(id: id, name: 'Artist'));
    expect(song.artists, isEmpty);
    expect(album.artists, isEmpty);
    expect(() => song.artists.clear(), throwsUnsupportedError);
    final lines = <MusicLyricLine>[const MusicLyricLine(text: 'Line')];
    final lyrics = MusicLyrics(lines: lines);
    lines.clear();
    expect(lyrics.lines, hasLength(1));
    final items = [song];
    final page = MusicPage(items, offset: 10, hasMore: true);
    items.clear();
    expect(page.items, hasLength(1));
    expect(page.nextOffset, 11);
  });
}
