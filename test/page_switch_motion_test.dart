import 'support/music_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/ui/background.dart';
import 'package:lazer_nextgen/ui/pages.dart';
import 'package:lazer_nextgen/ui/shell.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/animation/motion_snapshot.dart';

const Track _track = Track(
  id: 'switch-a',
  title: 'Switch fixture',
  artist: 'Test artist',
  album: 'Test album',
  duration: Duration(minutes: 3),
  coverSeed: 1,
);

const Track _other = Track(
  id: 'switch-b',
  title: 'Second fixture',
  artist: 'Test artist',
  album: 'Test album',
  duration: Duration(minutes: 2),
  coverSeed: 2,
);

const Playlist _playlist = Playlist(
  id: '1',
  name: 'Switch playlist',
  trackIds: <String>[],
  coverSeed: 1,
  trackCount: 1,
);

class _Catalog extends Catalog {
  _Catalog() : super(gateway: TestMusicGateway());
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
    bool Function()? isCancelled,
  }) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async =>
      const GatewayLyrics(lrc: '[00:00.00]First lyric\n[00:05.00]Second lyric');
  @override
  HomeFeed? get home => const HomeFeed(
    recommended: <Playlist>[_playlist],
    featured: Album(
      id: '9',
      title: 'Fixture album',
      artist: 'Test artist',
      year: '2024',
      coverSeed: 1,
      note: '',
    ),
    featuredTracks: <Track>[_track],
    quick: <Track>[_track],
    playlists: <Playlist>[_playlist],
    albums: <Album>[],
  );
}

Widget _app(Widget home) => MaterialApp(
  theme: buildAppleTheme(brightness: Brightness.dark),
  home: home,
);

Future<AppState> _phoneShell(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final AppState state = AppState(catalog: _Catalog());
  addTearDown(state.dispose);
  // The ambient mesh is opt-in now; this test measures its scheduling.
  state.backgroundMode = AppBackgroundMode.nowPlayingDynamic;
  state.playQueue(const <Track>[_track]);
  await tester.pumpWidget(_app(AppShell(state: state)));
  await tester.pump(const Duration(milliseconds: 200));
  return state;
}

/// Wait for the page spring itself. The ambient canvas resumes continuously
/// afterward, so pumpAndSettle would wait for an unrelated perpetual animation.
Future<void> _settleSwitch(WidgetTester tester) async {
  await tester.pump();
  for (var frame = 0; frame < 120; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
    final moving = tester
        .widgetList<MotionSnapshot>(find.byType(MotionSnapshot))
        .any(
          (snapshot) =>
              snapshot.animation.status == AnimationStatus.forward ||
              snapshot.animation.status == AnimationStatus.reverse,
        );
    if (!moving) {
      await tester.pump();
      return;
    }
  }
  fail('The page spring did not release its transition snapshot.');
}

Future<void> _openSearch(WidgetTester tester) async {
  await tester.tap(find.byTooltip('搜索'));
}

class _StatusTrackedAnimation extends AlwaysStoppedAnimation<double> {
  _StatusTrackedAnimation() : super(1);

  final statusListeners = <AnimationStatusListener>{};

  @override
  void addStatusListener(AnimationStatusListener listener) =>
      statusListeners.add(listener);

  @override
  void removeStatusListener(AnimationStatusListener listener) =>
      statusListeners.remove(listener);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('rebuilding a page transition releases its animation listeners', (
    tester,
  ) async {
    final animation = _StatusTrackedAnimation();
    for (var rebuild = 0; rebuild < 10; rebuild++) {
      await tester.pumpWidget(
        _app(
          MotionSnapshot(animation: animation, child: Text('Page $rebuild')),
        ),
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
    expect(
      animation.statusListeners,
      isEmpty,
      reason:
          'State reports must not accumulate listeners until the next page switch.',
    );
  });

  testWidgets('a page switch parks the ambient mesh until it lands', (
    tester,
  ) async {
    await _phoneShell(tester);
    TickerMode backdrop() => tester.widget<TickerMode>(
      find
          .ancestor(
            of: find.byType(AppAlbumBackdrop),
            matching: find.byType(TickerMode),
          )
          .first,
    );
    expect(backdrop().enabled, isTrue);

    await _openSearch(tester);
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      backdrop().enabled,
      isFalse,
      reason: 'the whole-window mesh must not repaint during the switch',
    );
    expect(find.byType(AppSearchPage), findsOneWidget);

    await _settleSwitch(tester);
    expect(backdrop().enabled, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('playback reports wait for a running switch to land', (
    tester,
  ) async {
    final AppState state = await _phoneShell(tester);
    int pageBuilds = 0;
    debugOnRebuildDirtyWidget = (Element element, bool builtOnce) {
      if (element.widget is AppSearchPage) pageBuilds++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);

    await _openSearch(tester);
    await tester.pump(const Duration(milliseconds: 16));
    pageBuilds = 0;

    // Ten reports a second is what playback looks like from here.
    for (int i = 0; i < 6; i++) {
      state.notifyListeners();
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      pageBuilds,
      0,
      reason: 'the incoming page must not rebuild while the switch animates',
    );

    await _settleSwitch(tester);
    state.notifyListeners();
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      pageBuilds,
      greaterThan(0),
      reason: 'the page must follow the state again once the switch landed',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a report folded into the switch still reaches the chrome', (
    tester,
  ) async {
    final AppState state = await _phoneShell(tester);
    await _openSearch(tester);
    await tester.pump(const Duration(milliseconds: 16));

    state.playQueue(const <Track>[_other]);
    await tester.pump(const Duration(milliseconds: 16));
    await _settleSwitch(tester);
    expect(find.text(_other.title), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
