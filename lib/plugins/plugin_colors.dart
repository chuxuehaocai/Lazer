/// The palette values `host.colors` and `host.set_colors` speak.
///
/// Both runtimes validate the Lua table through this class instead of each
/// carrying its own copy of the rules, so the native and browser builds accept
/// exactly the same input. The host handler also answers through [response],
/// which keeps one definition of what a plugin reads back.
abstract final class PluginColors {
  /// Palette names the Lua side uses; they are `AppPaletteMode` names.
  static const Set<String> modes = <String>{'fixed', 'nowPlaying', 'custom'};

  /// The request `host.colors()` sends: read without changing anything.
  static const Map<String, dynamic> query = <String, dynamic>{'command': 'get'};

  /// Normalises one `host.set_colors` table into a host request.
  ///
  /// Unknown keys are rejected instead of ignored: a plugin that misspells
  /// `accent` must hear about it rather than repaint nothing. `accent` implies
  /// `custom`, because a colour with no mode has no other meaning, and it may
  /// not be combined with a mode that ignores it.
  static Map<String, dynamic> request(Object? value) {
    if (value == null) return const <String, dynamic>{'command': 'set'};
    if (value is! Map) throw const FormatException('Colors require a table');
    for (final key in value.keys) {
      if (key != 'mode' && key != 'accent') {
        throw const FormatException('Unknown color option');
      }
    }
    final mode = value['mode'];
    if (mode != null && (mode is! String || !modes.contains(mode))) {
      throw const FormatException('Unknown palette mode');
    }
    final raw = value['accent'];
    final rgb = raw == null ? null : _parseHex(raw);
    if (mode is String && rgb != null && mode != 'custom') {
      throw const FormatException('accent requires mode "custom"');
    }
    final resolved = mode as String? ?? (rgb == null ? null : 'custom');
    return <String, dynamic>{
      'command': 'set',
      'mode': ?resolved,
      'accent': ?rgb,
    };
  }

  /// The table a plugin reads back, in the contract's spelling.
  ///
  /// `accent` is omitted rather than null when the shell is not painting a
  /// custom colour, so Lua sees `nil` and the table keeps one shape per state.
  static Map<String, dynamic> response(String mode, int? argb) =>
      <String, dynamic>{
        'ok': true,
        'mode': mode,
        if (argb != null) 'accent': _format(argb),
      };

  static String _format(int argb) =>
      '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  /// One accepted spelling: `#RRGGBB`.
  ///
  /// Short forms and `0x` prefixes would leave the plugin and the settings
  /// picker disagreeing about what "the same colour" means, so they are
  /// errors rather than conveniences.
  static int _parseHex(Object value) {
    if (value is! String || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)) {
      throw const FormatException('accent must be #RRGGBB');
    }
    return 0xFF000000 | int.parse(value.substring(1), radix: 16);
  }
}
