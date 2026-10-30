import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/cache/disk_cache.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/catalog_details.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/legacy/legacy_login.dart';
import 'package:lazer_nextgen/legacy/legacy_shell.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/playback_queue_store.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/utils/artwork.dart';
import 'package:lazer_nextgen/widgets/catalog_links.dart';

class _Net extends NeteaseGateway {
  @override
  Future<String> createQrKey() async =>
      throw UnsupportedError('QR disabled in this fixture');
  @override
  Future<GatewayLoginStatus> loginWithCookie(String cookie) async {
    sessionCookie = cookie;
    return const GatewayLoginStatus(
      profile: GatewayUserProfile(userId: 1, nickname: 'Net listener'),
    );
  }

  @override
  Future<GatewayLoginStatus> loginStatus() async => const GatewayLoginStatus(
    profile: GatewayUserProfile(userId: 1, nickname: 'Net listener'),
  );
  @override
  Future<Set<int>> likedSongIds(int uid) async => {};
}

class _Catalog extends Catalog {
  _Catalog()
    : super(
        gateway: _Net(),
        cache: DiskCache(
          directory: () async =>
              throw const FileSystemException('Cache disabled'),
        ),
      );
  Completer<UserCollections>? delayedNetCollections;
  Object? detailError;
  @override
  Future<AlbumDetails> albumDetailsFor(String key, {bool force = false}) async {
    try {
      return await super.albumDetailsFor(key, force: force);
    } catch (error) {
      detailError = error;
      rethrow;
    }
  }

  @override
  Future<HomeFeed?> loadHome({int? userId}) async =>
      usesPlatformGateway ? super.loadHome(userId: userId) : null;
  @override
  Future<UserCollections> userCollections(int uid) async => usesPlatformGateway
      ? super.userCollections(uid)
      : delayedNetCollections == null
      ? UserCollections.empty
      : delayedNetCollections!.future;
  @override
  Future<AudioSource?> audioSourceFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
    bool useCache = true,
  }) => super.audioSourceFor(track, quality: quality, useCache: false);
}

class _Engine implements AudioEngine {
  @override
  bool active = false;
  String? url;
  @override
  Duration position = Duration.zero;
  @override
  Duration? get duration => const Duration(seconds: 8);
  @override
  Stream<void> get completed => const Stream.empty();
  @override
  Future<void> setUrl(String url) async {
    this.url = url;
    active = true;
  }

  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration value) async => position = value;
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> stop() async => active = false;
  @override
  void dispose() {}
}

class _Server {
  bool starred = false, reject = false;
  int calls = 0;
  final scrobbles = <Map<String, List<String>>>[];
  final song = <String, dynamic>{
    'id': 'song-uuid',
    'title': 'Server song',
    'album': 'Server album',
    'albumId': 'album-uuid',
    'artist': 'Server artist',
    'artistId': 'artist-uuid',
    'duration': 8,
    'suffix': 'flac',
    'contentType': 'audio/flac',
  };
  Map<String, dynamic> get album => {
    'id': 'album-uuid',
    'name': 'Server album',
    'artist': 'Server artist',
    'artistId': 'artist-uuid',
    'songCount': 1,
    'song': [song],
  };
  Map<String, dynamic> get playlist => {
    'id': 'playlist-uuid',
    'name': 'Server mix',
    'owner': 'alice',
    'songCount': 1,
    'entry': [song],
  };

  NavidromeGateway gateway(String server, String username, bool allowHttp) =>
      NavidromeGateway(
        serverUrl: server,
        username: username,
        allowInsecureHttp: allowHttp,
        client: MockClient((request) async {
          calls++;
          final params = Uri(query: request.body).queryParametersAll;
          final method = request.url.pathSegments.last.replaceAll('.view', '');
          if (reject) {
            return http.Response(
              jsonEncode({
                'subsonic-response': {
                  'status': 'failed',
                  'error': {'code': 40},
                },
              }),
              200,
            );
          }
          final body = switch (method) {
            'ping' => <String, dynamic>{},
            'getAlbumList2' => {
              'albumList2': {
                'album': [album],
              },
            },
            'getRandomSongs' => {
              'randomSongs': {
                'song': [song],
              },
            },
            'getPlaylists' => {
              'playlists': {
                'playlist': [playlist],
              },
            },
            'getStarred2' => {
              'starred2': {
                'song': starred ? [song] : [],
              },
            },
            'getSong' => {'song': song},
            'getAlbum' => {'album': album},
            'getArtist' => {
              'artist': {
                'id': 'artist-uuid',
                'name': 'Server artist',
                'albumCount': 1,
                'album': [album],
              },
            },
            'getPlaylist' || 'createPlaylist' => {'playlist': playlist},
            'search3' => {
              'searchResult3': {
                'song': [song],
                'album': [album],
                'artist': [
                  {'id': 'artist-uuid', 'name': 'Server artist'},
                ],
              },
            },
            'getLyricsBySongId' => {
              'lyricsList': {
                'structuredLyrics': [
                  {
                    'synced': true,
                    'offset': 50,
                    'line': [
                      {'start': 1000, 'value': 'First line'},
                    ],
                  },
                ],
              },
            },
            'star' => (() {
              starred = true;
              return <String, dynamic>{};
            })(),
            'unstar' => (() {
              starred = false;
              return <String, dynamic>{};
            })(),
            'updatePlaylist' => <String, dynamic>{},
            'scrobble' => (() {
              scrobbles.add(params);
              return <String, dynamic>{};
            })(),
            _ => throw StateError('Unexpected endpoint $method'),
          };
          return http.Response(
            jsonEncode({
              'subsonic-response': {'status': 'ok', ...body},
            }),
            200,
          );
        }),
      );
}

Future<void> _flush() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _pumpMusicUi(WidgetTester tester) async {
  // Mock HTTP streams cross the widget test's fake clock and the real I/O
  // zone. Let each staged request finish before advancing the next frame.
  for (var frame = 0; frame < 12; frame++) {
    await tester.pump(const Duration(milliseconds: 60));
    await tester.runAsync(_flush);
  }
}

AppState _state(_Server server, {_Catalog? catalog, AudioEngine? engine}) =>
    AppState(
      catalog: catalog ?? _Catalog(),
      navidromeFactory: server.gateway,
      audioEngine: engine,
      artworkSeedLoader: (_) async => null,
    );

Future<AuthOutcome> _connect(
  AppState state, [
  String host = 'http://localhost:4533/proxy',
]) => state.signInWithNavidrome(
  serverUrl: host,
  username: 'alice',
  password: 'secret-password',
  allowInsecureHttp: true,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'one shared catalogue drives Navidrome home, search, details and favorites',
    () async {
      final server = _Server();
      final state = _state(server);
      addTearDown(() async {
        await _flush();
        state.dispose();
      });
      expect((await _connect(state)).ok, isTrue);
      await state.refreshHome();
      await state.refreshCollections();
      expect(state.isNavidrome, isTrue);
      expect(state.user.name, 'alice');
      expect(state.musicProvider.experimental, isTrue);
      expect(state.home!.quick.single.title, 'Server song');
      final results = await state.search('Server');
      final track = results.tracks.single;
      expect(track.id, contains(':song:'));
      expect(track.albumIdentity, contains(':album:'));
      expect(track.artists.single.hasIdentity, isTrue);
      final album = await state.catalog.albumDetailsFor(
        results.albums.single.id,
      );
      expect(album.tracks.single.id, track.id);
      final artist = await state.catalog.artistDetails(results.artists.single);
      expect(artist.tracks.single.id, track.id);
      expect(
        (await state.catalog.artistAlbumPageFor(
          results.artists.single,
        )).albums.single.id,
        results.albums.single.id,
      );
      expect(
        (await state.catalog.playlistTracks(
          state.collections.created.single.id,
        )).single.id,
        track.id,
      );
      final source = await state.catalog.audioSourceFor(
        track,
        quality: AudioQuality.lossless,
        useCache: false,
      );
      expect(
        source!.url,
        startsWith('http://localhost:4533/proxy/rest/stream.view'),
      );
      final lyrics = await state.catalog.lyricsFor(track);
      expect(lyrics!.lrc, contains('[00:01.050]First line'));
      await state.addSongToCloudPlaylist(state.collections.liked!.id, track.id);
      expect(server.starred, isTrue);
      expect(
        (await state.catalog.playlistTracks(
          state.collections.liked!.id,
        )).single.id,
        track.id,
      );
      final created = await state.createCloudPlaylist('New list');
      expect(created!.id, contains(':playlist:'));
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('lazer_music_connections_v1'),
        contains('localhost'),
      );
      expect(
        prefs.getString('lazer_music_connections_v1'),
        isNot(contains('secret-password')),
      );
    },
  );

  test(
    'failed login preserves the active account and selected catalogue',
    () async {
      final server = _Server();
      final state = _state(server);
      addTearDown(() async {
        await _flush();
        state.dispose();
      });
      await _connect(state);
      final key = state.activeConnectionKey;
      final gateway = state.catalog.activeGateway;
      server.reject = true;
      final result = await _connect(state, 'http://other.local:4533');
      expect(result.ok, isFalse);
      expect(result.error, contains('用户名和密码'));
      expect(state.activeConnectionKey, key);
      expect(state.catalog.activeGateway, same(gateway));
      expect(state.signedIn, isTrue);
    },
  );

  test(
    'switching retains NetEase credentials and clears prior playback and views',
    () async {
      final server = _Server();
      final state = _state(server, engine: _Engine());
      addTearDown(() async {
        await _flush();
        state.dispose();
      });
      await state.signInWithCookie('MUSIC_U=fixture');
      final net = state.activeConnectionKey;
      await _connect(state);
      await state.refreshHome();
      final native = state.activeConnectionKey;
      final song = state.home!.quick.single;
      state.playQueue([song]);
      await _flush();
      await state.selectMusicConnection(net);
      expect(state.isNavidrome, isFalse);
      expect(state.user.name, 'Net listener');
      expect(state.gateway.sessionCookie, 'MUSIC_U=fixture');
      expect(state.current, isNull);
      await state.selectMusicConnection(native);
      expect(state.user.name, 'alice');
      await state.signOut();
      expect(state.isNavidrome, isTrue);
      expect(state.isGuest, isTrue);
      expect(state.gateway.sessionCookie, 'MUSIC_U=fixture');
      await state.selectMusicConnection(net);
      expect(state.user.name, 'Net listener');
    },
  );

  test(
    'late collections from a previous platform cannot replace the current library',
    () async {
      final server = _Server();
      final catalog = _Catalog();
      final state = _state(server, catalog: catalog);
      addTearDown(() async {
        await _flush();
        state.dispose();
      });
      await state.signInWithCookie('MUSIC_U=fixture');
      await _flush();
      catalog.delayedNetCollections = Completer<UserCollections>();
      final old = state.refreshCollections(force: true);
      await _connect(state);
      await state.refreshCollections();
      final native = state.collections.created.single.id;
      catalog.delayedNetCollections!.complete(
        const UserCollections(
          created: [
            Playlist(
              id: 'foreign',
              name: 'Wrong account',
              trackIds: [],
              coverSeed: 0,
            ),
          ],
        ),
      );
      await old;
      expect(state.collections.created.single.id, native);
      expect(state.collections.created.single.name, 'Server mix');
    },
  );

  test(
    'connection identity and album links survive queue serialization without tokens',
    () async {
      final server = _Server();
      final state = _state(server);
      addTearDown(() async {
        await _flush();
        state.dispose();
      });
      await _connect(state);
      final track = (await state.search('Server')).tracks.single.copyWith(
        coverUrl: 'http://localhost/rest/getCoverArt.view?t=sensitive-token',
      );
      final store = PlaybackQueueStore();
      await store.save([track], 0, 1);
      final snapshot = await store.load();
      expect(snapshot!.tracks.single.id, track.id);
      expect(snapshot.tracks.single.albumIdentity, track.albumIdentity);
      expect(
        snapshot.tracks.single.artists.single.key,
        track.artists.single.key,
      );
      expect(snapshot.tracks.single.coverUrl, isNull);
      final raw = (await SharedPreferences.getInstance()).getString(
        playbackQueueKey,
      )!;
      expect(raw, isNot(contains('sensitive-token')));
      expect(
        normalizedArtworkUrl(
          'http://localhost:4533/proxy/rest/getCoverArt.view?id=cover',
        ),
        startsWith('http://'),
      );
    },
  );

  test(
    'saved connections restore as signed out without storing replayable credentials',
    () async {
      final server = _Server();
      final first = _state(server);
      await _connect(first);
      await _flush();
      final key = first.activeConnectionKey;
      first.dispose();
      final restored = _state(server);
      addTearDown(() async {
        await _flush();
        restored.dispose();
      });
      final before = server.calls;
      await restored.bootstrap();
      expect(restored.activeConnectionKey, key);
      expect(restored.isNavidrome, isTrue);
      expect(restored.isGuest, isTrue);
      expect(restored.homeError, '请登录 Navidrome 服务器。');
      expect(server.calls, before);
    },
  );

  testWidgets(
    'shared login offers an experimental Navidrome form and connects',
    (tester) async {
      final server = _Server();
      final state = _state(server);
      addTearDown(state.dispose);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showLegacyLoginDialog(context, state),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Navidrome'));
      await tester.pumpAndSettle();
      expect(find.text('实验性'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('navidrome-server')),
        'http://localhost:4533',
      );
      await tester.enterText(
        find.byKey(const ValueKey('navidrome-username')),
        'alice',
      );
      await tester.enterText(
        find.byKey(const ValueKey('navidrome-password')),
        'secret-password',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('navidrome-connect')),
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('navidrome-connect')));
        await _flush();
      });
      await tester.pumpAndSettle();
      expect(
        state.isNavidrome,
        isTrue,
        reason: 'The form must adopt the connected server.',
      );
      expect(find.byType(Dialog), findsNothing);
      expect(state.isNavidrome, isTrue);
      expect(state.signedIn, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'shared player resolves Navidrome audio, lyrics, favorites and qualified listens',
    (tester) async {
      final server = _Server();
      final engine = _Engine();
      final state = _state(server, engine: engine);
      addTearDown(state.dispose);
      await tester.runAsync(() async {
        await _connect(state);
        await state.refreshHome();
        await state.refreshCollections();
        await _flush();
      });
      state.playQueue([state.home!.quick.single]);
      await _pumpMusicUi(tester);
      expect(state.audioReady, isTrue);
      expect(
        engine.url,
        startsWith('http://localhost:4533/proxy/rest/stream.view'),
      );
      expect(state.lyrics.single.text, 'First line');
      await tester.runAsync(state.toggleLikeCurrent);
      await _pumpMusicUi(tester);
      expect(state.currentLiked, isTrue);
      expect(state.likedCount, 1);
      for (var second = 1; second <= 4; second++) {
        engine.position = Duration(seconds: second);
        await tester.pump(const Duration(seconds: 1));
      }
      await _pumpMusicUi(tester);
      state.pause();
      expect(
        server.scrobbles.where(
          (entry) => entry['submission']!.single == 'false',
        ),
        hasLength(1),
      );
      expect(
        server.scrobbles.where(
          (entry) => entry['submission']!.single == 'true',
        ),
        hasLength(1),
      );
      expect(
        server.scrobbles.every((entry) => entry['id']!.single == 'song-uuid'),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('shared shell opens Navidrome albums and artist links', (
    tester,
  ) async {
    final server = _Server();
    final state = _state(server);
    state.legacyBackground = LegacyBackgroundMode.off;
    addTearDown(state.dispose);
    await tester.runAsync(() async {
      await _connect(state);
      await state.refreshHome();
      await _flush();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(),
        home: LegacyShell(state: state),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Server album'), findsWidgets);
    final track = state.home!.quick.single;
    final context = tester.element(find.byType(LegacyShell));
    await openAlbumDetails(context, state, state.home!.albums.single);
    await _pumpMusicUi(tester);
    expect(
      find.text('Server song'),
      findsWidgets,
      reason: '${(state.catalog as _Catalog).detailError}',
    );
    await openArtists(context, state, track.artists);
    await _pumpMusicUi(tester);
    expect(find.text('Server artist'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
