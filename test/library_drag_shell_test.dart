import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/legacy/legacy_shell.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/legacy/legacy_widgets.dart';
import 'package:lazer_nextgen/state/app_state.dart';

const GatewayUserProfile _profile = GatewayUserProfile(
  userId: 7,
  nickname: 'tester',
);

Playlist _playlist(String id, String name) => Playlist(
  id: id,
  name: name,
  trackIds: const <String>[],
  coverSeed: 1,
  trackCount: 2,
);

class _Gateway extends NeteaseGateway {
  @override
  Future<GatewayLoginStatus> loginWithCookie(String cookie) async {
    sessionCookie = 'MUSIC_U=fixture';
    return const GatewayLoginStatus(profile: _profile);
  }

  @override
  Future<Set<int>> likedSongIds(int uid) async => <int>{};
}

class _Catalog extends Catalog {
  _Catalog() : super(gateway: _Gateway());
  @override
  Future<UserCollections?> cachedUserCollections(int uid) async => null;
  @override
  Future<UserCollections> userCollections(int uid) async => UserCollections(
    created: <Playlist>[
      _playlist('1', 'Alpha'),
      _playlist('2', 'Bravo'),
      _playlist('3', 'Charlie'),
      _playlist('4', 'Delta'),
    ],
  );
  @override
  Future<HomeFeed?> loadHome({int? userId}) async => null;
  @override
  Future<void> invalidateCollections(int uid) async {}
  @override
  Future<void> invalidatePlaylist(String id) async {}
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('long-pressing a card lifts it inside the phone shell', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await state.signInWithCookie('MUSIC_U=fixture');
    await tester.pump();
    await tester.pump();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLegacyTheme(brightness: Brightness.dark),
        home: LegacyShell(state: state),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('音乐库').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final Finder cards = find.byType(LegacyPlaylistCard);
    expect(cards, findsWidgets);
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(cards.first),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 80));
    expect(
      find.byKey(const ValueKey('playlist-drag-preview')),
      findsOneWidget,
      reason: 'the card must lift onto the overlay',
    );
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
  });
}
