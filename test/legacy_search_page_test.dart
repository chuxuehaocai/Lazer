import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/legacy/legacy_search_page.dart';
import 'package:lazer_nextgen/legacy/legacy_playlist_grid.dart';
import 'package:lazer_nextgen/legacy/legacy_widgets.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SearchCatalog extends Catalog {
  final requests = <String, Completer<SearchResults>>{};
  int requestCount = 0;
  @override
  Future<SearchResults> search(String query) {
    requestCount++;
    return (requests[query] = Completer<SearchResults>()).future;
  }
}

Track song(int index) => Track(
  id: '$index',
  title: 'Song $index',
  artist: 'Artist',
  album: 'Album',
  duration: const Duration(minutes: 3),
  coverSeed: index,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'search builds visible results and typing does not rebuild them',
    (tester) async {
      final catalog = SearchCatalog();
      final state = AppState(catalog: catalog);
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LegacySearchPage(state: state, onOpenPlaylist: (_) {}),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'first');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      catalog.requests['first']!.complete(
        SearchResults(tracks: List<Track>.generate(1000, song)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Song 0'), findsOneWidget);
      expect(find.text('Song 999'), findsNothing);
      var rowsRebuilt = 0;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        if (element.widget is LegacyTrackRow) rowsRebuilt++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = null);
      await tester.enterText(find.byType(TextField), 'second');
      await tester.pump();
      expect(rowsRebuilt, 0);
      expect(find.byTooltip('清除'), findsOneWidget);
      await tester.tap(find.byTooltip('清除'));
      await tester.pump();
      expect(find.text('Song 0'), findsNothing);
      expect(find.byTooltip('清除'), findsNothing);
    },
  );

  testWidgets('search playlist cards build lazily and the last card opens', (
    tester,
  ) async {
    final catalog = SearchCatalog();
    final state = AppState(catalog: catalog);
    addTearDown(state.dispose);
    Playlist? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LegacySearchPage(
            state: state,
            onOpenPlaylist: (playlist) => opened = playlist,
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'lists');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    catalog.requests['lists']!.complete(
      SearchResults(
        playlists: List<Playlist>.generate(
          1000,
          (i) => Playlist(
            id: '$i',
            name: 'Playlist $i',
            trackIds: const [],
            coverSeed: i,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('歌单'));
    await tester.pumpAndSettle();
    expect(find.text('Playlist 0'), findsOneWidget);
    expect(find.text('Playlist 999'), findsNothing);
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).last);
    scroll.position.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('Playlist 999'), findsOneWidget);
    await tester.tap(find.text('Playlist 999'));
    await tester.pump();
    expect(opened?.id, '999');
    expect(tester.takeException(), isNull);
  });

  testWidgets('playlist rows fit narrow layouts and large text', (
    tester,
  ) async {
    final playlist = Playlist(
      id: '1',
      name: 'Playlist name',
      trackIds: const [],
      coverSeed: 1,
      trackCount: 20,
    );
    final layout = LegacyPlaylistGridLayout(200);
    expect(layout.columns, 1);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              child: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(2)),
                child: CustomScrollView(
                  slivers: [
                    LegacyPlaylistRowsSliver(
                      playlists: [playlist, playlist],
                      layout: layout,
                      onOpen: (_) {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    final cards = tester.widgetList<LegacyPlaylistCard>(
      find.byType(LegacyPlaylistCard),
    );
    expect(cards.every((card) => card.width <= 200), isTrue);
  });

  testWidgets('a cleared query cannot show a late result', (tester) async {
    final catalog = SearchCatalog();
    final state = AppState(catalog: catalog);
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LegacySearchPage(state: state, onOpenPlaylist: (_) {}),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'slow');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.tap(find.byTooltip('清除'));
    await tester.pump();
    catalog.requests['slow']!.complete(SearchResults(tracks: [song(7)]));
    await tester.pump();
    expect(find.text('Song 7'), findsNothing);
    expect(find.text('搜索歌曲、歌手或歌单。'), findsOneWidget);
  });

  testWidgets('repeated submission shares an in-flight search', (tester) async {
    final catalog = SearchCatalog();
    final state = AppState(catalog: catalog);
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LegacySearchPage(state: state, onOpenPlaylist: (_) {}),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'same');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    expect(catalog.requestCount, 1);
    catalog.requests['same']!.complete(SearchResults(tracks: [song(1)]));
    await tester.pump();
    expect(find.text('Song 1'), findsOneWidget);
  });

  testWidgets('changing state reloads the query and ignores old results', (
    tester,
  ) async {
    final first = SearchCatalog();
    final second = SearchCatalog();
    final oldState = AppState(catalog: first);
    final newState = AppState(catalog: second);
    addTearDown(oldState.dispose);
    addTearDown(newState.dispose);
    Widget page(AppState state) => MaterialApp(
      home: Scaffold(
        body: LegacySearchPage(state: state, onOpenPlaylist: (_) {}),
      ),
    );
    await tester.pumpWidget(page(oldState));
    await tester.enterText(find.byType(TextField), 'query');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpWidget(page(newState));
    expect(second.requestCount, 1);
    second.requests['query']!.complete(SearchResults(tracks: [song(2)]));
    await tester.pump();
    first.requests['query']!.complete(SearchResults(tracks: [song(1)]));
    await tester.pump();
    expect(find.text('Song 2'), findsOneWidget);
    expect(find.text('Song 1'), findsNothing);
  });
}
