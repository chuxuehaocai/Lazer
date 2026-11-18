import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/navigation/pull_down_to_close.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/shell.dart';

import 'support/player_transition.dart';

class _PhoneState extends AppState {
  _PhoneState() {
    autoDpiScale = false;
    layoutStyle = AppLayoutStyle.phone;
    backgroundMode = AppBackgroundMode.off;
    playerBackground = AppBackgroundMode.off;
  }

  @override
  Track get current => const Track(
    id: 'shell-pull',
    title: 'The current song',
    artist: 'Artist',
    album: 'Album',
    duration: Duration(minutes: 3),
    coverSeed: 1,
  );

  @override
  Future<void> ensureCurrentLyrics({bool force = false}) async {}

  @override
  void playerPresentationChanged(bool visible) {}
}

Widget _host(_PhoneState state) => MaterialApp(
  theme: buildAppleTheme(),
  home: AppShell(state: state),
);

Future<_PhoneState> _mount(WidgetTester tester) async {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = const Size(390, 850);
  addTearDown(tester.view.reset);
  final state = _PhoneState();
  addTearDown(state.dispose);
  await tester.pumpWidget(_host(state));
  await tester.pumpAndSettle();
  return state;
}

Future<NowPlayingPage> _open(WidgetTester tester) async {
  await tapNowPlayingControl(tester);
  await tester.pump();
  await pumpPlayerTransition(
    tester,
    playerSlideAnimation(tester),
    AnimationStatus.completed,
  );
  return tester.widget<NowPlayingPage>(find.byType(NowPlayingPage));
}

void _lateCallbacks(PlayerPullDown pull) {
  pull.startPull();
  pull.updatePull(.3);
  pull.endPull(1200);
  pull.cancelPull();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a late pull cancellation cannot reopen a closing player', (
    tester,
  ) async {
    await _mount(tester);
    final page = await _open(tester);
    final motion = playerSlideAnimation(tester);
    final pull = page.pullDown!;
    pull.startPull();
    pull.updatePull(.08);
    page.onClose!();
    pull.cancelPull();
    await pumpPlayerTransition(tester, motion, AnimationStatus.dismissed);
    expect(find.byType(NowPlayingPage), findsNothing);
    expect(pull.canStart, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('retired pulls cannot change the next player opening', (
    tester,
  ) async {
    await _mount(tester);
    final first = await _open(tester);
    final oldPull = first.pullDown!;
    oldPull.startPull();
    oldPull.updatePull(.08);
    final closing = playerSlideAnimation(tester);
    first.onClose!();
    await pumpPlayerTransition(tester, closing, AnimationStatus.dismissed);
    final next = await _open(tester);
    final opening = playerSlideAnimation(tester);
    _lateCallbacks(oldPull);
    await tester.pump(const Duration(milliseconds: 50));
    expect(opening.value.dy, closeTo(0, .001));
    expect(next.pullDown!.canStart, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('replacing app state retires the previous player pull', (
    tester,
  ) async {
    await _mount(tester);
    final oldPage = await _open(tester);
    final oldPull = oldPage.pullDown!;
    oldPull.startPull();
    oldPull.updatePull(.08);
    final replacement = _PhoneState();
    addTearDown(replacement.dispose);
    await tester.pumpWidget(_host(replacement));
    await tester.pumpAndSettle();
    expect(find.byType(NowPlayingPage), findsNothing);
    final page = await _open(tester);
    final motion = playerSlideAnimation(tester);
    _lateCallbacks(oldPull);
    await tester.pump(const Duration(milliseconds: 50));
    expect(motion.value.dy, closeTo(0, .001));
    expect(page.pullDown!.canStart, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('late pull callbacks remain safe after the shell is disposed', (
    tester,
  ) async {
    await _mount(tester);
    final page = await _open(tester);
    final pull = page.pullDown!;
    pull.startPull();
    pull.updatePull(.08);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(pull.canStart, isFalse);
    expect(() => _lateCallbacks(pull), returnsNormally);
    expect(tester.takeException(), isNull);
  });

  testWidgets('duplicate starts and completions cannot retarget a pull', (
    tester,
  ) async {
    await _mount(tester);
    final page = await _open(tester);
    final motion = playerSlideAnimation(tester);
    final pull = page.pullDown!;
    pull.updatePull(.3);
    expect(motion.value.dy, closeTo(0, .001));
    pull.startPull();
    pull.updatePull(.1);
    pull.startPull();
    pull.updatePull(.15);
    expect(motion.value.dy, closeTo(.15, .001));
    pull.cancelPull();
    pull.endPull(1200);
    await pumpPlayerTransition(tester, motion, AnimationStatus.completed);
    expect(pull.canStart, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
