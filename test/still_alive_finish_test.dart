import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/animation/view_transitions.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/easter_egg/still_alive_audio.dart';
import 'package:lazer_nextgen/easter_egg/still_alive_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';

class _HostState extends AppState {
  _HostState() {
    autoDpiScale = false;
    layoutStyle = AppLayoutStyle.desktop;
  }

  @override
  Future<void> bootstrap() async {}

  @override
  bool get autoUpdateCheckDue => false;

  @override
  HomeFeed get home => const HomeFeed(
    featuredTracks: [],
    quick: [],
    daily: [],
    playlists: [],
    recommended: [],
    albums: [],
  );
}

class _RecordingPlayback extends ChangeNotifier implements StillAlivePlayback {
  _RecordingPlayback({required this.trackDuration});

  final Duration trackDuration;
  int pauseCalls = 0;
  bool _completed = false;
  Duration _position = Duration.zero;

  @override
  bool get ready => true;
  @override
  bool get playing => !_completed;
  @override
  bool get completed => _completed;
  @override
  Duration get position => _position;
  @override
  Duration? get duration => trackDuration;
  @override
  String? get error => null;
  @override
  Future<void> load() async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {
    pauseCalls++;
  }

  @override
  Future<void> restart() async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> close() async {}

  /// Reports the decoder reaching the end of the bundled track.
  void reportCompletion() {
    _completed = true;
    _position = trackDuration;
    notifyListeners();
  }
}

/// Pumps the page until the credits have been rendered at least once.
Future<void> _settle(WidgetTester tester, {int frames = 30}) async {
  for (var index = 0; index < frames; index++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

String _frameText(WidgetTester tester) {
  final text = tester.widget<Text>(
    find.byKey(const ValueKey('frums-credits-animation')),
  );
  return text.data ?? '';
}

Future<_RecordingPlayback> _openEgg(
  WidgetTester tester, {
  Duration trackDuration = const Duration(seconds: 98),
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final playback = _RecordingPlayback(trackDuration: trackDuration);
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(onPressed: () {}, child: const Text('open')),
          ),
        ),
      ),
    ),
  );
  await tester.pump();

  final navigator = Navigator.of(tester.element(find.text('open')));
  unawaited(
    navigator.push<void>(
      ApplePageRoute<void>(
        builder: (_) =>
            StillAlivePage(playback: playback, appState: _HostState()),
      ),
    ),
  );
  await tester.pump();
  await _settle(tester);
  return playback;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'the credits hold their last frame and pause when the score ends',
    (tester) async {
      final playback = await _openEgg(tester);
      expect(playback.pauseCalls, 0, reason: 'the soundtrack is still playing');

      // The score runs 72 bars of four beats at 179 BPM; the fake clock only
      // advances while the ticker is pumping frames.
      for (var step = 0; step < 60; step++) {
        await tester.pump(const Duration(seconds: 2));
      }

      final held = _frameText(tester);
      expect(held.trim().isNotEmpty, isTrue);

      // A finished score keeps its closing frame instead of wrapping around.
      for (var step = 0; step < 10; step++) {
        await tester.pump(const Duration(seconds: 2));
      }
      expect(_frameText(tester), held);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('the soundtrack completion pauses playback once', (tester) async {
    final playback = await _openEgg(tester);
    expect(playback.pauseCalls, 0);

    playback.reportCompletion();
    await tester.pump();
    expect(playback.pauseCalls, 1);

    // Repeated reports must not keep re-issuing pause on a finished page.
    playback.reportCompletion();
    await tester.pump();
    expect(playback.pauseCalls, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('the soundtrack completion returns to the previous page', (
    tester,
  ) async {
    final playback = await _openEgg(tester);
    expect(find.byKey(const ValueKey('still-alive-report')), findsOneWidget);

    playback.reportCompletion();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('still-alive-report')), findsNothing);
    expect(find.text('open'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
