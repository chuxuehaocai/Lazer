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
