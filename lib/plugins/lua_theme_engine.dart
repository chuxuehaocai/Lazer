import '../theme/lazer_theme.dart';
import '../ui/layout_system.dart';
import 'lua_plugin_runtime.dart';

/// The host-side result of a plugin theme operation.
class LuaThemeBundle {
  const LuaThemeBundle({this.theme, this.layout});

  final LazerThemeTokens? theme;
  final LazerLayoutDefinition? layout;

  bool get isEmpty => theme == null && layout == null;
}

/// Loads a declarative skin from a Lua plugin without exposing Flutter types.
///
/// A plugin may return an inline `theme`/`layout` object from `describe`, or
/// declare `theme = true` / `{operation = "theme"}` and return the bundle from
/// that operation. Invalid fields are ignored by the token parsers; a failed
/// optional skin never prevents the music gateway from starting.
abstract final class LuaThemeEngine {
  static Future<LuaThemeBundle?> load(
    LuaPluginRuntime runtime,
    Object? description,
  ) async {
    if (description is! Map) return null;
    final declaration = description['theme'] ?? description['skin'];
    if (declaration == null || declaration == false) return null;
    Object? payload = declaration;
    if (declaration == true ||
        declaration is Map && declaration['operation'] != null) {
      final operation = declaration is Map && declaration['operation'] is String
          ? declaration['operation'] as String
          : 'theme';
      try {
        payload = await runtime.invoke(operation);
      } catch (_) {
        return null;
      }
    }
    return decode(payload);
  }

  /// Decodes an already returned Lua value; exposed for host contract tests.
  static LuaThemeBundle? decode(Object? raw) {
    if (raw is! Map) return null;
    final map = _stringMap(raw);
    final themeRaw =
        map['theme'] ??
        map['tokens'] ??
        (map.containsKey('elements') ? map : null);
    final layoutRaw = map['layout'];
    final theme = themeRaw is Map
        ? LazerThemeTokens.fromJson(_stringMap(themeRaw))
        : null;
    final layout = layoutRaw is Map
        ? LazerLayoutDefinition.fromJson(_stringMap(layoutRaw))
        : null;
    final bundle = LuaThemeBundle(theme: theme, layout: layout);
    return bundle.isEmpty ? null : bundle;
  }

  static Map<String, Object?> _stringMap(Map raw) => <String, Object?>{
    for (final entry in raw.entries)
      if (entry.key is String) entry.key as String: entry.value,
  };
}
