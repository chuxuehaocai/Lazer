import 'support/music_gateway.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/ui/pages.dart';
import 'package:lazer_nextgen/ui/shell.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/state/app_state.dart';

const Track _track = Track(
  id: '1',
  title: 'A',
  artist: 'B',
  album: 'C',
  duration: Duration(minutes: 3),
  coverSeed: 1,
);

Playlist _playlist(int index) => Playlist(
  id: '$index',
  name: '歌单 $index',
  trackIds: <String>[],
  coverSeed: index,
  trackCount: 3,
);

MusicChart _chart(int index) => MusicChart(
  id: 'chart$index',
  title: '榜单 $index',
  source: 'test',
  issueLabel: '第 ${index + 1} 期',
  entries: const <ChartEntry>[ChartEntry(rank: 1, title: 'A', artist: 'B')],
);

class _Catalog extends Catalog {
  _Catalog() : super(gateway: _Gateway());

  @override
  HomeFeed? get home => HomeFeed(
    recommended: <Playlist>[for (int i = 0; i < 12; i++) _playlist(i)],
    featuredTracks: const <Track>[_track],
    quick: const <Track>[_track],
    playlists: <Playlist>[for (int i = 0; i < 12; i++) _playlist(i)],
    albums: const <Album>[],
  );

  @override
  Future<HomeFeed?> loadHome({int? userId}) async => home;

  @override
  Future<List<Track>> playlistTracks(String id) async => const <Track>[_track];

  @override
  Future<List<Track>?> cachedPlaylistTracks(String playlistId) async => null;

  @override
  Future<MusicChart> prepareChart(
    MusicChart chart, {
    bool force = false,
  }) async => chart;

  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => null;
}

class _Gateway extends TestMusicGateway {}

Widget _app(AppState state) => MaterialApp(
  theme: buildAppleTheme(brightness: Brightness.dark),
  builder: (BuildContext context, Widget? child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: true),
    child: child!,
  ),
  home: AppShell(state: state),
);

ScrollableState _scrollableInside(WidgetTester tester, Finder shelf) {
  final Finder list = find.descendant(
    of: shelf,
    matching: find.byType(ListView),
  );
  expect(list, findsOneWidget);
  return tester.state<ScrollableState>(
    find.descendant(of: list, matching: find.byType(Scrollable)),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'phone home shelves follow mouse and touch drags and open cards',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final AppState state = AppState(catalog: _Catalog());
      state.discoveryCharts = <MusicChart>[
        for (int i = 0; i < 6; i++) _chart(i),
      ];
      addTearDown(state.dispose);
      await tester.pumpWidget(_app(state));
      await tester.pumpAndSettle();

      final Finder recommendations = find.byKey(
        const ValueKey<String>('recommendations'),
      );
      final Finder charts = find.byKey(const ValueKey<String>('charts'));
      final Finder homeScroll = find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first;

      // The sliver list builds lazily; scroll the page until each shelf exists.
      // The charts shelf shares the same drag handling, so check it first.
      await tester.scrollUntilVisible(charts, 300, scrollable: homeScroll);
      await tester.pumpAndSettle();
      final ScrollableState chartScroll = _scrollableInside(tester, charts);
      expect(chartScroll.position.axis, Axis.horizontal);
      expect(chartScroll.position.maxScrollExtent, greaterThan(0));
      await tester.drag(
        find.descendant(of: charts, matching: find.byType(ListView)),
        const Offset(-200, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(chartScroll.position.pixels, greaterThan(0));

      await tester.scrollUntilVisible(
        recommendations,
        300,
        scrollable: homeScroll,
      );
      await tester.pumpAndSettle();
      expect(recommendations, findsOneWidget);

      // A mouse drag is how a phone-sized emulator or a head unit is used.
      await tester.ensureVisible(recommendations);
      await tester.pumpAndSettle();
      final ScrollableState playlistScroll = _scrollableInside(
        tester,
        recommendations,
      );
      expect(playlistScroll.position.axis, Axis.horizontal);
      expect(playlistScroll.position.maxScrollExtent, greaterThan(0));
      final double start = playlistScroll.position.pixels;
      await tester.drag(
        find.descendant(of: recommendations, matching: find.byType(ListView)),
        const Offset(-200, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(
        playlistScroll.position.pixels,
        greaterThan(start),
        reason: 'the shelf should follow a horizontal mouse drag on mobile too',
      );

      final Finder playlistList = find.descendant(
        of: recommendations,
        matching: find.byType(ListView),
      );
      final double afterMouse = playlistScroll.position.pixels;
      await tester.drag(playlistList, const Offset(-160, 0));
      await tester.pumpAndSettle();
      expect(
        playlistScroll.position.pixels,
        greaterThan(afterMouse),
        reason: 'the shelf should follow a horizontal touch drag',
      );

      final double afterTouch = playlistScroll.position.pixels;
      await tester.drag(
        playlistList,
        const Offset(120, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(
        playlistScroll.position.pixels,
        lessThan(afterTouch),
        reason: 'the shelf should scroll back the other way',
      );

      await tester.ensureVisible(recommendations);
      await tester.pumpAndSettle();
      await tester.tap(find.text('歌单 3'));
      await tester.pumpAndSettle();
      expect(find.byType(AppPlaylistPage), findsOneWidget);
      expect(find.text('歌单 3'), findsWidgets);
      expect(tester.takeException(), isNull);

      // A chart card opens the same way the playlist card does.
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(charts, -300, scrollable: homeScroll);
      await tester.pumpAndSettle();
      await tester.tap(find.text('榜单 1'));
      await tester.pumpAndSettle();
      expect(find.byType(AppChartPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
