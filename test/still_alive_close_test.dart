import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/animation/view_transitions.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/easter_egg/still_alive_audio.dart';
import 'package:lazer_nextgen/easter_egg/still_alive_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/widgets/window_chrome.dart';
import 'package:lazer_nextgen/widgets/window_frame.dart';

class _InlineChromeState extends AppState {
  _InlineChromeState() {
    autoDpiScale = false;
    layoutStyle = AppLayoutStyle.desktop;
    titleBarStyle = DesktopTitleBarStyle.inline;
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

/// Keeps just_audio and media_kit out of the test: only the page's own layout
/// and its exits are under test here.
class _SilentPlayback extends ChangeNotifier implements StillAlivePlayback {
  @override
  bool get ready => true;
  @override
  bool get playing => false;
  @override
  bool get completed => false;
  @override
  Duration get position => Duration.zero;
  @override
  Duration? get duration => const Duration(minutes: 3);
  @override
  String? get error => null;
  @override
  Future<void> load() async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> restart() async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> close() async {}
}

Future<void> _settle(WidgetTester tester, {int frames = 20}) async {
  for (var index = 0; index < frames; index++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<void> _pushEgg(WidgetTester tester, AppState state) async {
  final navigator = Navigator.of(tester.element(find.text('open')));
  unawaited(
    navigator.push<void>(
      ApplePageRoute<void>(
        builder: (_) =>
            StillAlivePage(playback: _SilentPlayback(), appState: state),
      ),
    ),
  );
  await tester.pump();
  await _settle(tester, frames: 30);
  expect(
    find.byKey(const ValueKey('still-alive-report')),
    findsOneWidget,
    reason: 'the credits page should be open',
  );
  expect(
    find.byKey(const ValueKey('frums-credits-animation')),
    findsOneWidget,
    reason: 'the Frums ASCII animation should be mounted',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<_InlineChromeState> mountHost(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method.startsWith('is') ? false : null,
    );
    final state = _InlineChromeState();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        builder: (context, child) => WindowFrame(
          enabled: true,
          state: state,
          navigatorKey: navigator,
          child: child!,
        ),
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
    await _settle(tester);
    return state;
  }

  testWidgets('the floating window capsule does not swallow the close button', (
    tester,
  ) async {
    final state = await mountHost(tester);
    await _pushEgg(tester, state);

    final close = find.byKey(const ValueKey('still-alive-close'));
    expect(close, findsOneWidget);
    final rect = tester.getRect(close);
    // The capsule paints over the top-right corner; the page has to stay below
    // it, otherwise the click lands on the window's own caption buttons.
    expect(
      rect.top,
      greaterThanOrEqualTo(kInlineChromeInset),
      reason: 'the close button sits under the caption capsule at $rect',
    );

    await tester.tap(close);
    await tester.pump();
    await _settle(tester, frames: 30);
    expect(find.byKey(const ValueKey('still-alive-report')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('Escape closes the credits while they play', (tester) async {
    final state = await mountHost(tester);
    await _pushEgg(tester, state);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await _settle(tester, frames: 30);
    expect(find.byKey(const ValueKey('still-alive-report')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('a phone keeps the close button at the top of the page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = _InlineChromeState()..layoutStyle = AppLayoutStyle.phone;
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
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
    await _settle(tester);
    await _pushEgg(tester, state);

    final rect = tester.getRect(
      find.byKey(const ValueKey('still-alive-close')),
    );
    expect(rect.top, lessThan(kInlineChromeInset));
    await tester.tap(find.byKey(const ValueKey('still-alive-close')));
    await tester.pump();
    await _settle(tester, frames: 30);
    expect(find.byKey(const ValueKey('still-alive-report')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
