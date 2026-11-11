import 'package:lua_dardo_plus/lua.dart';
// The vendored interpreter exposes instruction dispatch on its implementation.
// ignore: implementation_imports
import 'package:lua_dardo_plus/src/state/lua_state_impl.dart';

/// Normal plugin calls have no quota. Interactive chunks share a finite budget
/// across nested calls, including protected calls, so loops cannot freeze the UI.
class ConsoleCapableLuaState extends LuaStateImpl {
  int? _remaining;

  @override
  int fetch() {
    final remaining = _remaining;
    if (remaining != null) {
      if (remaining <= 0) throw StateError('Lua instruction limit exceeded');
      _remaining = remaining - 1;
    }
    return super.fetch();
  }

  Future<List<String>> evaluate(String source) async {
    if (source.length > 16 * 1024) {
      throw ArgumentError('Lua input exceeds 16 KiB');
    }
    final output = <String>[];
    var characters = 0;
    void write(String value) {
      if (output.length >= 200 || characters >= 32 * 1024) return;
      final available = 32 * 1024 - characters;
      final bounded = value.length > available
          ? value.substring(0, available)
          : value;
      output.add(bounded);
      characters += bounded.length;
    }

    setTop(0);
    register('print', (state) {
      write(
        [
          for (var i = 1; i <= state.getTop(); i++) _display(state, i),
        ].join('\t'),
      );
      return 0;
    });
    // Coroutine states do not inherit the instruction counter. Interactive
    // sessions deliberately keep their code on this one bounded state.
    setTop(0);
    _remaining = 20000;
    try {
      final text = source.startsWith('=') ? source.substring(1) : source;
      var expression = false;
      try {
        expression = loadString('return $text') == ThreadStatus.luaOk;
      } catch (_) {
        // This interpreter throws parser exceptions instead of always returning
        // luaErrSyntax. Retry assignments/statements with a clean stack.
      }
      if (!expression) {
        setTop(0);
        if (loadString(text) != ThreadStatus.luaOk) {
          throw FormatException(toStr(-1) ?? 'Invalid Lua source');
        }
      }
      await callAsync(0, luaMultret);
      for (var i = 1; i <= getTop(); i++) {
        write(_display(this, i));
      }
      return output;
    } finally {
      _remaining = null;
      setTop(0);
    }
  }
}

String _display(LuaState lua, int index) => switch (lua.type(index)) {
  LuaType.luaNil => 'nil',
  LuaType.luaBoolean => '${lua.toBoolean(index)}',
  LuaType.luaNumber =>
    lua.isInteger(index) ? '${lua.toInteger(index)}' : '${lua.toNumber(index)}',
  LuaType.luaString => lua.toStr(index) ?? '',
  final type => '<${type.name}>',
};
