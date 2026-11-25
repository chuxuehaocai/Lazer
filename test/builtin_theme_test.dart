import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/lazer_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 内置主题（Mio）与「设置 → 外观 → 主题风格」这条线。
///
/// 背景：以前界面只认插件皮肤，装了 Lua 主题插件就没法用回自带主题；
/// 现在自带主题列表默认只有 Mio 一个，并且选中的内置主题压过插件皮肤。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('内置主题注册表', () {
    test('默认只有 Mio 一个', () {
      expect(LazerThemeTokens.builtinThemes, hasLength(1));
      final LazerThemeTokens mio = LazerThemeTokens.builtinThemes.single;
      expect(mio.id, 'builtin.mio');
      expect(mio.name, 'Mio');
    });

    test('Mio 是 parchment 那套几何 + 羊皮纸调色板', () {
      const LazerThemeTokens mio = LazerThemeTokens.mio;
      expect(mio.groupedCardRadius, 0);
      expect(mio.listTileMinHeight, 64);
      expect(mio.railWidth, 232);
      expect(mio.playerBarHeight, 100);
      expect(mio.glassBlurSigma, 0);
      expect(mio.backgroundPlayMode, 'off');
      expect(mio.lyricDimAlpha, .48);
      expect(mio.lyricTranslationAlpha, .48);
      // 画布 / 墨 / 强调色来自 design_tokens 的 ivoryMedium / slateDark / clay。
      expect(mio.colors['background'], const Color(0xFFF0EEE6));
      expect(mio.colors['label'], const Color(0xFF141413));
      expect(mio.colors['accent'], const Color(0xFFD97757));
      expect(mio.darkColors['background'], const Color(0xFF191918));
    });

    test('内置主题与 Apple 预设是两套（不能互相顶掉）', () {
      expect(LazerThemeTokens.apple.id, 'builtin.apple');
      expect(LazerThemeTokens.mio.id, isNot(LazerThemeTokens.apple.id));
      expect(LazerThemeTokens.mio.groupedCardRadius,
          isNot(LazerThemeTokens.apple.groupedCardRadius));
    });
  });

  group('AppState 选择', () {
    test('默认选中 Mio', () async {
      final AppState state = AppState();
      expect(state.builtinThemeId, 'builtin.mio');
      expect(state.builtinTheme?.name, 'Mio');
      // 默认就走内置主题，不等插件。
      expect(state.pluginTheme?.id, 'builtin.mio');
    });

    test('存进偏好，重启后读回', () async {
      final AppState state = AppState();
      // 已经是 Mio 了：先切到「跟随插件」，再切回来，写盘才会发生。
      await state.setBuiltinTheme(null);
      await state.setBuiltinTheme('builtin.mio');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('lazer_builtin_theme'), 'builtin.mio');
    });

    test('选「跟随插件皮肤」= 清空，回落到插件提供的皮肤', () async {
      final AppState state = AppState();
      await state.setBuiltinTheme(null);
      expect(state.builtinThemeId, isNull);
      expect(state.builtinTheme, isNull);
      // 没有插件在跑时仍然给出 null（各页面再回落到 Apple）
      expect(state.pluginTheme, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('lazer_builtin_theme'), isFalse);
    });

    test('未知 id 不会被当成主题', () async {
      final AppState state = AppState();
      await state.setBuiltinTheme('builtin.nope');
      expect(state.builtinTheme, isNull);
    });
  });

  group('接线', () {
    test('根签名带上内置主题 id，否则换主题不会重建', () {
      final String source = _rootMainSource();
      expect(source.contains('_state.builtinThemeId'), isTrue);
    });

    test('设置页有「主题风格」这一行，选项来自 builtinThemes', () {
      final String source = _settingsSource();
      expect(source.contains("label: '主题风格'"), isTrue);
      expect(source.contains('LazerThemeTokens.builtinThemes'), isTrue);
      expect(source.contains('跟随插件皮肤'), isTrue);
    });
  });
}

String _rootMainSource() {
  final File file = File('lib/main.dart');
  return file.readAsStringSync();
}

String _settingsSource() {
  final File file = File('lib/ui/settings_page.dart');
  return file.readAsStringSync();
}
