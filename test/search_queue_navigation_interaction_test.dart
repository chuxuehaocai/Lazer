import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/search_page.dart';
import 'package:lazer_nextgen/widgets/apple_ui.dart';
import 'package:lazer_nextgen/widgets/capsule_navigation_bar.dart';
import 'package:lazer_nextgen/widgets/playback_queue_view.dart';
import 'package:lazer_nextgen/widgets/track_batch_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

Track _track(int index) => Track(
  id: 'ui-$index',
  title: 'Song $index',
  artist: 'Artist',
  album: 'Album',
  duration: const Duration(minutes: 3),
  coverSeed: index,
);

class _CountingTicks extends ChangeNotifier {
  int subscriptions = 0;

  @override
  void addListener(VoidCallback listener) {
    subscriptions++;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    subscriptions--;
    super.removeListener(listener);
  }
}

class _InteractionState extends AppState {
  final requests = <String>[];
  final played = <int>[];
  Future<SearchResults> Function(String)? searchHandler;
  bool local = false;
  String source = 'cloud';
  List<Track> tracks = [];
  int index = 0;
  bool isPlaying = false;
  final tickLane = _CountingTicks();

  @override
  Listenable get ticks => tickLane;

  @override
  bool get isLocalPlayback => local;
  @override
  String get activeContentKey => source;
  @override
  List<Track> get queue => tracks;
  @override
  int get queueLength => tracks.length;
  @override
  int get queueIndex => index;
  @override
  Track? get current => tracks.isEmpty ? null : tracks[index];
  @override
  bool get playing => isPlaying;
  @override
  void playTrackAt(int index) => played.add(index);

  @override
  Future<SearchResults> search(String query) {
    requests.add(query);
    return searchHandler?.call(query) ?? Future.value(SearchResults.empty);
  }

  void changeCurrent(int value) {
    index = value;
    notifyListeners();
  }

  @override
  void dispose() {
    super.dispose();
    tickLane.dispose();
  }
}

Widget _host(
  Widget child, {
  double width = 600,
  double scale = 1,
  bool reduced = true,
}) => MaterialApp(
  theme: buildAppleTheme().copyWith(platform: TargetPlatform.windows),
  home: MediaQuery(
    data: MediaQueryData(
      size: Size(width, 560),
      textScaler: TextScaler.linear(scale),
      disableAnimations: reduced,
    ),
    child: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: width, height: 560, child: child),
      ),
    ),
  ),
);

Widget _search(_InteractionState state) =>
    AppSearchPage(state: state, onOpenPlaylist: (_) {});

Future<void> _submit(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField), query);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('search clear works without a custom callback', (tester) async {
    final controller = TextEditingController(text: 'something');
    addTearDown(controller.dispose);
    final changes = <String>[];
    await tester.pumpWidget(
      _host(AppleSearchField(controller: controller, onChanged: changes.add)),
    );
    await tester.tap(find.byTooltip('清除'));
    await tester.pump();
    expect(controller.text, isEmpty);
    expect(changes, ['']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('search tabs fit narrow windows with large text', (tester) async {
    final state = _InteractionState()
      ..searchHandler = (_) async => SearchResults(tracks: [_track(0)]);
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(_search(state), width: 320, scale: 2));
    await _submit(tester, 'song');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Song 0'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a query with only artist hits opens the populated category', (
    tester,
  ) async {
    final state = _InteractionState()
      ..searchHandler = (_) async =>
          const SearchResults(artists: [ArtistRef(id: 1, name: 'Only artist')]);
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(_search(state)));
    await _submit(tester, 'artist');
    await tester.pumpAndSettle();
    expect(find.text('Only artist'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('switching from cloud artists to local search shows songs', (
    tester,
  ) async {
    final cloud = _InteractionState()
      ..searchHandler = (_) async => const SearchResults(
        artists: [ArtistRef(id: 1, name: 'Cloud artist')],
      );
    final local = _InteractionState()
      ..local = true
      ..source = 'local'
      ..searchHandler = (_) async => SearchResults(tracks: [_track(7)]);
    addTearDown(cloud.dispose);
    addTearDown(local.dispose);
    await tester.pumpWidget(_host(_search(cloud)));
    await _submit(tester, 'music');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '歌手'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_host(_search(local)));
    await tester.pumpAndSettle();
    expect(find.text('Song 7'), findsOneWidget);
    expect(find.text('Cloud artist'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'search retry uses the committed query and rejects late results',
    (tester) async {
      final first = Completer<SearchResults>();
      var failures = 0;
      final state = _InteractionState()
        ..searchHandler = (query) {
          if (query == 'old') return first.future;
          if (query == 'new' && failures == 0) {
            failures++;
            return Future.error(StateError('offline'));
          }
          return Future.value(SearchResults(tracks: [_track(2)]));
        };
      addTearDown(state.dispose);
      await tester.pumpWidget(_host(_search(state)));
      await _submit(tester, 'old');
      await _submit(tester, 'new');
      await tester.pumpAndSettle();
      expect(find.text('搜索失败，请检查网络后重试。'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      first.complete(SearchResults(tracks: [_track(1)]));
      await tester.pumpAndSettle();
      expect(state.requests, ['old', 'new', 'new']);
      expect(find.text('Song 2'), findsOneWidget);
      expect(find.text('Song 1'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'duplicate submits coalesce and clearing invalidates pending search',
    (tester) async {
      final pending = Completer<SearchResults>();
      final state = _InteractionState()..searchHandler = (_) => pending.future;
      addTearDown(state.dispose);
      await tester.pumpWidget(_host(_search(state)));
      await _submit(tester, 'pending');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(state.requests, ['pending']);
      await tester.tap(find.byTooltip('清除'));
      await tester.pump();
      pending.complete(SearchResults(tracks: [_track(99)]));
      await tester.pumpAndSettle();
      expect(find.text('Song 99'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('an empty queue explains its state', (tester) async {
    final state = _InteractionState();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(PlaybackQueueView(state: state)));
    expect(find.text('播放队列为空。'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('queue rows fit narrow panels with triple-size text', (
    tester,
  ) async {
    final state = _InteractionState()..tracks = [_track(0)];
    addTearDown(state.dispose);
    await tester.pumpWidget(
      _host(
        PlaybackQueueView(state: state, showHeader: false),
        width: 200,
        scale: 3,
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Song 0'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'search categories work with Tab and Enter and explain empty tabs',
    (tester) async {
      final state = _InteractionState()
        ..searchHandler = (_) async => SearchResults(tracks: [_track(0)]);
      addTearDown(state.dispose);
      await tester.pumpWidget(_host(_search(state)));
      await _submit(tester, 'song');
      await tester.pumpAndSettle();
      final target = tester.element(find.widgetWithText(TextButton, '专辑'));
      var focused = false;
      for (var step = 0; step < 10 && !focused; step++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        FocusManager.instance.primaryFocus?.context?.visitAncestorElements((
          element,
        ) {
          if (identical(element, target)) focused = true;
          return !focused;
        });
      }
      expect(focused, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('没有找到相关结果。'), findsOneWidget);
      expect(find.text('Song 0'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'queue changes preserve scrolling until the locate action is used',
    (tester) async {
      final state = _InteractionState()..tracks = List.generate(80, _track);
      addTearDown(state.dispose);
      await tester.pumpWidget(_host(PlaybackQueueView(state: state)));
      state.changeCurrent(60);
      await tester.pumpAndSettle();
      expect(find.text('Song 0'), findsOneWidget);
      expect(find.text('Song 60'), findsNothing);
      await tester.tap(find.byTooltip('定位正在播放'));
      await tester.pumpAndSettle();
      expect(find.text('Song 60'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('changing source invalidates a search on the same AppState', (
    tester,
  ) async {
    final old = Completer<SearchResults>();
    final state = _InteractionState();
    state.searchHandler = (_) => state.source == 'cloud'
        ? old.future
        : Future.value(SearchResults(tracks: [_track(4)]));
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(_search(state)));
    await _submit(tester, 'music');
    state.source = 'another-provider';
    state.notifyListeners();
    await tester.pumpAndSettle();
    old.complete(SearchResults(tracks: [_track(3)]));
    await tester.pumpAndSettle();
    expect(find.text('Song 4'), findsOneWidget);
    expect(find.text('Song 3'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('hidden queue indicators stop listening to playback ticks', (
    tester,
  ) async {
    final state = _InteractionState()
      ..tracks = [_track(0)]
      ..isPlaying = true;
    addTearDown(state.dispose);
    await tester.pumpWidget(
      _host(
        TickerMode(enabled: true, child: PlaybackQueueView(state: state)),
        reduced: false,
      ),
    );
    expect(state.tickLane.subscriptions, 1);
    await tester.pumpWidget(
      _host(
        TickerMode(enabled: false, child: PlaybackQueueView(state: state)),
        reduced: false,
      ),
    );
    expect(state.tickLane.subscriptions, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('batch actions are disabled when nothing can be selected', (
    tester,
  ) async {
    var selections = 0;
    var downloads = 0;
    await tester.pumpWidget(
      _host(
        TrackBatchBar(
          selectedCount: 0,
          totalCount: 0,
          onSelectAll: () => selections++,
          onDownload: () => downloads++,
          onClose: () {},
        ),
        width: 280,
        scale: 2,
      ),
    );
    expect(find.text('全选'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('batch-select-all')));
    await tester.tap(find.byKey(const ValueKey('batch-download')));
    expect(selections, 0);
    expect(downloads, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('capsule destinations support desktop keyboard activation', (
    tester,
  ) async {
    final selected = <int>[];
    await tester.pumpWidget(
      _host(
        Center(
          child: SizedBox(
            width: 300,
            child: CapsuleNavigationBar(
              selectedIndex: 0,
              blurEnabled: false,
              onDestinationSelected: selected.add,
              destinations: const [
                NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
                NavigationDestination(
                  icon: Icon(Icons.search),
                  label: 'Search',
                ),
                NavigationDestination(
                  icon: Icon(Icons.settings),
                  label: 'Settings',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, [1]);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
