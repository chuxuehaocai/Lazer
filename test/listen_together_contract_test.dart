import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/cache/disk_cache.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/lyrics/cached_lyrics_store.dart';
import 'package:lazer_nextgen/state/app_state.dart';

import 'support/music_gateway.dart';

/// Room owner whose answers are supplied per test, so the controller is
/// exercised against both the current contract and older plugin payloads.
class _RoomAccount extends TestMusicGateway {
  _RoomAccount(this.answer);

  final Future<Map<String, dynamic>> Function(
    String operation,
    Map<String, dynamic> args,
  )
  answer;
  final List<String> calls = <String>[];

  @override
  String get connectionId => 'room';

  @override
  Future<Map<String, dynamic>> listenTogether(
    String operation, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    calls.add(operation);
    return answer(operation, args);
  }
}

class _RoomCatalog extends Catalog {
  _RoomCatalog()
    : super(
        cache: DiskCache(
          directory: () async => throw const FileSystemException('disabled'),
        ),
        lyricsCache: CachedLyricsStore(
          supportDirectory: () async =>
              throw const FileSystemException('disabled'),
        ),
      );

  @override
  Future<HomeFeed?> loadHome({int? userId}) async => null;

  @override
  Future<UserCollections> userCollections(int uid) async =>
      UserCollections.empty;

  @override
  Future<UserCollections?> cachedUserCollections(int uid) async => null;

  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async =>
      const GatewayLyrics(pureMusic: true);
}

Track _song(MusicGateway gateway) => Track(
  id: gateway.id(MusicEntityKind.song, 'room-song').cacheKey,
  title: 'Song',
  artist: 'Artist',
  album: 'Album',
  duration: const Duration(minutes: 3),
  coverSeed: 0,
);

Future<AppState> _signedIn(_RoomAccount account) async {
  final _RoomCatalog catalog = _RoomCatalog();
  catalog.connections.add(account);
  final AppState state = AppState(catalog: catalog);
  await state.selectMusicConnection(GatewayRegistry.keyOf(account));
  await state.signInWithCookie('fixture');
  state.playQueue(<Track>[_song(account)]);
  state.pause();
  return state;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('capability names tolerate the spellings plugins use', () {
    expect(MusicCapability.parse('listenTogether'), MusicCapability.listenTogether);
    expect(MusicCapability.parse('listen_together'), MusicCapability.listenTogether);
    expect(MusicCapability.parse('Listen-Together'), MusicCapability.listenTogether);
    expect(MusicCapability.parse('browse_albums'), MusicCapability.browseAlbums);
    expect(MusicCapability.parse('teleport'), isNull);
    expect(MusicCapability.parse(null), isNull);
  });

  test('a platform that declares no capabilities keeps its manifest ones', () {
    final Set<MusicCapability> inherited = MusicCapability.parseAll(
      null,
      fallback: const <String>['search', 'listen_together'],
    );
    expect(inherited, {MusicCapability.search, MusicCapability.listenTogether});
    expect(
      MusicCapability.parseAll(const <Object?>['listenTogether', 7, 'nope']),
      {MusicCapability.listenTogether},
    );
  });

  test('a legacy room payload still creates a room and reads its roster', () async {
    final _RoomAccount account = _RoomAccount((
      String operation,
      Map<String, dynamic> args,
    ) async {
      if (operation == 'command') return <String, dynamic>{};
      // No code, a users list, and uid/nickname/avatar field names: the
      // shape an older plugin answers with.
      return <String, dynamic>{
        'roomId': 'room-1',
        'users': <Map<String, dynamic>>[
          <String, dynamic>{
            'uid': 4242,
            'nickname': 'Ann',
            'avatar': 'https://a',
          },
        ],
      };
    });
    final AppState state = await _signedIn(account);
    addTearDown(state.dispose);

    expect(await state.listenTogether.create(), isTrue);
    expect(state.listenTogether.roomId, 'room-1');
    expect(state.listenTogether.inviterId, '7');
    expect(state.listenTogether.members.single.userId, '4242');
    expect(state.listenTogether.members.single.name, 'Ann');
    expect(state.listenTogether.members.single.avatarUrl, 'https://a');
    await state.listenTogether.leave();
    expect(
      account.calls,
      containsAll(<String>['create', 'command', 'heartbeat', 'leave']),
    );
  });

  test('a room failure code rejects the room instead of opening an empty one', () async {
    final _RoomAccount account = _RoomAccount((
      String operation,
      Map<String, dynamic> args,
    ) async {
      if (operation == 'command') return <String, dynamic>{};
      return <String, dynamic>{'code': 400, 'roomId': 'room-1'};
    });
    final AppState state = await _signedIn(account);
    addTearDown(state.dispose);

    expect(await state.listenTogether.create(), isFalse);
    expect(state.listenTogether.ready, isFalse);
    expect(state.listenTogether.error, '创建一起听房间失败，请稍后重试。');
  });

  test('an expired session asks for a login instead of a generic failure', () async {
    final _RoomAccount account = _RoomAccount((
      String operation,
      Map<String, dynamic> args,
    ) async {
      throw const MusicGatewayException(
        'fixture',
        'listenTogether',
        code: 40,
        httpStatus: 401,
      );
    });
    final AppState state = await _signedIn(account);
    addTearDown(state.dispose);

    expect(await state.listenTogether.create(), isFalse);
    expect(state.listenTogether.error, '请先登录后再一起听');
  });

  test('joining keeps working when the plugin answers without a code', () async {
    final _RoomAccount account = _RoomAccount((
      String operation,
      Map<String, dynamic> args,
    ) async {
      if (operation == 'command' || operation == 'heartbeat') {
        return <String, dynamic>{};
      }
      return <String, dynamic>{
        'roomId': args['roomId'],
        'members': <Map<String, dynamic>>[
          <String, dynamic>{'userId': '4242', 'name': 'Ann'},
        ],
      };
    });
    final AppState state = await _signedIn(account);
    addTearDown(state.dispose);

    expect(await state.listenTogether.join('room-9|4242'), isTrue);
    expect(state.listenTogether.roomId, 'room-9');
    expect(state.listenTogether.inviterId, '4242');
    expect(state.listenTogether.members.single.userId, '4242');
    await state.listenTogether.leave();
  });
}