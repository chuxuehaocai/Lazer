import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/widgets/playlist_picker_dialog.dart';

const GatewayUserProfile _profile = GatewayUserProfile(
  userId: 7,
  nickname: '测试账户',
);

const Track _track = Track(
  id: '5',
  title: 'Song',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 3),
  coverSeed: 1,
);

class _Gateway extends NeteaseGateway {
  final List<String> createdNames = <String>[];
  final List<(int, int)> added = <(int, int)>[];

  @override
  Future<GatewayLoginStatus> loginWithCookie(String cookie) async {
    sessionCookie = 'MUSIC_U=fixture';
    return const GatewayLoginStatus(profile: _profile);
  }

  @override
  Future<Set<int>> likedSongIds(int uid) async => <int>{};

  @override
  Future<GatewayPlaylist?> createPlaylist(
    String name, {
    bool privacy = false,
  }) async {
    createdNames.add(name);
    return GatewayPlaylist(id: 99, name: name, created: true, trackCount: 0);
  }

  @override
  Future<void> addTracksToPlaylist(int playlistId, List<int> trackIds) async {
    for (final int id in trackIds) {
      added.add((playlistId, id));
    }
  }
}

class _Catalog extends Catalog {
  _Catalog({super.gateway});

  _Gateway get _fake => gateway as _Gateway;

  @override
  Future<void> invalidatePlaylist(String id) async {}

  @override
  Future<void> invalidateCollections(int uid) async {}

  @override
  Future<void> invalidateHome({int? userId}) async {}

  @override
  Future<HomeFeed?> loadHome({int? userId}) async => null;

  @override
  Future<UserCollections?> cachedUserCollections(int uid) async => null;

  @override
  Future<UserCollections> userCollections(int uid) async => UserCollections(
    created: <Playlist>[
      for (final String name in _fake.createdNames)
        Playlist(
          id: '99',
          name: name,
          trackIds: const <String>[],
          coverSeed: 1,
          trackCount: 0,
        ),
    ],
  );

  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => null;

  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async =>
      const GatewayLyrics(lrc: '');
}

Future<AppState> _signedIn() async {
  final _Gateway gateway = _Gateway();
  final _Catalog catalog = _Catalog(gateway: gateway);
  final AppState state = AppState(catalog: catalog);
  addTearDown(state.dispose);
  final AuthOutcome outcome = await state.signInWithCookie('MUSIC_U=fixture');
  expect(outcome.ok, isTrue);
  return state;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the library can create a cloud playlist without a song', (
    tester,
  ) async {
    final AppState state = await _signedIn();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showCreateCloudPlaylistDialog(context, state),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('新建歌单'), findsNothing);
    await tester.enterText(find.byType(TextField), '夜间散步');
    await tester.tap(find.widgetWithText(FilledButton, '创建'));
    await tester.pumpAndSettle();

    final _Gateway gateway = state.catalog.gateway as _Gateway;
    expect(gateway.createdNames, <String>['夜间散步']);
    expect(find.text('已创建「夜间散步」'), findsOneWidget);
  });

  testWidgets('the now-playing picker adds the current song to a cloud list', (
    tester,
  ) async {
    final AppState state = await _signedIn();
    final _Gateway gateway = state.catalog.gateway as _Gateway;
    gateway.createdNames.add('夜间散步');
    await state.refreshCollections(force: true);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () =>
                    showAddToPlaylistDialog(context, state, track: _track),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('夜间散步'));
    await tester.pumpAndSettle();

    expect(gateway.added, <(int, int)>[(99, 5)]);
    expect(find.text('已添加到「夜间散步」'), findsOneWidget);
  });
}
