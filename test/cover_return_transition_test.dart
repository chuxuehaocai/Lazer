import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/legacy/legacy_pages.dart';
import 'package:lazer_nextgen/legacy/legacy_shell.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/legacy/legacy_widgets.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/widgets/cover_transition.dart';
import 'package:lazer_nextgen/widgets/retained_content_switcher.dart';

const _forwardKey = ValueKey<String>('cover-transition-flight');
const _returnKey = ValueKey<String>('cover-transition-return-flight');

class _ReturnHarness extends StatefulWidget {
  const _ReturnHarness({this.reducedMotion = false, this.artwork});
  final bool reducedMotion;
  final Widget? artwork;

  @override
  State<_ReturnHarness> createState() => _ReturnHarnessState();
}

class _ReturnHarnessState extends State<_ReturnHarness> {
  GlobalKey source = GlobalKey();
  final ValueNotifier<Offset> sourceOffset = ValueNotifier(
    const Offset(20, 24),
  );
  bool open = false;
  bool sourceRemoved = false;

  void enter() {
    rememberCoverTransition('return-fixture', source);
    setState(() => open = true);
  }

  void back() {
    returnCoverTransition('return-fixture');
    setState(() => open = false);
  }

  void moveSource(Offset offset, {bool replaceKey = false}) {
    if (replaceKey) source = GlobalKey();
    sourceOffset.value = offset;
  }

  void removeSource() {
    sourceRemoved = true;
    sourceOffset.value += const Offset(1, 0);
  }

  @override
  void dispose() {
    cancelCoverTransitions();
    sourceOffset.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: widget.reducedMotion),
      child: Scaffold(
        body: RetainedContentSwitcher(
          currentKey: open ? 'detail' : 'root',
          retainKeys: open ? const {'root'} : const {},
          duration: widget.reducedMotion
              ? Duration.zero
              : const Duration(milliseconds: 420),
          page: open
              ? Stack(
                  children: [
                    Positioned(
                      left: 300,
                      top: 160,
                      child: CoverTransitionTarget(
                        identity: 'return-fixture',
                        size: 190,
                        child:
                            widget.artwork ??
                            const ColoredBox(color: Colors.teal),
                      ),
                    ),
                  ],
                )
              : ValueListenableBuilder<Offset>(
                  valueListenable: sourceOffset,
                  builder: (context, offset, _) => Stack(
                    children: [
                      if (!sourceRemoved)
                        Positioned(
                          left: offset.dx,
                          top: offset.dy,
                          child: CoverTransitionSource(
                            key: source,
                            identity: 'return-fixture',
                            child: const SizedBox.square(
                              dimension: 90,
                              child: ColoredBox(color: Colors.teal),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
        ),
      ),
    ),
  );
}

class _ArtworkCounts {
  int builds = 0;
  int layouts = 0;
}

class _ArtworkProbe extends StatelessWidget {
  const _ArtworkProbe(this.counts);
  final _ArtworkCounts counts;

  @override
  Widget build(BuildContext context) {
    counts.builds++;
    return _LayoutProbe(
      counts: counts,
      child: ColoredBox(color: Theme.of(context).colorScheme.primary),
    );
  }
}

class _LayoutProbe extends SingleChildRenderObjectWidget {
  const _LayoutProbe({required this.counts, required super.child});
  final _ArtworkCounts counts;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderLayoutProbe(counts);
}

class _RenderLayoutProbe extends RenderProxyBox {
  _RenderLayoutProbe(this.counts);
  final _ArtworkCounts counts;

  @override
  void performLayout() {
    counts.layouts++;
    super.performLayout();
  }
}

const _playlist = Playlist(
  id: 'return-playlist',
  name: 'Return playlist',
  trackIds: [],
  coverSeed: 1,
  trackCount: 1,
);
const _track = Track(
  id: 'return-track',
  title: 'Return fixture song',
  artist: 'Fixture artist',
  album: 'Fixture album',
  duration: Duration(minutes: 3),
  coverSeed: 1,
);

class _Catalog extends Catalog {
  int requests = 0;

  @override
  HomeFeed? get home => const HomeFeed(
    recommended: [_playlist],
    featured: Album(
      id: 'fixture-album',
      title: 'Fixture album',
      artist: 'Fixture artist',
      year: '2026',
      coverSeed: 1,
      note: '',
    ),
    featuredTracks: [_track],
    quick: [_track],
    playlists: [_playlist],
    albums: [],
  );

  @override
  Future<List<Track>?> cachedPlaylistTracks(String id) async => null;

  @override
  Future<List<Track>> playlistTracks(String id) async {
    requests++;
    return [_track];
  }
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
  await tester.pump(const Duration(milliseconds: 440));
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(cancelCoverTransitions);

  testWidgets('return flies from detail into the live source and reveals it', (
    tester,
  ) async {
    await tester.pumpWidget(const _ReturnHarness());
    final state = tester.state<_ReturnHarnessState>(
      find.byType(_ReturnHarness),
    );
    final sourceRect = tester.getRect(find.byKey(state.source));
    state.enter();
    await _settle(tester);
    final detailRect = tester.getRect(find.byType(CoverTransitionTarget));
    state.back();
    await tester.pump();
    await tester.pump();
    expect(tester.getRect(find.byKey(_returnKey)), detailRect);
    final hiddenSource = find.descendant(
      of: find.byKey(state.source),
      matching: find.byType(Opacity),
    );
    expect(tester.widget<Opacity>(hiddenSource).opacity, 0);
    await tester.pump(const Duration(milliseconds: 84));
    final early = tester.getRect(find.byKey(_returnKey));
    expect(early.left, lessThan((detailRect.left + sourceRect.left) / 2));
    await tester.pump(const Duration(milliseconds: 340));
    await tester.pump();
    expect(find.byKey(_returnKey), findsNothing);
    expect(tester.widget<Opacity>(hiddenSource).opacity, 1);
    expect(tester.getRect(find.byKey(state.source)), sourceRect);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fast back starts at the in-flight artwork and can reopen', (
    tester,
  ) async {
    await tester.pumpWidget(const _ReturnHarness());
    final state = tester.state<_ReturnHarnessState>(
      find.byType(_ReturnHarness),
    );
    state.enter();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 84));
    final visibleRect = tester.getRect(find.byKey(_forwardKey));
    state.back();
    await tester.pump();
    await tester.pump();
    expect(tester.getRect(find.byKey(_returnKey)), visibleRect);
    expect(find.byKey(_forwardKey), findsNothing);
    await tester.pump(const Duration(milliseconds: 80));
    state.enter();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(_returnKey), findsNothing);
    expect(find.byKey(_forwardKey), findsOneWidget);
    await _settle(tester);
    expect(find.byKey(_forwardKey), findsNothing);
    expect(find.byType(CoverTransitionTarget), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('return flight transforms do not rebuild or relayout artwork', (
    tester,
  ) async {
    final counts = _ArtworkCounts();
    await tester.pumpWidget(_ReturnHarness(artwork: _ArtworkProbe(counts)));
    final state = tester.state<_ReturnHarnessState>(
      find.byType(_ReturnHarness),
    );
    state.enter();
    await _settle(tester);
    state.back();
    await tester.pump();
    await tester.pump();
    final flight = find.byKey(_returnKey);
    expect(flight, findsOneWidget);
    final takeoffBuilds = counts.builds;
    final takeoffLayouts = counts.layouts;
    expect(takeoffBuilds, greaterThanOrEqualTo(3));
    expect(takeoffLayouts, greaterThanOrEqualTo(3));
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 30));
      expect(flight, findsOneWidget);
      expect(counts.builds, takeoffBuilds);
      expect(counts.layouts, takeoffLayouts);
    }
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(flight, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion returns immediately without hiding source', (
    tester,
  ) async {
    await tester.pumpWidget(const _ReturnHarness(reducedMotion: true));
    final state = tester.state<_ReturnHarnessState>(
      find.byType(_ReturnHarness),
    );
    state.enter();
    await tester.pump();
    await tester.pump();
    state.back();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(_returnKey), findsNothing);
    expect(find.byKey(_forwardKey), findsNothing);
    expect(find.byKey(state.source), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('return follows the rebuilt source instead of its old rectangle', (
    tester,
  ) async {
    await tester.pumpWidget(const _ReturnHarness());
    final state = tester.state<_ReturnHarnessState>(
      find.byType(_ReturnHarness),
    );
    state.enter();
    await _settle(tester);
    // A resize/DPI reflow may recreate the local key and change card position.
    state.moveSource(const Offset(140, 120), replaceKey: true);
    await tester.pump();
    state.back();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(_returnKey), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));
    state.moveSource(const Offset(210, 100));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final destination = tester.getRect(find.byKey(state.source));
    final flying = tester.getRect(find.byKey(_returnKey));
    expect((flying.topLeft - destination.topLeft).distance, lessThan(2));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();
    expect(find.byKey(_returnKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a recycled source skips the return flight and leaves no overlay',
    (tester) async {
      await tester.pumpWidget(const _ReturnHarness());
      final state = tester.state<_ReturnHarnessState>(
        find.byType(_ReturnHarness),
      );
      state.enter();
      await _settle(tester);
      state.removeSource();
      await tester.pump();
      state.back();
      await _settle(tester);
      expect(find.byKey(_returnKey), findsNothing);
      expect(find.byKey(_forwardKey), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('closing the shell during a return removes the overlay', (
    tester,
  ) async {
    await tester.pumpWidget(const _ReturnHarness());
    final state = tester.state<_ReturnHarnessState>(
      find.byType(_ReturnHarness),
    );
    state.enter();
    await _settle(tester);
    state.back();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(_returnKey), findsOneWidget);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await _settle(tester);
    expect(find.byKey(_returnKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shell retains the scrolled shelf and returns with system Back', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final catalog = _Catalog();
    final state = AppState(catalog: catalog);
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLegacyTheme(),
        home: LegacyShell(state: state),
      ),
    );
    await tester.pump();
    final card = find.byType(LegacyPlaylistCard).first;
    await tester.ensureVisible(card);
    await _settle(tester);
    final homeState = tester.state(find.byType(LegacyHomePage));
    final sourceRect = tester.getRect(card);
    final scroll = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(LegacyHomePage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    final savedOffset = scroll.position.pixels;
    await tester.tap(card);
    await _settle(tester);
    expect(find.byType(LegacyPlaylistPage), findsOneWidget);
    expect(catalog.requests, 1);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(_returnKey), findsOneWidget);
    await _settle(tester);
    expect(tester.state(find.byType(LegacyHomePage)), same(homeState));
    expect(scroll.position.pixels, savedOffset);
    expect(tester.getRect(card), sourceRect);
    expect(find.byType(LegacyPlaylistPage), findsNothing);
    expect(find.byKey(_returnKey), findsNothing);
    // The toolbar uses the same return path as system/remote Back.
    await tester.tap(card);
    await _settle(tester);
    await tester.tap(find.byTooltip('返回'));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(_returnKey), findsOneWidget);
    await _settle(tester);
    expect(tester.state(find.byType(LegacyHomePage)), same(homeState));
    expect(scroll.position.pixels, savedOffset);
    expect(tester.takeException(), isNull);
  });
}
