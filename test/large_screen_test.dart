import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/catalog_details.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/legacy/legacy_player_bar.dart';
import 'package:lazer_nextgen/legacy/legacy_pages.dart';
import 'package:lazer_nextgen/legacy/legacy_shell.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/tv/large_screen_chrome.dart';
import 'package:lazer_nextgen/tv/large_screen_pages.dart';
import 'package:lazer_nextgen/tv/tv_mode.dart';

const Track _track = Track(
  id: 'large-screen-track',
  title: '夜航',
  artist: '测试歌手',
  album: '测试专辑',
  duration: Duration(minutes: 4),
  coverSeed: 4,
);

const Playlist _playlist = Playlist(
  id: 'large-screen-playlist',
  name: '测试歌单',
  trackIds: <String>[],
  coverSeed: 1,
  trackCount: 3,
  description: '来自你的听歌偏好',
);

const Album _album = Album(
  id: 'large-screen-album',
  title: '测试专辑',
  artist: '测试歌手',
  year: '2026',
  coverSeed: 9,
  note: '一张用于布局测试的专辑。',
  trackCount: 12,
);

class _Gateway extends NeteaseGateway {
  @override
  Future<Set<int>> likedSongIds(int uid) async => <int>{};
}

class _ReportingState extends AppState {
  _ReportingState() : super(catalog: _Catalog());

  void publishCharts(List<MusicChart> charts) {
    discoveryCharts = charts;
    notifyListeners();
  }
}

class _Catalog extends Catalog {
  _Catalog() : super(gateway: _Gateway());

  @override
  Future<HomeFeed?> loadHome({int? userId}) async => home;

  @override
  HomeFeed? get home => const HomeFeed(
    recommended: <Playlist>[_playlist],
    featuredTracks: <Track>[_track],
    quick: <Track>[_track],
    playlists: <Playlist>[_playlist],
    albums: <Album>[_album],
    editorialPlaylists: <Playlist>[_playlist],
  );

  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => null;

  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async =>
      const GatewayLyrics(lrc: '[00:00.00]第一句');

  @override
  Future<List<Track>> playlistTracks(String id) async => const <Track>[_track];

  @override
  Future<AlbumDetails> albumDetails(int albumId, {bool force = false}) async =>
      const AlbumDetails(album: _album, tracks: <Track>[_track]);

  @override
  Future<SearchResults> search(String query) async => const SearchResults(
    tracks: <Track>[_track],
    albums: <Album>[_album],
    playlists: <Playlist>[_playlist],
  );

  @override
  Future<ArtistDetails> artistDetails(
    ArtistRef seed, {
    bool force = false,
  }) async => ArtistDetails(
    artist: seed,
    tracks: const <Track>[_track],
    description: '测试歌手介绍',
    musicCount: 1,
    albumCount: 1,
  );

  @override
  Future<ArtistAlbumPage> artistAlbumPage(
    int id, {
    int offset = 0,
    bool force = false,
  }) async => const ArtistAlbumPage(
    albums: <Album>[_album],
    more: false,
    receivedCount: 1,
  );

  @override
  Future<MusicChart> prepareChart(
    MusicChart chart, {
    bool force = false,
  }) async => chart;
}

Widget _largeScreenApp(AppState state) => TvScope(
  active: true,
  child: MaterialApp(
    theme: buildLegacyTheme(brightness: Brightness.dark),
    builder: (BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    ),
    home: LegacyShell(state: state),
  ),
);

LargeScreenActions _noopActions() => LargeScreenActions(
  onOpenPlaylist: (Playlist playlist) {},
  onOpenAlbum: (Album album) {},
  onOpenArtist: (ArtistRef artist) {},
  onOpenChart: (MusicChart chart) {},
  onOpenLikes: () {},
  onOpenLocalMusic: () {},
  onPlayTracks: (List<Track> tracks, int index) {},
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('large screen mode', () {
    test('电视形态在大屏幕模式下被命名为大屏幕模式', () {
      expect(AppSurface.tv.label, '大屏幕模式');
      expect(AppSurface.tv.detail, contains('十英尺'));
      expect(AppSurfaceLabels.parse('tv'), AppSurface.tv);
      expect(AppSurface.auto.label, '自动选择');
    });

    test('a detected television boots into the large-screen surface', () async {
      final AppState state = AppState(
        catalog: _Catalog(),
        deviceIsTelevision: true,
      );
      addTearDown(state.dispose);
      await state.bootstrap();
      expect(state.surface, AppSurface.tv);
    });

    test('an explicit surface choice survives television detection', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'lazer_surface': 'standard',
      });
      final AppState state = AppState(
        catalog: _Catalog(),
        deviceIsTelevision: true,
      );
      addTearDown(state.dispose);
      await state.bootstrap();
      expect(state.surface, AppSurface.standard);
    });

    testWidgets('the shell draws the capsule, shelves and transport', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final AppState state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      await tester.pumpWidget(_largeScreenApp(state));
      await tester.pumpAndSettle();

      expect(find.byType(LargeScreenNavBar), findsOneWidget);
      expect(find.byType(LargeScreenTransport), findsOneWidget);
      expect(find.text('现在就听'), findsOneWidget);
      expect(find.text('资料库'), findsOneWidget);
      expect(find.text('为你打造'), findsOneWidget);
      expect(find.text('精选推荐'), findsOneWidget);
      expect(find.text('新发行'), findsOneWidget);
      // The desktop source list is not part of this composition.
      expect(find.text('Lazer'), findsNothing);
      expect(find.text('测试歌单'), findsWidgets);
      // The dock has no seek rail: transport controls sit on the centre line,
      // with the playing metadata on the left and the actions on the right.
      expect(find.byType(LegacyThinSeekBar), findsNothing);
      final Offset dockCentre = tester.getCenter(
        find.byType(LargeScreenTransport),
      );
      final Offset playCentre = tester.getCenter(
        find.byIcon(Icons.play_arrow_rounded),
      );
      expect((playCentre.dx - dockCentre.dx).abs(), lessThan(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('same-sized chart updates reach the large screen shelf', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = _ReportingState();
      addTearDown(state.dispose);
      await tester.pumpWidget(_largeScreenApp(state));
      await tester.pumpAndSettle();

      MusicChart chart(String title) => MusicChart(
        id: 'chart',
        title: title,
        source: 'test',
        issueLabel: '',
        entries: const <ChartEntry>[],
      );
      state.publishCharts([chart('old')]);
      await tester.pump();
      expect(
        tester.widget<ChartShelf>(find.byType(ChartShelf)).charts.single.title,
        'old',
      );
      state.publishCharts([chart('new')]);
      await tester.pump();
      expect(
        tester.widget<ChartShelf>(find.byType(ChartShelf)).charts.single.title,
        'new',
      );
    });

    testWidgets('the library tab shows the rail and the artwork grid', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final AppState state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      await tester.pumpWidget(_largeScreenApp(state));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('large-screen-tab-library')),
      );
      await tester.pumpAndSettle();

      expect(find.text('最近添加'), findsNothing);
      expect(find.text('专辑'), findsNothing);
      expect(find.text('播放列表'), findsWidgets);
      expect(find.text('歌手'), findsWidgets);
      expect(find.text('歌曲'), findsWidgets);
      expect(find.text('测试歌单'), findsWidgets);
      expect(find.text('测试专辑'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('settings rows show the remote selection', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final AppState state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      await tester.pumpWidget(_largeScreenApp(state));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('large-screen-tab-settings')),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();

      // The page anchor can be the scroll view; once focus is on a dropdown,
      // switch or slider, its row carries the TV wash and ring. Material's own
      // faint focus overlay is not enough at ten feet.
      expect(
        find.descendant(
          of: find.byType(TvFocusHighlight),
          matching: find.byType(TvFocusOutline),
        ),
        findsWidgets,
      );
      expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<TvFocusHighlight>(),
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the search chip opens the large-screen search page', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final AppState state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      await tester.pumpWidget(_largeScreenApp(state));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('large-screen-search')),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SearchBar), findsOneWidget);
      expect(find.text('歌曲'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the large-screen search waits for the Enter commit', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final AppState state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      await tester.pumpWidget(_largeScreenApp(state));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('large-screen-search')),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '夜航');
      await tester.pump(const Duration(milliseconds: 400));
      // The idle notice is still there: typing alone must not search. The
      // field's own editable text is not a result, so assert on the artist
      // that only the result row renders.
      expect(find.text('搜索歌曲、歌手或歌单'), findsWidgets);
      expect(find.text('测试歌手'), findsNothing);

      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text('测试歌手'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Select on the focused card opens the collection page', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final AppState state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      await tester.pumpWidget(_largeScreenApp(state));
      await tester.pumpAndSettle();

      // The page anchors focus on its first actionable control (a shortcut
      // tile); one press down lands on the feature shelf, and the remote's
      // centre button is the only way in on a television.
      expect(FocusManager.instance.primaryFocus, isNotNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();

      expect(find.text('播放全部'), findsOneWidget);
      expect(find.text('夜航'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the large-screen page switch cross-fades', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final AppState state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      // Unlike the other tests this one must keep motion enabled: the point is
      // that a switch draws both pages for the length of the transition.
      await tester.pumpWidget(
        TvScope(
          active: true,
          child: MaterialApp(
            theme: buildLegacyTheme(brightness: Brightness.dark),
            home: LegacyShell(state: state),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('精选推荐'), findsOneWidget);

      await tester.tap(find.text('资料库'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // The outgoing browse page is still composited while the library fades
      // in; the switch is not silently zero-length.
      expect(find.text('精选推荐'), findsOneWidget);
      expect(find.text('播放列表'), findsWidgets);

      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('精选推荐'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the D-pad crosses from content to the capsule and back', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final AppState state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      await tester.pumpWidget(_largeScreenApp(state));
      await tester.pumpAndSettle();

      final FocusNode contentFocus = FocusManager.instance.primaryFocus!;
      expect(
        FocusTraversalGroup.maybeOf(contentFocus.context!),
        isA<LargeScreenTraversalPolicy>(),
        reason: 'the shell must own the directional policy inside the route',
      );
      // Walk up the page until the capsule is reached; from a bottom control
      // the D-pad has to cross the shelves first, from the top row it is one
      // press.
      FocusNode chrome = contentFocus;
      for (int step = 0; step < 4; step++) {
        if (chrome.context
                ?.findAncestorWidgetOfExactType<LargeScreenNavBar>() !=
            null) {
          break;
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
        chrome = FocusManager.instance.primaryFocus!;
      }
      expect(chrome, isNot(contentFocus));
      expect(
        chrome.context!.findAncestorWidgetOfExactType<LargeScreenNavBar>(),
        isNotNull,
        reason: 'up from the shelves must reach the destination capsule',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      final FocusNode backInContent = FocusManager.instance.primaryFocus!;
      expect(backInContent, isNot(chrome));
      expect(
        backInContent.context!
            .findAncestorWidgetOfExactType<LargeScreenNavBar>(),
        isNull,
        reason: 'down from the capsule must return to the shelves',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a playlist card opens the large-screen collection page', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final AppState state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      await tester.pumpWidget(_largeScreenApp(state));
      await tester.pumpAndSettle();

      await tester.tap(find.text('测试歌单').first);
      await tester.pumpAndSettle();

      expect(find.text('播放全部'), findsOneWidget);
      expect(find.text('测试歌单'), findsWidgets);
      expect(find.text('夜航'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the large-screen pages fit a 1280×720 panel', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final AppState state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      await tester.pumpWidget(_largeScreenApp(state));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('the library and collection reflow at a phone-width window', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final AppState state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      await tester.pumpWidget(
        TvScope(
          active: true,
          child: MaterialApp(
            theme: buildLegacyTheme(brightness: Brightness.dark),
            home: Scaffold(
              body: LargeScreenLibraryPage(
                state: state,
                actions: _noopActions(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(
        TvScope(
          active: true,
          child: MaterialApp(
            theme: buildLegacyTheme(brightness: Brightness.dark),
            home: Scaffold(
              body: LargeScreenCollectionPage(
                state: state,
                playlist: _playlist,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('播放全部'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('large-screen remote traversal', () {
    testWidgets('the D-pad follows the card geometry, not the build order', (
      WidgetTester tester,
    ) async {
      final List<FocusNode> nodes = <FocusNode>[
        for (int i = 0; i < 6; i++) FocusNode(debugLabel: 'card$i'),
      ];
      addTearDown(() {
        for (final FocusNode node in nodes) {
          node.dispose();
        }
      });
      Widget button(int index) => SizedBox(
        width: 100,
        height: 60,
        child: TextButton(
          focusNode: nodes[index],
          onPressed: () {},
          child: Text('card$index'),
        ),
      );
      await tester.pumpWidget(
        TvScope(
          active: true,
          child: MaterialApp(
            home: TvTraversalScope(
              child: Scaffold(
                body: Column(
                  children: <Widget>[
                    Row(
                      children: <Widget>[for (int i = 0; i < 3; i++) button(i)],
                    ),
                    Row(
                      children: <Widget>[for (int i = 3; i < 6; i++) button(i)],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      nodes[0].requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(nodes[1].hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        nodes[4].hasFocus,
        isTrue,
        reason:
            'down must land on the card physically below, not the next in '
            'widget order',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(nodes[3].hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(nodes[0].hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a move past the built items scrolls the row instead of '
        'dead-ending', (WidgetTester tester) async {
      final List<FocusNode> nodes = <FocusNode>[
        for (int i = 0; i < 8; i++) FocusNode(debugLabel: 'shelf$i'),
      ];
      addTearDown(() {
        for (final FocusNode node in nodes) {
          node.dispose();
        }
      });
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        TvScope(
          active: true,
          child: MaterialApp(
            home: TvTraversalScope(
              child: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 300,
                    height: 80,
                    child: ListView.builder(
                      controller: controller,
                      scrollDirection: Axis.horizontal,
                      itemExtent: 240,
                      scrollCacheExtent: const ScrollCacheExtent.pixels(0),
                      itemCount: nodes.length,
                      itemBuilder: (BuildContext context, int index) =>
                          TextButton(
                            focusNode: nodes[index],
                            onPressed: () {},
                            child: Text('shelf$index'),
                          ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      nodes[0].requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(nodes[1].hasFocus, isTrue);
      final double afterFirst = controller.offset;

      // The third card is outside the built range: the failed move nudges the
      // shelf so the next press has somewhere to land.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(afterFirst));

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(nodes[2].hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    });
  });
}
