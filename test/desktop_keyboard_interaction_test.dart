import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/tv/tv_mode.dart';
import 'package:lazer_nextgen/ui/playlist_page.dart';
import 'package:lazer_nextgen/ui/widgets.dart';

final _tracks = List.generate(
  2,
  (index) => Track(
    id: 'keyboard-$index',
    title: 'Keyboard song $index',
    artist: 'Artist',
    album: 'Album',
    duration: const Duration(minutes: 3),
    coverSeed: index,
  ),
);

class _PlaylistCatalog extends Catalog {
  @override
  Future<List<Track>?> cachedPlaylistTracks(String playlistId) async => _tracks;

  @override
  Stream<List<Track>> playlistTrackPages(String playlistId) async* {
    yield _tracks;
  }
}

class _QueueState extends AppState {
  _QueueState() : super(catalog: _PlaylistCatalog());

  final played = <int>[];

  @override
  void playQueue(List<Track> tracks, {int startIndex = 0}) {
    played.add(startIndex);
  }
}

// Navigate through real focus stops, including the playlist's header controls.
Future<void> _tabTo(WidgetTester tester, Finder target) async {
  final targetElement = tester.element(target);
  for (var step = 0; step < 20; step++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    var inside = false;
    FocusManager.instance.primaryFocus?.context?.visitAncestorElements((node) {
      if (node == targetElement) inside = true;
      return !inside;
    });
    if (inside) return;
  }
  fail('The keyboard could not reach $target');
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final tv in [false, true]) {
    testWidgets('navigation entries support keyboard activation, TV=$tv', (
      tester,
    ) async {
      final activated = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(),
          home: TvScope(
            active: tv,
            child: Scaffold(
              body: SizedBox(
                width: 240,
                child: Column(
                  children: [
                    AppRailItem(
                      icon: Icons.home_rounded,
                      label: 'Home',
                      selected: true,
                      onTap: () => activated.add('home'),
                    ),
                    AppRailItem(
                      icon: Icons.search_rounded,
                      label: 'Search',
                      selected: false,
                      onTap: () => activated.add('search'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      final activate = tv
          ? LogicalKeyboardKey.select
          : LogicalKeyboardKey.enter;
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(activate);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(activate);
      await tester.pumpAndSettle();
      expect(activated, ['home', 'search']);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('playlist Enter plays normally and only selects in batch mode', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = _QueueState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(),
        home: Scaffold(
          body: AppPlaylistPage(
            state: state,
            playlist: const Playlist(
              id: 'keyboard-fixture',
              name: 'Keyboard playlist',
              trackIds: [],
              coverSeed: 0,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final first = find.byKey(const ValueKey('playlist-row-0'));
    final second = find.byKey(const ValueKey('playlist-row-1'));
    await _tabTo(tester, first);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(state.played, [0]);

    await tester.longPress(first);
    await tester.pumpAndSettle();
    expect(tester.widget<AppTrackRow>(first).selectionMode, isTrue);
    expect(tester.widget<AppTrackRow>(first).selected, isTrue);
    await _tabTo(tester, second);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(tester.widget<AppTrackRow>(second).selected, isTrue);
    expect(state.played, [0]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
