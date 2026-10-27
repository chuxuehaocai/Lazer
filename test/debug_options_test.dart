import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/legacy/legacy_pages.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<AppState> _pumpSettings(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 4200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final AppState state = AppState();
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

  testWidgets('seven taps on the version card reveal the debug section', (
    tester,
  ) async {
    final AppState state = await _pumpSettings(tester);

    expect(state.debugOptionsEnabled, isFalse);
    expect(find.text('调试'), findsNothing);
    expect(find.text('显示帧数'), findsNothing);
    // The frame switch moved out of the performance group.
    expect(find.text('显示帧率'), findsNothing);

    final Finder version = find.text('Lazer');
    await tester.ensureVisible(version);
    for (var tap = 0; tap < 6; tap++) {
      await tester.tap(version);
      await tester.pump(const Duration(milliseconds: 40));
    }
    await tester.pumpAndSettle();
    expect(
      state.debugOptionsEnabled,
      isFalse,
      reason: 'six taps must not unlock the debug section',
    );

    await tester.tap(version);
    await tester.pumpAndSettle();
    expect(state.debugOptionsEnabled, isTrue);
    expect(find.text('调试'), findsOneWidget);
    expect(find.text('显示帧数'), findsOneWidget);
    expect(find.text('音频设备'), findsOneWidget);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('lazer_debug_options'), isTrue);

    // Disabling the section also stops the overlay, otherwise it would stay
    // on screen with no switch left to turn it off.
    await state.setShowFrameStats(true);
    await tester.pumpAndSettle();
    expect(state.showFrameStats, isTrue);
    await tester.ensureVisible(version);
    for (var tap = 0; tap < 7; tap++) {
      await tester.tap(version);
      await tester.pump(const Duration(milliseconds: 40));
    }
    await tester.pumpAndSettle();
    expect(state.debugOptionsEnabled, isFalse);
    expect(state.showFrameStats, isFalse);
    expect(find.text('显示帧数'), findsNothing);
    expect(prefs.getBool('lazer_debug_options'), isFalse);
    expect(prefs.getBool('lazer_show_frame_stats'), isFalse);
  });

  testWidgets('the debug audio panel opens without an audio plugin', (
    tester,
  ) async {
    final AppState state = await _pumpSettings(tester);
    await state.setDebugOptionsEnabled(true);
    await tester.pumpAndSettle();

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
