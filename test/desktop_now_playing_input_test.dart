import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/lyrics.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/player/desktop_now_playing.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/tv/tv_mode.dart';
import 'package:lazer_nextgen/widgets/media_shortcut_listener.dart';

class _State extends AppState {
  _State() {
    lyricControlsSeconds = 1;
    lyrics = parseLrc('[00:00.00]First line\n[00:04.00]Second line');
  }

  @override
  Track get current => const Track(
    id: 'desktop-input',
    title: 'Desktop input',
    artist: 'Artist',
    album: 'Album',
    duration: Duration(minutes: 3),
    coverSeed: 1,
  );

  @override
  Future<void> ensureCurrentLyrics({bool force = false}) async {}
}

Widget _host(AppState state, {bool tv = false}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: true),
    child: child!,
  ),
  home: TvScope(
    active: tv,
    child: MediaShortcutListener(
      state: state,
      child: NowPlayingPage(state: state),
    ),
  ),
);

bool _visible(WidgetTester tester) => tester
    .widget<DesktopNowPlaying>(find.byType(DesktopNowPlaying))
    .controlsVisible;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('only a click wakes the desktop dock; shortcuts still work', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = _State();
    addTearDown(state.dispose);
    await state.setVolume(.5);
    await tester.pumpWidget(_host(state));
    await tester.pump();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(5, 5));
    expect(_visible(tester), isTrue);

    await tester.pump(const Duration(milliseconds: 700));
    await mouse.moveTo(const Offset(640, 350));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendEventToBinding(
      const PointerScrollEvent(
        kind: PointerDeviceKind.mouse,
        position: Offset(640, 350),
        scrollDelta: Offset(0, 40),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      _visible(tester),
      isFalse,
      reason: 'hover, scrolling and keys must not restart the hide timer',
    );

    await mouse.moveTo(const Offset(-10, -10));
    await mouse.moveTo(const Offset(600, 350));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.sendEventToBinding(
      const PointerScrollEvent(
        kind: PointerDeviceKind.mouse,
        position: Offset(600, 350),
        scrollDelta: Offset(0, 40),
      ),
    );
    await tester.pump();
    expect(_visible(tester), isFalse);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(state.volume, closeTo(.55, .001));
    expect(_visible(tester), isFalse);

    await mouse.down(
      tester.getCenter(find.byKey(const ValueKey('now-playing-cover'))),
    );
    await mouse.up();
    await tester.pump();
    expect(_visible(tester), isTrue);
    await mouse.removePointer();
    await tester.pump(const Duration(milliseconds: 1100));
    expect(_visible(tester), isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a held desktop seek keeps the dock visible until release', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = _State();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state));
    await tester.pump();
    final seek = find.byKey(const ValueKey('desktop-seek-bar'));
    final mouse = await tester.startGesture(
      tester.getCenter(seek),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveBy(const Offset(80, 0));
    await tester.pump(const Duration(seconds: 2));
    expect(_visible(tester), isTrue);
    await mouse.up();
    await mouse.removePointer();
    await tester.pump(const Duration(milliseconds: 1100));
    expect(_visible(tester), isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('television remotes can still wake their transport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = _State();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state, tv: true));
    await tester.pump();
    Focus.of(tester.element(find.byIcon(Icons.search_rounded))).requestFocus();
    await tester.pump(const Duration(milliseconds: 1100));
    expect(_visible(tester), isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    expect(_visible(tester), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
