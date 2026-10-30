import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/animation/lyric_spring.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/lyrics.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/widgets/lyric_viewport.dart';
import 'package:lazer_nextgen/widgets/timed_lyric_text.dart';
import 'package:lazer_nextgen/widgets/app_scroll_behavior.dart';

const _track = Track(
  id: '90001',
  title: 'Motion fixture',
  artist: 'Test',
  album: 'Test',
  duration: Duration(minutes: 2),
  coverSeed: 1,
);

class _Catalog extends Catalog {
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => GatewayLyrics(
    lrc: [
      for (var i = 0; i < 30; i++)
        '[00:${(i * 2).toString().padLeft(2, '0')}.00]歌词 $i',
    ].join('\n'),
    tlyric: [
      for (var i = 0; i < 30; i++)
        '[00:${(i * 2).toString().padLeft(2, '0')}.00]翻译 $i',
    ].join('\n'),
  );
  @override
  Future<List<Track>> playlistTracks(String id) async => tracks;
  List<Track> get tracks => [
    for (var i = 1; i <= 100; i++)
      Track(
        id: '$i',
        title: '歌曲 $i',
        artist: 'Test',
        album: 'Test',
        duration: const Duration(minutes: 2),
        coverSeed: i,
      ),
  ];
}

class _WordPlaybackState extends AppState {
  _WordPlaybackState() {
    lyrics = const [
      LyricLine(
        Duration.zero,
        'Animated lyric',
        words: [
          LyricWord(Duration.zero, Duration(seconds: 30), 'Animated lyric'),
        ],
      ),
    ];
  }
  @override
  Track? get current => _track;
  @override
  bool get playing => true;
  @override
  Duration get precisePosition => const Duration(seconds: 1);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'Reference slow, adaptive and scale trajectories match upstream TypeScript',
    () {
      // Captured by executing the actual upstream Spring, not a Dart round trip.
      final cases = [
        (
          const LyricSpringParams(mass: .9, stiffness: 90, damping: 15),
          300.0,
          100.0,
          [
            297.46826815767037,
            281.0841955413481,
            242.77522195514908,
            167.84279189239305,
            98.84190950474752,
            99.98530423690991,
          ],
          85.70793006557773,
        ),
        (
          lyricPositionPolicy(intervalMs: 350),
          300.0,
          100.0,
          [
            294.38248284603054,
            263.6079320499713,
            208.35355896124068,
            137.03134048354585,
            100.75925057844066,
            100.00062170964338,
          ],
          77.08853432044108,
        ),
        (
          const LyricSpringParams(mass: 2, stiffness: 100, damping: 25),
          97.0,
          100.0,
          [
            97.019436698618,
            97.152324347162,
            97.49581464466874,
            98.32400091816152,
            99.7626556051046,
            100.00751626074798,
          ],
          91.74193811729143,
        ),
      ];
      for (final fixture in cases) {
        final spring = LyricSpring(fixture.$2, params: fixture.$1)
          ..setTarget(fixture.$3);
        var sample = 0;
        for (var frame = 1; frame <= 60; frame++) {
          spring.update(1 / 60);
          if ([1, 3, 6, 12, 30, 60].contains(frame)) {
            expect(spring.value, closeTo(fixture.$4[sample++], 1e-8));
          }
        }
        spring.setTarget(50);
        spring.update(.1);
        expect(
          spring.value,
          closeTo(fixture.$5, 1e-8),
          reason: 'retarget must preserve current velocity',
        );
      }
    },
  );
  test(
    'Reference queued target and stagger preserve upstream frame ordering',
    () {
      final spring = LyricSpring(0, params: lyricPositionPolicy())
        ..setTarget(100, delay: .05);
      for (final value in [
        0.0,
        0.0,
        0.0,
        0.0,
        1.265865921164817,
        4.613831338455995,
      ]) {
        spring.update(1 / 60);
        expect(spring.value, closeTo(value, 1e-8));
      }
      expect(
        lyricStaggerDelays([-150, -60, 0, 60, 120], [60, 60, 60, 60, 60], 2),
        orderedEquals([0.0, 0.0, .05, .1, .1 + .05 / 1.05]),
      );
      expect(lyricPositionPolicy(intervalMs: 100).stiffness, 220);
      expect(lyricPositionPolicy(intervalMs: 800).stiffness, 170);
      expect(lyricPositionPolicy(seeking: true).damping, 15);
    },
  );
  testWidgets(
    'manual browsing fades blur, coasts and resumes following after two seconds',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      state.playQueue([_track]);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLegacyTheme(),
          home: Scaffold(body: LyricViewport(state: state)),
        ),
      );
      await tester.pumpAndSettle();
      final blur = find.byKey(const ValueKey('lyric-blur-1'));
      final initial = tester.widget<ImageFiltered>(blur).imageFilter;
      final initialY = tester.getTopLeft(find.text('歌词 1')).dy;
      final gesture = await tester.startGesture(const Offset(200, 600));
      await gesture.moveBy(const Offset(0, -90));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.widget<ImageFiltered>(blur).imageFilter, isNot(initial));
      expect(
        tester.widget<ImageFiltered>(blur).enabled,
        true,
        reason: 'blur fades progressively during interruption',
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.widget<ImageFiltered>(blur).enabled, false);
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(tester.widget<ImageFiltered>(blur).enabled, false);
      await tester.pump(const Duration(milliseconds: 1100));
      await tester.pumpAndSettle();
      expect(tester.widget<ImageFiltered>(blur).enabled, true);
      expect(tester.getTopLeft(find.text('歌词 1')).dy, closeTo(initialY, .1));
      await state.setLyricBlurEnabled(false);
      await tester.pumpAndSettle();
      expect(tester.widget<ImageFiltered>(blur).enabled, false);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('manual lyric scrolling stops at the first and last line', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    state.playQueue([_track]);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLegacyTheme(),
        home: Scaffold(body: LyricViewport(state: state)),
      ),
    );
    await tester.pumpAndSettle();
    final first = find.byKey(ValueKey<String>('lyric-line-0'));
    final firstTop = tester.getTopLeft(first).dy;

    // Pulling down at the first line must not reveal empty space above it.
    final down = await tester.startGesture(const Offset(195, 250));
    await down.moveBy(const Offset(0, 600));
    await tester.pump();
    expect(tester.getTopLeft(first).dy, closeTo(firstTop, .1));
    await down.up();
    await tester.pump();

    // Scrolling to the end stops with the last line in the focus band.
    final up = await tester.startGesture(const Offset(195, 250));
    await up.moveBy(const Offset(0, -6000));
    await tester.pump();
    final last = find.byKey(ValueKey<String>('lyric-line-29'));
    expect(last, findsOneWidget);
    final lastTop = tester.getTopLeft(last).dy;
    await up.moveBy(const Offset(0, -600));
    await tester.pump();
    expect(tester.getTopLeft(last).dy, closeTo(lastTop, .1));
    await up.up();
    await tester.pump();

    expect(tester.takeException(), isNull);
    state.pause();
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'settled word animation repaints without rebuilding the position stack',
    (tester) async {
      final state = _WordPlaybackState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: LyricViewport(state: state)),
        ),
      );
      for (var i = 0; i < 240; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      var stackBuilds = 0;
      var wordColorBuilds = 0;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        if (element.widget.key ==
            const ValueKey<String>('lyric-position-stack')) {
          stackBuilds++;
        }
        if (element.widget is AnimatedBuilder &&
            find
                .descendant(
                  of: find.byWidget(element.widget),
                  matching: find.byKey(const ValueKey('lyric-color-0')),
                )
                .evaluate()
                .isNotEmpty) {
          wordColorBuilds++;
        }
      };
      addTearDown(() => debugOnRebuildDirtyWidget = null);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(stackBuilds, 0);
      expect(
        wordColorBuilds,
        0,
        reason: 'word highlights repaint without rebuilding settled colors',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('manual scrolling mounts only nearby lyric rows', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    state.playQueue([_track]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LyricViewport(state: state)),
      ),
    );
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(const Offset(180, 700));
    await gesture.moveBy(const Offset(0, -4000));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(
      find.byKey(ValueKey<String>('lyric-line-0')),
      findsNothing,
      reason: 'the old playback focus must not keep the gap mounted',
    );
    expect(
      find.byType(TimedLyricText).evaluate().length,
      lessThan(20),
      reason: 'only viewport rows should remain mounted while browsing',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cached lyric heights match wrapped text after width and font changes',
    (tester) async {
      final state = _WordPlaybackState()
        ..lyrics = [
          for (var i = 0; i < 30; i++)
            LyricLine(
              Duration(seconds: i * 4),
              i.isEven
                  ? 'A repeated chorus with enough words to wrap'
                  : 'Short verse $i',
              translation: i % 3 == 0
                  ? 'A repeated translated chorus with multiple words'
                  : null,
            ),
        ];
      addTearDown(state.dispose);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final width in [240.0, 640.0]) {
        tester.view.physicalSize = Size(width, 700);
        for (final fontSize in [22.0, 30.0]) {
          await state.setLyricFontSize(fontSize);
          await tester.pumpWidget(
            MaterialApp(
              theme: buildLegacyTheme(),
              home: Scaffold(body: LyricViewport(state: state)),
            ),
          );
          await tester.pump();
          final rows = find.byWidgetPredicate(
            (widget) =>
                widget is Positioned &&
                widget.key is ValueKey<String> &&
                (widget.key! as ValueKey<String>).value.startsWith(
                  'lyric-line-',
                ),
          );
          expect(rows, findsWidgets);
          for (final element in rows.evaluate()) {
            final row = element.widget as Positioned;
            final texts = find.descendant(
              of: find.byKey(row.key!),
              matching: find.byType(Text),
            );
            var height = 20.0;
            for (final text in texts.evaluate()) {
              height += tester.getSize(find.byWidget(text.widget)).height;
            }
            if (texts.evaluate().length > 1) height += 5;
            expect(row.height, closeTo(height, .001));
          }
        }
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('wheel scrolling has momentum and no framework scrollbar', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final content = Scaffold(
      body: ListView.builder(
        controller: controller,
        itemCount: 100,
        itemExtent: 60,
        itemBuilder: (_, i) => Text('$i'),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const AppScrollBehavior(retention: .95),
        home: content,
      ),
    );
    final center = tester.getCenter(find.byType(ListView));
    await tester.sendEventToBinding(
      PointerScrollEvent(position: center, scrollDelta: const Offset(0, 120)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final first = controller.offset;
    expect(first, greaterThan(0));
    expect(
      first,
      lessThan(40),
      reason: 'wheel motion must not jump the entire step',
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.offset, greaterThan(first));
    await tester.pumpAndSettle();
    expect(find.byType(Scrollbar), findsNothing);
    final low = const InertiaScrollPhysics(
      retention: .85,
    ).createBallisticSimulation(controller.position, 1000)!;
    final high = const InertiaScrollPhysics(
      retention: .98,
    ).createBallisticSimulation(controller.position, 1000)!;
    expect(
      high.x(.5) - controller.offset,
      greaterThan(low.x(.5) - controller.offset),
    );
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const AppScrollBehavior(retention: .98),
        home: content,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      (controller.position.physics as InertiaScrollPhysics).retention,
      .98,
      reason: 'changing the preference updates an already-mounted scroll view',
    );
  });

  testWidgets('the default settings hand the wheel back to Flutter', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final content = Scaffold(
      body: ListView.builder(
        controller: controller,
        itemCount: 100,
        itemExtent: 60,
        itemBuilder: (_, i) => Text('$i'),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(scrollBehavior: const AppScrollBehavior(), home: content),
    );
    final center = tester.getCenter(find.byType(ListView));
    await tester.sendEventToBinding(
      PointerScrollEvent(position: center, scrollDelta: const Offset(0, 120)),
    );
    await tester.pump();
    // Stock Flutter applies a wheel step synchronously and adds no momentum.
    final first = controller.offset;
    expect(first, greaterThan(0));
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.offset, first);
    await tester.pumpAndSettle();
    expect(find.byType(Scrollbar), findsNothing);
  });
}
