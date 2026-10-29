import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/catalog_details.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/diagnostics/build_info.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/legacy/legacy_shell.dart';
import 'package:lazer_nextgen/legacy/legacy_pages.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/detail_requests.dart';
import 'package:lazer_nextgen/widgets/apple_ui.dart';

const Track _track = Track(
  id: '1939575649',
  title: 'まにまに',
  artist: 'r-906 / 初音ミク',
  album: 'まにまに',
  duration: Duration(minutes: 4),
  coverSeed: 1,
  translatedTitle: '测试译名',
);

const Playlist _playlist = Playlist(
  id: '12',
  name: '测试歌单',
  trackIds: <String>[],
  coverSeed: 1,
  trackCount: 3,
  description: '来自你的听歌偏好',
);

class _Gateway extends NeteaseGateway {
  @override
  Future<Set<int>> likedSongIds(int uid) async => <int>{};
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
    albums: <Album>[],
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
  Future<List<Track>> playlistTracks(String id) async => <Track>[_track];
  @override
  Future<ArtistDetails> artistDetails(
    ArtistRef seed, {
    bool force = false,
  }) async => ArtistDetails(
    artist: seed,
    tracks: const <Track>[_track],
    description: '\u6d4b\u8bd5\u6b4c\u624b\u4ecb\u7ecd',
    musicCount: 1,
    albumCount: 2,
  );
  @override
  Future<ArtistAlbumPage> artistAlbumPage(
    int id, {
    int offset = 0,
    bool force = false,
  }) async => const ArtistAlbumPage(
    albums: <Album>[
      Album(
        id: '77',
        title: '\u6d4b\u8bd5\u4e13\u8f91',
        artist: '\u6d4b\u8bd5\u6b4c\u624b',
        year: '2026',
        coverSeed: 77,
        note: '',
        trackCount: 12,
        releaseType: '\u4e13\u8f91',
      ),
      Album(
        id: '78',
        title: '\u6d4b\u8bd5 EP',
        artist: '\u6d4b\u8bd5\u6b4c\u624b',
        year: '2025',
        coverSeed: 78,
        note: '',
        trackCount: 3,
        releaseType: 'EP/Single',
      ),
    ],
    more: false,
    receivedCount: 2,
  );
  @override
  Future<List<Track>> artistSongs(int id, {bool force = false}) async =>
      const <Track>[_track];
  @override
  Future<SearchResults> search(String query) async => const SearchResults(
    tracks: <Track>[_track],
    playlists: <Playlist>[_playlist],
  );
}

class _DeferredChartCatalog extends _Catalog {
  final Completer<MusicChart> prepared = Completer<MusicChart>();

  @override
  Future<MusicChart> prepareChart(MusicChart chart, {bool force = false}) =>
      prepared.future;
}

class _PagedAlbumsCatalog extends _Catalog {
  final Completer<ArtistAlbumPage> second = Completer<ArtistAlbumPage>();

  @override
  Future<ArtistAlbumPage> artistAlbumPage(
    int id, {
    int offset = 0,
    bool force = false,
  }) async {
    if (id == 2) {
      return const ArtistAlbumPage(
        albums: [
          Album(
            id: 'c',
            title: 'Other artist',
            artist: 'Other',
            year: '2022',
            coverSeed: 3,
            note: '',
            releaseType: 'Album',
          ),
        ],
        more: false,
        receivedCount: 1,
      );
    }
    if (offset > 0) return second.future;
    return const ArtistAlbumPage(
      albums: [
        Album(
          id: 'a',
          title: 'First album',
          artist: 'Artist',
          year: '2020',
          coverSeed: 1,
          note: '',
          releaseType: 'Album',
        ),
      ],
      more: true,
      receivedCount: 1,
    );
  }
}

class _DeferredSongsCatalog extends _Catalog {
  final Completer<List<Track>> first = Completer<List<Track>>();
  int fallbackCalls = 0;

  @override
  Future<List<Track>> artistSongs(int id, {bool force = false}) => id == 1
      ? first.future
      : Future.value(const [
          Track(
            id: 'new',
            title: 'New artist song',
            artist: 'Other',
            album: '',
            duration: Duration(minutes: 1),
            coverSeed: 1,
          ),
        ]);

  @override
  Future<ArtistDetails> artistDetails(
    ArtistRef seed, {
    bool force = false,
  }) async {
    fallbackCalls++;
    return ArtistDetails(artist: seed, tracks: const [_track]);
  }
}

class _DeferredArtistDetailsCatalog extends _Catalog {
  final Completer<ArtistDetails> second = Completer<ArtistDetails>();

  @override
  Future<ArtistDetails> artistDetails(ArtistRef seed, {bool force = false}) =>
      seed.id == 2 ? second.future : super.artistDetails(seed, force: force);
}

class _UnmatchedChartCatalog extends _Catalog {
  int prepareCalls = 0;
  bool forced = false;

  @override
  Future<MusicChart> prepareChart(
    MusicChart chart, {
    bool force = false,
  }) async {
    prepareCalls++;
    forced = forced || force;
    // Answers, but never resolves a playable row: this is the board the user
    // saw with no play links at all.
    return chart;
  }
}

class _SignedInState extends AppState {
  _SignedInState() : super(catalog: _Catalog());

  @override
  SessionUser get user => const SessionUser(
    name: 'CYP2D6_Official',
    handle: '@23',
    method: AuthMethod.cookie,
    detail: '3 个字段',
    userId: 23,
    avatarUrl: 'https://example.com/avatar.jpg',
    vipType: 11,
  );

  @override
  bool get isGuest => false;
}

/// The legacy shell under a theme whose backdrop animation is disabled, so
/// `pumpAndSettle` can settle: the flowing canvas keeps a ticker running, and
/// reduced-motion is exactly how the shell handles that for tests and users.
Widget _legacyApp(AppState state) => MaterialApp(
  theme: buildLegacyTheme(brightness: Brightness.dark),
  builder: (BuildContext context, Widget? child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: true),
    child: child!,
  ),
  home: LegacyShell(state: state),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('artist releases appear before later pages finish', (
    tester,
  ) async {
    final catalog = _PagedAlbumsCatalog();
    final state = AppState(catalog: catalog);
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: LegacyArtistReleasesPage(
          state: state,
          artist: const ArtistRef(id: 1, name: 'Artist'),
          group: AlbumReleaseGroup.album,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('First album'), findsOneWidget);
    expect(find.textContaining('加载中'), findsOneWidget);
    catalog.second.complete(
      const ArtistAlbumPage(
        albums: [
          Album(
            id: 'b',
            title: 'Second album',
            artist: 'Artist',
            year: '2021',
            coverSeed: 2,
            note: '',
            releaseType: 'Album',
          ),
        ],
        more: false,
        receivedCount: 1,
      ),
    );
    await tester.pump();
    expect(find.text('Second album'), findsOneWidget);
    expect(find.textContaining('加载中'), findsNothing);
  });

  testWidgets('artist overview shows releases while later pages load', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final catalog = _PagedAlbumsCatalog();
    final state = AppState(catalog: catalog);
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LegacyArtistPage(
            state: state,
            artist: const ArtistRef(id: 1, name: 'Artist'),
            onOpenAllSongs: () {},
            onOpenAlbums: () {},
            onOpenSingles: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('First album'), findsOneWidget);
    expect(find.textContaining('加载中'), findsOneWidget);
    catalog.second.complete(
      const ArtistAlbumPage(albums: [], more: false, receivedCount: 0),
    );
    await tester.pump();
    expect(find.textContaining('加载中'), findsNothing);
  });

  testWidgets(
    'artist overview retains releases and offers retry on page failure',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final catalog = _PagedAlbumsCatalog();
      final state = AppState(catalog: catalog);
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LegacyArtistPage(
              state: state,
              artist: const ArtistRef(id: 1, name: 'Artist'),
              onOpenAllSongs: () {},
              onOpenAlbums: () {},
              onOpenSingles: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      catalog.second.completeError(StateError('later page failed'));
      await tester.pump();
      expect(find.text('First album'), findsOneWidget);
      expect(find.text('歌手资料加载失败，请重试。'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    },
  );

  testWidgets('artist overview clears old details while switching', (
    tester,
  ) async {
    final catalog = _DeferredArtistDetailsCatalog();
    final state = AppState(catalog: catalog);
    addTearDown(state.dispose);
    Widget page(int id, String name) => MaterialApp(
      home: Scaffold(
        body: LegacyArtistPage(
          state: state,
          artist: ArtistRef(id: id, name: name),
          onOpenAllSongs: () {},
          onOpenAlbums: () {},
          onOpenSingles: () {},
        ),
      ),
    );
    await tester.pumpWidget(page(1, 'Old artist'));
    await tester.pump();
    expect(find.text('Old artist'), findsOneWidget);
    await tester.pumpWidget(page(2, 'New artist'));
    await tester.pump();
    expect(find.text('Old artist'), findsNothing);
    expect(find.text('New artist'), findsOneWidget);
    catalog.second.complete(
      const ArtistDetails(
        artist: ArtistRef(id: 2, name: 'New artist'),
        tracks: [],
      ),
    );
    await tester.pump();
  });

  testWidgets('old artist pages cannot replace a new artist', (tester) async {
    final catalog = _PagedAlbumsCatalog();
    final state = AppState(catalog: catalog);
    addTearDown(state.dispose);
    Widget page(int id) => MaterialApp(
      home: LegacyArtistReleasesPage(
        state: state,
        artist: ArtistRef(id: id, name: 'Artist $id'),
        group: AlbumReleaseGroup.album,
      ),
    );
    await tester.pumpWidget(page(1));
    await tester.pump();
    expect(find.text('First album'), findsOneWidget);
    await tester.pumpWidget(page(2));
    await tester.pump();
    expect(find.text('Other artist'), findsOneWidget);
    catalog.second.complete(
      const ArtistAlbumPage(albums: [], more: false, receivedCount: 0),
    );
    await tester.pump();
    expect(find.text('Other artist'), findsOneWidget);
    expect(find.text('First album'), findsNothing);
  });

  testWidgets('an outdated song request cannot change the new artist', (
    tester,
  ) async {
    final catalog = _DeferredSongsCatalog();
    final state = AppState(catalog: catalog);
    addTearDown(state.dispose);
    Widget page(int id) => MaterialApp(
      home: LegacyArtistSongsPage(
        state: state,
        artist: ArtistRef(id: id, name: 'Artist $id'),
      ),
    );
    await tester.pumpWidget(page(1));
    await tester.pumpWidget(page(2));
    await tester.pump();
    expect(find.text('New artist song'), findsOneWidget);
    catalog.first.completeError(StateError('old request failed'));
    await tester.pump();
    expect(find.text('New artist song'), findsOneWidget);
    expect(find.text('全部歌曲加载失败，请重试。'), findsNothing);
    expect(catalog.fallbackCalls, 0);
  });

  test('the legacy theme keeps the Lazer palette and type ramp', () {
    final ThemeData dark = buildLegacyTheme(brightness: Brightness.dark);
    expect(dark.colorScheme.primary, LegacyTokens.nightBlue);
    expect(dark.colorScheme.surface, LegacyTokens.nightPaper);
    expect(dark.textTheme.displaySmall?.fontSize, 36);
    expect(dark.textTheme.headlineMedium?.fontSize, 28);
    expect(dark.textTheme.bodyMedium?.fontSize, 14);

    final ThemeData light = buildLegacyTheme();
    expect(light.colorScheme.primary, const Color(0xFF35657D));
    expect(light.colorScheme.surface, LegacyTokens.paperRaised);
    // Every Material 3 surface role is explicit; none of them may fall back
    // to Flutter's purple baseline scheme.
    expect(light.colorScheme.surfaceContainerLowest, const Color(0xFFFFFFFF));
    expect(light.colorScheme.surfaceContainerHighest, const Color(0xFFE3DED4));
    expect(dark.colorScheme.surfaceDim, const Color(0xFF0F1619));
    expect(dark.colorScheme.surfaceBright, const Color(0xFF394448));
    expect(dark.colorScheme.inversePrimary, const Color(0xFF35657D));
    expect(light.useMaterial3, isTrue);
    expect(dark.textTheme.labelSmall?.fontSize, 11);
    expect(
      dark.cardTheme.shape,
      const RoundedRectangleBorder(borderRadius: AppShape.lgRadius),
    );
  });

  testWidgets('the legacy shell draws rail, discovery page and transport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await tester.pumpWidget(_legacyApp(state));
    await tester.pumpAndSettle();

    // Rail chrome and the discovery page. 'Lazer' is both the rail wordmark
    // and the empty transport's artist line.
    expect(find.text('Lazer'), findsWidgets);
    expect(find.text('主页'), findsOneWidget);
    expect(find.text('音乐库'), findsOneWidget);
    expect(find.text('我喜欢'), findsOneWidget);
    expect(find.text('每日推荐'), findsWidgets);
    expect(find.text('最近播放'), findsOneWidget);
    expect(find.text('未选择曲目'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 音乐库 shows the recommended playlists for a guest.
    await tester.tap(find.text('音乐库').first);
    await tester.pumpAndSettle();
    expect(find.text('推荐歌单'), findsOneWidget);

    // 设置 opens the preferences page.
    await tester.tap(find.byKey(const ValueKey('rail-account')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    expect(find.text('配色'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the rail opens settings from the entry under the account block',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final AppState state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      await tester.pumpWidget(_legacyApp(state));
      await tester.pumpAndSettle();

      // The entry sits under the account row, so settings opens without the
      // account menu having to be expanded first.
      expect(find.text('设置'), findsOneWidget);
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(find.text('配色'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('artist links open an Apple-style detail in the content pane', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() => artistDetailRequest.value = null);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await tester.pumpWidget(_legacyApp(state));
    await tester.pumpAndSettle();

    artistDetailRequest.value = const ArtistRef(
      id: 11,
      name: '\u6d4b\u8bd5\u6b4c\u624b',
    );
    await tester.pumpAndSettle();

    expect(find.text('\u6d4b\u8bd5\u6b4c\u624b'), findsWidgets);
    expect(find.text('\u6b4c\u66f2\u6392\u884c'), findsOneWidget);
    expect(find.text('\u4e13\u8f91'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('artist-all-albums')));
    await tester.pumpAndSettle();
    expect(find.text('\u5168\u90e8\u4e13\u8f91'), findsWidgets);
    expect(find.text('\u6d4b\u8bd5\u4e13\u8f91'), findsOneWidget);

    await tester.tap(find.byTooltip('\u8fd4\u56de'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).at(1), const Offset(0, -520));
    await tester.pumpAndSettle();
    expect(find.text('\u5355\u66f2 / EP'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('artist-all-singles')));
    await tester.pumpAndSettle();
    expect(find.text('\u5168\u90e8\u5355\u66f2 / EP'), findsWidgets);
    expect(find.text('\u6d4b\u8bd5 EP'), findsOneWidget);
    expect(
      find.text('Lazer'),
      findsWidgets,
      reason: '\u4fa7\u680f\u5e94\u7ee7\u7eed\u4fdd\u7559',
    );

    await tester.tap(find.byTooltip('\u8fd4\u56de'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('artist-all-songs')));
    await tester.pumpAndSettle();
    expect(find.text('\u5168\u90e8\u6b4c\u66f2'), findsWidgets);
    expect(find.text('\u307e\u306b\u307e\u306b'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the legacy shell folds into bottom tabs on a narrow window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(520, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await tester.pumpWidget(_legacyApp(state));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('音乐库'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the legacy shell lays out at every window size', (tester) async {
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    for (final Size size in <Size>[
      const Size(520, 900),
      const Size(800, 700),
      const Size(1024, 768),
      const Size(1600, 1000),
    ]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(_legacyApp(state));
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: 'legacy shell overflowed at $size',
      );
    }
  });

  testWidgets('the legacy settings expose every preference', (tester) async {
    // Tall enough that the lazy list builds every row, About included.
    tester.view.physicalSize = const Size(1280, 4200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await tester.pumpWidget(_legacyApp(state));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rail-account')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();

    for (final String label in <String>[
      '配色',
      '设备形态',
      '界面布局',
      'DPI 缩放',
      '自动调节 DPI 缩放',
      '背景',
      '内容不透明度',
      '动态背景渲染精度',
      '主题',
      '语言',
      '震动反馈',
      '歌词控件自动隐藏',
      '歌词字号',
      '歌词粗细',
      '歌词模糊',
      '手动浏览后恢复跟随',
      '滚动惯性',
      '滚动加速度',
      '刷新曲库',
    ]) {
      expect(find.text(label), findsOneWidget, reason: 'missing $label');
    }
    expect(find.text('70%'), findsOneWidget);
    // The precision slider reads its stored percentage and reports the mesh
    // that setting draws.
    expect(find.text('80%'), findsOneWidget);
    expect(find.textContaining('网格 22×14'), findsOneWidget);
    // DPI 100% and the default scroll acceleration both read 100%.
    expect(find.text('100%'), findsWidgets);
    final Finder aboutTile = find.ancestor(
      of: find.text('Lazer'),
      matching: find.byType(AppleListTile),
    );
    expect(aboutTile, findsOneWidget);
    expect(
      find.descendant(
        of: aboutTile,
        matching: find.text('提交 ${BuildInfo.shortCommit}'),
      ),
      findsOneWidget,
      reason: 'the About row names the build commit',
    );
    expect(
      find.descendant(
        of: aboutTile,
        matching: find.byWidgetPredicate(
          (Widget widget) =>
              widget is Image &&
              widget.image is AssetImage &&
              (widget.image as AssetImage).assetName == 'assets/app_icon.png',
        ),
      ),
      findsOneWidget,
      reason: 'the About row must use the app icon',
    );
    expect(
      find.descendant(
        of: aboutTile,
        matching: find.byIcon(Icons.graphic_eq_rounded),
      ),
      findsNothing,
      reason: 'the About row must not use the Apple Music-style tile',
    );

    Finder controlFor<T extends Widget>(String label) => find.descendant(
      of: find
          .ancestor(of: find.text(label), matching: find.byType(Container))
          .first,
      matching: find.byType(T),
    );

    // The automatic scale switch is on out of the box, and turning it off
    // leaves the manual scale in place.
    await tester.tap(controlFor<Switch>('自动调节 DPI 缩放'));
    await tester.pumpAndSettle();
    expect(state.autoDpiScale, isFalse);

    // The DPI slider writes a manual scale.
    final Finder dpi = controlFor<Slider>('DPI 缩放');
    await tester.ensureVisible(dpi);
    await tester.drag(dpi, const Offset(120, 0));
    await tester.pumpAndSettle();
    expect(state.dpiScale, greaterThan(1.0));

    // Lyrics: size slider, weight chips and the blur switch.
    final Finder lyricSize = controlFor<Slider>('歌词字号');
    await tester.ensureVisible(lyricSize);
    await tester.drag(lyricSize, const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(state.lyricFontSize, greaterThan(22));
    await tester.ensureVisible(find.text('粗体'));
    await tester.tap(find.text('粗体'));
    await tester.pumpAndSettle();
    expect(state.lyricFontWeight, 700);
    await tester.ensureVisible(find.text('歌词模糊'));
    await tester.tap(controlFor<Switch>('歌词模糊'));
    await tester.pumpAndSettle();
    expect(state.lyricBlurEnabled, isFalse);

    // Haptics and the scroll sliders.
    await tester.ensureVisible(find.text('震动反馈'));
    await tester.tap(controlFor<Switch>('震动反馈'));
    await tester.pumpAndSettle();
    expect(state.hapticsEnabled, isFalse);
    final Finder inertia = controlFor<Slider>('滚动惯性');
    await tester.ensureVisible(inertia);
    await tester.drag(inertia, const Offset(-800, 0));
    await tester.pumpAndSettle();
    expect(state.scrollRetention, lessThan(0.90));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the rail search page searches and lists the results', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await tester.pumpWidget(_legacyApp(state));
    await tester.pumpAndSettle();

    // The toolbar has no field any more: 搜索 is a rail destination.
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'まにまに');
    await tester.pump(const Duration(milliseconds: 400));
    // Typing alone must not start a request; the tab strip appears only after
    // the user commits the query with Enter / the IME search action.
    expect(find.text('歌曲'), findsNothing);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('歌曲'), findsOneWidget);
    expect(find.text('歌单'), findsOneWidget);
    expect(find.text('まにまに'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
  testWidgets('signed-in rail shows the artwork avatar and VIP status', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = _SignedInState();
    addTearDown(state.dispose);
    await tester.pumpWidget(_legacyApp(state));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('CYP2D6_Official'), findsOneWidget);
    expect(find.text('黑胶会员'), findsOneWidget);
    expect(find.text('3 个字段'), findsNothing);
    final tile = find.ancestor(
      of: find.text('CYP2D6_Official'),
      matching: find.byType(PopupMenuButton<String>),
    );
    expect(tile, findsOneWidget);
    expect(
      find.descendant(of: tile, matching: find.byType(Image)),
      findsOneWidget,
      reason: 'the signed-in account must use its avatar, not an initial',
    );
    expect(find.descendant(of: tile, matching: find.text('C')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('chart rows show matching progress before playback is resolved', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final catalog = _DeferredChartCatalog();
    final state = AppState(catalog: catalog);
    addTearDown(state.dispose);
    const source = MusicChart(
      id: 'biliboard:1:124',
      title: '周榜',
      source: 'Biliboard',
      issueLabel: 'Current',
      providerKey: 'biliboard:1',
      entries: <ChartEntry>[
        ChartEntry(rank: 1, title: 'まにまに', artist: 'r-906'),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLegacyTheme(),
        home: Scaffold(
          body: LegacyChartPage(state: state, chart: source),
        ),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.link_off_rounded), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsWidgets);

    catalog.prepared.complete(
      const MusicChart(
        id: 'biliboard:1:124',
        title: '周榜',
        source: 'Biliboard',
        issueLabel: 'Current',
        providerKey: 'biliboard:1',
        entries: <ChartEntry>[
          ChartEntry(rank: 1, title: 'まにまに', artist: 'r-906', track: _track),
        ],
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('a board that resolved no playable row offers a retry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final catalog = _UnmatchedChartCatalog();
    final state = AppState(catalog: catalog);
    addTearDown(state.dispose);
    const source = MusicChart(
      id: 'biliboard:1:124',
      title: 'weekly',
      source: 'Biliboard',
      issueLabel: 'Current',
      providerKey: 'biliboard:1',
      entries: <ChartEntry>[
        ChartEntry(rank: 1, title: 'unmatched', artist: 'producer'),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLegacyTheme(),
        home: Scaffold(
          body: LegacyChartPage(state: state, chart: source),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(catalog.prepareCalls, 1);
    expect(find.byIcon(Icons.link_off_rounded), findsOneWidget);
    expect(find.text('\u91cd\u8bd5'), findsOneWidget);

    await tester.tap(find.text('\u91cd\u8bd5'));
    await tester.pumpAndSettle();

    expect(catalog.prepareCalls, 2);
    expect(catalog.forced, isTrue);
  });
}
