import 'support/music_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/catalog_details.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/detail_requests.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/pages.dart';
import 'package:lazer_nextgen/ui/shell.dart';
import 'package:lazer_nextgen/ui/widgets.dart';
import 'package:lazer_nextgen/widgets/cover_transition.dart';

Album _album(String id, String title, String artist) => Album(
  id: id,
  title: title,
  artist: artist,
  year: '2024',
  coverSeed: 1,
  note: '',
);

class _Gateway extends TestMusicGateway {
  /// The account the next sign-in adopts, so a test can switch accounts.
  int uid = 7;

  @override
  Future<FixtureLoginStatus> fixtureLoginWithCookie(String cookie) async {
    sessionCookie = 'MUSIC_U=test';
    return FixtureLoginStatus(
      profile: FixtureProfile(userId: uid, nickname: 'tester'),
    );
  }
}

/// A catalogue whose 收藏的专辑 collection is a fixed list of pages.
class _Catalog extends Catalog {
  _Catalog({
    this.pages = const <List<Album>>[],
    this.pagesForUid,
    TestMusicGateway? gateway,
  }) : super(gateway: gateway ?? _Gateway());

  List<List<Album>> pages;

  /// When set, each account reads its own collection.
  Map<int, List<List<Album>>>? pagesForUid;

  /// Answers every read with an empty page that still claims more, which is
  /// what a service that never learns to stop looks like.
  bool alwaysEmptyWithMore = false;

  /// Thrown by the first read when set, so the retry path can be exercised.
  bool failFirst = false;

  final List<int> offsets = <int>[];
  int calls = 0;

  @override
  Future<AlbumPage> savedAlbums(
    int uid, {
    int offset = 0,
    bool force = false,
  }) async {
    offsets.add(offset);
    calls++;
    if (failFirst && calls == 1) throw StateError('offline');
    if (alwaysEmptyWithMore) {
      return const AlbumPage(albums: <Album>[], more: true, receivedCount: 0);
    }
    final List<List<Album>> source = pagesForUid?[uid] ?? pages;
    var skip = offset;
    for (var index = 0; index < source.length; index++) {
      final List<Album> page = source[index];
      if (skip >= page.length) {
        skip -= page.length;
        continue;
      }
      return AlbumPage(
        albums: page.sublist(skip),
        more: index < source.length - 1,
        receivedCount: page.length - skip,
      );
    }
    return const AlbumPage(albums: <Album>[], more: false, receivedCount: 0);
  }

  @override
  Future<UserCollections?> cachedUserCollections(int uid) async => null;

  @override
  Future<UserCollections> userCollections(int uid) async =>
      const UserCollections();

  @override
  Future<HomeFeed?> loadHome({int? userId}) async => null;

  @override
  Future<void> invalidateCollections(int uid) async {}

  @override
  Future<void> invalidatePlaylist(String id) async {}
}

Future<AppState> _state(
  WidgetTester tester,
  _Catalog catalog, {
  bool signedIn = true,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final AppState state = AppState(catalog: catalog);
  addTearDown(state.dispose);
  if (signedIn) {
    await state.signInWithCookie('MUSIC_U=test');
    await tester.pump();
    await tester.pump();
  }
  return state;
}

Widget _page(AppState state) => MaterialApp(
  theme: buildAppleTheme(brightness: Brightness.dark),
  home: Scaffold(
    body: AnimatedBuilder(
      animation: state,
      builder: (BuildContext context, _) => AppSavedAlbumsPage(state: state),
    ),
  ),
);

/// Runs the frames a page needs to settle after an asynchronous load.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// A title inside the album grid. The search field holds the typed query as
/// text too, so a plain `find.text` would answer with both.
Finder _gridText(String text) =>
    find.descendant(of: find.byType(SliverGrid), matching: find.text(text));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('收藏的专辑 lists the account albums and opens one', (tester) async {
    final catalog = _Catalog(
      pages: <List<Album>>[
        <Album>[_album('1', 'Night', 'Artist A'), _album('2', 'Day', 'B')],
      ],
    );
    final state = await _state(tester, catalog);
    await tester.pumpWidget(_page(state));
    await _settle(tester);

    expect(catalog.offsets, <int>[0]);
    expect(find.text('收藏的专辑'), findsOneWidget);
    expect(find.text('2 张'), findsOneWidget);
    expect(find.text('Night'), findsOneWidget);
    expect(find.text('Artist A'), findsOneWidget);

    await tester.tap(find.text('Night'));
    await tester.pump();
    expect(albumDetailRequest.value?.title, 'Night');
    albumDetailRequest.value = null;
  });

  testWidgets('an empty collection says so instead of showing a grid', (
    tester,
  ) async {
    final state = await _state(tester, _Catalog());
    await tester.pumpWidget(_page(state));
    await _settle(tester);
    expect(find.text('还没有收藏的专辑'), findsOneWidget);
  });

  testWidgets('the filter searches pages that are not loaded yet', (
    tester,
  ) async {
    final catalog = _Catalog(
      pages: <List<Album>>[
        <Album>[_album('1', 'Alpha', 'A'), _album('2', 'Bravo', 'B')],
        <Album>[_album('3', 'Charlie', 'C')],
      ],
    );
    final state = await _state(tester, catalog);
    await tester.pumpWidget(_page(state));
    await _settle(tester);
    expect(_gridText('Charlie'), findsNothing);
    expect(catalog.offsets, <int>[0]);

    await tester.enterText(find.byType(SearchBar), 'Charlie');
    await _settle(tester);
    // The filter walks the rest of the collection on its own.
    expect(catalog.offsets, <int>[0, 2]);
    expect(_gridText('Charlie'), findsOneWidget);
    expect(_gridText('Alpha'), findsNothing);

    await tester.enterText(find.byType(SearchBar), 'Delta');
    await _settle(tester);
    expect(find.text('没有找到匹配的专辑'), findsOneWidget);
  });

  testWidgets('a guest is pointed at sign-in and no album is requested', (
    tester,
  ) async {
    final catalog = _Catalog(
      pages: <List<Album>>[
        <Album>[_album('1', 'Night', 'Artist A')],
      ],
    );
    final state = await _state(tester, catalog, signedIn: false);
    await tester.pumpWidget(_page(state));
    await _settle(tester);

    expect(catalog.offsets, isEmpty);
    // The subtitle and the notice both carry the invitation.
    expect(find.text('登录后同步收藏的专辑'), findsNWidgets(2));
    expect(find.text('登录'), findsOneWidget);
    expect(find.byType(SearchBar), findsNothing);
  });

  testWidgets('a failed page offers a retry that loads the collection', (
    tester,
  ) async {
    final catalog = _Catalog(
      pages: <List<Album>>[
        <Album>[_album('1', 'Night', 'Artist A')],
      ],
    )..failFirst = true;
    final state = await _state(tester, catalog);
    await tester.pumpWidget(_page(state));
    await _settle(tester);
    expect(find.text('收藏的专辑加载失败，请重试。'), findsOneWidget);

    catalog.failFirst = false;
    await tester.tap(find.text('重试'));
    await _settle(tester);
    expect(find.text('收藏的专辑加载失败，请重试。'), findsNothing);
    expect(find.text('Night'), findsOneWidget);
  });

  testWidgets('the covers do not sit on the search field', (tester) async {
    final catalog = _Catalog(
      pages: <List<Album>>[
        <Album>[_album('1', 'Night', 'Artist A')],
      ],
    );
    final state = await _state(tester, catalog);
    await tester.pumpWidget(_page(state));
    await _settle(tester);

    final Rect field = tester.getRect(find.byType(SearchBar));
    final Rect cover = tester.getRect(find.byType(AppCover));
    expect(
      cover.top - field.bottom,
      greaterThanOrEqualTo(20),
      reason: 'the grid must read as its own shelf, not as part of the field',
    );
  });

  testWidgets('资料库 opens 收藏的专辑 in place and back returns to it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(520, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final catalog = _Catalog(
      pages: <List<Album>>[
        <Album>[_album('1', 'Night', 'Artist A')],
      ],
    );
    final AppState state = AppState(catalog: catalog);
    addTearDown(state.dispose);
    await state.signInWithCookie('MUSIC_U=test');
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(brightness: Brightness.dark),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: AppShell(state: state, autoCheckUpdates: false),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('音乐库'));
    await tester.pumpAndSettle();
    final Finder entry = find.byKey(
      const ValueKey<String>('open-saved-albums'),
    );
    expect(entry, findsOneWidget);

    await tester.tap(entry);
    await tester.pumpAndSettle();
    // The library keeps its section while the content pane swaps to the page.
    expect(find.byType(AppSavedAlbumsPage), findsOneWidget);
    expect(find.text('Night'), findsOneWidget);
    expect(find.text('收藏的专辑'), findsOneWidget);

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.byType(AppSavedAlbumsPage), findsNothing);
    expect(entry, findsOneWidget);
  });

  testWidgets('signing in as somebody else replaces the collection', (
    tester,
  ) async {
    final gateway = _Gateway();
    final catalog = _Catalog(
      gateway: gateway,
      pagesForUid: <int, List<List<Album>>>{
        7: <List<Album>>[
          <Album>[_album('1', 'Mine', 'Artist A')],
        ],
        8: <List<Album>>[
          <Album>[_album('2', 'Theirs', 'Artist B')],
        ],
      },
    );
    final state = await _state(tester, catalog);
    await tester.pumpWidget(_page(state));
    await _settle(tester);
    expect(find.text('Mine'), findsOneWidget);

    // Another session owns a different collection: the list must not keep
    // showing the previous account's albums as if they were the new one's.
    gateway.uid = 8;
    await state.signInWithCookie('MUSIC_U=test');
    await _settle(tester);
    expect(find.text('Theirs'), findsOneWidget);
    expect(find.text('Mine'), findsNothing);
    expect(catalog.offsets, <int>[0, 0]);
  });

  testWidgets('album card text participates in the shared cover transition', (
    tester,
  ) async {
    final catalog = _Catalog(
      pages: <List<Album>>[
        <Album>[_album('1', 'Night', 'Artist A')],
      ],
    );
    final state = await _state(tester, catalog);
    await tester.pumpWidget(_page(state));
    await _settle(tester);
    expect(find.byType(CoverTransitionText), findsNWidgets(2));
  });

  testWidgets('a page that claims more without albums stops the walk', (
    tester,
  ) async {
    final catalog = _Catalog()..alwaysEmptyWithMore = true;
    final state = await _state(tester, catalog);
    await tester.pumpWidget(_page(state));
    await _settle(tester);

    expect(find.text('还没有收藏的专辑'), findsOneWidget);
    expect(catalog.offsets, <int>[0]);
  });

  testWidgets('refresh stays reachable while the collection is empty', (
    tester,
  ) async {
    final catalog = _Catalog();
    final state = await _state(tester, catalog);
    await tester.pumpWidget(_page(state));
    await _settle(tester);
    expect(catalog.calls, 1);

    await tester.tap(find.byTooltip('刷新'));
    await _settle(tester);
    expect(catalog.calls, 2);
  });

  testWidgets('a filter that runs out of its page budget says so', (
    tester,
  ) async {
    final List<List<Album>> pages = <List<Album>>[
      for (var index = 0; index < 12; index++)
        <Album>[_album('$index', 'Album $index', 'Artist $index')],
    ];
    final catalog = _Catalog(pages: pages);
    final state = await _state(tester, catalog);
    await tester.pumpWidget(_page(state));
    await _settle(tester);

    await tester.enterText(find.byType(SearchBar), 'zzz');
    for (var frame = 0; frame < 60; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.text('没有找到匹配的专辑，试试更精确的关键词'), findsOneWidget);
    // The walk is bounded: the rest of the collection was never requested.
    expect(catalog.offsets.length, lessThan(pages.length));
  });
}
