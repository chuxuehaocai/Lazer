import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/legacy/legacy_pages.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/local/local_library.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/playback_queue_store.dart';
import 'package:lazer_nextgen/widgets/settings_row.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _LocalLibrary extends LocalLibrary {
  @override
  Future<void> load() async {}
}

class _Catalog extends Catalog {
  @override
  Future<HomeFeed?> loadHome({int? userId}) async => null;
}

AppState _newState() => AppState(
  catalog: _Catalog(),
  localLibrary: _LocalLibrary(),
  queueStore: PlaybackQueueStore(read: () async => null, write: (_) async {}),
);

Future<AppState> _pumpSettings(
  WidgetTester tester, {
  AppState? existing,
}) async {
  tester.view.physicalSize = const Size(1280, 4200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final AppState state = existing ?? _newState();
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLegacyTheme(brightness: Brightness.dark),
      home: Scaffold(
        body: AnimatedBuilder(
          animation: state,
          builder: (BuildContext context, Widget? child) =>
              LegacySettingsPage(state: state),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets(
    'debug tools are visible by default while the frame overlay stays off',
    (tester) async {
      final AppState state = await _pumpSettings(tester);

      expect(
        state.showFrameStats,
        const bool.fromEnvironment('LAZER_FRAME_STATS'),
      );
      expect(find.text('调试'), findsOneWidget);
      expect(find.text('显示帧数'), findsOneWidget);
      expect(find.text('音频设备'), findsOneWidget);
      // The frame switch moved out of the performance group.
      expect(find.text('显示帧率'), findsNothing);

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('lazer_debug_options'), isFalse);
    },
  );

  testWidgets(
    'frame overlay can be toggled and persisted without hiding its controls',
    (tester) async {
      final state = await _pumpSettings(tester);
      final frame = find.text('显示帧数');
      await tester.ensureVisible(frame);
      final frameSwitch = find.descendant(
        of: find.byWidgetPredicate(
          (widget) => widget is SettingsRow && widget.label == '显示帧数',
        ),
        matching: find.byType(Switch),
      );
      await tester.tap(frameSwitch);
      await tester.pumpAndSettle();
      expect(state.showFrameStats, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('lazer_show_frame_stats'), isTrue);
      await tester.tap(frameSwitch);
      await tester.pumpAndSettle();
      expect(state.showFrameStats, isFalse);
      expect(prefs.getBool('lazer_show_frame_stats'), isFalse);
      expect(find.text('显示帧数'), findsOneWidget);
      expect(find.text('音频设备'), findsOneWidget);
      expect(prefs.containsKey('lazer_debug_options'), isFalse);
    },
  );

  for (final framePreference in [false, true]) {
    testWidgets(
      'old hidden-debug preference cannot hide tools or override FPS=$framePreference on bootstrap',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'lazer_debug_options': false,
          'lazer_show_frame_stats': framePreference,
        });
        final state = _newState();
        await tester.runAsync(state.bootstrap);
        expect(state.showFrameStats, framePreference);
        await _pumpSettings(tester, existing: state);
        expect(find.text('调试'), findsOneWidget);
        expect(find.text('显示帧数'), findsOneWidget);
        expect(find.text('音频设备'), findsOneWidget);
        expect(state.showFrameStats, framePreference);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('lazer_show_frame_stats'), framePreference);
      },
    );
  }

  testWidgets('the debug audio panel opens without an audio plugin', (
    tester,
  ) async {
    await _pumpSettings(tester);

    await tester.tap(find.byKey(const ValueKey('open-audio-device-info')));
    await tester.pump();
    // The audio_session plugin answers through a real platform channel; give
    // the real event loop a moment before pumping the result into the frame.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('音频设备'), findsNWidgets(2));
    // The widget test has no platform audio plugin, so the report falls back
    // to the unsupported notice instead of hanging or throwing.
    expect(find.text('当前平台不支持读取音频设备（仅 Android 与 iOS 支持）。'), findsOneWidget);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('完成'), findsNothing);
  });
}
