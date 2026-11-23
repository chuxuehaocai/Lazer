import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/audio/system_media_handler.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/l10n/app_localizations.dart';
import 'package:lazer_nextgen/main.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/home_pages.dart';
import 'package:lazer_nextgen/ui/shell.dart';

Track _track(int index) => Track(
  id: 'track-$index',
  title: 'Track $index',
  artist: 'Artist',
  album: 'Album',
  duration: const Duration(minutes: 3),
  coverSeed: index,
);

List<Track> _tracks([int count = 4]) =>
    List<Track>.generate(count, _track, growable: false);

List<MusicChart> _charts() => List<MusicChart>.generate(
  4,
  (index) => MusicChart(
    id: 'chart-$index',
    title: 'Chart $index',
    source: 'test',
    issueLabel: 'Today',
    entries: const <ChartEntry>[],
  ),
  growable: false,
);

/// A signed-in session whose home feed fills both reported shelves: the four
/// shortcut cards and the chart cover lane.
class _HomeState extends AppState {
  _HomeState({AppLayoutStyle style = AppLayoutStyle.auto}) {
    autoDpiScale = false;
    layoutStyle = style;
    backgroundMode = AppBackgroundMode.off;
    playerBackground = AppBackgroundMode.off;
    discoveryCharts = _charts();
    collections = UserCollections(
      liked: Playlist(
        id: 'liked',
        name: 'Liked',
        trackIds: const <String>['track-0'],
        coverSeed: 0,
        trackCount: 1,
      ),
    );
  }

  final HomeFeed _feed = HomeFeed(
    featuredTracks: _tracks(),
    quick: _tracks(),
    daily: _tracks(),
    playlists: const <Playlist>[],
    albums: const <Album>[],
  );

  @override
  Future<void> bootstrap() async {}
  @override
  bool get autoUpdateCheckDue => false;
  @override
  bool get isLocalPlayback => false;
  @override
  HomeFeed? get home => _feed;
  @override
  bool get signedIn => true;
  @override
  List<Track> get recentTracks => _tracks();
  @override
  Track? get current => null;
  @override
  bool supportsMusic(MusicCapability capability) => true;
}

class _UnusedAudio extends Fake implements AudioEngine {
  @override
  void dispose() {}
}

final Finder _actions = find.byKey(const ValueKey<String>('home-actions'));
final Finder _chartsShelf = find.byKey(const ValueKey<String>('charts'));

Finder _shelfScrollable(Finder shelf) =>
    find.descendant(of: shelf, matching: find.byType(Scrollable));

ScrollableState _shelfState(WidgetTester tester, Finder shelf) =>
    tester.state<ScrollableState>(_shelfScrollable(shelf));

Future<void> _pumpPage(WidgetTester tester, _HomeState state) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppleTheme(),
      home: Scaffold(
        body: AppHomePage(
          state: state,
          onOpenPlaylist: (_) {},
          onPlayTrack: (_, _) {},
          onOpenChart: (_) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpShell(WidgetTester tester, _HomeState state) async {
  await tester.pumpWidget(
    MaterialApp(theme: buildAppleTheme(), home: AppShell(state: state)),
  );
  await tester.pumpAndSettle();
}

/// Mounts the real `LazerApp`: theming, interface scaling, the shared browse
/// backdrop, the shell, retained pages and the route transitions the reported
/// screen ran inside. A harness that stops at the page would miss anything the
/// shell, backdrop or transition wrapper adds above it.
Future<void> _pumpProduction(WidgetTester tester, _HomeState state) async {
  await tester.runAsync(
    () => AppLocalizations.delegate.load(const Locale('en')),
  );
  await tester.pumpWidget(
    LazerApp(
      state: state,
      audio: _UnusedAudio(),
      media: SystemMediaController(state),
      windowFrameEnabled: false,
    ),
  );
  await tester.pumpAndSettle();
}

enum _Host {
  page,
  shell,
  production;

  Future<void> pump(WidgetTester tester, _HomeState state) => switch (this) {
    _Host.page => _pumpPage(tester, state),
    _Host.shell => _pumpShell(tester, state),
    _Host.production => _pumpProduction(tester, state),
  };
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final host in _Host.values) {
    testWidgets('${host.name}: portrait phone shelves answer a swipe', (
      tester,
    ) async {
      tester.view
        ..devicePixelRatio = 3
        ..physicalSize = const Size(1170, 2532)
        ..padding = const FakeViewPadding(top: 44, bottom: 34);
      addTearDown(tester.view.reset);
      final state = _HomeState();
      // LazerApp owns its state and disposes it when the tree unmounts.
      if (host != _Host.production) addTearDown(state.dispose);
      await host.pump(tester, state);

      expect(_actions, findsOneWidget);
      final actionScroll = _shelfState(tester, _actions);
      expect(
        actionScroll.position.maxScrollExtent,
        greaterThan(0),
        reason: 'four 228dp shortcuts must overflow a 390dp phone lane',
      );
      await tester.drag(_actions, const Offset(-160, 0));
      await tester.pumpAndSettle();
      expect(
        actionScroll.position.pixels,
        greaterThan(0),
        reason: 'a horizontal swipe must page the shortcut shelf',
      );

      await tester.scrollUntilVisible(
        _chartsShelf,
        260,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(_chartsShelf, findsOneWidget);
      final chartScroll = _shelfState(tester, _chartsShelf);
      expect(chartScroll.position.maxScrollExtent, greaterThan(0));
      await tester.drag(_chartsShelf, const Offset(-160, 0));
      await tester.pumpAndSettle();
      expect(
        chartScroll.position.pixels,
        greaterThan(0),
        reason: 'a horizontal swipe must page the chart cover shelf',
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('portrait phone: the feed pages vertically over both shelves', (
    tester,
  ) async {
    tester.view
      ..devicePixelRatio = 3
      ..physicalSize = const Size(1170, 2532)
      ..padding = const FakeViewPadding(top: 44, bottom: 34);
    addTearDown(tester.view.reset);
    final state = _HomeState();
    await _pumpProduction(tester, state);

    final pageScroll = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    // The swipe starts on the shortcut lane: the vertical drag must reach the
    // page instead of dying on the shelf that fills that band.
    await tester.drag(_actions, const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(
      pageScroll.position.pixels,
      greaterThan(0),
      reason: 'a vertical swipe on the shortcut lane must page the home feed',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('landscape phone: the shortcut row keeps a scrollable lane', (
    tester,
  ) async {
    // A phone on its side is 844x390 logical, and with the default auto layout
    // it is not the compact presentation: the row used to be stretched to
    // exactly the viewport here, so it answered no swipe at all.
    tester.view
      ..devicePixelRatio = 3
      ..physicalSize = const Size(2532, 1170)
      ..padding = const FakeViewPadding(top: 0, bottom: 20);
    addTearDown(tester.view.reset);
    final state = _HomeState();
    await _pumpProduction(tester, state);

    expect(
      tester.getSize(find.byType(FilledCoverCard).first).width,
      228,
      reason: 'the phone shelf card, not a squeezed fitted card',
    );
    final actionScroll = _shelfState(tester, _actions);
    expect(
      actionScroll.position.maxScrollExtent,
      greaterThan(0),
      reason: 'a landscape phone must still have somewhere to swipe to',
    );
    await tester.drag(_actions, const Offset(-160, 0));
    await tester.pumpAndSettle();
    expect(actionScroll.position.pixels, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop window still fills the four-across row', (tester) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(1280, 800);
    addTearDown(tester.view.reset);
    final state = _HomeState(style: AppLayoutStyle.desktop);
    await _pumpProduction(tester, state);

    final actionScroll = _shelfState(tester, _actions);
    expect(
      actionScroll.position.maxScrollExtent,
      0,
      reason: 'a 1280px window keeps the fitted row and its arrow paging',
    );
    final cards = find.byType(FilledCoverCard);
    expect(cards, findsNWidgets(4));
    expect(tester.getSize(cards.first).width, tester.getSize(cards.last).width);
    expect(
      tester.getBottomRight(cards.last).dx,
      closeTo(tester.getBottomRight(_actions).dx, .1),
      reason: 'the last card stays flush with the content lane',
    );
    expect(tester.takeException(), isNull);
  });
}
