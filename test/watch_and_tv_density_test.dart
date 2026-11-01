import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/watch/watch_shell.dart';
import 'package:lazer_nextgen/widgets/accessible_controls.dart';
import 'package:lazer_nextgen/widgets/ui_scaling.dart';

class _WatchState extends AppState {
  _WatchState({required bool round})
    : super(deviceIsWatch: true, deviceIsRoundWatch: round);
  @override
  Track get current => const Track(
    id: 'watch-fixture',
    title: '手表测试歌曲',
    artist: '歌手',
    album: '专辑',
    duration: Duration(minutes: 3),
    coverSeed: 1,
  );
  String? submittedPhone, submittedCode;
  @override
  Future<AuthOutcome> signInWithPhoneCaptcha(
    String phone,
    String captcha,
  ) async {
    submittedPhone = phone;
    submittedCode = captcha;
    return const AuthOutcome(true);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final round in [false, true]) {
    testWidgets(
      '${round ? 'round' : 'square'} Android watch fits a 192px display',
      (tester) async {
        tester.view.physicalSize = const Size(192, 192);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final state = _WatchState(round: round);
        addTearDown(state.dispose);
        expect(state.legacyBackground, LegacyBackgroundMode.nowPlayingStatic);
        expect(state.playerBackground, LegacyBackgroundMode.nowPlayingStatic);
        await tester.pumpWidget(
          MaterialApp(
            home: WatchShell(state: state, round: round),
          ),
        );
        await tester.pump();
        expect(find.byType(ListView), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('音乐'));
        await tester.pump();
        expect(find.text('本地音乐 · 0'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('设置'));
        await tester.pump();
        await tester.enterText(
          find.byKey(const ValueKey('watch-login-phone')),
          '13800000000',
        );
        final captcha = find.byKey(const ValueKey('watch-login-captcha'));
        await tester.scrollUntilVisible(
          captcha,
          60,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.enterText(captcha, '123456');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect(state.submittedPhone, '13800000000');
        expect(state.submittedCode, '123456');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'TV sliders leave vertically, adjust horizontally, and render at 70%',
    (tester) async {
      final state = AppState()..surface = AppSurface.tv;
      final slider = FocusNode(), above = FocusNode(), below = FocusNode();
      addTearDown(() {
        state.dispose();
        slider.dispose();
        above.dispose();
        below.dispose();
      });
      var value = .5;
      await tester.pumpWidget(
        MaterialApp(
          home: UiScaling(
            state: state,
            child: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) => Column(
                  children: [
                    TextButton(
                      focusNode: above,
                      onPressed: () {},
                      child: const Text('above'),
                    ),
                    SizedBox(
                      width: 200,
                      child: AccessibleSlider(
                        value: value,
                        focusNode: slider,
                        onChanged: (v) => setState(() => value = v),
                      ),
                    ),
                    TextButton(
                      focusNode: below,
                      onPressed: () {},
                      child: const Text('below'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      final transform = tester.widget<Transform>(
        find
            .byWidgetPredicate(
              (w) =>
                  w is Transform && (w.transform.storage[0] - .7).abs() < .001,
            )
            .first,
      );
      expect(transform.transform.storage[0], .7);
      slider.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(value, .5);
      expect(below.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(slider.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(value, greaterThan(.5));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(above.hasFocus, isTrue);
    },
  );
}
