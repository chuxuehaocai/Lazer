import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/media_shortcuts.dart';
import 'package:lazer_nextgen/widgets/media_shortcut_listener.dart';
import 'package:lazer_nextgen/widgets/shortcut_recorder_dialog.dart';

class _ShortcutState extends AppState {
  final bindings = MediaShortcutSettings.defaults();
  int playCount = 0;
  int muteCount = 0;

  @override
  Map<MediaShortcutAction, MediaShortcutBinding?> get mediaShortcuts =>
      bindings;

  @override
  void togglePlay() => playCount++;

  @override
  Future<void> toggleMute() async => muteCount++;
}

Future<void> _chord(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('focused button owns Space without also firing media binding', (
    tester,
  ) async {
    final state = _ShortcutState();
    addTearDown(state.dispose);
    state.bindings[MediaShortcutAction.mute] = const MediaShortcutBinding(
      LogicalKeyboardKey.space,
    );
    var presses = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaShortcutListener(
          state: state,
          child: Scaffold(
            body: TextButton(
              autofocus: true,
              onPressed: () => presses++,
              child: const Text('Action'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(presses, 1);
    expect(state.muteCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('local keyboard action takes priority over a media binding', (
    tester,
  ) async {
    final state = _ShortcutState();
    addTearDown(state.dispose);
    var localCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaShortcutListener(
          state: state,
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(
                LogicalKeyboardKey.keyP,
                control: true,
              ): () =>
                  localCount++,
            },
            child: const Focus(autofocus: true, child: SizedBox()),
          ),
        ),
      ),
    );
    await tester.pump();
    await _chord(tester, LogicalKeyboardKey.keyP);
    expect(localCount, 1);
    expect(state.playCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('unhandled media shortcuts work and detach when removed', (
    tester,
  ) async {
    final state = _ShortcutState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaShortcutListener(
          state: state,
          child: const Focus(autofocus: true, child: SizedBox()),
        ),
      ),
    );
    await tester.pump();
    await _chord(tester, LogicalKeyboardKey.keyP);
    expect(state.playCount, 1);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await _chord(tester, LogicalKeyboardKey.keyP);
    expect(state.playCount, 1);
  });

  testWidgets('restoring a held key does not dispatch a media action', (
    tester,
  ) async {
    final state = _ShortcutState();
    addTearDown(state.dispose);
    state.bindings[MediaShortcutAction.mute] = const MediaShortcutBinding(
      LogicalKeyboardKey.keyM,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: MediaShortcutListener(
          state: state,
          child: const Focus(autofocus: true, child: SizedBox()),
        ),
      ),
    );
    await tester.pump();
    HardwareKeyboard.instance.handleKeyEvent(
      const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyM,
        logicalKey: LogicalKeyboardKey.keyM,
        timeStamp: Duration.zero,
        synthesized: true,
      ),
    );
    HardwareKeyboard.instance.handleKeyEvent(
      const KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.keyM,
        logicalKey: LogicalKeyboardKey.keyM,
        timeStamp: Duration(milliseconds: 1),
        synthesized: true,
      ),
    );
    await tester.pump();
    expect(state.muteCount, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    expect(state.muteCount, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('editing text and recording a shortcut suppress playback', (
    tester,
  ) async {
    final state = _ShortcutState();
    addTearDown(state.dispose);
    late BuildContext pageContext;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaShortcutListener(
          state: state,
          child: Scaffold(
            body: Builder(
              builder: (context) {
                pageContext = context;
                return const TextField(autofocus: true);
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await _chord(tester, LogicalKeyboardKey.keyP);
    expect(state.playCount, 0);
    final dialog = showShortcutRecorderDialog(
      pageContext,
      action: MediaShortcutAction.playPause,
      current: state.bindings[MediaShortcutAction.playPause],
      conflict: (_) => null,
    );
    await tester.pumpAndSettle();
    await _chord(tester, LogicalKeyboardKey.keyP);
    expect(state.playCount, 0);
    await tester.tap(find.byKey(const ValueKey('shortcut-save')));
    await tester.pumpAndSettle();
    expect(
      (await dialog)?.binding,
      state.bindings[MediaShortcutAction.playPause],
    );
    expect(MediaShortcutRecorder.active, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('shortcut recorder stays usable in a short large-text window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(480, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late BuildContext pageContext;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: Builder(
          builder: (context) {
            pageContext = context;
            return const Scaffold();
          },
        ),
      ),
    );
    final dialog = showShortcutRecorderDialog(
      pageContext,
      action: MediaShortcutAction.previousTrack,
      current: kDefaultMediaShortcuts[MediaShortcutAction.previousTrack],
      conflict: (_) => MediaShortcutAction.nextTrack,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _chord(tester, LogicalKeyboardKey.keyN);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final save = tester.widget<FilledButton>(
      find.descendant(
        of: find.byKey(const ValueKey('shortcut-save')),
        matching: find.byType(FilledButton),
      ),
    );
    expect(save.onPressed, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(await dialog, isNull);
    expect(MediaShortcutRecorder.active, isFalse);
  });
}
