import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/player/desktop_artwork_layout.dart';
import 'package:lazer_nextgen/player/desktop_now_playing.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/tv/tv_mode.dart';

const _track = Track(
  id: 'fold',
  title: 'A song',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 3),
  coverSeed: 3,
);

const _art = ValueKey('fold-art');
const _lyrics = ValueKey('fold-lyrics');

Widget _host(
  AppState state,
  ValueNotifier<DesktopNowPlayingPane> pane, {
  bool disableAnimations = false,
}) => MaterialApp(
  theme: buildAppleTheme(brightness: Brightness.dark),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: disableAnimations),
    child: child!,
  ),
  home: TvScope(
    active: false,
    child: Scaffold(
      body: ValueListenableBuilder<DesktopNowPlayingPane>(
        valueListenable: pane,
        builder: (context, current, _) => DesktopNowPlaying(
          state: state,
          track: _track,
          artwork: const ColoredBox(key: _art, color: Colors.blue),
          lyrics: const ColoredBox(key: _lyrics, color: Colors.red),
          comments: const Text('Comments'),
          queue: const Text('Queue'),
          pane: current,
          onPaneChanged: (value) => pane.value = value,
          onBack: () {},
          onSaveArtwork: () {},
          onFullscreen: () {},
          controlsVisible: true,
          onActivity: () {},
        ),
      ),
    ),
  ),
);

Rect _artRect(WidgetTester tester) => tester.getRect(find.byKey(_art));

Rect _canvasRect(WidgetTester tester) =>
    tester.getRect(find.byType(DesktopArtworkLayout));

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  testWidgets('folding the lyrics centres and grows the artwork', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState();
    final pane = ValueNotifier(DesktopNowPlayingPane.lyrics);
    addTearDown(state.dispose);
    addTearDown(pane.dispose);

    await tester.pumpWidget(_host(state, pane));
    await tester.pumpAndSettle();

    final Rect canvas = _canvasRect(tester);
    final Rect rest = _artRect(tester);
    // The two-column spread centres both panes as one group, so the cover sits
    // in the middle of the left column: half a column plus half a gap left of
    // the canvas centre while the lyrics are up.
    final double gap = (canvas.width * .075).clamp(24.0, 110.0);
    final double column = ((canvas.width - gap) / 2).clamp(0.0, 520.0);
    expect(
      rest.center.dx,
      closeTo(canvas.center.dx - column / 2 - gap / 2, .6),
      reason: 'the cover owns the left column before the fold',
    );
    expect(rest.center.dx, lessThan(canvas.center.dx - 100));
    expect(rest.width, closeTo(rest.height, .1));
    expect(_lyricsHitTestable(), findsOneWidget);

    pane.value = DesktopNowPlayingPane.none;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));
    final Rect mid = _artRect(tester);
    expect(mid.width, greaterThan(rest.width));
    expect(mid.width, lessThan(800));
    expect(tester.takeException(), isNull);

    await tester.pumpAndSettle();
    final Rect folded = _artRect(tester);
    expect(folded.center.dx, closeTo(canvas.center.dx, .6));
    expect(folded.width, greaterThan(rest.width));
    expect(folded.width, closeTo(folded.height, .1));
    // The reading pane keeps its geometry while it fades, so its last frame is
    // not a squeezed lyric column.
    expect(tester.getSize(find.byKey(_lyrics)).width, greaterThan(0));
    expect(_lyricsHitTestable(), findsNothing);
    expect(tester.takeException(), isNull);

    pane.value = DesktopNowPlayingPane.lyrics;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));
    expect(_artRect(tester).width, lessThan(folded.width));
    await tester.pumpAndSettle();
    expect(_artRect(tester), rest);
    expect(_lyricsHitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a reversed fold continues from the presented frame', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState();
    final pane = ValueNotifier(DesktopNowPlayingPane.lyrics);
    addTearDown(state.dispose);
    addTearDown(pane.dispose);

    await tester.pumpWidget(_host(state, pane));
    await tester.pumpAndSettle();
    final Rect rest = _artRect(tester);

    pane.value = DesktopNowPlayingPane.none;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final Rect presented = _artRect(tester);
    expect(presented.width, greaterThan(rest.width + 8));

    // Interrupt mid-flight: the retarget frame must present the frame the eye
    // just saw instead of snapping to either endpoint.
    pane.value = DesktopNowPlayingPane.lyrics;
    await tester.pump();
    final Rect retargeted = _artRect(tester);
    expect(retargeted.width, closeTo(presented.width, 2));
    expect(retargeted.center.dx, closeTo(presented.center.dx, 2));

    // The spring keeps the incoming momentum for a moment before it turns
    // around; the point is that it never restarts from an endpoint.
    await tester.pump(const Duration(milliseconds: 500));
    final Rect resuming = _artRect(tester);
    expect(resuming.width, lessThan(presented.width));
    expect(resuming.width, greaterThanOrEqualTo(rest.width - 8));

    await tester.pumpAndSettle();
    expect(_artRect(tester), rest);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a reversed fold resumes from a part-grown cover', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState();
    final pane = ValueNotifier(DesktopNowPlayingPane.none);
    addTearDown(state.dispose);
    addTearDown(pane.dispose);

    // Open folded, then unfold: the spring must start at the folded geometry and
    // never pass through the lyrics-visible endpoint first.
    await tester.pumpWidget(_host(state, pane));
    await tester.pumpAndSettle();
    final Rect folded = _artRect(tester);
    final Rect canvas = _canvasRect(tester);
    expect(folded.center.dx, closeTo(canvas.center.dx, .6));

    pane.value = DesktopNowPlayingPane.lyrics;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final Rect mid = _artRect(tester);
    expect(mid.width, lessThan(folded.width));
    await tester.pumpAndSettle();
    final Rect rest = _artRect(tester);
    expect(rest.center.dx, lessThan(folded.center.dx));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a short canvas still centres the cover when folded', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState();
    final pane = ValueNotifier(DesktopNowPlayingPane.lyrics);
    addTearDown(state.dispose);
    addTearDown(pane.dispose);

    await tester.pumpWidget(_host(state, pane));
    await tester.pumpAndSettle();
    final Rect canvas = _canvasRect(tester);
    final Rect rest = _artRect(tester);
    // The short canvas puts the 72-pixel cover beside the metadata, at the left
    // edge of the reading column.
    expect(rest.width, lessThan(120));
    expect(rest.center.dx, lessThan(canvas.center.dx - 100));

    pane.value = DesktopNowPlayingPane.none;
    await tester.pumpAndSettle();
    final Rect folded = _artRect(tester);
    expect(folded.center.dx, closeTo(canvas.center.dx, .6));
    // The cover leads the block, so the block's centre sits a little below it.
    expect(folded.center.dy, lessThan(canvas.center.dy));
    expect(folded.top, greaterThan(canvas.top + 20));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('reduced motion folds without animation', (tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState();
    final pane = ValueNotifier(DesktopNowPlayingPane.lyrics);
    addTearDown(state.dispose);
    addTearDown(pane.dispose);

    await tester.pumpWidget(_host(state, pane, disableAnimations: true));
    await tester.pumpAndSettle();
    final Rect rest = _artRect(tester);

    pane.value = DesktopNowPlayingPane.none;
    await tester.pump();
    final Rect folded = _artRect(tester);
    expect(folded, isNot(rest));
    expect(folded.center.dx, closeTo(_canvasRect(tester).center.dx, .6));
    await tester.pumpAndSettle();
    expect(_artRect(tester), folded);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Finder _lyricsHitTestable() => find.byKey(_lyrics).hitTestable();
