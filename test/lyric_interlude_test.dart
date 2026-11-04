import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/lyrics/interlude.dart';
import 'package:lazer_nextgen/lyrics/lyric_document.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/widgets/lyric_viewport.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Playback extends AppState {
  Duration playhead = Duration.zero;
  Duration trackDuration = const Duration(seconds: 14);
  bool isPlaying = false;
  _Playback() {
    lyrics = const [
      LyricLine(Duration.zero, 'Before'),
      LyricLine(Duration(seconds: 3), ''),
      LyricLine(Duration(seconds: 10), 'After'),
      LyricLine(Duration(seconds: 12), 'Last'),
    ];
  }
  void report(int milliseconds) {
    playhead = Duration(milliseconds: milliseconds);
    notifyListeners();
  }

  @override
  Track get current => Track(
    id: 'interlude',
    title: 'Test',
    artist: 'Test',
    album: 'Test',
    duration: trackDuration,
    coverSeed: 0,
  );
  @override
  Duration get precisePosition => playhead;
  @override
  bool get playing => isPlaying;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('timeline retains blanks and infers intro, exact and long LRC gaps', () {
    final timeline = lyricsWithInterludes(const [
      LyricLine(Duration(seconds: 5), 'First', end: Duration(seconds: 9)),
      LyricLine(Duration(seconds: 15), 'Second'),
      LyricLine(Duration(seconds: 31), 'Third'),
    ], const Duration(seconds: 35));
    expect(timeline.map((line) => line.time.inSeconds), [0, 5, 9, 15, 23, 31]);
    expect(
      timeline
          .where((line) => line.text.isEmpty)
          .map((line) => line.end!.inSeconds),
      [5, 15, 31],
    );
    final explicit = lyricsWithInterludes(const [
      LyricLine(Duration.zero, 'First', end: Duration(seconds: 2)),
      LyricLine(Duration(seconds: 8), ''),
      LyricLine(Duration(seconds: 15), 'Second'),
    ], const Duration(seconds: 18));
    expect(explicit.where((line) => line.text.isEmpty), hasLength(1));
  });

  test(
    'old player hold, sequential lighting, breath and exit phases remain',
    () {
      expect(lyricInterludeSnapshot(5000, 11000, 5200).opacity, 0);
      final entered = lyricInterludeSnapshot(5000, 11000, 6500);
      expect(entered.opacity, greaterThan(.99));
      expect(entered.scale, greaterThanOrEqualTo(1));
      expect(
        entered.dotOpacities.first,
        greaterThan(entered.dotOpacities.last),
      );
      final exiting = lyricInterludeSnapshot(5000, 11000, 10500);
      expect(exiting.scale, greaterThan(1));
      expect(exiting.opacity, greaterThan(0));
      expect(
        lyricInterludeSnapshot(5000, 11000, 11000).opacity,
        closeTo(0, .001),
      );
      expect(lyricInterludeSnapshot(5000, 6000, 5500).opacity, 0);
    },
  );

  testWidgets(
    'blank row enters and preserves its last visual while collapsing',
    (tester) async {
      final state = _Playback();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(),
          home: Scaffold(body: LyricViewport(state: state)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(LyricInterludeDots), findsNothing);
      state.report(4500);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      expect(find.byType(LyricInterludeDots), findsOneWidget);
      final dots = tester.widget<LyricInterludeDots>(
        find.byType(LyricInterludeDots),
      );
      final halfway = dots.presence();
      expect(halfway, greaterThan(0));
      expect(halfway, lessThan(1));
      await tester.pumpAndSettle();
      expect(dots.presence(), 1);
      state.report(10200);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      expect(find.byType(LyricInterludeDots), findsOneWidget);
      expect(dots.presence(), lessThan(1));
      final paintFinder = find.descendant(
        of: find.byType(LyricInterludeDots),
        matching: find.byType(CustomPaint),
      );
      final recording = TestRecordingCanvas();
      tester
          .widget<CustomPaint>(paintFinder)
          .painter!
          .paint(recording, tester.getSize(paintFinder));
      expect(
        recording.invocations.where(
          (call) => call.invocation.memberName == #drawCircle,
        ),
        hasLength(6),
        reason: 'rebuilding the outgoing row must retain all three lit dots',
      );
      await tester.pumpAndSettle();
      expect(find.byType(LyricInterludeDots), findsNothing);
      // Seeking back must insert the same passage again without stale indices.
      state.report(6000);
      await tester.pumpAndSettle();
      expect(find.byType(LyricInterludeDots), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('duration arriving later creates the inferred trailing passage', (
    tester,
  ) async {
    final state = _Playback()..trackDuration = Duration.zero;
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(),
        home: Scaffold(body: LyricViewport(state: state)),
      ),
    );
    await tester.pumpAndSettle();
    final original = state.lyrics;
    state.trackDuration = const Duration(seconds: 30);
    state.report(24000);
    await tester.pumpAndSettle();
    expect(identical(original, state.lyrics), isTrue);
    final dots = tester.widget<LyricInterludeDots>(
      find.byType(LyricInterludeDots),
    );
    expect(dots.line.time, const Duration(seconds: 20));
    expect(dots.line.end, const Duration(seconds: 30));
    expect(tester.takeException(), isNull);
  });
}
