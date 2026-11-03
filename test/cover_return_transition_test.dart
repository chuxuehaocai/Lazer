import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/ui/pages.dart';
import 'package:lazer_nextgen/ui/shell.dart';
import 'package:lazer_nextgen/ui/player_bar.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/widgets.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/widgets/cover_transition.dart';
import 'package:lazer_nextgen/widgets/retained_content_switcher.dart';
import 'support/player_transition.dart';

const _forwardKey = ValueKey<String>('cover-transition-flight');
const _returnKey = ValueKey<String>('cover-transition-return-flight');

class _ReturnHarness extends StatefulWidget {
  const _ReturnHarness({
    this.reducedMotion = false,
    this.artwork,
    this.scrollAxis,
    this.inset = EdgeInsets.zero,
  });
  final bool reducedMotion;
  final Widget? artwork;
  final Axis? scrollAxis;
  final EdgeInsets inset;

  @override
  State<_ReturnHarness> createState() => _ReturnHarnessState();
}

class _ReturnHarnessState extends State<_ReturnHarness> {
  final screen = GlobalKey();
  GlobalKey source = GlobalKey();
  final ValueNotifier<Offset> sourceOffset = ValueNotifier(
    const Offset(20, 24),
  );
  final scroll = ScrollController();
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
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    builder: (context, child) => RepaintBoundary(key: screen, child: child),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: widget.reducedMotion),
      child: Scaffold(
        backgroundColor: Colors.white,
        body: Padding(
          padding: widget.inset,
          child: RetainedContentSwitcher(
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
                    builder: (context, offset, _) {
                      final content = Stack(
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
                      );
                      final axis = widget.scrollAxis;
                      if (axis == null) return content;
                      return SingleChildScrollView(
                        controller: scroll,
                        scrollDirection: axis,
                        child: SizedBox(
                          width: axis == Axis.horizontal ? 2400 : 800,
                          height: axis == Axis.vertical ? 1800 : 600,
                          child: content,
                        ),
                      );
                    },
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
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => null;

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
  await tester.pumpAndSettle();
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(cancelCoverTransitions);

  testWidgets(
    'opening the player retains the underlying playlist return destination',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      await state.setAppBackground(AppBackgroundMode.off);
      await state.setPlayerBackground(AppBackgroundMode.off);
      state.playQueue(const [_track]);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(),
          home: AppShell(state: state),
        ),
      );
      await tester.pump();
      final card = find.byType(AppPlaylistCard).first;
      await tester.ensureVisible(card);
      await _settle(tester);
      await tester.tap(card);
      await _settle(tester);
      tester.widget<AppPlayerBar>(find.byType(AppPlayerBar)).onOpen();
      await tester.pump();
      final motion = playerSlideAnimation(tester);
      await pumpPlayerTransition(tester, motion, AnimationStatus.completed);
      tester.widget<NowPlayingPage>(find.byType(NowPlayingPage)).onClose!();
      await tester.pump();
      await pumpPlayerTransition(tester, motion, AnimationStatus.dismissed);
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump();
      expect(find.byKey(_returnKey), findsOneWidget);
      await _settle(tester);
      expect(find.byType(AppPlaylistPage), findsNothing);
      expect(card, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('return overlays stay inside the content pane on every frame', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const _ReturnHarness(inset: EdgeInsets.fromLTRB(80, 100, 40, 30)),
    );
    final state = tester.state<_ReturnHarnessState>(
      find.byType(_ReturnHarness),
    );
    // A retained, scrolled card can sit partly above or beside its viewport.
    state.moveSource(const Offset(-55, -70));
    await tester.pump();
    for (final returning in [false, true]) {
      if (returning) {
        state.back();
      } else {
        state.enter();
      }
      await tester.pump();
      for (final milliseconds in [0, 80, 80, 120, 180, 300]) {
        await tester.pump(Duration(milliseconds: milliseconds));
        final pixels = await tester.runAsync(() async {
          final boundary =
              state.screen.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage();
          try {
            final data = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            return data!.buffer.asUint8List();
          } finally {
            image.dispose();
          }
        });
        for (final point in [const Offset(95, 65), const Offset(50, 120)]) {
          final offset = (point.dy.toInt() * 600 + point.dx.toInt()) * 4;
          expect(
            pixels!.sublist(offset, offset + 4),
            [255, 255, 255, 255],
            reason:
                'cover overlays must never paint over chrome or safe insets',
          );
        }
      }
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
  });

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
    expect(
      (tester.getRect(find.byKey(_returnKey)).topLeft - detailRect.topLeft)
          .distance,
      lessThan(.001),
    );
    final hiddenSource = find.descendant(
      of: find.byKey(state.source),
      matching: find.byType(Opacity),
    );
    expect(tester.widget<Opacity>(hiddenSource).opacity, 0);
    await tester.pump(const Duration(milliseconds: 220));
    final early = tester.getRect(find.byKey(_returnKey));
    expect(early.left, lessThan((detailRect.left + sourceRect.left) / 2));
    await tester.pumpAndSettle();
    await tester.pump();
    expect(find.byKey(_returnKey), findsNothing);
    expect(tester.widget<Opacity>(hiddenSource).opacity, 1);
    expect(tester.getRect(find.byKey(state.source)), sourceRect);
    expect(tester.takeException(), isNull);
  });

  for (final axis in Axis.values) {
    testWidgets(
      'scrolling $axis during return restores the cover to its card',
      (tester) async {
        await tester.pumpWidget(_ReturnHarness(scrollAxis: axis));
        final state = tester.state<_ReturnHarnessState>(
          find.byType(_ReturnHarness),
        );
        state.enter();
        await _settle(tester);
        state.back();
        await tester.pump();
        await tester.pump();
        expect(find.byKey(_returnKey), findsOneWidget);
        final scroll = find.byType(SingleChildScrollView).first;
        await tester.drag(
          scroll,
          axis == Axis.vertical ? const Offset(0, -100) : const Offset(-100, 0),
        );
        await tester.pump();
        expect(state.scroll.offset, greaterThan(0));
        expect(
          find.byKey(_returnKey),
          findsNothing,
          reason: 'the artwork must move with the scrolling card immediately',
        );
        final opacity = find.descendant(
          of: find.byKey(state.source),
          matching: find.byType(Opacity),
        );
        expect(tester.widget<Opacity>(opacity).opacity, 1);
        final snapshot = tester.widget<SnapshotWidget>(
          find
              .ancestor(of: scroll, matching: find.byType(SnapshotWidget))
              .first,
        );
        expect(snapshot.controller.allowSnapshotting, isFalse);
        await _settle(tester);
        expect(tester.takeException(), isNull);
      },
    );
  }

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
    expect(
      (tester.getRect(find.byKey(_returnKey)).topLeft - visibleRect.topLeft)
          .distance,
      lessThan(.001),
    );
    expect(find.byKey(_forwardKey), findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    expect(
      tester.getRect(find.byKey(_returnKey)).left,
      greaterThan(visibleRect.left),
      reason: 'Back inherits the outbound velocity before turning around',
    );
    await tester.pump(const Duration(milliseconds: 80));
    final beforeReopen = tester.getRect(find.byKey(_returnKey));
    state.enter();
    await tester.pump();
    await tester.pump();
    // The last returning layer stays until the replacement has painted.
    // Flush that layer's deferred unmount without advancing either spring.
    await tester.pump();
    expect(find.byKey(_returnKey), findsNothing);
    expect(find.byKey(_forwardKey), findsOneWidget);
    expect(
      (tester.getRect(find.byKey(_forwardKey)).topLeft - beforeReopen.topLeft)
          .distance,
      lessThan(.001),
    );
    await tester.pump(const Duration(milliseconds: 1));
    expect(
      tester.getRect(find.byKey(_forwardKey)).left,
      lessThan(beforeReopen.left),
      reason: 'reopen inherits the returning velocity',
    );
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
    await tester.pumpAndSettle();
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
    final destination = tester.getRect(find.byKey(state.source));
    var closest = double.infinity;
    for (var frame = 0; frame < 120; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (find.byKey(_returnKey).evaluate().isEmpty) break;
      final flying = tester.getRect(find.byKey(_returnKey));
      closest = math.min(
        closest,
        (flying.topLeft - destination.topLeft).distance,
      );
      if (closest < 8) break;
    }
    expect(closest, lessThan(75));
    await tester.pumpAndSettle();
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
        theme: buildAppleTheme(),
        home: AppShell(state: state),
      ),
    );
    await tester.pump();
    final card = find.byType(AppPlaylistCard).first;
    await tester.ensureVisible(card);
    await _settle(tester);
    final homeState = tester.state(find.byType(AppHomePage));
    final sourceRect = tester.getRect(card);
    final scroll = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(AppHomePage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    final savedOffset = scroll.position.pixels;
    await tester.tap(card);
    await _settle(tester);
    expect(find.byType(AppPlaylistPage), findsOneWidget);
    expect(catalog.requests, 1);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(_returnKey), findsOneWidget);
    await _settle(tester);
    expect(tester.state(find.byType(AppHomePage)), same(homeState));
    expect(scroll.position.pixels, savedOffset);
    expect(tester.getRect(card), sourceRect);
    expect(find.byType(AppPlaylistPage), findsNothing);
    expect(find.byKey(_returnKey), findsNothing);
    // The toolbar uses the same return path as system/remote Back.
    await tester.tap(card);
    await _settle(tester);
    await tester.tap(find.byTooltip('返回'));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(_returnKey), findsOneWidget);
    await _settle(tester);
    expect(tester.state(find.byType(AppHomePage)), same(homeState));
    expect(scroll.position.pixels, savedOffset);
    expect(tester.takeException(), isNull);
  });

  for (final library in [false, true]) {
    testWidgets(
      '${library ? 'library' : 'home'} scroll takes over an unfinished cover return',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final state = AppState(catalog: _Catalog())
          ..collections = UserCollections(
            created: [
              for (var i = 0; i < 20; i++)
                Playlist(
                  id: 'return-playlist-$i',
                  name: 'Playlist $i',
                  trackIds: const [],
                  coverSeed: i,
                  trackCount: 1,
                ),
            ],
          );
        addTearDown(state.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppleTheme(),
            home: AppShell(state: state),
          ),
        );
        await tester.pump();
        if (library) {
          await tester.tap(find.text('音乐库').last);
          await _settle(tester);
        }
        final root = find.byType(library ? AppLibraryPage : AppHomePage);
        final card = find
            .descendant(of: root, matching: find.byType(AppPlaylistCard))
            .first;
        await tester.ensureVisible(card);
        await _settle(tester);
        final scrollable = find
            .descendant(of: root, matching: find.byType(Scrollable))
            .first;
        final position = tester.state<ScrollableState>(scrollable).position;
        final before = position.pixels;
        await tester.tap(card);
        await _settle(tester);
        await tester.binding.handlePopRoute();
        await tester.pump();
        await tester.pump();
        expect(find.byKey(_returnKey), findsOneWidget);
        final returnedPosition = tester
            .state<ScrollableState>(scrollable)
            .position;
        expect(returnedPosition.pixels, before);
        await tester.drag(scrollable, Offset(0, before > 50 ? 80 : -80));
        await tester.pump();
        expect(returnedPosition.pixels, isNot(before));
        expect(find.byKey(_returnKey), findsNothing);
        final cover = find
            .descendant(of: card, matching: find.byType(CoverTransitionSource))
            .first;
        final opacity = find
            .descendant(of: cover, matching: find.byType(Opacity))
            .first;
        expect(tester.widget<Opacity>(opacity).opacity, 1);
        await _settle(tester);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
