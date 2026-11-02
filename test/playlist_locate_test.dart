import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/ui/pages.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/state/app_state.dart';

List<Track> _tracks() => <Track>[
  for (var i = 0; i < 40; i++)
    Track(
      id: 'track-$i',
      title: 'Track $i',
      artist: 'Artist $i',
      album: 'Album',
      duration: const Duration(minutes: 3),
      coverSeed: i,
      // Every other row carries an extra translated-title line so the list
      // has variable heights; the locator must still land exactly.
      translatedTitle: i.isEven ? '译名 $i' : null,
    ),
];

class _Catalog extends Catalog {
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => const GatewayLyrics();
  @override
  Future<List<Track>> playlistTracks(String id) async => _tracks();

  @override
  Future<List<Track>?> cachedPlaylistTracks(String playlistId) async => null;
}

Future<void> _locateCurrentTrack(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final List<Track> tracks = _tracks();
  final state = AppState(catalog: _Catalog());
  addTearDown(state.dispose);
  state.playQueue(tracks, startIndex: 30);
  const playlist = Playlist(
    id: 'playlist-fixture',
    name: 'Playlist fixture',
    trackIds: <String>[],
    coverSeed: 1,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppleTheme(),
      home: Scaffold(
        body: AppPlaylistPage(state: state, playlist: playlist),
      ),
    ),
  );
  await tester.pumpAndSettle();

  final locate = find.byKey(const ValueKey<String>('playlist-locate'));
  expect(locate, findsOneWidget);
  final button = tester.getRect(locate);
  final list = tester.getRect(find.byType(CustomScrollView));
  expect(button.right, closeTo(list.right - 18, 1));
  expect(button.bottom, closeTo(list.bottom - 18, 1));
  expect(
    find.byKey(const ValueKey<String>('playlist-row-30')),
    findsNothing,
    reason: 'the current track starts far outside the lazy list window',
  );

  await tester.tap(locate);
  await tester.pumpAndSettle();

  final current = find.byKey(const ValueKey<String>('playlist-row-30'));
  expect(current, findsOneWidget);
  final row = tester.getRect(current);
  final viewport = tester.getRect(find.byType(CustomScrollView));
  expect(row.top, greaterThanOrEqualTo(viewport.top - .5));
  expect(row.bottom, lessThanOrEqualTo(viewport.bottom + .5));
  expect(
    row.center.dy,
    closeTo(viewport.center.dy, 24),
    reason: 'locating centres the current row in the list viewport',
  );
  expect(
    locate,
    findsNothing,
    reason: 'the locator hides once the current row is on screen',
  );

  await tester.drag(find.byType(CustomScrollView), const Offset(0, 800));
  await tester.pumpAndSettle();
  expect(
    locate,
    findsOneWidget,
    reason: 'scrolling the current row out of view restores the locator',
  );
  expect(tester.takeException(), isNull);
  state.pause();
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the floating locate button centres the current track (phone)', (
    tester,
  ) async {
    await _locateCurrentTrack(tester, const Size(390, 844));
  });

  testWidgets(
    'the floating locate button centres the current track (desktop)',
    (tester) async {
      await _locateCurrentTrack(tester, const Size(1280, 800));
    },
  );

  testWidgets('no locator when the playing track is not in the playlist', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    state.playQueue(<Track>[
      const Track(
        id: 'somewhere-else',
        title: 'Elsewhere',
        artist: 'Other',
        album: 'Other',
        duration: Duration(minutes: 3),
        coverSeed: 0,
      ),
    ]);
    const playlist = Playlist(
      id: 'playlist-fixture',
      name: 'Playlist fixture',
      trackIds: <String>[],
      coverSeed: 1,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(),
        home: Scaffold(
          body: AppPlaylistPage(state: state, playlist: playlist),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('playlist-locate')), findsNothing);
    expect(tester.takeException(), isNull);
    state.pause();
    await tester.pump();
  });
}
