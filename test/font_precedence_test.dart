import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/lyrics/line_content.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/theme/font_preferences.dart';
import 'package:lazer_nextgen/theme/lazer_theme.dart';
import 'package:lazer_nextgen/ui/widgets.dart';
import 'package:lazer_nextgen/widgets/apple_ui.dart';

/// A Lua skin may ship type tokens (`displayWeight`, `titleWeight`, …). They are
/// the *default* for the app; anything the user chose in 字体自定义 has to win,
/// otherwise installing a skin silently rewrites the user's fonts.
void main() {
  const skin = LazerThemeTokens(
    displayWeight: 400,
    headingWeight: 700,
    titleWeight: 600,
    bodyWeight: 400,
    labelWeight: 600,
    sectionHeaderSize: 12,
  );

  FontPreferences customised() => const FontPreferences(
    <FontCategory, FontCustomization>{
      FontCategory.pageTitle: FontCustomization(weight: 700),
      FontCategory.title: FontCustomization(weight: 700),
      FontCategory.body: FontCustomization(weight: 700),
      FontCategory.caption: FontCustomization(weight: 700),
      FontCategory.controls: FontCustomization(weight: 700),
    },
    FontFamilyPreference(source: FontSource.system),
  );

  Future<void> pump(WidgetTester tester, Widget child, FontPreferences fonts) {
    return tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(fonts: fonts, ui: skin),
        home: Scaffold(body: child),
      ),
    );
  }

  FontWeight? weightOf(WidgetTester tester, String text) =>
      tester.widget<Text>(find.text(text)).style?.fontWeight;

  testWidgets('page title honours the user weight over the skin', (
    WidgetTester tester,
  ) async {
    await pump(tester, const ApplePageTitle(title: 'Library'), customised());
    expect(weightOf(tester, 'Library'), FontWeight.w700);
  });

  testWidgets('section header honours the user weight over the skin', (
    WidgetTester tester,
  ) async {
    await pump(tester, const AppleSectionHeader(title: 'Recent'), customised());
    expect(weightOf(tester, 'Recent'), FontWeight.w700);
  });

  testWidgets('list tile title and subtitle honour the user weight', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      AppleListTile(title: 'Track', subtitle: 'Artist', onTap: () {}),
      customised(),
    );
    expect(weightOf(tester, 'Track'), FontWeight.w700);
    expect(weightOf(tester, 'Artist'), FontWeight.w700);
  });

  testWidgets('without user choices the skin tokens still decide', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      const Column(
        children: <Widget>[
          ApplePageTitle(title: 'Library'),
          AppleSectionHeader(title: 'Recent'),
          AppSectionHeader(title: 'Shelves'),
        ],
      ),
      const FontPreferences(),
    );
    expect(weightOf(tester, 'Library'), FontWeight.w400);
    expect(weightOf(tester, 'Recent'), FontWeight.w600);
    // 首页真实用的那一个：皮肤没给 titleWeight 时它自己的 w700 是默认。
    expect(weightOf(tester, 'Shelves'), FontWeight.w700);
  });

  testWidgets('the real browse section header honours the user weight', (
    WidgetTester tester,
  ) async {
    // 皮肤给它的默认是 w700（AppSectionHeader 自己的 fallback）；用户选 400 就要 400。
    await pump(
      tester,
      const AppSectionHeader(title: 'Shelves'),
      const FontPreferences(<FontCategory, FontCustomization>{
        FontCategory.title: FontCustomization(weight: 400),
      }),
    );
    expect(weightOf(tester, 'Shelves'), FontWeight.w400);
  });

  group('歌词字重', () {
    const base = TextStyle(fontSize: 20);
    const skin = LazerThemeTokens(lyricWeight: 500);

    test('皮肤是默认值', () {
      final style = lyricTextStyle(base, 20, 700, theme: skin);
      expect(style.fontWeight, FontWeight.w500);
    });

    test('用户调过滑块就不让皮肤改（honorThemeWeight: false）', () {
      final style = lyricTextStyle(
        base,
        20,
        700,
        theme: skin,
        honorThemeWeight: false,
      );
      expect(style.fontWeight, FontWeight.w700);
    });
  });
}
