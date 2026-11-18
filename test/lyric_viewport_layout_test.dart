import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/lyrics/lyric_document.dart';
import 'package:lazer_nextgen/lyrics/viewport.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';

List<LyricLine> _document() => [
  for (var index = 0; index < 4; index++)
    LyricLine(
      Duration(seconds: index * 4),
      'Line $index',
      translation: 'Translation $index',
    ),
];

class _PlaybackState extends AppState {
  _PlaybackState() {
    lyrics = _document();
  }

  final lane = ChangeNotifier();
  String trackId = 'layout';
  Duration duration = const Duration(seconds: 30);

  @override
  Listenable get all => lane;

  @override
  Track get current => Track(
    id: trackId,
    title: 'Fixture',
    artist: 'Artist',
    album: 'Album',
    duration: duration,
    coverSeed: 1,
  );

  @override
  bool get playing => false;

  @override
  Duration get position => Duration.zero;

  @override
  Duration get precisePosition => Duration.zero;

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

void _expectReadableRows(WidgetTester tester) {
  for (var index = 0; index < 3; index++) {
    final original = tester.getRect(find.text('Line $index'));
    final translation = tester.getRect(find.text('Translation $index'));
    final next = tester.getRect(find.text('Line ${index + 1}'));
    expect(translation.top, greaterThanOrEqualTo(original.bottom));
    expect(
      next.top,
      greaterThan(translation.bottom),
      reason: 'Row ${index + 1} must not overlap row $index or its translation',
    );
  }
  expect(tester.takeException(), isNull);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final replacement in ['document', 'track', 'duration']) {
    testWidgets('$replacement replacement is readable on its first frame', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = _PlaybackState();
      addTearDown(state.dispose);
      await _show(tester, state);
      await tester.pumpAndSettle();
      _expectReadableRows(tester);

      // A cached document can be replaced by an equivalent remote result.
      // Inspect every first frame, without letting springs settle in between.
      for (var refresh = 0; refresh < 3; refresh++) {
        switch (replacement) {
          case 'document':
            state.lyrics = _document();
          case 'track':
            state.trackId = 'replacement-$refresh';
          case 'duration':
            state.duration += const Duration(seconds: 1);
        }
        state.lane.notifyListeners();
        await tester.pump();
        _expectReadableRows(tester);
        await tester.pump(const Duration(milliseconds: 16));
        _expectReadableRows(tester);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('lyrics refreshed in the background are readable when resumed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = _PlaybackState();
    addTearDown(state.dispose);
    await _show(tester, state);
    await tester.pumpAndSettle();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    state.lyrics = _document();
    state.lane.notifyListeners();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    _expectReadableRows(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a hidden pane can replace its lyrics without overlapping rows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = _PlaybackState();
    addTearDown(state.dispose);
    await _show(tester, state);
    await tester.pumpAndSettle();
    await _show(tester, state, visible: false);
    state.lyrics = _document();
    state.lane.notifyListeners();
    await _show(tester, state, visible: false);
    _expectReadableRows(tester);
    await _show(tester, state);
    _expectReadableRows(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
