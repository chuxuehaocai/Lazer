import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/lyrics/lyric_document.dart';
import 'package:lazer_nextgen/lyrics/viewport.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';

class _PlaybackState extends AppState {
  _PlaybackState() {
    lyrics = const [
      LyricLine(
        Duration.zero,
        'First',
        words: [LyricWord(Duration.zero, Duration(seconds: 1), 'First')],
      ),
      LyricLine(
        Duration(seconds: 5),
        'Second',
        words: [
          LyricWord(Duration(seconds: 5), Duration(seconds: 1), 'Second'),
        ],
      ),
    ];
  }

  Duration playhead = Duration.zero;
  int positionReads = 0;
  final lane = ChangeNotifier();

  @override
  Listenable get all => lane;

  @override
  Track get current => const Track(
    id: 'lyric-lifecycle',
    title: 'Fixture',
    artist: 'Artist',
    album: 'Album',
    duration: Duration(seconds: 30),
    coverSeed: 1,
  );

  @override
  bool get playing => true;

  @override
  Duration get position => playhead;

  @override
  Duration get precisePosition {
    positionReads++;
    return playhead;
  }

  void report(Duration value) {
    playhead = value;
    lane.notifyListeners();
  }

  @override
  void dispose() {
    lane.dispose();
    super.dispose();
  }
}

Future<void> _show(
  WidgetTester tester,
  _PlaybackState state, {
  bool visible = true,
}) => tester.pumpWidget(
  MaterialApp(
    theme: buildAppleTheme(),
    home: TickerMode(
      enabled: visible,
      child: Scaffold(body: LyricViewport(state: state)),
    ),
  ),
);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('finished word motion stops polling and seeks restart it', (
    tester,
  ) async {
    final state = _PlaybackState()..playhead = const Duration(seconds: 3);
    addTearDown(state.dispose);
    await _show(tester, state);
    await _settle(tester);
    final reads = state.positionReads;
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pump(const Duration(milliseconds: 100));
    expect(state.positionReads, reads);

    // Seeking within the same active line must wake a stopped word painter.
    state.report(const Duration(milliseconds: 500));
    await tester.pump();
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    final resumedReads = state.positionReads;
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 4));
    }
    expect(state.positionReads - resumedReads, 8);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('playback notification wakes the next word line after idle', (
    tester,
  ) async {
    final state = _PlaybackState()..playhead = const Duration(seconds: 3);
    addTearDown(state.dispose);
    await _show(tester, state);
    await _settle(tester);
    expect(tester.binding.transientCallbackCount, 0);
    state.report(const Duration(milliseconds: 5500));
    await tester.pump();
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('word animation includes the emphasized trailing float', (
    tester,
  ) async {
    final state = _PlaybackState()
      ..playhead = const Duration(milliseconds: 1400);
    addTearDown(state.dispose);
    await _show(tester, state);
    await _settle(tester);
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('hidden lyrics ignore playback notifications and catch up', (
    tester,
  ) async {
    final state = _PlaybackState();
    addTearDown(state.dispose);
    await _show(tester, state);
    await tester.pump();
    await _show(tester, state, visible: false);
    await _settle(tester);
    final reads = state.positionReads;
    state.report(const Duration(milliseconds: 5500));
    await tester.pump();
    expect(state.positionReads, reads);
    expect(tester.binding.transientCallbackCount, 0);

    await _show(tester, state);
    await tester.pump();
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    expect(state.positionReads, greaterThan(reads));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('background lyrics stop work until the app resumes', (
    tester,
  ) async {
    final state = _PlaybackState();
    addTearDown(state.dispose);
    await _show(tester, state);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    final reads = state.positionReads;
    state.report(const Duration(milliseconds: 5500));
    expect(state.positionReads, reads);
    expect(tester.binding.transientCallbackCount, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
