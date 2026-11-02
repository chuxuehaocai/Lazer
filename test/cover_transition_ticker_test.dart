import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/widgets/cover_transition.dart';

class _MutedPageHarness extends StatefulWidget {
  const _MutedPageHarness({this.artwork, this.sourceScale = 1});

  final Widget? artwork;
  final double sourceScale;

  @override
  State<_MutedPageHarness> createState() => _MutedPageHarnessState();
}

class _MutedPageHarnessState extends State<_MutedPageHarness> {
  final GlobalKey sourceKey = GlobalKey();
  bool opened = false;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Stack(
        children: <Widget>[
          if (!opened)
            Positioned(
              left: 20,
              top: 24,
              child: Transform.scale(
                scale: widget.sourceScale,
                child: GestureDetector(
                  onTap: () {
                    rememberCoverTransition('playlist:muted-page', sourceKey);
                    setState(() => opened = true);
                  },
                  child: SizedBox.square(
                    key: sourceKey,
                    dimension: 90,
                    child: const ColoredBox(color: Colors.teal),
                  ),
                ),
              ),
            ),
          if (opened)
            Positioned(
              left: 300,
              top: 160,
              // The shell pauses both pages' ambient animations while the
              // incoming page moves. The artwork flight lives in the root
              // overlay and must keep its own clock throughout that pause.
              child: TickerMode(
                enabled: false,
                child: CoverTransitionTarget(
                  identity: 'playlist:muted-page',
                  size: 190,
                  child: widget.artwork ?? const ColoredBox(color: Colors.teal),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class _ArtworkCounters {
  int builds = 0;
  int layouts = 0;
}

class _ArtworkProbe extends StatelessWidget {
  const _ArtworkProbe(this.counters);

  final _ArtworkCounters counters;

  @override
  Widget build(BuildContext context) {
    counters.builds++;
    return _LayoutProbe(
      counters: counters,
      child: ColoredBox(color: Theme.of(context).colorScheme.primary),
    );
  }
}

class _LayoutProbe extends SingleChildRenderObjectWidget {
  const _LayoutProbe({required this.counters, required super.child});

  final _ArtworkCounters counters;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderLayoutProbe(counters);
}

class _RenderLayoutProbe extends RenderProxyBox {
  _RenderLayoutProbe(this.counters);

  final _ArtworkCounters counters;

  @override
  void performLayout() {
    counters.layouts++;
    super.performLayout();
  }
}

void main() {
  testWidgets('hiding a cover only rebuilds the affected shelf source', (
    tester,
  ) async {
    const sourceCount = 120;
    final keys = List<GlobalKey>.generate(sourceCount, (_) => GlobalKey());
    var opened = false;
    late StateSetter update;
    final sources = [
      for (var i = 0; i < sourceCount; i++)
        Positioned(
          left: (i % 12) * 40,
          top: (i ~/ 12) * 40,
          child: CoverTransitionSource(
            key: keys[i],
            identity: 'shelf:$i',
            child: const SizedBox.square(
              dimension: 32,
              child: ColoredBox(color: Colors.teal),
            ),
          ),
        ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Stack(
                children: [
                  ...sources,
                  if (opened)
                    const Positioned(
                      left: 520,
                      top: 100,
                      child: CoverTransitionTarget(
                        identity: 'shelf:12',
                        size: 64,
                        child: ColoredBox(color: Colors.teal),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
    List<Opacity> sourceOpacities() => [
      for (final key in keys)
        tester.widget<Opacity>(
          find.descendant(of: find.byKey(key), matching: find.byType(Opacity)),
        ),
    ];
    final initial = sourceOpacities();
    rememberCoverTransition('shelf:12', keys[12]);
    await tester.pump();
    final waiting = sourceOpacities();
    expect(waiting[12].opacity, 1);
    expect(waiting, initial, reason: 'the source stays painted before takeoff');
    update(() => opened = true);
    await tester.pump();
    await tester.pump();
    final hidden = sourceOpacities();
    final hiddenRebuilds = [
      for (var i = 0; i < sourceCount; i++)
        if (!identical(initial[i], hidden[i])) i,
    ];
    expect(hidden[12].opacity, 0);
    cancelCoverTransitions();
    await tester.pump();
    final restored = sourceOpacities();
    final restoreRebuilds = [
      for (var i = 0; i < sourceCount; i++)
        if (!identical(hidden[i], restored[i])) i,
    ];
    expect(restored[12].opacity, 1);
    expect(hiddenRebuilds, [12]);
    expect(restoreRebuilds, [12]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('visibility changes coalesce and release recycled source keys', (
    tester,
  ) async {
    final key = GlobalKey();
    var cancelInBuild = false;
    var opened = false;
    late StateSetter update;
    Widget app() => MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            if (cancelInBuild) {
              rememberCoverTransition('recycled', key);
              cancelCoverTransitions();
            }
            return Stack(
              children: [
                CoverTransitionSource(
                  key: key,
                  identity: 'recycled',
                  child: const SizedBox.square(
                    dimension: 60,
                    child: ColoredBox(color: Colors.teal),
                  ),
                ),
                if (opened)
                  const Positioned(
                    left: 200,
                    top: 200,
                    child: CoverTransitionTarget(
                      identity: 'recycled',
                      size: 100,
                      child: ColoredBox(color: Colors.teal),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
    await tester.pumpWidget(app());
    update(() => cancelInBuild = true);
    await tester.pump();
    await tester.pump();
    Opacity source() => tester.widget<Opacity>(
      find.descendant(of: find.byKey(key), matching: find.byType(Opacity)),
    );
    expect(
      source().opacity,
      1,
      reason: 'the final cancellation wins within the build',
    );
    cancelInBuild = false;
    rememberCoverTransition('recycled', key);
    update(() => opened = true);
    await tester.pump();
    await tester.pump();
    expect(source().opacity, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    cancelCoverTransitions();
    opened = false;
    await tester.pumpWidget(app());
    expect(
      source().opacity,
      1,
      reason: 'a recycled source must not retain hidden state',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('flight starts at the transformed source artwork bounds', (
    tester,
  ) async {
    await tester.pumpWidget(const _MutedPageHarness(sourceScale: 1.2));
    final state = tester.state<_MutedPageHarnessState>(
      find.byType(_MutedPageHarness),
    );
    final sourceRect = tester.getRect(find.byKey(state.sourceKey));
    expect(sourceRect.width, closeTo(108, .001));
    await tester.tap(find.byKey(state.sourceKey));
    await tester.pump();
    await tester.pump();
    final flight = find.byKey(
      const ValueKey<String>('cover-transition-flight'),
    );
    final flightRect = tester.getRect(flight);
    expect((flightRect.topLeft - sourceRect.topLeft).distance, lessThan(.001));
    expect(
      (flightRect.bottomRight - sourceRect.bottomRight).distance,
      lessThan(.001),
    );
    await tester.pumpAndSettle();
    await tester.pump();
    expect(flight, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('artwork flight completes while page tickers are paused', (
    tester,
  ) async {
    await tester.pumpWidget(const _MutedPageHarness());
    final state = tester.state<_MutedPageHarnessState>(
      find.byType(_MutedPageHarness),
    );
    await tester.tap(find.byKey(state.sourceKey));
    await tester.pump();
    await tester.pump();
    final flight = find.byKey(
      const ValueKey<String>('cover-transition-flight'),
    );
    expect(flight, findsOneWidget);

    await tester.pumpAndSettle();
    await tester.pump();

    expect(flight, findsNothing);
    final target = find.byType(CoverTransitionTarget);
    final opacity = tester.widget<Opacity>(
      find.descendant(of: target, matching: find.byType(Opacity)),
    );
    expect(opacity.opacity, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('artwork covers most distance early then slows on arrival', (
    tester,
  ) async {
    await tester.pumpWidget(const _MutedPageHarness());
    final state = tester.state<_MutedPageHarnessState>(
      find.byType(_MutedPageHarness),
    );
    final start = tester.getRect(find.byKey(state.sourceKey));
    await tester.tap(find.byKey(state.sourceKey));
    await tester.pump();
    await tester.pump();
    final flight = find.byKey(
      const ValueKey<String>('cover-transition-flight'),
    );
    final destination = tester.getRect(find.byType(CoverTransitionTarget));

    await tester.pump(const Duration(milliseconds: 126));
    final early = tester.getRect(flight);
    final totalTravel = destination.left - start.left;
    final earlyTravel = early.left - start.left;
    expect(earlyTravel / totalTravel, greaterThan(.5));
    expect(early.width, greaterThan((start.width + destination.width) / 2));

    await tester.pump(const Duration(milliseconds: 126));
    final later = tester.getRect(flight);
    expect(later.left, greaterThan(early.left));
    expect(later.left - early.left, lessThan(earlyTravel));

    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 1));
    expect(flight, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('flight transforms retain artwork build and layout', (
    tester,
  ) async {
    final counters = _ArtworkCounters();
    await tester.pumpWidget(
      _MutedPageHarness(artwork: _ArtworkProbe(counters)),
    );
    final state = tester.state<_MutedPageHarnessState>(
      find.byType(_MutedPageHarness),
    );
    await tester.tap(find.byKey(state.sourceKey));
    await tester.pump();
    await tester.pump();
    final flight = find.byKey(
      const ValueKey<String>('cover-transition-flight'),
    );
    expect(flight, findsOneWidget);
    final buildsAtTakeoff = counters.builds;
    final layoutsAtTakeoff = counters.layouts;
    expect(buildsAtTakeoff, greaterThanOrEqualTo(2));
    expect(layoutsAtTakeoff, greaterThanOrEqualTo(2));

    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 30));
      expect(flight, findsOneWidget);
      expect(counters.builds, buildsAtTakeoff);
      expect(counters.layouts, layoutsAtTakeoff);
    }

    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 1));
    expect(flight, findsNothing);
    expect(tester.takeException(), isNull);
  });
}
