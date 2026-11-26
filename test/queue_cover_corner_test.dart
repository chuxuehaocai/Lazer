import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/theme/lazer_theme.dart';
import 'package:lazer_nextgen/theme/shape_scale.dart';
import 'package:lazer_nextgen/widgets/playback_queue_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

Track _track(int index) => Track(
  id: 'corner-$index',
  title: 'Song $index',
  artist: 'Artist',
  album: 'Album',
  duration: const Duration(minutes: 3),
  coverSeed: index,
);

/// A queue of three so the rows under test are not the current song: the
/// current row's highlight is a different surface, and one thing per test.
class _QueueState extends AppState {
  _QueueState() {
    layoutStyle = AppLayoutStyle.desktop;
    playerBackground = AppBackgroundMode.off;
  }

  @override
  List<Track> get queue => <Track>[_track(1), _track(2), _track(3)];
  @override
  int get queueLength => 3;
  @override
  int get queueIndex => 0;
  @override
  Track get current => _track(1);
  @override
  bool get playing => false;
}

/// The radius each 44 px queue cover is actually clipped to.
List<double> _coverRadii(WidgetTester tester) => tester
    .widgetList<ClipRRect>(find.byType(ClipRRect))
    .where(
      (ClipRRect clip) =>
          clip.child is SizedBox &&
          (clip.child! as SizedBox).width == 44 &&
          (clip.child! as SizedBox).height == 44,
    )
    .map(
      (ClipRRect clip) =>
          clip.borderRadius.resolve(TextDirection.ltr).topLeft.x,
    )
    .toList();

Future<void> _mount(WidgetTester tester, _QueueState state) async {
  tester.view.physicalSize = const Size(900, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppleTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: AppleShape(
          scale: AppleShape.resolve(
            followTheme: state.cornerFollowsTheme,
            customPx: state.cornerPx,
            theme: LazerThemeTokens.mio,
          ),
          cardPx: state.cornerPx,
          manual: !state.cornerFollowsTheme,
          capsulePx: 0,
          navBarPx: 0,
          child: child!,
        ),
      ),
      home: Scaffold(body: PlaybackQueueView(state: state)),
    ),
  );
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  for (final double cornerPx in <double>[0, 8, 14, 20]) {
    testWidgets('queue covers clip at the configured ${cornerPx}px corner', (
      tester,
    ) async {
      // The 44 px queue thumbnail was clipped with `AppShape.smRadius` — a
      // literal 8 — so this one list ignored 「设置 → 圆角大小」 entirely:
      // 0 px squared every card in the app except these rows, and a larger
      // corner left them looking unfinished next to the row's own highlight.
      final state = _QueueState()
        ..cornerFollowsTheme = false
        ..cornerPx = cornerPx;
      await _mount(tester, state);
      expect(tester.takeException(), isNull);

      final List<double> radii = _coverRadii(tester);
      expect(radii, isNotEmpty, reason: 'the queue rows must be on screen');
      // 44 px is the short edge, so the thumbnails cap at 44 / 4 = 11 px.
      final double expected = cornerPx > 11 ? 11 : cornerPx;
      for (final double radius in radii) {
        expect(radius, closeTo(expected, .01));
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('a zero corner squares the queue covers', (tester) async {
    final state = _QueueState()
      ..cornerFollowsTheme = false
      ..cornerPx = 0;
    await _mount(tester, state);
    expect(_coverRadii(tester), everyElement(0));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the row highlight and the cover share one corner', (
    tester,
  ) async {
    // The Material behind each row reads `cardRadiusOf`; the cover used to read
    // a fixed 8. At 20 px the highlight curved and the artwork inside it did
    // not, which is what the screenshot shows.
    final state = _QueueState()
      ..cornerFollowsTheme = false
      ..cornerPx = 20;
    await _mount(tester, state);

    final List<Material> rows = tester
        .widgetList<Material>(find.byType(Material))
        .where((Material m) => m.borderRadius != null)
        .toList();
    expect(rows, isNotEmpty);
    final double rowRadius = rows.first.borderRadius!
        .resolve(TextDirection.ltr)
        .topLeft
        .x;
    expect(rowRadius, closeTo(20, .01));
    // Same source, but the cover is capped by its own short edge.
    expect(_coverRadii(tester).first, closeTo(11, .01));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
