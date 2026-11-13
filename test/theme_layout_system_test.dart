import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/theme/lazer_theme.dart';
import 'package:lazer_nextgen/ui/layout_system.dart';

void main() {
  test('built-in theme tokens round-trip and clamp plugin input', () {
    final json = LazerThemeTokens.apple.toJson();
    final restored = LazerThemeTokens.fromJson(json);
    expect(restored.id, 'builtin.apple');
    expect(restored.groupedCardRadius, 14);
    expect(
      LazerThemeTokens.fromJson({
        'id': 'lua.demo',
        'name': 'Demo',
        'elements': {'groupedCardRadius': 999, 'glassBlurSigma': -4},
      }).groupedCardRadius,
      40,
    );
    expect(
      LazerThemeTokens.fromJson({
        'id': 'lua.demo',
        'elements': {'groupedCardRadius': 999, 'glassBlurSigma': -4},
      }).glassBlurSigma,
      0,
    );
  });

  test('theme and layout registries keep built-ins as safe fallbacks', () {
    final themes = LazerThemeRegistry();
    themes.register(const LazerThemeTokens(id: 'lua.demo', name: 'Demo'));
    expect(themes.resolve('lua.demo').name, 'Demo');
    expect(themes.resolve('missing').id, 'builtin.apple');

    final layouts = LazerLayoutRegistry();
    layouts.register(
      const LazerLayoutDefinition(
        id: 'lua.demo',
        name: 'Demo',
        maxContentWidth: 900,
      ),
    );
    expect(layouts.resolve('lua.demo').maxContentWidth, 900);
    expect(layouts.resolve('missing').id, 'builtin.adaptive');
  });

  testWidgets('scoped theme and layout tokens drive shared helpers', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const layout = LazerLayoutDefinition(
      id: 'lua.demo',
      name: 'Demo',
      compactInset: 28,
      maxContentWidth: 900,
    );
    const theme = LazerThemeTokens(
      id: 'lua.demo',
      name: 'Demo',
      groupedCardRadius: 22,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Theme(
          data: ThemeData(extensions: <ThemeExtension<dynamic>>[theme]),
          child: LazerLayoutScope(
            layout: layout,
            child: Builder(
              builder: (context) => Text(
                '${LazerThemeTokens.of(context).groupedCardRadius}|'
                '${lazerPageInset(context)}|'
                '${lazerContentMaxWidth(context, 1180)}',
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('22.0|28.0|900.0'), findsOneWidget);
  });
}
