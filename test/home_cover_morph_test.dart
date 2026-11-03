import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/ui/home_pages.dart';
import 'package:lazer_nextgen/widgets/cover_transition.dart';
import 'package:lazer_nextgen/widgets/retained_content_switcher.dart';

const _sourceColor = Color(0xffd02e46);
const _targetColor = Color(0xff284bd0);
const _forward = ValueKey<String>('cover-transition-flight');
const _return = ValueKey<String>('cover-transition-return-flight');

class _Harness extends StatefulWidget {
  const _Harness({
    this.daily,
    this.reduced = false,
    this.scale = 1,
    this.sourceArtwork,
    this.artwork,
  });
  final bool? daily;
  final bool reduced;
  final double scale;
  final Widget? sourceArtwork, artwork;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final screen = GlobalKey();
  final source = GlobalKey();
  bool opened = false;
  bool retargeted = false;
  void retarget() => setState(() => retargeted = true);
  void enter() {
    rememberCoverTransition(identity, source);
    setState(() => opened = true);
  }

  String get identity => switch (widget.daily) {
    true => 'playlist:$dailyRecommendationsPlaylistId',
    false => 'chart:board',
    null => 'morph-fixture',
  };

  void back() {
    returnCoverTransition(identity);
    setState(() => opened = false);
  }

  Widget _root() => Stack(
    children: [
      Positioned(
        left: 24,
        top: 32,
        width: widget.daily == null ? 240 : 550,
        height: widget.daily == null ? 140 : 294,
        child: TickerMode(
          enabled: false,
          child: widget.daily == null
              ? GestureDetector(
                  onTap: enter,
                  child: CoverTransitionSource(
                    key: source,
                    identity: identity,
                    morphArtwork: true,
                    radius: 18,
                    child:
                        widget.sourceArtwork ??
                        const ColoredBox(color: _sourceColor),
                  ),
                )
              : widget.daily!
              ? HomeActionShelf(
                  busy: false,
                  covers: const [],
                  onDaily: () => setState(() => opened = true),
                )
              : ChartShelf(
                  charts: const [
                    MusicChart(
                      id: 'board',
                      title: 'Billboard fixture',
                      source: 'Fixture',
                      issueLabel: 'This week',
                      entries: [],
                    ),
                  ],
                  onOpen: (_) => setState(() => opened = true),
                ),
        ),
      ),
    ],
  );

  @override
  void dispose() {
    cancelCoverTransitions();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    builder: (context, child) => RepaintBoundary(key: screen, child: child),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: widget.reduced),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Transform.scale(
          scale: widget.scale,
          alignment: Alignment.topLeft,
          child: RetainedContentSwitcher(
            currentKey: opened ? 'detail' : 'home',
            retainKeys: opened ? const {'home'} : const {},
            duration: widget.reduced
                ? Duration.zero
                : const Duration(milliseconds: 420),
            page: opened
                ? Stack(
                    children: [
                      Positioned(
                        left: 380,
                        top: 220,
                        child: CoverTransitionTarget(
                          identity: retargeted ? 'replacement' : identity,
                          size: 180,
                          child:
                              widget.artwork ??
                              const ColoredBox(color: _targetColor),
                        ),
                      ),
                    ],
                  )
                : _root(),
          ),
        ),
      ),
    ),
  );
}

class _CircleArt extends CustomPainter {
  const _CircleArt(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPaint(Paint()..color = color);
    canvas.drawCircle(
      size.center(Offset.zero),
      25,
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_CircleArt oldDelegate) => color != oldDelegate.color;
}

class _Counts {
  int builds = 0, layouts = 0;
}

class _Probe extends StatelessWidget {
  const _Probe(this.counts);
  final _Counts counts;
  @override
  Widget build(BuildContext context) {
    counts.builds++;
    return _LayoutProbe(counts);
  }
}

class _LayoutProbe extends SingleChildRenderObjectWidget {
  const _LayoutProbe(this.counts)
    : super(child: const ColoredBox(color: _targetColor));
  final _Counts counts;
  @override
  RenderObject createRenderObject(BuildContext context) => _RenderProbe(counts);
}

class _RenderProbe extends RenderProxyBox {
  _RenderProbe(this.counts);
  final _Counts counts;
  @override
  void performLayout() {
    counts.layouts++;
    super.performLayout();
  }
}

Future<Uint8List> _pixels(
  WidgetTester tester,
  GlobalKey key, {
  String? label,
}) async {
  late Uint8List result;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      result = Uint8List.fromList(data!.buffer.asUint8List());
      if (const bool.fromEnvironment('SAVE_COVER_MORPH_PROBES') &&
          label != null) {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('diag/home-cover-morph/$label.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(png!.buffer.asUint8List());
      }
    } finally {
      image.dispose();
    }
  });
  return result;
}

List<int> _sample(Uint8List pixels, Offset point) {
  final at = (point.dy.floor() * 800 + point.dx.floor()) * 4;
  return pixels.sublist(at, at + 4);
}

void _near(List<int> actual, List<int> expected, {int tolerance = 2}) {
  for (var i = 0; i < 4; i++) {
    expect(actual[i], closeTo(expected[i], tolerance));
  }
}

Rect _bounds(WidgetTester tester, Finder finder) {
  final box = tester.renderObject<RenderBox>(finder);
  return Rect.fromPoints(
    box.localToGlobal(Offset.zero),
    box.localToGlobal(box.size.bottomRight(Offset.zero)),
  );
}

void main() {
  setUp(() => cancelCoverTransitions());
  Future<_HarnessState> mount(
    WidgetTester tester, {
    _Harness harness = const _Harness(),
  }) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness);
    await tester.pump();
    return tester.state<_HarnessState>(find.byType(_Harness));
  }

  testWidgets('takeoff retains source pixels before the first overlay paint', (
    tester,
  ) async {
    final state = await mount(tester);
    final source = tester.getRect(find.byKey(state.source));
    final before = _sample(await _pixels(tester, state.screen), source.center);
    await tester.tap(find.byKey(state.source));
    await tester.pump();
    _near(_sample(await _pixels(tester, state.screen), source.center), before);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Back keeps the detail pixels on its first returning frame', (
    tester,
  ) async {
    final state = await mount(tester);
    state.enter();
    await tester.pumpAndSettle();
    final target = tester.getRect(find.byType(CoverTransitionTarget));
    final before = _sample(await _pixels(tester, state.screen), target.center);
    state.back();
    await tester.pump();
    _near(_sample(await _pixels(tester, state.screen), target.center), before);
    await tester.pumpAndSettle();
    expect(debugCoverSnapshotCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rapid reopen paints the returning composition immediately', (
    tester,
  ) async {
    final state = await mount(tester);
    state.enter();
    await tester.pumpAndSettle();
    for (var cycle = 0; cycle < 3; cycle++) {
      state.back();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final bounds = tester.getRect(find.byKey(_return));
      final before = _sample(
        await _pixels(tester, state.screen),
        bounds.center,
      );
      state.enter();
      await tester.pump();
      _near(
        _sample(await _pixels(tester, state.screen), bounds.center),
        before,
      );
      await tester.pump();
      final reopened = tester.getRect(find.byKey(_forward));
      expect((reopened.topLeft - bounds.topLeft).distance, lessThan(.001));
      expect(
        (reopened.bottomRight - bounds.bottomRight).distance,
        lessThan(.001),
      );
      await tester.pump(const Duration(milliseconds: 80));
    }
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(debugCoverSnapshotCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('landing hands opaque pixels to live artwork on every frame', (
    tester,
  ) async {
    final state = await mount(tester);
    state.enter();
    await tester.pump();
    await tester.pump();
    var completed = false;
    for (var frame = 0; frame < 180; frame++) {
      final flight = find.byKey(_forward);
      final flying = flight.evaluate().isNotEmpty;
      final bounds = tester.getRect(
        flying ? flight : find.byType(CoverTransitionTarget),
      );
      final pixel = _sample(await _pixels(tester, state.screen), bounds.center);
      expect(
        pixel.take(3).reduce((sum, value) => sum + value),
        greaterThan(315),
        reason: 'frame $frame must keep a cover rather than expose the canvas',
      );
      if (!flying) {
        _near(pixel, [40, 75, 208, 255]);
        completed = true;
        break;
      }
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(completed, isTrue);
    await tester.pumpAndSettle();
    state.back();
    await tester.pump();
    completed = false;
    for (var frame = 0; frame < 180; frame++) {
      final flight = find.byKey(_return);
      final flying = flight.evaluate().isNotEmpty;
      final bounds = tester.getRect(flying ? flight : find.byKey(state.source));
      final pixel = _sample(await _pixels(tester, state.screen), bounds.center);
      expect(
        pixel.take(3).reduce((sum, value) => sum + value),
        greaterThan(315),
        reason: 'return frame $frame must keep the cover painted',
      );
      if (!flying) {
        _near(pixel, [208, 46, 70, 255]);
        completed = true;
        break;
      }
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(completed, isTrue);
    await tester.pumpAndSettle();
    expect(debugCoverSnapshotCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reopening before return paint preserves the detail pixels', (
    tester,
  ) async {
    final state = await mount(tester);
    state.enter();
    await tester.pumpAndSettle();
    final bounds = tester.getRect(find.byType(CoverTransitionTarget));
    final before = _sample(await _pixels(tester, state.screen), bounds.center);
    state.back();
    state.enter();
    await tester.pump();
    _near(_sample(await _pixels(tester, state.screen), bounds.center), before);
    await tester.pump();
    _near(_sample(await _pixels(tester, state.screen), bounds.center), before);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(debugCoverSnapshotCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'different home artwork dissolves in both directions without a hard cut',
    (tester) async {
      final state = await mount(tester);
      final original = tester.getRect(find.byKey(state.source));
      final source = _sample(
        await _pixels(tester, state.screen),
        original.center,
      );
      _near(source, [208, 46, 70, 255]);
      await tester.tap(find.byKey(state.source));
      await tester.pump();
      await tester.pump();
      var bounds = tester.getRect(find.byKey(_forward));
      expect(bounds, original);
      _near(
        _sample(await _pixels(tester, state.screen), bounds.center),
        source,
      );
      expect(debugCoverSnapshotCount, 1);
      await tester.pump(const Duration(milliseconds: 113));
      bounds = tester.getRect(find.byKey(_forward));
      final middle = _sample(
        await _pixels(tester, state.screen),
        bounds.center,
      );
      expect(middle[0], inExclusiveRange(40, 208));
      expect(middle[2], inExclusiveRange(70, 208));
      expect(middle[3], 255);
      await tester.pumpAndSettle();
      final target = tester.getRect(find.byType(CoverTransitionTarget));
      _near(_sample(await _pixels(tester, state.screen), target.center), [
        40,
        75,
        208,
        255,
      ]);
      state.back();
      await tester.pump();
      await tester.pump();
      bounds = tester.getRect(find.byKey(_return));
      _near(_sample(await _pixels(tester, state.screen), bounds.center), [
        40,
        75,
        208,
        255,
      ]);
      await tester.pump(const Duration(milliseconds: 113));
      bounds = tester.getRect(find.byKey(_return));
      final returning = _sample(
        await _pixels(tester, state.screen),
        bounds.center,
      );
      expect(returning[0], inExclusiveRange(40, 208));
      expect(returning[2], inExclusiveRange(70, 208));
      expect(returning[3], 255);
      await tester.pump(const Duration(milliseconds: 500));
      bounds = tester.getRect(find.byKey(_return));
      _near(
        _sample(await _pixels(tester, state.screen), bounds.center),
        source,
      );
      await tester.pumpAndSettle();
      await tester.pump();
      _near(
        _sample(await _pixels(tester, state.screen), original.center),
        source,
      );
      expect(debugCoverSnapshotCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('returning before arrival preserves the current composition', (
    tester,
  ) async {
    final state = await mount(tester);
    await tester.tap(find.byKey(state.source));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    final before = tester.getRect(find.byKey(_forward));
    final color = _sample(await _pixels(tester, state.screen), before.center);
    state.back();
    await tester.pump();
    await tester.pump();
    final after = tester.getRect(find.byKey(_return));
    expect((after.topLeft - before.topLeft).distance, lessThan(.001));
    expect((after.bottomRight - before.bottomRight).distance, lessThan(.001));
    _near(_sample(await _pixels(tester, state.screen), after.center), color);
    await tester.pumpAndSettle();
    await tester.pump();
    expect(debugCoverSnapshotCount, 0);
    expect(tester.takeException(), isNull);
  });

  for (final daily in [true, false]) {
    testWidgets(
      '${daily ? 'daily' : 'chart'} starts with the actual composite card pixels',
      (tester) async {
        final state = await mount(tester, harness: _Harness(daily: daily));
        final source = find.byType(CoverTransitionSource).first;
        final bounds = tester.getRect(source);
        final point = bounds.center;
        final before = _sample(
          await _pixels(tester, state.screen, label: '$daily-home'),
          point,
        );
        await tester.tap(source);
        await tester.pump();
        await tester.pump();
        expect(find.byKey(_forward), findsOneWidget);
        _near(
          _sample(
            await _pixels(tester, state.screen, label: '$daily-first'),
            point,
          ),
          before,
        );
        expect(debugCoverSnapshotCount, 1);
        await tester.pump(const Duration(milliseconds: 160));
        await _pixels(tester, state.screen, label: '$daily-middle');
        await tester.pump(const Duration(milliseconds: 290));
        state.back();
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await _pixels(tester, state.screen, label: '$daily-return');
        await tester.pump(const Duration(milliseconds: 150));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(debugCoverSnapshotCount, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('reduced motion makes no snapshot or flight', (tester) async {
    final state = await mount(tester, harness: const _Harness(reduced: true));
    await tester.tap(find.byKey(state.source));
    await tester.pump();
    expect(find.byKey(_forward), findsNothing);
    expect(debugCoverSnapshotCount, 0);
    state.back();
    await tester.pump();
    expect(find.byKey(_return), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'rectangular artwork keeps circles round while the frame changes shape',
    (tester) async {
      final state = await mount(
        tester,
        harness: const _Harness(
          sourceArtwork: CustomPaint(painter: _CircleArt(_sourceColor)),
          artwork: CustomPaint(painter: _CircleArt(_targetColor)),
        ),
      );
      await tester.tap(find.byKey(state.source));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      final bounds = tester.getRect(find.byKey(_forward));
      final pixels = await _pixels(tester, state.screen);
      int diameter(Offset axis) {
        var length = 0;
        for (var step = -50; step <= 50; step++) {
          final pixel = _sample(pixels, bounds.center + axis * step.toDouble());
          if (pixel.take(3).every((channel) => channel > 190)) length++;
        }
        return length;
      }

      expect(bounds.width, greaterThan(bounds.height + 20));
      expect(diameter(const Offset(1, 0)), greaterThan(45));
      expect(
        diameter(const Offset(1, 0)),
        closeTo(diameter(const Offset(0, 1)), 2),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(debugCoverSnapshotCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('morph frames do not rebuild or lay out the cover again', (
    tester,
  ) async {
    final counts = _Counts();
    final state = await mount(
      tester,
      harness: _Harness(artwork: _Probe(counts)),
    );
    await tester.tap(find.byKey(state.source));
    await tester.pump();
    await tester.pump();
    final builds = counts.builds, layouts = counts.layouts;
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(counts.builds, builds);
    expect(counts.layouts, layouts);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(debugCoverSnapshotCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancel and rapid reentry release source textures', (
    tester,
  ) async {
    final state = await mount(tester);
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byKey(state.source));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      expect(debugCoverSnapshotCount, 1);
      state.back();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(debugCoverSnapshotCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a sign-in shortcut leaves its card visible and captures nothing',
    (tester) async {
      var openedLogin = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeActionShelf(
              busy: false,
              dailyOpensPlaylist: false,
              covers: const [],
              onDaily: () => openedLogin = true,
            ),
          ),
        ),
      );
      await tester.pump();
      final source = find.byType(CoverTransitionSource).first;
      await tester.tap(source);
      await tester.pump();
      expect(openedLogin, isTrue);
      expect(debugCoverSnapshotCount, 0);
      expect(
        tester
            .widget<Opacity>(
              find.descendant(of: source, matching: find.byType(Opacity)).first,
            )
            .opacity,
        1,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  for (final scale in [.8, 1.25]) {
    testWidgets(
      'composite artwork starts and returns at scaled bounds $scale',
      (tester) async {
        final state = await mount(tester, harness: _Harness(scale: scale));
        final original = _bounds(tester, find.byKey(state.source));
        await tester.tap(find.byKey(state.source));
        await tester.pump();
        await tester.pump();
        final takeoff = _bounds(tester, find.byKey(_forward));
        expect((takeoff.topLeft - original.topLeft).distance, lessThan(.001));
        expect(
          (takeoff.bottomRight - original.bottomRight).distance,
          lessThan(.001),
        );
        _near(_sample(await _pixels(tester, state.screen), original.center), [
          208,
          46,
          70,
          255,
        ]);
        await tester.pumpAndSettle();
        state.back();
        await tester.pump();
        await tester.pump();
        // The retained source is itself entering. Let the flight continue
        // until it catches the live destination, even after that page rests.
        var removed = false;
        var closest = double.infinity;
        for (var frame = 0; frame < 120; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          if (find.byKey(_return).evaluate().isEmpty) {
            removed = true;
            break;
          }
          final live = _bounds(tester, find.byKey(state.source));
          final flying = _bounds(tester, find.byKey(_return));
          closest = math.min(closest, (flying.center - live.center).distance);
        }
        expect(removed, isTrue);
        expect(closest, lessThan(40 * scale));
        await tester.pump();
        _near(_sample(await _pixels(tester, state.screen), original.center), [
          208,
          46,
          70,
          255,
        ]);
        await tester.pumpAndSettle();
        await tester.pump();
        expect(debugCoverSnapshotCount, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'changing a target during build releases pixels only after the old flight unmounts',
    (tester) async {
      final state = await mount(tester);
      await tester.tap(find.byKey(state.source));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(debugCoverSnapshotCount, 1);
      state.retarget();
      await tester.pump();
      await tester.pump();
      expect(debugCoverSnapshotCount, 0);
      expect(find.byKey(_forward), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Back before the first flight paint stays at the source card', (
    tester,
  ) async {
    final state = await mount(tester);
    final source = _bounds(tester, find.byKey(state.source));
    await tester.tap(find.byKey(state.source));
    await tester.pump();
    state.back();
    await tester.pump();
    await tester.pump();
    final returning = find.byKey(_return);
    expect(
      _bounds(
        tester,
        returning.evaluate().isNotEmpty ? returning : find.byKey(state.source),
      ),
      source,
    );
    _near(_sample(await _pixels(tester, state.screen), source.center), [
      208,
      46,
      70,
      255,
    ]);
    await tester.pumpAndSettle();
    await tester.pump();
    expect(debugCoverSnapshotCount, 0);
    expect(tester.takeException(), isNull);
  });
}
