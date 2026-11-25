import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/theme/lazer_theme.dart';
import 'package:lazer_nextgen/theme/shape_scale.dart';

/// `cornerScale` is the token a skin uses to say "this build is square"; the
/// 设置 → 圆角设置 switch decides whether that token or the user's slider wins.
/// These tests pin both halves of that contract.
void main() {
  group('cornerScale token', () {
    test('defaults to 1 when the skin does not declare it', () {
      final tokens = LazerThemeTokens.fromJson(<String, Object?>{
        'elements': <String, Object?>{},
      });
      expect(tokens.cornerScale, 1);
    });

    test('parses a numeric value', () {
      final tokens = LazerThemeTokens.fromJson(<String, Object?>{
        'elements': <String, Object?>{'cornerScale': .5},
      });
      expect(tokens.cornerScale, .5);
    });

    test('clamps into 0–2', () {
      expect(
        LazerThemeTokens.fromJson(<String, Object?>{
          'elements': <String, Object?>{'cornerScale': 9},
        }).cornerScale,
        2,
      );
      expect(
        LazerThemeTokens.fromJson(<String, Object?>{
          'elements': <String, Object?>{'cornerScale': -3},
        }).cornerScale,
        0,
      );
    });

    test('survives a non-numeric value and a NaN', () {
      expect(
        LazerThemeTokens.fromJson(<String, Object?>{
          'elements': <String, Object?>{'cornerScale': 'square'},
        }).cornerScale,
        1,
      );
      expect(
        LazerThemeTokens.fromJson(<String, Object?>{
          'elements': <String, Object?>{'cornerScale': double.nan},
        }).cornerScale,
        1,
      );
    });

    test('is serialized back so probes can read it', () {
      const tokens = LazerThemeTokens(cornerScale: 0);
      final elements = tokens.toJson()['elements'] as Map<String, Object?>;
      expect(elements['cornerScale'], 0);
    });
  });

  group('AppleShape', () {
    test('follow theme reads the token', () {
      const theme = LazerThemeTokens(cornerScale: 0);
      expect(
        AppleShape.resolve(followTheme: true, customPx: 24, theme: theme),
        0,
      );
    });

    test('manual mode ignores the token', () {
      const theme = LazerThemeTokens(cornerScale: 0);
      // 24 px = 1.5 × the 16 px baseline.
      expect(
        AppleShape.resolve(followTheme: false, customPx: 24, theme: theme),
        1.5,
      );
    });

    test('manual mode clamps into the px range', () {
      const theme = LazerThemeTokens.apple;
      expect(
        AppleShape.resolve(followTheme: false, customPx: 400, theme: theme),
        AppleShape.max,
      );
      expect(
        AppleShape.resolve(followTheme: false, customPx: -8, theme: theme),
        AppleShape.min,
      );
    });

    test('px and scale round-trip through the 16 px baseline', () {
      expect(AppleShape.pxOfScale(1), 16);
      expect(AppleShape.pxOfScale(.5), 8);
      expect(AppleShape.scaleOfPx(16), 1);
      expect(AppleShape.scaleOfPx(0), 0);
      expect(AppleShape.scaleOfPx(32), AppleShape.max);
    });

    testWidgets('scaleOf falls back to 1 without a provider', (
      WidgetTester tester,
    ) async {
      late double seen;
      await tester.pumpWidget(
        Builder(
          builder: (BuildContext context) {
            seen = AppleShape.scaleOf(context);
            return const SizedBox();
          },
        ),
      );
      expect(seen, AppleShape.identity);
    });

    testWidgets('scaleOf reports the provided factor to descendants', (
      WidgetTester tester,
    ) async {
      late double seen;
      await tester.pumpWidget(
        AppleShape(
          scale: .25,
          cardPx: 4,
          manual: false,
          child: Builder(
            builder: (BuildContext context) {
              seen = AppleShape.scaleOf(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(seen, .25);
    });

    testWidgets('cardRadiusOf: 手动模式用用户的 px，压过皮肤的 0', (
      WidgetTester tester,
    ) async {
      late double seen;
      await tester.pumpWidget(
        AppleShape(
          scale: 1.25,
          cardPx: 20,
          manual: true,
          child: Builder(
            builder: (BuildContext context) {
              seen = AppleShape.cardRadiusOf(
                context,
                const LazerThemeTokens(groupedCardRadius: 0),
              );
              return const SizedBox();
            },
          ),
        ),
      );
      // 不是 0 × 1.25（那样皮肤给了 0 就永远调不动）。
      expect(seen, 20);
    });

    testWidgets('cardRadiusOf: 跟随主题时用皮肤的角，滑块不参与', (
      WidgetTester tester,
    ) async {
      late double seen;
      await tester.pumpWidget(
        AppleShape(
          scale: 1,
          cardPx: 20,
          manual: false,
          child: Builder(
            builder: (BuildContext context) {
              seen = AppleShape.cardRadiusOf(
                context,
                const LazerThemeTokens(groupedCardRadius: 0),
              );
              return const SizedBox();
            },
          ),
        ),
      );
      expect(seen, 0);
    });

    testWidgets('cardRadiusOf 没有 provider 时回到皮肤令牌', (
      WidgetTester tester,
    ) async {
      late double seen;
      await tester.pumpWidget(
        Builder(
          builder: (BuildContext context) {
            seen = AppleShape.cardRadiusOf(
              context,
              const LazerThemeTokens(groupedCardRadius: 14),
            );
            return const SizedBox();
          },
        ),
      );
      expect(seen, 14);
    });

    test('设置页显示的数就是生效的卡片角', () {
      const skin = LazerThemeTokens(groupedCardRadius: 0);
      expect(
        AppleShape.cardPxFor(followTheme: true, customPx: 24, theme: skin),
        0,
      );
      expect(
        AppleShape.cardPxFor(followTheme: false, customPx: 24, theme: skin),
        24,
      );
    });

    test('根 UI 签名带上圆角字段（否则滑块不会实时刷新）', () {
      // AppleShape 包在 MaterialApp.builder 里，只有根 setState 才会换新；
      // _LazerAppState 只在 _RootUiSignature 变化时 setState。这条断言就是
      // 「改了没反应」那个 bug 的回归护栏。
      final source = File('lib/main.dart').readAsStringSync();
      final signature = RegExp(
        r'_RootUiSignature get _rootUiSignature => \((.|\n)*?\);',
      ).firstMatch(source)?.group(0);
      expect(signature, isNotNull);
      expect(signature, contains('cornerPx'));
      expect(signature, contains('cornerFollowsTheme'));
    });
  });
}
