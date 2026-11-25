import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/lazer_theme.dart';
import 'package:lazer_nextgen/theme/shape_scale.dart';

/// 窗口胶囊与移动端底边栏各自的三档圆角来源。
///
/// 这两类部件是「满圆 = 自身高度一半」的玻璃药丸：胶囊 40 dp → 20 px，底边栏
/// 56 dp → 28 px。所以它们的来源比全局多一档「跟随全局」，且手动值必须被夹在
/// 满圆半径内 —— 否则滑块上的数字会比实际画出来的形状更大。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('resolvePartPx', () {
    test('跟随主题用皮肤的 cornerScale × 满圆半径', () {
      expect(
        AppleShape.resolvePartPx(
          source: CornerSource.theme,
          customPx: 3,
          maxPx: 20,
          themeScale: 1,
          globalPx: 0,
        ),
        20,
      );
      expect(
        AppleShape.resolvePartPx(
          source: CornerSource.theme,
          customPx: 3,
          maxPx: 28,
          themeScale: 0,
          globalPx: 16,
        ),
        0,
      );
    });

    test('跟随全局直接用全局那个 px，不再放大', () {
      // 用户在「圆角大小」上写 6 px，胶囊和底边栏就都是 6 px。
      double global(double px, double maxPx) => AppleShape.resolvePartPx(
        source: CornerSource.global,
        customPx: 20,
        maxPx: maxPx,
        themeScale: 1,
        globalPx: px,
      );
      expect(global(6, 20), 6);
      expect(global(6, 28), 6);
      expect(global(0, 20), 0);
      expect(global(16, 28), 16);
      // 超过满圆半径仍然夹取：滑块写 40 也画不出更圆的药丸。
      expect(global(40, 20), 20);
    });

    test('手动设置直接用自己的 px，并夹在满圆半径内', () {
      double manual(double px, double maxPx) => AppleShape.resolvePartPx(
        source: CornerSource.manual,
        customPx: px,
        maxPx: maxPx,
        themeScale: 1,
        globalPx: 16,
      );
      expect(manual(6, 20), 6);
      expect(manual(0, 20), 0);
      // 超过满圆半径画不出更圆的药丸，显示值必须跟着夹取。
      expect(manual(40, 20), 20);
      expect(manual(99, 28), 28);
      // NaN 从滑块来不了，真出现时退回满圆（和 resolve 的兜底一致）。
      expect(manual(double.nan, 20), 20);
    });

    test('满圆半径是自身高度的一半', () {
      expect(AppleShape.capsulePxMax, 20); // kWindowChromeHeight / 2
      expect(AppleShape.navBarPxMax, 28); // (44 + 6 * 2) / 2
    });

    test('三档的名字就是设置页看到的那三个选项', () {
      expect(CornerSource.theme.label, '跟随主题');
      expect(CornerSource.global.label, '跟随全局');
      expect(CornerSource.manual.label, '手动设置');
      expect(
        CornerSourceLabels.parse('manual'),
        CornerSource.manual,
        reason: '旧的/未知的值要落到默认档而不是崩',
      );
      expect(CornerSourceLabels.parse('nope'), CornerSource.global);
    });
  });

  group('AppState', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('默认跟随全局', () async {
      final state = AppState();
      addTearDown(state.dispose);
      expect(state.capsuleCornerSource, CornerSource.global);
      expect(state.navBarCornerSource, CornerSource.global);
      expect(state.capsuleCornerPx, AppleShape.capsulePxDefault);
      expect(state.navBarCornerPx, AppleShape.navBarPxDefault);
    });

    test('来源与 px 都会写进偏好', () async {
      final state = AppState();
      addTearDown(state.dispose);
      await state.setCapsuleCornerSource(CornerSource.manual);
      await state.setCapsuleCornerPx(7);
      await state.setNavBarCornerSource(CornerSource.theme);
      await state.setNavBarCornerPx(11);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('lazer_capsule_corner_source'), 'manual');
      expect(prefs.getDouble('lazer_capsule_corner_px'), 7);
      expect(prefs.getString('lazer_nav_bar_corner_source'), 'theme');
      expect(prefs.getDouble('lazer_nav_bar_corner_px'), 11);

      // 启动时要真的读回来：bootstrap 里的键名对不上，重启就会回到默认档。
      final String source = File('lib/state/app_state.dart').readAsStringSync();
      expect(source, contains("prefs.getString('lazer_capsule_corner_source')"));
      expect(source, contains("prefs.getDouble('lazer_capsule_corner_px')"));
      expect(source, contains("prefs.getString('lazer_nav_bar_corner_source')"));
      expect(source, contains("prefs.getDouble('lazer_nav_bar_corner_px')"));
    });

    test('拖滑块自动切到手动，并夹在满圆半径内', () async {
      final state = AppState();
      addTearDown(state.dispose);
      expect(state.capsuleCornerSource, CornerSource.global);
      await state.setCapsuleCornerPxAndManual(4);
      expect(state.capsuleCornerSource, CornerSource.manual);
      expect(state.capsuleCornerPx, 4);

      await state.setCapsuleCornerPx(999);
      expect(state.capsuleCornerPx, AppleShape.capsulePxMax);
      await state.setCapsuleCornerPx(-5);
      expect(state.capsuleCornerPx, 0);

      await state.setNavBarCornerPxAndManual(9);
      expect(state.navBarCornerSource, CornerSource.manual);
      await state.setNavBarCornerPx(999);
      expect(state.navBarCornerPx, AppleShape.navBarPxMax);
    });
  });

  group('接线', () {
    test('胶囊与底边栏都读自己的设置，而不是写死 999 或 height/2', () {
      final String capsule = File(
        'lib/widgets/window_chrome_surface.dart',
      ).readAsStringSync();
      expect(capsule, contains('AppleShape.capsuleRadiusOf(context)'));
      expect(capsule, isNot(contains('kWindowChromeHeight / 2 *')));

      final String nav = File(
        'lib/widgets/capsule_navigation_bar.dart',
      ).readAsStringSync();
      expect(nav, contains('AppleShape.navBarRadiusOf(context)'));
      expect(nav, isNot(contains('999 *')));

      final String chrome = File(
        'lib/widgets/window_chrome.dart',
      ).readAsStringSync();
      expect(chrome, contains('AppleShape.capsuleRadiusOf(context)'));
    });

    test('根签名带上这两个字段，否则调了不会重建 AppleShape', () {
      final String main = File('lib/main.dart').readAsStringSync();
      expect(main, contains('_state.capsuleCornerSource'));
      expect(main, contains('_state.capsuleCornerPx'));
      expect(main, contains('_state.navBarCornerSource'));
      expect(main, contains('_state.navBarCornerPx'));
      expect(main, contains('capsulePx: capsulePx'));
      expect(main, contains('navBarPx: navBarPx'));
    });

    test('设置页有六行：两个来源 + 两个滑块（值单位为 px）', () {
      final String settings = File('lib/ui/settings_page.dart').readAsStringSync();
      for (final key in <String>[
        'capsule-corner-source',
        'capsule-corner-slider',
        'navbar-corner-source',
        'navbar-corner-slider',
      ]) {
        expect(settings, contains(key), reason: '$key 必须存在');
      }
      expect(settings, contains(' px'));
      expect(settings, contains('AppleShape.capsulePxMax'));
      expect(settings, contains('AppleShape.navBarPxMax'));
    });
  });

  test('px 范围覆盖 0 到满圆', () {
    expect(kCornerPxMin, 0);
    expect(AppleShape.capsulePxMax, greaterThan(kCornerPxMin));
    expect(AppleShape.navBarPxMax, greaterThan(AppleShape.capsulePxMax));
    // 主题给 0（全直角）时，药丸也必须能真的变成直角。
    expect(
      AppleShape.resolvePartPx(
        source: CornerSource.theme,
        customPx: 20,
        maxPx: 20,
        themeScale: LazerThemeTokens.apple.copyWith().cornerScale,
        globalPx: 16,
      ),
      isNot(0),
    );
  });
}
