import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/lyrics/image_export.dart';
import 'package:lazer_nextgen/lyrics/lyric_document.dart';
import 'package:lazer_nextgen/lyrics/selection_bar.dart';
import 'package:lazer_nextgen/lyrics/viewport.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';

class _PlaybackState extends AppState {
  _PlaybackState() {
    lyrics = [
      for (var index = 0; index < 30; index++)
        LyricLine(Duration(seconds: index * 2), 'Line $index'),
    ];
    lyricResumeSeconds = .2;
  }

  final lane = ChangeNotifier();
  final seeks = <double>[];
  Duration playhead = Duration.zero;
  String trackId = 'mobile-lyrics';

  @override
  Listenable get all => lane;

  @override
  Track get current => Track(
    id: trackId,
    title: 'Fixture',
    artist: 'Artist',
    album: 'Album',
    duration: const Duration(seconds: 60),
    coverSeed: 1,
  );

  @override
  bool get playing => false;

  @override
  Duration get position => playhead;

  @override
  Duration get precisePosition => playhead;

  @override
  Future<void> feedback({bool detent = false, bool boundary = false}) async {}

  @override
  void seek(double fraction) {
    seeks.add(fraction);
    playhead = current.duration * fraction;
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
  ValueChanged<bool>? onSelectionChanged,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppleTheme(),
      home: TickerMode(
        enabled: visible,
        child: Scaffold(
          body: LyricViewport(
            state: state,
            onSelectionChanged: onSelectionChanged,
          ),
        ),
      ),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

LyricSelectionToolbar _toolbar(WidgetTester tester) =>
    tester.widget<LyricSelectionToolbar>(find.byType(LyricSelectionToolbar));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('closing selection while a finger is held does not revive it', (
    tester,
  ) async {
    final state = _PlaybackState();
    addTearDown(state.dispose);
    final selections = <bool>[];
    await _show(tester, state, onSelectionChanged: selections.add);
    await _settle(tester);

    final hold = await tester.startGesture(
      tester.getCenter(find.text('Line 0')),
      pointer: 7,
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(_toolbar(tester).count, 1);
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();
    await hold.moveBy(const Offset(0, 90));
    await tester.pump();
    await hold.up();
    await _settle(tester);

    expect(selections, [true, false]);
    expect(find.byType(LyricSelectionToolbar), findsNothing);
    await tester.tap(find.text('Line 1'));
    await tester.pump();
    expect(state.seeks, [2 / 60]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a held lyric cannot select a replacement song', (tester) async {
    final state = _PlaybackState();
    addTearDown(state.dispose);
    final selections = <bool>[];
    await _show(tester, state, onSelectionChanged: selections.add);
    await _settle(tester);

    final hold = await tester.startGesture(
      tester.getCenter(find.text('Line 0')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(_toolbar(tester).count, 1);
    state
      ..trackId = 'replacement'
      ..lyrics = const [LyricLine(Duration.zero, 'Replacement')];
    state.lane.notifyListeners();
    await tester.pump();
    await hold.moveBy(const Offset(0, 40));
    await hold.up();
    await _settle(tester);

    expect(selections, [true, false]);
    expect(find.byType(LyricSelectionToolbar), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Replacement'));
    expect(state.seeks, [0]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a pending long press is cancelled when its document changes', (
    tester,
  ) async {
    final state = _PlaybackState();
    addTearDown(state.dispose);
    final selections = <bool>[];
    await _show(tester, state, onSelectionChanged: selections.add);
    await _settle(tester);

    final hold = await tester.startGesture(
      tester.getCenter(find.text('Line 0')),
    );
    await tester.pump(const Duration(milliseconds: 100));
    state.lyrics = const [LyricLine(Duration.zero, 'Replacement')];
    state.lane.notifyListeners();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await hold.up();
    await _settle(tester);

    expect(selections, isEmpty);
    expect(find.byType(LyricSelectionToolbar), findsNothing);
    expect(state.seeks, isEmpty);
    await tester.tap(find.text('Replacement'));
    expect(state.seeks, [0]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'hiding the pane clears selection and releases its gesture lock',
    (tester) async {
      final state = _PlaybackState();
      addTearDown(state.dispose);
      final selections = <bool>[];
      await _show(tester, state, onSelectionChanged: selections.add);
      await _settle(tester);
      await tester.longPress(find.text('Line 0'));
      await tester.pump();
      expect(_toolbar(tester).count, 1);

      await _show(
        tester,
        state,
        visible: false,
        onSelectionChanged: selections.add,
      );
      expect(find.byType(LyricSelectionToolbar), findsNothing);
      await _show(tester, state, onSelectionChanged: selections.add);
      await _settle(tester);

      expect(selections, [true, false]);
      expect(find.byType(LyricSelectionToolbar), findsNothing);
      await tester.tap(find.text('Line 1'));
      expect(state.seeks, [2 / 60]);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('backgrounding cancels an unfinished long press selection', (
    tester,
  ) async {
    final state = _PlaybackState();
    addTearDown(state.dispose);
    final selections = <bool>[];
    await _show(tester, state, onSelectionChanged: selections.add);
    await _settle(tester);
    final hold = await tester.startGesture(
      tester.getCenter(find.text('Line 0')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(_toolbar(tester).count, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await hold.moveBy(const Offset(0, 70));
    await hold.cancel();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _settle(tester);

    expect(selections, [true, false]);
    expect(find.byType(LyricSelectionToolbar), findsNothing);
    await tester.tap(find.text('Line 1'));
    expect(state.seeks, [2 / 60]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a pending long press cannot outlive hiding and reopening', (
    tester,
  ) async {
    final state = _PlaybackState();
    addTearDown(state.dispose);
    final selections = <bool>[];
    await _show(tester, state, onSelectionChanged: selections.add);
    await _settle(tester);
    final hold = await tester.startGesture(
      tester.getCenter(find.text('Line 0')),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await _show(
      tester,
      state,
      visible: false,
      onSelectionChanged: selections.add,
    );
    await _show(tester, state, onSelectionChanged: selections.add);
    await tester.pump(const Duration(milliseconds: 600));
    await hold.up();
    await _settle(tester);

    expect(selections, isEmpty);
    expect(find.byType(LyricSelectionToolbar), findsNothing);
    await tester.tap(find.text('Line 1'));
    expect(state.seeks, [2 / 60]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an outgoing toolbar cannot reselect after it is closed', (
    tester,
  ) async {
    final state = _PlaybackState();
    addTearDown(state.dispose);
    final selections = <bool>[];
    await _show(tester, state, onSelectionChanged: selections.add);
    await _settle(tester);
    await tester.longPress(find.text('Line 0'));
    await tester.pump();

    final toolbar = _toolbar(tester);
    toolbar.onClose();
    toolbar.onSelectAll();
    await _settle(tester);

    expect(selections, [true, false]);
    expect(find.byType(LyricSelectionToolbar), findsNothing);
    await tester.tap(find.text('Line 1'));
    expect(state.seeks, [2 / 60]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('rapid image requests present only one dialog', (tester) async {
    final state = _PlaybackState();
    addTearDown(state.dispose);
    await _show(tester, state);
    await _settle(tester);
    await tester.longPress(find.text('Line 0'));
    await tester.pump();

    final toolbar = _toolbar(tester);
    toolbar.onCreateImage();
    toolbar.onCreateImage();
    toolbar.onCreateImage();
    await _settle(tester);
    expect(find.byType(LyricImageDialog, skipOffstage: false), findsOneWidget);

    Navigator.of(tester.element(find.byType(LyricImageDialog))).pop();
    await _settle(tester);
    expect(find.byType(LyricImageDialog, skipOffstage: false), findsNothing);
    expect(find.byType(LyricSelectionToolbar), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cancelled selection invalidates an awaiting image request', (
    tester,
  ) async {
    final state = _PlaybackState();
    addTearDown(state.dispose);
    await _show(tester, state);
    await _settle(tester);
    await tester.longPress(find.text('Line 0'));
    await tester.pump();

    final toolbar = _toolbar(tester);
    toolbar.onCreateImage();
    toolbar.onClose();
    await _settle(tester);

    expect(find.byType(LyricImageDialog, skipOffstage: false), findsNothing);
    expect(find.byType(LyricSelectionToolbar), findsNothing);
    await tester.tap(find.text('Line 1'));
    expect(state.seeks, [2 / 60]);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
