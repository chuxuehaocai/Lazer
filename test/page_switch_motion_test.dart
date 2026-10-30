import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/legacy/legacy_background.dart';
import 'package:lazer_nextgen/legacy/legacy_pages.dart';
import 'package:lazer_nextgen/legacy/legacy_shell.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/state/app_state.dart';

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
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
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
  theme: buildLegacyTheme(brightness: Brightness.dark),
  home: home,
);

Future<AppState> _phoneShell(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final AppState state = AppState(catalog: _Catalog());
  addTearDown(state.dispose);
  state.playQueue(const <Track>[_track]);
  await tester.pumpWidget(_app(LegacyShell(state: state)));
  await tester.pump(const Duration(milliseconds: 200));
  return state;
}

/// Runs the mirrored switch motion to its end. A ticker only learns where it
/// started on its first tick, so the first frame after the tap cannot finish.
Future<void> _settleSwitch(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
  await tester.pump(const Duration(milliseconds: 420));
}

Future<void> _openSearch(WidgetTester tester) async {
  await tester.tap(
    find.descendant(
      of: find.byType(NavigationBar),
      matching: find.byIcon(Icons.search_outlined),
    ),
  );
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
    await _phoneShell(tester);
    final switcher = tester.widget<AnimatedSwitcher>(
      find
          .ancestor(
            of: find.byType(LegacyHomePage),
            matching: find.byType(AnimatedSwitcher),
          )
          .first,
    );
    final buildTransition = switcher.transitionBuilder;
    await tester.pumpWidget(const SizedBox.shrink());
    final animation = _StatusTrackedAnimation();
    for (var rebuild = 0; rebuild < 10; rebuild++) {
      await tester.pumpWidget(
        _app(buildTransition(Text('Page $rebuild'), animation)),
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
            of: find.byType(LegacyAlbumBackdrop),
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
    expect(find.byType(LegacySearchPage), findsOneWidget);

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
      if (element.widget is LegacySearchPage) pageBuilds++;
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
