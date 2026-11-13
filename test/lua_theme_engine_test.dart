import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/plugins/lua_theme_engine.dart';

void main() {
  test('decodes bounded Lua theme and layout tokens', () {
    final bundle = LuaThemeEngine.decode({
      'theme': {
        'id': 'lua.demo',
        'name': 'Demo',
        'elements': {
          'displayWeight': 850,
          'groupedCardRadius': 18,
          'glassBlurSigma': 1000,
          'lyricSpringStiffnessScale': 1.4,
          'lyricStaggerDelay': .08,
          'lyricFocusScaleDelta': 5,
        },
      },
      'layout': {
        'id': 'lua.compact',
        'name': 'Compact',
        'compactInset': 20,
        'maxContentWidth': 980,
      },
    });
    expect(bundle, isNotNull);
    expect(bundle!.theme!.id, 'lua.demo');
    expect(bundle.theme!.displayWeight, 850);
    expect(bundle.theme!.displayFontWeight, FontWeight.w800);
    expect(bundle.theme!.glassBlurSigma, 48);
    expect(bundle.theme!.lyricSpringStiffnessScale, 1.4);
    expect(bundle.theme!.lyricStaggerDelay, .08);
    expect(bundle.theme!.lyricFocusScaleDelta, 5);
    expect(bundle.layout!.id, 'lua.compact');
    expect(bundle.layout!.maxContentWidth, 980);
  });

  test('ignores malformed and empty skin responses', () {
    expect(LuaThemeEngine.decode(null), isNull);
    expect(LuaThemeEngine.decode({'theme': 'not-a-map'}), isNull);
    expect(
      LuaThemeEngine.decode({
        'theme': {'id': 'only-theme', 'elements': {}},
      })!.layout,
      isNull,
    );
  });
}
