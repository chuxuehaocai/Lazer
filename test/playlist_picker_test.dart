import 'support/music_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/widgets/playlist_picker_dialog.dart';

const FixtureProfile _profile = FixtureProfile(userId: 7, nickname: '测试账户');

const Track _track = Track(
  id: 'fixture:test:song:5',
  title: 'Song',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 3),
  coverSeed: 1,
);

class _Gateway extends TestMusicGateway {
  final List<String> createdNames = <String>[];
  final List<(int, int)> added = <(int, int)>[];

  @override
  Future<FixtureLoginStatus> fixtureLoginWithCookie(String cookie) async {
    sessionCookie = 'MUSIC_U=fixture';
    return const FixtureLoginStatus(profile: _profile);
  }

  @override
  Future<MusicPlaylist> createPlaylist(
    String name, {
    bool isPublic = false,
  }) async {
    createdNames.add(name);
    return MusicPlaylist(
      id: id(MusicEntityKind.playlist, '99'),
      name: name,
      writable: true,
    );
  }

  @override
  Future<void> addToPlaylist(MusicId playlist, List<MusicId> songs) async {
    for (final song in songs) {
      added.add((int.parse(playlist.value), int.parse(song.value)));
    }
  }
}

class _Catalog extends Catalog {
  _Catalog({super.gateway});

  @override
  Future<void> invalidatePlatformCollections(MusicGateway owner) async {}

  _Gateway get _fake => activeGateway as _Gateway;

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
          id: 'fixture:test:playlist:99',
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
    bool Function()? isCancelled,
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

    final _Gateway gateway = state.catalog.activeGateway as _Gateway;
    expect(gateway.createdNames, <String>['夜间散步']);
    expect(find.text('已创建「夜间散步」'), findsOneWidget);
  });

  testWidgets('the now-playing picker adds the current song to a cloud list', (
    tester,
  ) async {
    final AppState state = await _signedIn();
    final _Gateway gateway = state.catalog.activeGateway as _Gateway;
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
