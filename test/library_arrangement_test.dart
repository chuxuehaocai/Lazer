import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/legacy/legacy_pages.dart';
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
      _playlist('5', 'Echo'),
    ],
  );

  @override
  Future<HomeFeed?> loadHome({int? userId}) async => null;

  @override
  Future<void> invalidateCollections(int uid) async {}

  @override
  Future<void> invalidatePlaylist(String id) async {}
}

Future<AppState> _signedIn(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final AppState state = AppState(catalog: _Catalog());
  addTearDown(state.dispose);
  await state.signInWithCookie('MUSIC_U=fixture');
  await tester.pump();
  await tester.pump();
  return state;
}

Widget _library(AppState state, {ValueChanged<Playlist>? onOpen}) =>
    MaterialApp(
      theme: buildLegacyTheme(brightness: Brightness.dark),
      home: Scaffold(
        body: AnimatedBuilder(
          animation: state,
          builder: (BuildContext context, _) => LegacyLibraryPage(
            state: state,
            onOpenPlaylist: onOpen ?? (Playlist playlist) {},
            onOpenLocalMusic: () {},
          ),
        ),
      ),
    );

/// Runs the frames the release animation needs, however the first frame lands.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (find.byKey(const ValueKey('playlist-drag-preview')).evaluate().isEmpty) {
      return;
    }
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('歌单排列 decides how many cards share a row', (tester) async {
    final AppState state = await _signedIn(tester);
    await state.setPlaylistColumns(3);
    await tester.pumpWidget(_library(state));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final Finder cards = find.byType(LegacyPlaylistCard);
    expect(cards, findsNWidgets(5));
    final double rowTop = tester.getTopLeft(cards.at(0)).dy;
    expect(tester.getTopLeft(cards.at(1)).dy, rowTop);
    expect(tester.getTopLeft(cards.at(2)).dy, rowTop);
    expect(
      tester.getTopLeft(cards.at(3)).dy,
      greaterThan(rowTop),
      reason: 'a fourth card must wrap onto the next row',
    );

    // The automatic density on this width is three as well, so ask for two to
    // see the preference actually move the grid.
    await state.setPlaylistColumns(2);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final double twoUp = tester.getTopLeft(cards.at(1)).dy;
    expect(twoUp, rowTop);
    expect(
      tester.getTopLeft(cards.at(2)).dy,
      greaterThan(rowTop),
      reason: 'two per row leaves the third card on the next row',
    );

    // A count the width cannot honour drops columns instead of squashing the
    // cards under the readable floor.
    await state.setPlaylistColumns(6);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester.getSize(cards.at(0)).width,
      greaterThanOrEqualTo(76),
      reason: 'the width caps the arrangement',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the second lift is as visible as the first', (tester) async {
    final AppState state = await _signedIn(tester);
    await state.setPlaylistColumns(2);
    await tester.pumpWidget(_library(state));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    Finder preview() => find.byKey(const ValueKey('playlist-drag-preview'));
    double previewOpacity() => tester
        .widget<Opacity>(
          find.ancestor(of: preview(), matching: find.byType(Opacity)).first,
        )
        .opacity;

    // First lift and drop.
    final Finder cards = find.byType(LegacyPlaylistCard);
    TestGesture gesture = await tester.startGesture(
      tester.getCenter(cards.at(3)),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 24));
    await gesture.moveTo(tester.getCenter(cards.at(0)));
    await tester.pump();
    expect(preview(), findsOneWidget);
    expect(previewOpacity(), greaterThan(.9));
    await gesture.up();
    await tester.pump();
    await _settle(tester);
    expect(preview(), findsNothing);

    // Second lift: the landing animation must not leave the preview faded out.
    gesture = await tester.startGesture(
      tester.getCenter(find.byType(LegacyPlaylistCard).at(2)),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 24));
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    expect(preview(), findsOneWidget, reason: 'the card lifts again');
    expect(
      previewOpacity(),
      greaterThan(.9),
      reason: 'a stopped settle must not hand the next lift a zero opacity',
    );
    await gesture.up();
    await tester.pump();
    await _settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a mouse drag lifts the card without waiting for a hold', (
    tester,
  ) async {
    final AppState state = await _signedIn(tester);
    await state.setPlaylistColumns(2);
    final List<Playlist> opened = <Playlist>[];
    await tester.pumpWidget(_library(state, onOpen: opened.add));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final Finder cards = find.byType(LegacyPlaylistCard);
    final String draggedId = tester
        .widget<LegacyPlaylistCard>(cards.at(3))
        .playlist
        .id;
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(cards.at(3)),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 24));
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('playlist-drag-preview')),
      findsOneWidget,
      reason: 'a desktop drag lifts on movement, not after a 500 ms hold',
    );
    expect(opened, isEmpty, reason: 'a drag is not a tap');

    await gesture.moveTo(tester.getCenter(cards.at(0)));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await _settle(tester);
    expect(state.playlistOrder.first, draggedId);
    expect(opened, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a tap still opens the playlist', (tester) async {
    final AppState state = await _signedIn(tester);
    final List<Playlist> opened = <Playlist>[];
    await tester.pumpWidget(_library(state, onOpen: opened.add));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.byType(LegacyPlaylistCard).first);
    await tester.pump();
    expect(opened.single.name, 'Alpha');
    // A tap must not leave a lift behind.
    expect(find.byKey(const ValueKey('playlist-drag-preview')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('holding a card previews the move and settles on release', (
    tester,
  ) async {
    final AppState state = await _signedIn(tester);
    await state.setPlaylistColumns(2);
    await tester.pumpWidget(_library(state));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(state.playlistOrder, isEmpty);
    final Finder cards = find.byType(LegacyPlaylistCard);
    final LegacyPlaylistCard dragged = tester.widget<LegacyPlaylistCard>(
      cards.at(3),
    );
    final String draggedId = dragged.playlist.id;

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(cards.at(3)),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 60));
    // The lift: the card leaves the grid as a preview that rides the pointer,
    // so the same title is painted twice until it lands.
    expect(find.byKey(const ValueKey('playlist-drag-preview')), findsOneWidget);
    expect(find.text(dragged.playlist.name), findsNWidgets(2));

    await gesture.moveTo(tester.getCenter(cards.at(0)));
    await tester.pump();
    // The grid makes room before the listener lets go: the held card already
    // owns the first slot, and nothing is saved yet.
    final LegacyPlaylistCard held = tester.widget<LegacyPlaylistCard>(
      find.byType(LegacyPlaylistCard).at(0),
    );
    expect(held.playlist.id, draggedId);
    expect(
      state.playlistOrder,
      isEmpty,
      reason: 'a preview is not an arrangement until the card is dropped',
    );

    await gesture.up();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('playlist-drag-preview')),
      findsOneWidget,
      reason: 'the card flies into its slot instead of dropping instantly',
    );
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byKey(const ValueKey('playlist-drag-preview')), findsOneWidget);
    await _settle(tester);
    expect(find.byKey(const ValueKey('playlist-drag-preview')), findsNothing);

    expect(state.playlistOrder, isNotEmpty);
    expect(state.playlistOrder.first, draggedId);
    final LegacyPlaylistCard first = tester.widget<LegacyPlaylistCard>(
      find.byType(LegacyPlaylistCard).at(0),
    );
    expect(first.playlist.id, draggedId);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a card released away from a slot goes back home', (
    tester,
  ) async {
    final AppState state = await _signedIn(tester);
    await state.setPlaylistColumns(2);
    await tester.pumpWidget(_library(state));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final Finder cards = find.byType(LegacyPlaylistCard);
    final String home = tester
        .widget<LegacyPlaylistCard>(cards.at(0))
        .playlist
        .id;

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(cards.at(3)),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 60));
    await gesture.moveTo(tester.getCenter(cards.at(0)));
    await tester.pump();
    expect(
      tester.widget<LegacyPlaylistCard>(cards.at(0)).playlist.id,
      isNot(home),
      reason: 'the preview moved while the pointer was over the slot',
    );

    // Let go over the page margin, where no card would take the drop.
    await gesture.moveTo(const Offset(4, 4));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(find.byKey(const ValueKey('playlist-drag-preview')), findsOneWidget);
    await _settle(tester);
    expect(find.byKey(const ValueKey('playlist-drag-preview')), findsNothing);

    expect(
      state.playlistOrder,
      isEmpty,
      reason: 'an abandoned drop must not rearrange the library',
    );
    expect(
      tester.widget<LegacyPlaylistCard>(find.byType(LegacyPlaylistCard).at(0))
          .playlist
          .id,
      home,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the arrangement is written to the preferences', (
    tester,
  ) async {
    final AppState state = await _signedIn(tester);
    await state.setPlaylistOrder(<String>['5', '1', '3']);
    await state.setPlaylistColumns(4);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('lazer_playlist_order'), '5\n1\n3');
    expect(prefs.getInt('lazer_playlist_columns'), 4);
  });

  testWidgets('a card that is not in the saved order keeps its place last', (
    tester,
  ) async {
    final AppState state = await _signedIn(tester);
    // Tall enough that the lazy grid mounts every card, so the whole order is
    // visible to the assertion.
    tester.view.physicalSize = const Size(390, 1400);
    await state.setPlaylistOrder(<String>['4']);
    await tester.pumpWidget(_library(state));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final List<String> ids = <String>[
      for (final LegacyPlaylistCard card
          in tester.widgetList<LegacyPlaylistCard>(
            find.byType(LegacyPlaylistCard),
          ))
        card.playlist.id,
    ];
    expect(ids.first, '4');
    expect(ids, <String>['4', '1', '2', '3', '5']);
    expect(tester.takeException(), isNull);
  });
}
