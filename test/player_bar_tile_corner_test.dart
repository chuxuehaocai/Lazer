import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/theme/lazer_theme.dart';
import 'package:lazer_nextgen/theme/shape_scale.dart';
import 'package:lazer_nextgen/ui/player_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _track = Track(
  id: 'player-tile',
  title: 'A song whose title has to truncate',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 3),
  coverSeed: 1,
);

class _BarState extends AppState {
  _BarState() {
    autoDpiScale = false;
    layoutStyle = AppLayoutStyle.desktop;
    playerBackground = AppBackgroundMode.off;
  }

  @override
  Track get current => _track;
  @override
  bool get playing => false;
  @override
  Future<void> ensureCurrentLyrics({bool force = false}) async {}
  @override
  void playerPresentationChanged(bool visible) {}
}

/// The corner the now-playing tile of the desktop player bar is clipped to.
///
/// `_NowPlayingTile` used to default to a literal 14, so the desktop bar's
/// tile was the one card that ignored 「设置 → 圆角大小」: the floating compact
/// bar passed a radius explicitly and the desktop one did not, so it always
/// drew 14 × component scale.
double _tileRadius(WidgetTester tester) {
  final Finder tile = find.byKey(const ValueKey('player-now-playing-tile'));
  expect(tile, findsOneWidget);
  return tester
      .widget<ClipRRect>(tile)
      .borderRadius
      .resolve(TextDirection.ltr)
      .topLeft
      .x;
}

Future<void> _mount(WidgetTester tester, _BarState state) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(state.dispose);
  const channel = MethodChannel('window_manager');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    channel,
    (call) async => switch (call.method) {
      'isMaximized' || 'isFullScreen' => false,
      'isFocused' => true,
      _ => null,
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppleTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: AppleShape(
          scale: AppleShape.resolve(
            followTheme: state.cornerFollowsTheme,
            customPx: state.cornerPx,
            theme: LazerThemeTokens.mio,
          ),
          cardPx: state.cornerPx,
          manual: !state.cornerFollowsTheme,
          capsulePx: 0,
          navBarPx: 0,
          child: child!,
        ),
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: AppPlayerBar(state: state, onOpen: () {}),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  for (final double cornerPx in <double>[0, 8, 16, 24]) {
    testWidgets('the player bar tile is clipped at ${cornerPx}px', (
      tester,
    ) async {
      final state = _BarState()
        ..cornerFollowsTheme = false
        ..cornerPx = cornerPx;
      await _mount(tester, state);
      expect(tester.takeException(), isNull);
      expect(_tileRadius(tester), closeTo(cornerPx, .01));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('a zero corner squares the player bar tile', (tester) async {
    final state = _BarState()
      ..cornerFollowsTheme = false
      ..cornerPx = 0;
    await _mount(tester, state);
    expect(_tileRadius(tester), 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
