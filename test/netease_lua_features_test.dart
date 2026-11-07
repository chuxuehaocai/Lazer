import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/gateway/crypto.dart';
import 'package:lazer_nextgen/gateway/lua_music_gateway.dart';
import 'package:lazer_nextgen/gateway/music_gateway.dart';
import 'package:lazer_nextgen/plugins/lua_plugin_runtime.dart';
import 'package:lazer_nextgen/plugins/plugin_manifest.dart';
import 'package:lazer_nextgen/state/song_comments_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'account collections, lyric fallback and comments use valid provider requests',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'netease-features-',
      );
      addTearDown(() => directory.delete(recursive: true));
      var rejectLikes = false;
      var lyricMode = 'fallback';
      final requests = <String>[];
      Map<String, dynamic> song(int id) => {
        'id': id,
        'name': 'Song $id',
        'dt': 123000,
        'ar': [],
        'al': {},
      };
      final runtime = LuaPluginRuntime(
        manifest: PluginManifest.decode(
          await File('plugins/lazer.netease/manifest.json').readAsString(),
        ),
        sources: {
          'main.lua': await File(
            'plugins/lazer.netease/main.lua',
          ).readAsString(),
        },
        dataDirectory: directory.path,
        httpHandler: (request) async {
          final path = Uri.parse(request['url'] as String).path;
          requests.add(path);
          var payload = <String, dynamic>{};
          if (path.startsWith('/eapi/')) {
            final params = Uri.splitQueryString(
              request['body'] as String,
            )['params']!;
            final bytes = [
              for (var i = 0; i < params.length; i += 2)
                int.parse(params.substring(i, i + 2), radix: 16),
            ];
            final parts = gatewayAesEcbDecrypt(
              bytes,
              'e82ckenh8dichen8',
            ).split('-36cd479b6b5-');
            expect(parts, hasLength(3));
            expect(parts.first, path.replaceFirst('/eapi/', '/api/'));
            expect(params, gatewayEapi(parts.first, parts[1]));
            payload = jsonDecode(parts[1]) as Map<String, dynamic>;
          }
          final body = switch (path) {
            '/weapi/w/nuser/account/get' => {
              'code': 200,
              'profile': {'userId': 42, 'nickname': 'Listener'},
            },
            '/eapi/song/like/get' =>
              rejectLikes
                  ? {'code': 301}
                  : {
                      'code': 200,
                      'ids': [7, 8, 9],
                    },
            '/eapi/song/like' => {'code': 200},
            '/weapi/v3/song/detail' => {
              'code': 200,
              'songs': [song(9), song(8), song(7)],
            },
            '/weapi/user/playlist' => {
              'code': 200,
              'playlist': [
                {
                  'id': 99,
                  'name': 'Listener喜欢的音乐',
                  'specialType': 5,
                  'trackCount': 3,
                  'creator': {'userId': 42},
                },
              ],
            },
            '/eapi/v6/playlist/detail' => {
              'code': 200,
              'playlist': {
                'id': 99,
                'trackIds': [
                  {'id': 7},
                  {'id': 8},
                  {'id': 9},
                ],
              },
            },
            '/weapi/album/sublist' => {
              'code': 200,
              'data': [
                {'id': 2, 'name': 'Saved'},
              ],
            },
            '/weapi/album/new' => {
              'code': 200,
              'albums': [
                {'id': 3, 'name': 'New'},
              ],
            },
            '/eapi/song/lyric/v1' =>
              lyricMode == 'pure'
                  ? {'code': 200, 'pureMusic': true}
                  : {'code': 500},
            '/eapi/song/lyric' =>
              lyricMode == 'empty'
                  ? {'code': 200}
                  : {
                      'code': 200,
                      'lrc': {'lyric': '[00:01.00]Lyrics'},
                      'tlyric': {'lyric': '[00:01.00]翻译'},
                    },
            '/weapi/v1/resource/comments/R_SO_4_7' => {
              'code': 200,
              'total': 1,
              'more': false,
              'comments': [
                {
                  'commentId': 12,
                  'content': 'Comment',
                  'user': {'userId': 43, 'nickname': 'Author'},
                  'likedCount': 2,
                  'beReplied': [
                    {
                      'user': {'nickname': 'Reply'},
                      'content': 'Quoted',
                    },
                  ],
                },
              ],
            },
            '/weapi/v1/comment/like' => {'code': 200},
            _ => throw StateError('Unexpected endpoint $path'),
          };
          if (path == '/eapi/song/like/get') expect(payload['uid'], 42);
          if (path == '/eapi/song/like') {
            expect(payload['trackId'], 7);
            expect(payload['userid'], 42);
            expect(payload['like'], true);
          }
          if (path == '/eapi/song/lyric/v1') expect(payload['yv'], 0);
          return {'status': 200, 'headers': {}, 'body': jsonEncode(body)};
        },
      );
      addTearDown(runtime.close);
      final gateway = LuaMusicGateway(
        runtime: runtime,
        provider: MusicProvider.netease,
        connectionId: 'lazer.netease',
        declaredCapabilities: {MusicCapability.comments},
      );
      await gateway.loginWithCookie('MUSIC_U=fixture');
      final favorites = await gateway.favorites(limit: 1, offset: 1);
      expect(favorites.items.single.id.value, '8');
      expect(favorites.items.single.starred, true);
      expect(favorites.hasMore, true);
      final playlists = await gateway.playlists();
      expect(playlists.items.single.isFavorites, true);
      expect(playlists.items.single.writable, true);
      expect(
        (await gateway.playlistSongs(
          playlists.items.single.id,
        )).items.map((song) => song.id.value),
        ['7', '8', '9'],
      );
      expect((await gateway.savedAlbums()).items.single.title, 'Saved');
      expect((await gateway.albums()).items.single.title, 'New');
      final id = gateway.id(MusicEntityKind.song, '7');
      await gateway.setFavorite(id, true);
      final lyrics = await gateway.lyrics(id);
      expect(lyrics.single.synced, true);
      expect(lyrics.single.translation, contains('翻译'));
      expect(requests, contains('/eapi/song/lyric'));
      lyricMode = 'pure';
      expect(await gateway.lyrics(id), isEmpty);
      lyricMode = 'empty';
      await expectLater(gateway.lyrics(id), throwsA(isA<PluginException>()));
      rejectLikes = true;
      await expectLater(
        gateway.favorites(),
        throwsA(isA<PluginException>().having((e) => e.code, 'code', 301)),
      );

      final comments = SongCommentsController.forMusicGateway(gateway);
      addTearDown(comments.dispose);
      await comments.openSong(id.cacheKey, accountId: 42);
      expect(comments.unsupported, false);
      expect(comments.error, isNull);
      expect(comments.latest.single.replies.single.author, 'Reply');
      await comments.toggleLike(12);
      expect(comments.latest.single.liked, true);
      expect(comments.latest.single.likedCount, 3);
      expect(requests, contains('/weapi/v1/comment/like'));
    },
  );
}
