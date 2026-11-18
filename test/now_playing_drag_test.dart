import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/audio/system_media_handler.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/l10n/app_localizations.dart';
import 'package:lazer_nextgen/main.dart';
import 'package:lazer_nextgen/navigation/pull_down_to_close.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/widgets/window_chrome.dart';

const _track = Track(
  id: 'fixture',
  title: 'Raspberry',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 3),
  coverSeed: 2,
);

class _DragState extends AppState {
  _DragState() {
    autoDpiScale = false;
    layoutStyle = AppLayoutStyle.desktop;
    titleBarStyle = DesktopTitleBarStyle.inline;
  }

  @override
  Future<void> bootstrap() async {}

  @override
  bool get autoUpdateCheckDue => false;

  @override
  Track get current => _track;

  @override
  bool get playing => false;

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

class _UnusedAudio extends Fake implements AudioEngine {
  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<List<String>> mountPlayer(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async {
        calls.add(call.method);
        return call.method.startsWith('is') ? false : null;
      },
    );
    await tester.runAsync(
      () => AppLocalizations.delegate.load(const Locale('en')),
    );
    final state = _DragState();
    await state.setIndependentPlayback(true);
    await tester.pumpWidget(
      LazerApp(
        state: state,
        audio: _UnusedAudio(),
        media: SystemMediaController(state),
        windowFrameEnabled: true,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Raspberry').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    return calls;
  }

  testWidgets('the player page top band drags the window', (tester) async {
    final calls = await mountPlayer(tester);
    expect(find.byKey(const ValueKey('desktop-now-playing')), findsOneWidget);

    // The capsule floats over the player too, so its band is the handle. Aim at
    // empty chrome between the collapse button and the song actions.
    calls.clear();
    await tester.dragFrom(const Offset(640, 30), const Offset(0, 60));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(calls, contains('startDragging'));

    // Below the band the page owns the pointer: the lyrics pane must not move
    // the window.
    calls.clear();
    await tester.dragFrom(const Offset(900, 420), const Offset(0, 60));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(calls, isNot(contains('startDragging')));
  });

  testWidgets('double-clicking the player band toggles the window size', (
    tester,
  ) async {
    final calls = await mountPlayer(tester);
    calls.clear();
    const point = Offset(640, 30);
    // A mouse, because a title bar answers to mouse double-clicks only.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: point);
    addTearDown(mouse.removePointer);
    await mouse.down(point);
    await mouse.up();
    await tester.pump(const Duration(milliseconds: 80));
    await mouse.down(point);
    await mouse.up();
    await tester.pump(const Duration(milliseconds: 200));
    expect(calls, contains('maximize'));
  });

  testWidgets('the desktop player keeps its pull-down below the band', (
    tester,
  ) async {
    await mountPlayer(tester);
    final page = tester.getRect(
      find.byKey(const ValueKey('desktop-now-playing')),
    );
    final region = find.byType(PlayerPullDownRegion);
    expect(region, findsOneWidget);
    expect(
      tester.getRect(region).top,
      closeTo(page.top + kInlineChromeInset, .5),
      reason: 'pull-down must start under the window drag band',
    );
  });
}
