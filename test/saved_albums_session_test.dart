import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/catalog_details.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/album_library_page.dart';

AlbumPage _page(String title, {bool more = false}) => AlbumPage(
  albums: [
    Album(
      id: title,
      title: title,
      artist: 'Artist',
      year: '',
      coverSeed: 1,
      note: '',
    ),
  ],
  more: more,
  receivedCount: 1,
);

class _Catalog extends Catalog {
  final requests = <int>[];
  Future<AlbumPage> Function(int)? load;

  @override
  Future<AlbumPage> savedAlbums(int uid, {int offset = 0, bool force = false}) {
    requests.add(uid);
    return load!(uid);
  }
}

class _State extends AppState {
  _State(_Catalog catalog) : super(catalog: catalog);
  int uid = 1;
  String source = 'first-platform';
  @override
  bool get isGuest => uid == 0;
  @override
  SessionUser get user => SessionUser(
    name: 'User',
    handle: 'user',
    method: AuthMethod.cookie,
    detail: '',
    userId: uid,
  );
  @override
  String get activeContentKey => source;

  void session({required int user, String? platform}) {
    uid = user;
    if (platform != null) source = platform;
    notifyListeners();
  }
}

Widget _host(_State state) => MaterialApp(
  theme: buildAppleTheme(),
  home: Scaffold(body: AppSavedAlbumsPage(state: state)),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a matching first page still lets search reach later matches', (
    tester,
  ) async {
    final catalog = _Catalog();
    catalog.load = (_) async => switch (catalog.requests.length) {
      1 => _page('Wanted first', more: true),
      2 => _page('Unrelated', more: true),
      _ => _page('Wanted last'),
    };
    final state = _State(catalog);
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Wanted');
    await tester.pump(const Duration(milliseconds: 300));
    expect(catalog.requests, hasLength(1));
    await tester.tap(find.text('加载更多专辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加载更多专辑'));
    await tester.pumpAndSettle();
    expect(find.text('Wanted first'), findsOneWidget);
    expect(find.text('Wanted last'), findsOneWidget);
    expect(find.text('Unrelated'), findsNothing);
    expect(find.text('加载更多专辑'), findsNothing);
  });

  testWidgets(
    'bounded empty searches can explicitly continue beyond the budget',
    (tester) async {
      final catalog = _Catalog();
      catalog.load = (_) async => catalog.requests.length < 10
          ? _page('Album ${catalog.requests.length}', more: true)
          : _page('Needle');
      final state = _State(catalog);
      addTearDown(state.dispose);
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Ne');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(find.byType(TextField), 'Needle');
      expect(catalog.requests, hasLength(1));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(catalog.requests, hasLength(9));
      expect(find.text('Needle'), findsOneWidget); // The search input only.
      await tester.tap(find.text('加载更多专辑'));
      await tester.pumpAndSettle();
      expect(catalog.requests, hasLength(10));
      expect(find.text('Needle'), findsNWidgets(2));
      expect(find.text('加载更多专辑'), findsNothing);
    },
  );

  testWidgets('account switches invalidate an in-flight saved-album request', (
    tester,
  ) async {
    final old = Completer<AlbumPage>();
    final catalog = _Catalog()
      ..load = (uid) =>
          uid == 1 ? old.future : Future.value(_page('Second account'));
    final state = _State(catalog);
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state));
    state.session(user: 2);
    await tester.pump();
    old.complete(_page('First account'));
    await tester.pumpAndSettle();
    expect(catalog.requests, [1, 2]);
    expect(find.text('Second account'), findsOneWidget);
    expect(find.text('First account'), findsNothing);
  });

  testWidgets(
    'platform changes reload albums even when the numeric user ID is the same',
    (tester) async {
      var page = _page('First platform');
      final catalog = _Catalog()..load = (_) async => page;
      final state = _State(catalog);
      addTearDown(state.dispose);
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();
      page = _page('Second platform');
      state.session(user: 1, platform: 'second-platform');
      await tester.pumpAndSettle();
      expect(catalog.requests, [1, 1]);
      expect(find.text('Second platform'), findsOneWidget);
      expect(find.text('First platform'), findsNothing);
    },
  );

  testWidgets(
    'signing out clears an old request before the same account signs back in',
    (tester) async {
      final old = Completer<AlbumPage>();
      var first = true;
      final catalog = _Catalog()
        ..load = (_) {
          if (first) {
            first = false;
            return old.future;
          }
          return Future.value(_page('Fresh login'));
        };
      final state = _State(catalog);
      addTearDown(state.dispose);
      await tester.pumpWidget(_host(state));
      state.session(user: 0);
      await tester.pump();
      old.complete(_page('Previous login'));
      await tester.pumpAndSettle();
      state.session(user: 1);
      await tester.pumpAndSettle();
      expect(catalog.requests, [1, 1]);
      expect(find.text('Fresh login'), findsOneWidget);
      expect(find.text('Previous login'), findsNothing);
    },
  );

  testWidgets('replacing AppState moves saved-album ownership and listeners', (
    tester,
  ) async {
    final old = Completer<AlbumPage>();
    final firstCatalog = _Catalog()..load = (_) => old.future;
    final nextCatalog = _Catalog()
      ..load = (_) async => _page('Replacement state');
    final first = _State(firstCatalog);
    final next = _State(nextCatalog);
    addTearDown(first.dispose);
    addTearDown(next.dispose);
    await tester.pumpWidget(_host(first));
    await tester.pumpWidget(_host(next));
    old.complete(_page('Replaced state'));
    await tester.pumpAndSettle();
    expect(nextCatalog.requests, [1]);
    expect(find.text('Replacement state'), findsOneWidget);
    expect(find.text('Replaced state'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    first.session(user: 2);
    expect(tester.takeException(), isNull);
  });
}
