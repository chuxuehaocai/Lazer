import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/legacy/legacy_pages.dart';
import 'package:lazer_nextgen/legacy/legacy_player_bar.dart';
import 'package:lazer_nextgen/legacy/legacy_shell.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/widgets/apple_ui.dart';

const Track _track = Track(
  id: 'open-cost',
  title: 'Open cost fixture',
  artist: 'Test artist',
  album: 'Test album',
  duration: Duration(minutes: 3),
  coverSeed: 1,
);

const Playlist _playlist = Playlist(
  id: '1',
  name: 'Open cost playlist',
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

class _TickState extends AppState {
  final ChangeNotifier positionTicks = ChangeNotifier();
  Duration value = Duration.zero;

  @override
  Track? get current => _track;
  @override
  Duration get precisePosition => value;
  late final Listenable _all = Listenable.merge(<Listenable>[
    this,
    positionTicks,
  ]);
  @override
  Listenable get all => _all;

  void tick(Duration position) {
    value = position;
    positionTicks.notifyListeners();
  }

  @override
  void dispose() {
    positionTicks.dispose();
    super.dispose();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('covered transport stops ticking and catches up when revealed', (
    tester,
  ) async {
    final state = _TickState();
    final visible = ValueNotifier<bool>(true);
    addTearDown(state.dispose);
    addTearDown(visible.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLegacyTheme(brightness: Brightness.dark),
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: visible,
            builder: (context, enabled, child) =>
                TickerMode(enabled: enabled, child: child!),
            child: LegacyPlayerBar(state: state, onOpen: () {}),
          ),
        ),
      ),
    );
    LegacyThinSeekBar seekBar() =>
        tester.widget<LegacyThinSeekBar>(find.byType(LegacyThinSeekBar));
    state.tick(const Duration(seconds: 30));
    await tester.pump();
    expect(seekBar().progress, closeTo(1 / 6, 0.001));

    visible.value = false;
    await tester.pump();
    state.tick(const Duration(seconds: 90));
    await tester.pump();
    expect(seekBar().progress, closeTo(1 / 6, 0.001));

    visible.value = true;
    await tester.pump();
    expect(seekBar().progress, closeTo(.5, 0.001));
  });

  testWidgets('player bar skips unrelated reports and parent rebuilds', (
    tester,
  ) async {
    final state = _TickState();
    final parent = ValueNotifier<int>(0);
    addTearDown(state.dispose);
    addTearDown(parent.dispose);
    void open() {}
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLegacyTheme(brightness: Brightness.dark),
        home: Scaffold(
          body: ValueListenableBuilder<int>(
            valueListenable: parent,
            builder: (context, value, _) =>
                LegacyPlayerBar(state: state, onOpen: open),
          ),
        ),
      ),
    );
    var glassBuilds = 0;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      if (element.widget is AppleGlass) glassBuilds++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    await state.setLyricFontSize(26);
    await tester.pump();
    expect(glassBuilds, 0);
    parent.value++;
    await tester.pump();
    expect(glassBuilds, 0);
    state.toggleShuffle();
    await tester.pump();
    expect(glassBuilds, greaterThan(0));
    expect(find.byIcon(Icons.shuffle_rounded), findsOneWidget);
    // A preview does not notify, but an ensuing parent rebuild must see it.
    state.previewVolume(0);
    parent.value++;
    await tester.pump();
    expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cached player bar follows theme and callback changes', (
    tester,
  ) async {
    final state = _TickState();
    addTearDown(state.dispose);
    var first = 0;
    var second = 0;
    void onFirst() => first++;
    void onSecond() => second++;
    Widget app(Brightness brightness, VoidCallback callback) => MaterialApp(
      theme: buildLegacyTheme(brightness: brightness),
      home: Scaffold(
        body: LegacyPlayerBar(state: state, onOpen: callback),
      ),
    );
    await tester.pumpWidget(app(Brightness.dark, onFirst));
    final dark = tester.widget<AppleGlass>(find.byType(AppleGlass)).color;
    await tester.tap(find.text(_track.title));
    expect(first, 1);
    await tester.pumpWidget(app(Brightness.light, onSecond));
    await tester.pumpAndSettle();
    final light = tester.widget<AppleGlass>(find.byType(AppleGlass)).color;
    expect(light, isNot(dark));
    await tester.tap(find.text(_track.title));
    expect(second, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opening the player rebuilds nothing but the player itself', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    state.playQueue(const <Track>[_track]);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLegacyTheme(brightness: Brightness.dark),
        home: LegacyShell(state: state),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    int playerBuilds = 0;
    int browseBuilds = 0;
    debugOnRebuildDirtyWidget = (Element element, bool builtOnce) {
      final Type type = element.widget.runtimeType;
      if (type == NowPlayingPage) playerBuilds++;
      if (type == LegacyHomePage) browseBuilds++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);

    await tester.tap(
      find.descendant(
        of: find.byType(LegacyPlayerBar),
        matching: find.text(_track.title),
      ),
    );
    await tester.pump();
    expect(playerBuilds, 1, reason: 'the player is built once, on its frame');
    expect(
      browseBuilds,
      0,
      reason: 'the page the player is about to cover is not rebuilt',
    );

    // The 300 ms entrance runs, and lands.
    for (int i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      playerBuilds,
      1,
      reason: 'the entrance landing must not rebuild the whole player',
    );
    expect(browseBuilds, 0);
    expect(tester.takeException(), isNull);
  });
}
