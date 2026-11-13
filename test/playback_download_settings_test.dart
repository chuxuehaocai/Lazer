import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/track_transition.dart';
import 'package:lazer_nextgen/ui/pages.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('settings choose playback and download quality', (tester) async {
    tester.view.physicalSize = const Size(1000, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState();
    addTearDown(state.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(brightness: Brightness.dark),
        home: Scaffold(body: AppSettingsPage(state: state)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('playback-quality')), findsOneWidget);
    expect(find.byKey(const ValueKey('download-quality')), findsOneWidget);
    expect(find.byKey(const ValueKey('open-download-queue')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('playback-quality')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(AudioQuality.lossless.label).last);
    await tester.pumpAndSettle();
    expect(state.playbackQuality, AudioQuality.lossless);

    await tester.tap(find.byKey(const ValueKey('download-quality')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(AudioQuality.standard.label).last);
    await tester.pumpAndSettle();
    expect(state.downloadQuality, AudioQuality.standard);
  });

  testWidgets('settings choose how one song reaches the next', (tester) async {
    tester.view.physicalSize = const Size(1000, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState();
    addTearDown(state.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(brightness: Brightness.dark),
        home: Scaffold(body: AppSettingsPage(state: state)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('track-transition')), findsOneWidget);
    expect(state.trackTransition, TrackTransition.albumGapless);
    expect(find.text(TrackTransition.albumGapless.label), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('track-transition-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(TrackTransition.autoMix.label).last);
    await tester.pumpAndSettle();

    expect(state.trackTransition, TrackTransition.autoMix);
    expect(state.autoMixEnabled, isTrue);
    expect(
      (await SharedPreferences.getInstance()).getBool('lazer_automix_enabled'),
      isTrue,
    );
  });

  testWidgets('the download group links to local music', (tester) async {
    tester.view.physicalSize = const Size(1000, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState();
    addTearDown(state.dispose);
    int opened = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(brightness: Brightness.dark),
        home: Scaffold(
          body: AppSettingsPage(state: state, onOpenLocalMusic: () => opened++),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder manage = find.byKey(
      const ValueKey('open-local-music-settings'),
    );
    expect(manage, findsOneWidget);
    await tester.ensureVisible(manage);
    await tester.pumpAndSettle();
    await tester.tap(manage);
    expect(opened, 1);
  });
}
