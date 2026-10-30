import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/gateway/navidrome_transport.dart';

const _songJson = <String, dynamic>{
  'id': 'song-uuid/with spaces',
  'title': 'Nocturne',
  'artist': 'Artist',
  'artistId': 'artist-uuid',
  'album': 'Night',
  'albumId': 'album-uuid',
  'duration': 123.456,
  'track': 2,
  'discNumber': 1,
  'coverArt': 'cover/uuid',
  'starred': '2026-01-01T00:00:00Z',
  'contentType': 'audio/flac',
  'suffix': 'flac',
  'bitRate': 900,
};

const _albumJson = <String, dynamic>{
  'id': 'album-uuid',
  'name': 'Night',
  'artist': 'Artist',
  'artistId': 'artist-uuid',
  'year': 2025,
  'songCount': 2,
  'song': [_songJson, _songJson],
};

const _playlistJson = <String, dynamic>{
  'id': 'playlist-uuid',
  'name': 'Night mix',
  'owner': 'alice',
  'public': false,
  'songCount': 3,
  'entry': [_songJson, _songJson, _songJson],
};

http.Response _ok([Map<String, dynamic> body = const {}]) => http.Response(
  jsonEncode({
    'subsonic-response': {'status': 'ok', 'version': '1.16.1', ...body},
  }),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

http.Response _failed(int code) => http.Response(
  jsonEncode({
    'subsonic-response': {
      'status': 'failed',
      'error': {'code': code, 'message': 'untrusted-secret-message'},
    },
  }),
  200,
);

String _method(http.Request request) =>
    request.url.pathSegments.last.replaceFirst('.view', '');

Map<String, List<String>> _parameters(http.Request request) =>
    Uri(query: request.body).queryParametersAll;

void main() {
  group('Navidrome connection and authentication', () {
    test('canonicalizes proxy paths and /rest without losing the prefix', () {
      expect(
        navidromeServerUri('https://music.example/proxy/rest/').toString(),
        'https://music.example/proxy/',
      );
      expect(
        navidromeServerUri('https://music.example').toString(),
        'https://music.example/',
      );
      for (final value in [
        'music.example',
        'file:///tmp/music',
        'https://alice:secret@music.example',
        'https://music.example/?token=secret',
        'https://music.example/#fragment',
      ]) {
        expect(() => navidromeServerUri(value), throwsArgumentError);
      }
      expect(
        () => navidromeServerUri('http://localhost:4533'),
        throwsArgumentError,
      );
      expect(
        navidromeServerUri(
          'http://localhost:4533',
          allowInsecureHttp: true,
        ).scheme,
        'http',
      );
    });

    test(
      'POST auth uses token+random salt, not password or URL credentials',
      () async {
        final requests = <http.Request>[];
        final gateway = NavidromeGateway(
          serverUrl: 'https://music.example/proxy/rest/',
          username: ' alice ',
          client: MockClient((request) async {
            requests.add(request);
            expect(request.method, 'POST');
            expect(request.followRedirects, isFalse);
            expect(
              request.url.toString(),
              'https://music.example/proxy/rest/ping.view',
            );
            final params = _parameters(request);
            expect(params['u'], ['alice']);
            expect(params['v'], ['1.16.1']);
            expect(params['c'], ['lazer']);
            expect(params['f'], ['json']);
            expect(params.containsKey('p'), isFalse);
            expect(
              params['t']!.single,
              md5
                  .convert(utf8.encode('p&ss word${params['s']!.single}'))
                  .toString(),
            );
            return _ok();
          }),
        );
        addTearDown(gateway.close);
        expect(gateway.provider.experimental, isTrue);
        expect(gateway.supports(MusicCapability.comments), isFalse);
        expect(gateway.supports(MusicCapability.listenTogether), isFalse);
        final user = await gateway.login('p&ss word');
        expect(user.name, 'alice');
        expect(user.id.value, 'alice');
        final firstSalt = gateway.session!.salt;
        await gateway.login('p&ss word');
        expect(gateway.session!.salt, isNot(firstSalt));
        expect(gateway.session!.toString(), isNot(contains('alice')));
        expect(
          jsonEncode(gateway.session!.toJson()),
          isNot(contains('p&ss word')),
        );
        expect(requests, hasLength(2));
      },
    );

    test('bad credentials do not replace the authenticated session', () async {
      var reject = false;
      final gateway = NavidromeGateway(
        serverUrl: 'https://music.example',
        username: 'alice',
        client: MockClient((_) async => reject ? _failed(40) : _ok()),
      );
      addTearDown(gateway.close);
      await gateway.login('valid');
      final previous = gateway.session;
      reject = true;
      await expectLater(
        gateway.login('invalid'),
        throwsA(
          isA<MusicGatewayException>().having(
            (error) => error.authenticationFailure,
            'auth',
            isTrue,
          ),
        ),
      );
      expect(gateway.session, same(previous));
      expect(gateway.user!.name, 'alice');
      expect(await gateway.checkSession(), isNull);
      expect(gateway.session, isNull);
    });

    test('an in-flight login cannot resurrect a cleared session', () async {
      final pending = Completer<http.Response>();
      final gateway = NavidromeGateway(
        serverUrl: 'https://music.example',
        username: 'alice',
        client: MockClient((_) => pending.future),
      );
      addTearDown(gateway.close);
      final login = gateway.login('password');
      gateway.clearSession();
      pending.complete(_ok());
      await expectLater(login, throwsA(isA<MusicGatewayException>()));
      expect(gateway.session, isNull);
      expect(gateway.user, isNull);
    });

    test(
      'session serialization restores identity without raw passwords',
      () async {
        NavidromeGateway build(String username) => NavidromeGateway(
          serverUrl: 'https://music.example/proxy',
          username: username,
          client: MockClient((_) async => _ok()),
        );
        final first = build('alice');
        final second = build('alice');
        final other = build('bob');
        addTearDown(first.close);
        addTearDown(second.close);
        addTearDown(other.close);
        await first.login('password');
        final restored = NavidromeSession.fromJson(
          jsonDecode(jsonEncode(first.session!.toJson()))
              as Map<String, dynamic>,
        );
        await second.restoreSession(restored);
        expect(second.connectionId, first.connectionId);
        expect(second.cacheNamespace, first.cacheNamespace);
        expect(other.connectionId, isNot(first.connectionId));
        await expectLater(other.restoreSession(restored), throwsArgumentError);
        expect(
          () => NavidromeSession.fromJson({'token': 'bad'}),
          throwsFormatException,
        );
      },
    );

    test(
      'a stale authentication failure cannot clear a newer session',
      () async {
        var ping = 0;
        final pending = Completer<http.Response>();
        final gateway = NavidromeGateway(
          serverUrl: 'https://music.example',
          username: 'alice',
          client: MockClient((_) {
            ping++;
            return ping == 2 ? pending.future : Future.value(_ok());
          }),
        );
        addTearDown(gateway.close);
        await gateway.login('old-password');
        final check = gateway.checkSession();
        await gateway.login('new-password');
        final current = gateway.session;
        pending.complete(_failed(40));
        await expectLater(
          check,
          throwsA(
            isA<MusicGatewayException>().having(
              (error) => error.authenticationFailure,
              'stale response',
              isFalse,
            ),
          ),
        );
        expect(gateway.session, same(current));
        expect(gateway.user!.name, 'alice');
      },
    );
  });

  group('Navidrome catalogue and mutations', () {
    late NavidromeGateway gateway;
    late List<http.Request> requests;
    late FutureOr<http.Response> Function(http.Request) respond;

    setUp(() async {
      requests = [];
      respond = (_) => _ok();
      gateway = NavidromeGateway(
        serverUrl: 'http://localhost:4533/library',
        username: 'alice',
        allowInsecureHttp: true,
        client: MockClient((request) async {
          requests.add(request);
          if (_method(request) == 'ping') return _ok();
          return respond(request);
        }),
      );
      await gateway.login('secret');
      requests.clear();
    });
    tearDown(() => gateway.close());

    test(
      'search maps opaque IDs, metadata, categories and page offsets',
      () async {
        respond = (request) {
          if (_method(request) == 'getPlaylists') {
            return _ok({
              'playlists': {
                'playlist': [_playlistJson],
              },
            });
          }
          final params = _parameters(request);
          expect(params['query'], ['Night & day']);
          expect(params['songCount'], ['2']);
          expect(params['songOffset'], ['2']);
          expect(params['artistOffset'], ['2']);
          expect(params['albumOffset'], ['2']);
          return _ok({
            'searchResult3': {
              'song': [_songJson, _songJson],
              'album': [_albumJson],
              'artist': [
                {'id': 'artist-uuid', 'name': 'Artist'},
              ],
            },
          });
        };
        final result = await gateway.search(
          ' Night & day ',
          limit: 1,
          offset: 2,
        );
        final song = result.songs.items.single;
        expect(song.id.value, 'song-uuid/with spaces');
        expect(song.duration.inMilliseconds, 123456);
        expect(song.bitRate, 900000);
        expect(song.starred, isTrue);
        expect(song.albumId!.value, 'album-uuid');
        expect(song.artists.single.id.value, 'artist-uuid');
        expect(result.songs.hasMore, isTrue);
        expect(result.songs.nextOffset, 3);
        expect(result.albums.items.single.year, 2025);
        final cover = Uri.parse(song.coverUrl!);
        expect(cover.scheme, 'http');
        expect(cover.path, '/library/rest/getCoverArt.view');
        expect(cover.queryParameters['id'], 'cover/uuid');
        expect(cover.queryParameters['p'], isNull);
        expect(result.playlists.items, isEmpty);
      },
    );

    test(
      'album, artist and playlist paging preserve duplicate songs',
      () async {
        respond = (request) => switch (_method(request)) {
          'getAlbum' => _ok({'album': _albumJson}),
          'getArtist' => _ok({
            'artist': {
              'id': 'artist-uuid',
              'name': 'Artist',
              'albumCount': 1,
              'album': [_albumJson],
            },
          }),
          'getPlaylist' => _ok({'playlist': _playlistJson}),
          'getPlaylists' => _ok({
            'playlists': {
              'playlist': [_playlistJson],
            },
          }),
          _ => _ok(),
        };
        final albumId = gateway.id(MusicEntityKind.album, 'album-uuid');
        final artistId = gateway.id(MusicEntityKind.artist, 'artist-uuid');
        final playlistId = gateway.id(
          MusicEntityKind.playlist,
          'playlist-uuid',
        );
        expect((await gateway.album(albumId)).songCount, 2);
        expect((await gateway.albumSongs(albumId, limit: 1)).hasMore, isTrue);
        expect(
          (await gateway.albumSongs(albumId, limit: 1, offset: 1)).hasMore,
          isFalse,
        );
        expect((await gateway.artist(artistId)).albumCount, 1);
        expect(
          (await gateway.artistAlbums(artistId)).items.single.title,
          'Night',
        );
        expect((await gateway.playlists()).items.single.writable, isTrue);
        expect((await gateway.playlist(playlistId)).name, 'Night mix');
        final page = await gateway.playlistSongs(
          playlistId,
          limit: 2,
          offset: 1,
        );
        expect(page.items, hasLength(2));
        expect(page.items.first.id, page.items.last.id);
        expect(page.hasMore, isFalse);
        expect(
          (await gateway.playlistSongs(playlistId, offset: 30)).items,
          isEmpty,
        );
      },
    );

    test(
      'album browsing uses bounded lookahead and independent random mode',
      () async {
        respond = (request) {
          expect(_method(request), 'getAlbumList2');
          return _ok({
            'albumList2': {
              'album': [_albumJson, _albumJson],
            },
          });
        };
        expect(gateway.supports(MusicCapability.browseAlbums), isTrue);
        final page = await gateway.albums(limit: 1, offset: 2);
        expect(page.items, hasLength(1));
        expect(page.hasMore, isTrue);
        expect(_parameters(requests.last)['type'], ['newest']);
        expect(_parameters(requests.last)['size'], ['2']);
        expect(_parameters(requests.last)['offset'], ['2']);
        final random = await gateway.albums(
          sort: MusicAlbumSort.random,
          limit: 2,
        );
        expect(random.hasMore, isFalse);
        expect(_parameters(requests.last)['size'], ['2']);
        await gateway.albums(limit: 500);
        expect(_parameters(requests.last)['size'], ['500']);
      },
    );

    test(
      'playlist search filters and pages the permitted playlist list',
      () async {
        respond = (request) => _method(request) == 'getPlaylists'
            ? _ok({
                'playlists': {
                  'playlist': [
                    _playlistJson,
                    {..._playlistJson, 'id': 'p2'},
                    {..._playlistJson, 'name': 'Morning'},
                  ],
                },
              })
            : _ok({'searchResult3': {}});
        final result = await gateway.search('NIGHT', limit: 1, offset: 1);
        expect(result.playlists.items.single.id.value, 'p2');
        expect(result.playlists.hasMore, isFalse);
        expect(result.songs.items, isEmpty);
      },
    );

    test(
      'playlist creation sets privacy and updates send repeated parameters',
      () async {
        respond = (request) => _method(request) == 'createPlaylist'
            ? _ok({'playlist': _playlistJson})
            : _ok();
        final created = await gateway.createPlaylist(' Night mix ');
        expect(created.writable, isTrue);
        expect(created.isPublic, isFalse);
        expect(_parameters(requests[0])['name'], ['Night mix']);
        expect(_parameters(requests[1])['public'], ['false']);
        final song = gateway.id(MusicEntityKind.song, 'uuid + / &');
        await gateway.addToPlaylist(created.id, [song, song]);
        expect(_parameters(requests.last)['songIdToAdd'], [
          'uuid + / &',
          'uuid + / &',
        ]);
        await gateway.removeFromPlaylist(created.id, [2, 0, 2]);
        expect(_parameters(requests.last)['songIndexToRemove'], ['2', '0']);
        expect(_parameters(requests.last)['playlistId'], ['playlist-uuid']);
      },
    );

    test('favorites use getStarred2, star and unstar', () async {
      respond = (_) => _ok({
        'starred2': {
          'song': [_songJson, _songJson],
        },
      });
      final favorites = await gateway.favorites(limit: 1);
      expect(favorites.items.single.starred, isTrue);
      expect(favorites.hasMore, isTrue);
      await gateway.setFavorite(favorites.items.single.id, true);
      expect(_method(requests.last), 'star');
      await gateway.setFavorite(favorites.items.single.id, false);
      expect(_method(requests.last), 'unstar');
      expect(_parameters(requests.last)['id'], [_songJson['id']]);
    });

    test(
      'streams preserve HTTP+proxy prefix and request raw or transcoding',
      () async {
        respond = (_) => _ok({'song': _songJson});
        final songId = gateway.id(
          MusicEntityKind.song,
          _songJson['id'] as String,
        );
        final raw = await gateway.stream(songId);
        expect(raw.uri.scheme, 'http');
        expect(raw.uri.path, '/library/rest/stream.view');
        expect(raw.uri.queryParameters['format'], 'raw');
        expect(raw.uri.queryParameters['maxBitRate'], '0');
        expect(raw.suffix, 'flac');
        expect(raw.bitRate, 900000);
        expect(raw.transcoded, isFalse);
        final compressed = await gateway.stream(
          songId,
          quality: MusicStreamQuality.medium,
        );
        expect(compressed.uri.queryParameters['format'], 'mp3');
        expect(compressed.uri.queryParameters['maxBitRate'], '192');
        expect(compressed.contentType, 'audio/mpeg');
        expect(compressed.bitRate, 192000);
        expect(compressed.toString(), isNot(contains(gateway.session!.token)));
      },
    );

    test(
      'structured lyrics preserve millisecond timing and signed offsets',
      () async {
        respond = (_) => _ok({
          'lyricsList': {
            'structuredLyrics': [
              {
                'lang': 'eng',
                'synced': true,
                'offset': -120,
                'line': [
                  {'start': 1234, 'value': 'First'},
                  {'start': 2345, 'value': 'Second'},
                ],
              },
            ],
          },
        });
        final lyrics = (await gateway.lyrics(
          gateway.id(MusicEntityKind.song, 'song'),
        )).single;
        expect(lyrics.synced, isTrue);
        expect(lyrics.language, 'eng');
        expect(lyrics.offset.inMilliseconds, -120);
        expect(lyrics.lines.first.start!.inMilliseconds, 1234);
        expect(lyrics.lines.last.text, 'Second');
        expect(requests, hasLength(1));
      },
    );

    test(
      'old lyric endpoints fall back but authentication failures do not',
      () async {
        var failAuth = false;
        respond = (request) => switch (_method(request)) {
          'getLyricsBySongId' => _failed(failAuth ? 40 : 70),
          'getSong' => _ok({'song': _songJson}),
          'getLyrics' => _ok({
            'lyrics': {'value': 'First\nSecond'},
          }),
          _ => _ok(),
        };
        final song = gateway.id(MusicEntityKind.song, 'song');
        expect((await gateway.lyrics(song)).single.lines, hasLength(2));
        expect(_parameters(requests.last)['artist'], ['Artist']);
        requests.clear();
        failAuth = true;
        await expectLater(
          gateway.lyrics(song),
          throwsA(isA<MusicGatewayException>()),
        );
        expect(requests, hasLength(1));
      },
    );

    test(
      'scrobble distinguishes now-playing from qualified submission',
      () async {
        final song = gateway.id(MusicEntityKind.song, 'song');
        await gateway.scrobble(song, played: Duration.zero);
        expect(requests, isEmpty);
        await gateway.scrobble(song, played: Duration.zero, submission: false);
        expect(_parameters(requests.last)['submission'], ['false']);
        await gateway.scrobble(
          song,
          played: const Duration(seconds: 60),
          time: DateTime.fromMillisecondsSinceEpoch(123456),
        );
        expect(_parameters(requests.last)['submission'], ['true']);
        expect(_parameters(requests.last)['time'], ['123456']);
      },
    );

    test(
      'invalid pages and foreign references never reach the transport',
      () async {
        await expectLater(
          gateway.search('song', offset: -1),
          throwsArgumentError,
        );
        await expectLater(gateway.playlists(limit: 501), throwsArgumentError);
        await expectLater(gateway.createPlaylist(' '), throwsArgumentError);
        const foreign = MusicId(
          provider: 'navidrome',
          connection: 'other',
          kind: MusicEntityKind.song,
          value: 'song',
        );
        await expectLater(gateway.song(foreign), throwsArgumentError);
        await expectLater(
          gateway.setFavorite(gateway.id(MusicEntityKind.album, 'album'), true),
          throwsArgumentError,
        );
        await expectLater(
          gateway.addToPlaylist(
            gateway.id(MusicEntityKind.playlist, 'playlist'),
            [foreign],
          ),
          throwsArgumentError,
        );
        expect(requests, isEmpty);
      },
    );

    test('malformed responses and service errors are sanitized', () async {
      final song = gateway.id(MusicEntityKind.song, 'song');
      for (final response in [
        http.Response('untrusted-secret-message', 500),
        http.Response('untrusted-secret-message', 200),
        http.Response('{}', 200),
        _failed(40),
      ]) {
        respond = (_) => response;
        await expectLater(
          gateway.song(song),
          throwsA(
            isA<MusicGatewayException>().having(
              (error) => error.toString(),
              'redacted',
              isNot(contains('untrusted-secret-message')),
            ),
          ),
        );
      }
    });

    test(
      'pending responses cannot produce media URLs after sign-out',
      () async {
        final pending = Completer<http.Response>();
        respond = (_) => pending.future;
        final future = gateway.song(gateway.id(MusicEntityKind.song, 'song'));
        gateway.clearSession();
        pending.complete(_ok({'song': _songJson}));
        await expectLater(future, throwsA(isA<MusicGatewayException>()));
      },
    );

    test(
      'random-song recommendations work without NetEase endpoints',
      () async {
        respond = (_) => _ok({
          'randomSongs': {
            'song': [_songJson],
          },
        });
        final page = await gateway.recommendations(limit: 12);
        expect(page.items.single.title, 'Nocturne');
        expect(_method(requests.last), 'getRandomSongs');
        expect(_parameters(requests.last)['size'], ['12']);
      },
    );
  });
}
