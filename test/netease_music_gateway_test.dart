import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/gateway/transport.dart';

const _song = GatewaySong(
  id: 42,
  title: 'Nocturne',
  artists: ['Artist'],
  artistDetails: [GatewayArtist(id: 9, name: 'Artist')],
  albumName: 'Night',
  albumId: 7,
  duration: Duration(seconds: 123),
);

class _Legacy extends NeteaseGateway {
  bool rejectLogin = false;
  bool closed = false;
  String? level;
  bool? privacy;
  final searchPages = <(GatewaySearchType, int, int)>[];
  final additions = <List<int>>[];
  final removals = <List<int>>[];
  final plays = <(int, int, bool)>[];
  final likes = <(int, int, bool)>[];
  List<int> playlistIds = [42, 43];

  @override
  Future<GatewayLoginStatus> loginStatus() async => const GatewayLoginStatus(
    profile: GatewayUserProfile(userId: 3, nickname: 'Listener'),
  );
  @override
  Future<GatewayLoginStatus> loginWithCookie(String cookie) async {
    if (rejectLogin) return const GatewayLoginStatus();
    sessionCookie = cookie;
    return loginStatus();
  }

  @override
  void close() {
    closed = true;
    super.close();
  }

  @override
  Future<Map<String, dynamic>> searchResultPage(
    String keywords,
    GatewaySearchType type, {
    int limit = 30,
    int offset = 0,
  }) async {
    searchPages.add((type, limit, offset));
    return switch (type) {
      GatewaySearchType.song => {
        'songs': [
          for (var i = 0; i < limit; i++)
            {
              'id': 42 + i,
              'name': 'Nocturne',
              'ar': [
                {'id': 9, 'name': 'Artist'},
              ],
              'al': {'id': 7, 'name': 'Night'},
              'dt': 123000,
            },
        ],
      },
      GatewaySearchType.album => {
        'albums': [
          {
            'id': 7,
            'name': 'Night',
            'size': 2,
            'publishTime': DateTime.utc(2020).millisecondsSinceEpoch,
            'artist': {'id': 9, 'name': 'Artist'},
          },
        ],
      },
      GatewaySearchType.artist => {
        'artists': [
          {'id': 9, 'name': 'Artist'},
        ],
      },
      GatewaySearchType.playlist => {
        'playlists': [
          {
            'id': 11,
            'name': 'Mix',
            'creator': {'userId': 3},
          },
        ],
      },
    };
  }

  @override
  Future<List<GatewaySong>> songDetails(List<int> ids) async => [
    for (final id in ids.reversed)
      GatewaySong(
        id: id,
        title: 'Song $id',
        artists: _song.artists,
        artistDetails: _song.artistDetails,
        albumName: _song.albumName,
        albumId: 7,
        duration: _song.duration,
      ),
  ];
  @override
  Future<GatewayAlbum?> albumDetail(int id) async =>
      const GatewayAlbum(id: 7, title: 'Night', trackCount: 2);
  @override
  Future<Map<String, dynamic>> albumDetailRaw(int id) async => {
    'songs': [
      for (final id in [42, 43]) {'id': id, 'name': 'Song $id'},
    ],
  };
  @override
  Future<Map<String, dynamic>> artistDetail(int id) async => {
    'data': {
      'artist': {
        'id': 9,
        'name': 'Artist',
        'briefDesc': 'Biography',
        'albumSize': 2,
      },
    },
  };
  @override
  Future<Map<String, dynamic>> artistAlbums(
    int id, {
    int limit = 30,
    int offset = 0,
  }) async => {
    'hotAlbums': [
      {'id': 7, 'name': 'Night'},
    ],
    'more': true,
  };
  @override
  Future<List<GatewayPlaylist>> userPlaylists(
    int uid, {
    int limit = 30,
    int offset = 0,
  }) async => const [
    GatewayPlaylist(id: 11, name: 'Mix', creatorId: 3, specialType: 5),
  ];
  @override
  Future<GatewayPlaylist?> topPlaylist(int id) async =>
      const GatewayPlaylist(id: 11, name: 'Mix', creatorId: 3);
  @override
  Future<Map<String, dynamic>> playlistTracks(
    int id, {
    int? limit,
    int offset = 0,
  }) async => {
    'songs': [
      {
        'song': {'id': 42, 'name': 'First'},
      },
      {
        'data': {'id': 43, 'name': 'Second'},
      },
    ],
  };
  @override
  Future<Map<String, dynamic>> playlistDetail(
    int id, {
    int subscriberLimit = 8,
  }) async => {
    'playlist': {
      'id': id,
      'name': 'Mix',
      'trackIds': [
        for (final song in playlistIds) {'id': song},
      ],
    },
  };
  @override
  Future<GatewayPlaylist?> createPlaylist(
    String name, {
    bool privacy = false,
  }) async {
    this.privacy = privacy;
    return GatewayPlaylist(id: 12, name: name, created: true);
  }

  @override
  Future<void> addTracksToPlaylist(int playlistId, List<int> trackIds) async =>
      additions.add(trackIds);
  @override
  Future<void> removeTracksFromPlaylist(
    int playlistId,
    List<int> trackIds,
  ) async => removals.add(trackIds);
  @override
  Future<Set<int>> likedSongIds(int uid) async => {42, 43, 44};
  @override
  Future<void> setSongLiked(int songId, int userId, bool liked) async =>
      likes.add((songId, userId, liked));
  @override
  Future<GatewaySongUrl?> songUrl(int id, {String level = 'exhigh'}) async {
    this.level = level;
    return GatewaySongUrl(
      id: id,
      url: 'http://cdn.example/song.flac',
      br: 900000,
      type: 'flac',
      size: 1000,
    );
  }

  @override
  Future<GatewayLyrics> preferredLyrics(int id) async => const GatewayLyrics(
    lrc: '[00:01]Line',
    yrc: '[1000,500](1000,500,0)Line',
    tlyric: '[00:01]Translation',
  );
  @override
  Future<void> reportPlayStart({
    required int songId,
    required int sourceId,
  }) async => plays.add((songId, 0, false));
  @override
  Future<void> reportPlayback({
    required int songId,
    required int playedSeconds,
    int sourceId = 0,
  }) async => plays.add((songId, playedSeconds, true));
  @override
  Future<List<GatewaySong>> dailyRecommendedSongs() async => [_song];
}

class _Transport extends NeteaseTransport {
  String? alias;
  Map<String, String>? parameters;
  @override
  Future<Map<String, dynamic>> request(
    String alias,
    Map<String, String> parameters,
  ) async {
    this.alias = alias;
    this.parameters = parameters;
    return {
      'result': {'albums': <Object>[]},
    };
  }
}

void main() {
  late _Legacy legacy;
  late NeteaseMusicGateway gateway;
  setUp(() {
    legacy = _Legacy();
    gateway = NeteaseMusicGateway(
      connectionId: 'netease-main',
      gateway: legacy,
    );
  });
  tearDown(() => legacy.close());

  test(
    'legacy import remains compatible and paged search uses cloudsearch',
    () async {
      final transport = _Transport();
      addTearDown(transport.close);
      final legacy = NeteaseGateway(transport: transport);
      expect(
        await legacy.searchResultPage(
          ' Night ',
          GatewaySearchType.album,
          limit: 11,
          offset: 20,
        ),
        {'albums': <Object>[]},
      );
      expect(transport.alias, '/cloudsearch');
      expect(transport.parameters, {
        'keywords': 'Night',
        'type': '10',
        'limit': '11',
        'offset': '20',
      });
      await expectLater(
        legacy.searchResultPage('', GatewaySearchType.album),
        throwsArgumentError,
      );
    },
  );

  test(
    'session profile adoption and failed authentication preserve the user',
    () async {
      final guest = gateway.cacheNamespace;
      await gateway.loginWithCookie('MUSIC_U=one');
      final previous = gateway.user;
      expect(gateway.user!.id.value, '3');
      expect(gateway.cacheNamespace, isNot(guest));
      legacy.rejectLogin = true;
      expect(await gateway.loginWithCookie('invalid'), isNull);
      expect(gateway.user, same(previous));
      expect(legacy.sessionCookie, 'MUSIC_U=one');
      gateway.clearSession();
      expect(gateway.user, isNull);
      expect(legacy.sessionCookie, isNull);
    },
  );

  test(
    'closing a wrapper leaves its borrowed gateway and session intact',
    () async {
      await gateway.loginWithCookie('MUSIC_U=one');
      gateway.close();
      expect(legacy.closed, isFalse);
      expect(legacy.sessionCookie, 'MUSIC_U=one');
      expect(gateway.user, isNull);
    },
  );

  test(
    'search maps categories and propagates independent page offsets',
    () async {
      await gateway.checkSession();
      final results = await gateway.search('Night', limit: 1, offset: 20);
      expect(results.songs.items.single.id.value, '42');
      expect(results.songs.items.single.artists.single.id.value, '9');
      expect(results.songs.hasMore, isTrue);
      expect(results.albums.items.single.year, 2020);
      expect(results.artists.items.single.name, 'Artist');
      expect(results.playlists.items.single.writable, isTrue);
      expect(legacy.searchPages, [
        for (final type in GatewaySearchType.values) (type, 2, 20),
      ]);
    },
  );

  test(
    'song, album, artist and nested playlist metadata stay provider neutral',
    () async {
      final song = await gateway.song(gateway.id(MusicEntityKind.song, '42'));
      expect(song.albumId!.value, '7');
      expect(song.title, 'Song 42');
      final albumId = gateway.id(MusicEntityKind.album, '7');
      expect((await gateway.album(albumId)).title, 'Night');
      expect(
        (await gateway.albumSongs(
          albumId,
          limit: 1,
          offset: 1,
        )).items.single.id.value,
        '43',
      );
      final artistId = gateway.id(MusicEntityKind.artist, '9');
      expect((await gateway.artist(artistId)).description, 'Biography');
      expect((await gateway.artistAlbums(artistId)).hasMore, isTrue);
      final playlistId = gateway.id(MusicEntityKind.playlist, '11');
      expect((await gateway.playlist(playlistId)).name, 'Mix');
      expect(
        (await gateway.playlistSongs(playlistId, limit: 1)).hasMore,
        isTrue,
      );
      expect(
        (await gateway.playlistSongs(playlistId)).items.last.title,
        'Second',
      );
    },
  );

  test(
    'playlist editing validates IDs and translates positions only when safe',
    () async {
      await gateway.checkSession();
      final created = await gateway.createPlaylist('Mix');
      expect(legacy.privacy, isTrue);
      expect(created.isPublic, isFalse);
      expect(created.writable, isTrue);
      final song = gateway.id(MusicEntityKind.song, '42');
      await gateway.addToPlaylist(created.id, [song]);
      expect(legacy.additions.single, [42]);
      await gateway.removeFromPlaylist(created.id, [1, 1]);
      expect(legacy.removals.single, [43]);
      legacy.playlistIds = [42, 42, 43];
      await expectLater(
        gateway.removeFromPlaylist(created.id, [0]),
        throwsA(isA<MusicUnsupportedException>()),
      );
      expect(legacy.removals, hasLength(1));
      await expectLater(
        gateway.removeFromPlaylist(created.id, [5]),
        throwsRangeError,
      );
    },
  );

  test(
    'favorites retain upstream ID order when details arrive reversed',
    () async {
      await gateway.checkSession();
      final result = await gateway.favorites(limit: 2);
      expect(result.items.map((song) => song.id.value), ['42', '43']);
      expect(result.hasMore, isTrue);
      await gateway.setFavorite(result.items.first.id, false);
      expect(legacy.likes.single, (42, 3, false));
      expect((await gateway.playlists()).items.single.isFavorites, isTrue);
    },
  );

  test(
    'quality tiers, lyrics and qualified play submissions map to NetEase',
    () async {
      await gateway.checkSession();
      final song = gateway.id(MusicEntityKind.song, '42');
      final source = await gateway.stream(song);
      expect(legacy.level, 'lossless');
      expect(source.uri.scheme, 'https');
      expect(source.size, 1000);
      await gateway.stream(song, quality: MusicStreamQuality.medium);
      expect(legacy.level, 'higher');
      final lyrics = (await gateway.lyrics(song)).single;
      expect(lyrics.synced, isTrue);
      expect(lyrics.wordByWord, startsWith('[1000,'));
      expect(lyrics.translation, '[00:01]Translation');
      await gateway.scrobble(song, played: Duration.zero, submission: false);
      await gateway.scrobble(song, played: const Duration(seconds: 50));
      await gateway.scrobble(song, played: Duration.zero);
      expect(legacy.plays, [(42, 0, false), (42, 50, true)]);
      expect((await gateway.recommendations()).items.single.title, 'Nocturne');
    },
  );

  test(
    'foreign, malformed and unsupported references fail explicitly',
    () async {
      const foreign = MusicId(
        provider: 'navidrome',
        connection: 'netease-main',
        kind: MusicEntityKind.song,
        value: '42',
      );
      await expectLater(gateway.song(foreign), throwsArgumentError);
      await expectLater(
        gateway.song(gateway.id(MusicEntityKind.song, 'uuid')),
        throwsArgumentError,
      );
      await expectLater(
        gateway.playlists(),
        throwsA(isA<MusicGatewayException>()),
      );
      expect(gateway.supports(MusicCapability.browseAlbums), isFalse);
      await expectLater(
        gateway.albums(),
        throwsA(isA<MusicUnsupportedException>()),
      );
    },
  );
}
