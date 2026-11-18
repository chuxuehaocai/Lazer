import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/player_bar.dart';
import 'package:lazer_nextgen/ui/shell.dart';
import 'package:lazer_nextgen/ui/widgets.dart';
import 'package:lazer_nextgen/widgets/capsule_navigation_bar.dart';

const _track = Track(
  id: 'phone-capsule',
  title: 'The current song',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 3),
  coverSeed: 1,
);

class _PhoneState extends AppState {
  _PhoneState() {
    autoDpiScale = false;
    layoutStyle = AppLayoutStyle.phone;
    backgroundMode = AppBackgroundMode.off;
    playerBackground = AppBackgroundMode.off;
  }

  final positionTicks = ValueNotifier<double>(0);
  late final Listenable _all = Listenable.merge([this, positionTicks]);
  bool hasTrack = true;
  int playerOpens = 0;

  @override
  bool get isLocalPlayback => false;
  @override
  Track? get current => hasTrack ? _track : null;
  @override
  double get progress => positionTicks.value;
  @override
  Listenable get all => _all;
  @override
  Future<void> ensureCurrentLyrics({bool force = false}) async {}
  @override
  void playerPresentationChanged(bool visible) {
    if (visible) playerOpens++;
  }

  @override
  void dispose() {
    positionTicks.dispose();
    super.dispose();
  }
}

Widget _host(Widget child, {double textScale = 1}) => MaterialApp(
  theme: buildAppleTheme(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(textScale),
      disableAnimations: true,
    ),
    child: child!,
  ),
  home: child,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final width in [320.0, 390.0, 600.0]) {
    for (final textScale in [1.0, 2.0]) {
      testWidgets(
        'phone capsule and cover share one safe row at $width/$textScale',
        (tester) async {
          tester.view
            ..devicePixelRatio = 1
            ..physicalSize = Size(width, 900)
            ..padding = const FakeViewPadding(top: 44, bottom: 34);
          addTearDown(tester.view.reset);
          final state = _PhoneState();
          addTearDown(state.dispose);
          await tester.pumpWidget(
            _host(AppShell(state: state), textScale: textScale),
          );
          await tester.pumpAndSettle();

          final navigation = find.byType(CapsuleNavigationBar);
          final cover = find.byKey(const ValueKey('bottom-track-cover'));
          expect(
            AppleSemanticColors.of(tester.element(navigation)).accent,
            AppleSemanticColors.light.accent,
          );
          final ring = find.descendant(
            of: cover,
            matching: find.byType(CircularProgressIndicator),
          );
          expect(
            tester.widget<CircularProgressIndicator>(ring).color,
            AppleSemanticColors.light.accent,
          );
          expect(tester.getSize(cover), const Size.square(48));
          expect(tester.getSize(navigation).height, 56);
          expect(tester.getCenter(navigation).dy, tester.getCenter(cover).dy);
          expect(
            tester.getTopLeft(cover).dx - tester.getBottomRight(navigation).dx,
            10,
          );
          expect(tester.getBottomRight(navigation).dy, lessThanOrEqualTo(866));
          expect(cover.hitTestable(), findsOneWidget);
          expect(find.byType(AppPlayerBar), findsNothing);
          final semantics = tester.ensureSemantics();
          expect(tester.getSemantics(cover).label, _track.title);
          semantics.dispose();
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets('shell palette is the same on both sides of the phone breakpoint', (
    tester,
  ) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(390, 850);
    addTearDown(tester.view.reset);
    final state = _PhoneState()..layoutStyle = AppLayoutStyle.desktop;
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(AppShell(state: state)));
    await tester.pumpAndSettle();
    expect(
      AppleSemanticColors.of(
        tester.element(find.byType(CapsuleNavigationBar)),
      ).accent,
      AppleSemanticColors.light.accent,
    );
    tester.view.physicalSize = const Size(1280, 850);
    await tester.pumpAndSettle();
    expect(
      AppleSemanticColors.of(tester.element(find.byType(AppPlayerBar))).accent,
      AppleSemanticColors.light.accent,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final key in [LogicalKeyboardKey.enter, LogicalKeyboardKey.space]) {
    testWidgets('phone player entry supports ${key.keyLabel} once', (
      tester,
    ) async {
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(390, 850);
      addTearDown(tester.view.reset);
      final state = _PhoneState();
      addTearDown(state.dispose);
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_host(AppShell(state: state)));
      await tester.pumpAndSettle();
      final cover = find.byKey(const ValueKey('bottom-track-cover'));
      final focus = Focus.of(tester.element(cover));
      expect(focus.canRequestFocus, isTrue);
      expect(find.bySemanticsLabel(_track.title), findsOneWidget);
      // Exercise real Tab traversal, not an injected tap or activation callback.
      for (var step = 0; step < 30 && !focus.hasPrimaryFocus; step++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(focus.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
      expect(state.playerOpens, 1);
      expect(find.byType(NowPlayingPage), findsOneWidget);
      expect(focus.canRequestFocus, isFalse);
      focus.requestFocus();
      await tester.pump();
      expect(focus.hasPrimaryFocus, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
    });
  }

  testWidgets('position ticks update only the visible cover ring', (
    tester,
  ) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(390, 850);
    addTearDown(tester.view.reset);
    final state = _PhoneState();
    addTearDown(state.dispose);
    final enabled = ValueNotifier(true);
    addTearDown(enabled.dispose);
    await tester.pumpWidget(
      _host(
        ValueListenableBuilder<bool>(
          valueListenable: enabled,
          builder: (_, value, child) =>
              TickerMode(enabled: value, child: child!),
          child: AppShell(state: state),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final cover = find.byKey(const ValueKey('bottom-track-cover'));
    final ring = find.descendant(
      of: cover,
      matching: find.byType(CircularProgressIndicator),
    );
    final artwork = find.descendant(of: cover, matching: find.byType(AppCover));
    final navigationWidget = tester.widget(find.byType(CapsuleNavigationBar));
    final artworkWidget = tester.widget(artwork);

    state.positionTicks.value = .4;
    await tester.pump();
    expect(tester.widget<CircularProgressIndicator>(ring).value, .4);
    expect(
      tester.widget(find.byType(CapsuleNavigationBar)),
      same(navigationWidget),
    );
    expect(tester.widget(artwork), same(artworkWidget));

    enabled.value = false;
    await tester.pump();
    state.positionTicks.value = .8;
    await tester.pump();
    expect(tester.widget<CircularProgressIndicator>(ring).value, .4);
    enabled.value = true;
    await tester.pump();
    expect(tester.widget<CircularProgressIndicator>(ring).value, .8);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an empty queue leaves the full navigation capsule', (
    tester,
  ) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(390, 850);
    addTearDown(tester.view.reset);
    final state = _PhoneState()..hasTrack = false;
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(AppShell(state: state)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bottom-track-cover')), findsNothing);
    expect(tester.getSize(find.byType(CapsuleNavigationBar)).width, 358);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
