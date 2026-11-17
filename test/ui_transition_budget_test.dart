import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/animation/view_transitions.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/widgets/animated_track_cover.dart';
import 'package:lazer_nextgen/widgets/plate_art.dart';
import 'package:lazer_nextgen/widgets/retained_content_switcher.dart';

class _IdentityProbe extends StatefulWidget {
  _IdentityProbe(this.id, this.created) : super(key: ValueKey(id));
  final String id;
  final Map<String, int> created;
  @override
  State<_IdentityProbe> createState() => _IdentityProbeState();
}

class _IdentityProbeState extends State<_IdentityProbe> {
  @override
  void initState() {
    super.initState();
    widget.created.update(widget.id, (count) => count + 1, ifAbsent: () => 1);
  }

  @override
  Widget build(BuildContext context) => Text(widget.id);
}

class _PageProbe extends StatefulWidget {
  const _PageProbe(this.id, this.live, this.ticks);

  final String id;
  final Set<String> live;
  final Map<String, int> ticks;

  @override
  State<_PageProbe> createState() => _PageProbeState();
}

class _PageProbeState extends State<_PageProbe>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation;

  @override
  void initState() {
    super.initState();
    widget.live.add(widget.id);
    _animation =
        AnimationController(vsync: this, duration: const Duration(seconds: 1))
          ..addListener(
            () => widget.ticks.update(
              widget.id,
              (value) => value + 1,
              ifAbsent: () => 1,
            ),
          )
          ..repeat();
  }

  @override
  void dispose() {
    widget.live.remove(widget.id);
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(widget.id);
}

Track _track(int id) => Track(
  id: '$id',
  title: 'Track $id',
  artist: 'Artist',
  album: 'Album',
  duration: const Duration(minutes: 3),
  coverSeed: id,
);

Widget _cover(int id, {bool visible = true, bool reduced = false}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: TickerMode(
          enabled: visible,
          child: Center(
            child: SizedBox.square(
              dimension: 120,
              child: AnimatedTrackCover(
                track: _track(id),
                direction: 1,
                size: 120,
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('rebuilding a view preserves the outgoing view on rapid return', (
    tester,
  ) async {
    final created = <String, int>{};
    for (final id in ['a', 'b', 'b', 'a']) {
      await tester.pumpWidget(
        MaterialApp(
          home: ViewTransitionSwitcher(child: _IdentityProbe(id, created)),
        ),
      );
    }
    expect(created, {'a': 1, 'b': 1});
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('interrupted navigation retains at most one outgoing page', (
    tester,
  ) async {
    final live = <String>{};
    final ticks = <String, int>{};
    for (var i = 0; i < 50; i++) {
      await tester.pumpWidget(
        MaterialApp(
          home: RetainedContentSwitcher(
            currentKey: '$i',
            page: _PageProbe('$i', live, ticks),
            retainKeys: const {},
          ),
        ),
      );
      expect(live.length, lessThanOrEqualTo(2));
      expect(live, contains('$i'));
    }
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(live, {'49'});
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(live, isEmpty);
  });

  testWidgets(
    'history has a hard budget and preserves root and nearest pages',
    (tester) async {
      final live = <String>{};
      final ticks = <String, int>{};
      for (var i = 0; i < 20; i++) {
        await tester.pumpWidget(
          MaterialApp(
            home: RetainedContentSwitcher(
              maxRetainedPages: 3,
              currentKey: '$i',
              page: _PageProbe('$i', live, ticks),
              retainKeys: {for (var j = 0; j < i; j++) '$j'},
            ),
          ),
        );
        expect(live.length, lessThanOrEqualTo(4));
        final painted = tester
            .widgetList<Offstage>(find.byType(Offstage, skipOffstage: false))
            .where((widget) => !widget.offstage);
        expect(
          painted.length,
          lessThanOrEqualTo(3),
        ); // Navigator plus two pages.
      }
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(live, {'0', '18', '19'});
      final rootTicks = ticks['0'];
      await tester.pump(const Duration(milliseconds: 100));
      expect(ticks['0'], rootTicks);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('committed back navigation can reconstruct an evicted target', (
    tester,
  ) async {
    final live = <String>{};
    final ticks = <String, int>{};
    Future<void> show(String id, {String? target, bool committed = false}) =>
        tester.pumpWidget(
          MaterialApp(
            home: RetainedContentSwitcher(
              maxRetainedPages: 2,
              duration: Duration.zero,
              currentKey: id,
              page: _PageProbe(id, live, ticks),
              retainKeys: const {'0', '1', '2'},
              backTargetKey: target,
              backCommitted: committed,
            ),
          ),
        );
    await show('0');
    await show('1');
    await show('2');
    expect(live, {'0', '2'});
    await show('2', target: '1');
    await show('1', target: '1', committed: true);
    expect(live, {'0', '1'});
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('disposing a moving switch reports completion and cancels work', (
    tester,
  ) async {
    final reports = <bool>[];
    for (final id in ['a', 'b']) {
      await tester.pumpWidget(
        MaterialApp(
          home: RetainedContentSwitcher(
            currentKey: id,
            page: Text(id),
            retainKeys: const {},
            onTransitionChanged: reports.add,
          ),
        ),
      );
    }
    expect(reports.last, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(reports.last, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rapid track changes keep at most three cover image layers', (
    tester,
  ) async {
    for (var i = 0; i < 50; i++) {
      await tester.pumpWidget(_cover(i));
      expect(find.byType(PlateArt).evaluate().length, lessThanOrEqualTo(3));
    }
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.byType(PlateArt), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('hidden covers immediately release outgoing layers', (
    tester,
  ) async {
    await tester.pumpWidget(_cover(0));
    await tester.pumpWidget(_cover(1));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pumpWidget(_cover(1, visible: false));
    expect(find.byType(PlateArt), findsOneWidget);
    for (var i = 2; i < 30; i++) {
      await tester.pumpWidget(_cover(i, visible: false));
      expect(find.byType(PlateArt), findsOneWidget);
    }
    await tester.pumpWidget(_cover(29));
    expect(find.byType(PlateArt), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('reduced motion changes collapse pending cover transitions', (
    tester,
  ) async {
    await tester.pumpWidget(_cover(0));
    await tester.pumpWidget(_cover(1));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pumpWidget(_cover(1, reduced: true));
    expect(find.byType(PlateArt), findsOneWidget);
    await tester.pumpWidget(_cover(2, reduced: true));
    expect(find.byType(PlateArt), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
