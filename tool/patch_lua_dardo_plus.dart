import 'dart:convert';
import 'dart:io';

const _luaStateFile = 'lib/src/state/lua_state_impl.dart';
const _stringLibraryFile = 'lib/src/stdlib/string_lib.dart';

void main() {
  final packageRoot = _findPackageRoot();
  final luaStatePath = _join(packageRoot, _luaStateFile);
  final stringLibraryPath = _join(packageRoot, _stringLibraryFile);

  _patchLuaState(luaStatePath);
  _patchStringLibrary(stringLibraryPath);
  stdout.writeln('Patched lua_dardo_plus at $packageRoot');
}

String _findPackageRoot() {
  final configFile = File('.dart_tool/package_config.json');
  if (!configFile.existsSync()) {
    throw StateError(
      'Missing .dart_tool/package_config.json; run flutter pub get first.',
    );
  }

  final config =
      jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
  final packages = config['packages'] as List<dynamic>? ?? const [];
  for (final entry in packages) {
    final package = entry as Map<String, dynamic>;
    if (package['name'] != 'lua_dardo_plus') continue;
    final rootUri = package['rootUri'] as String?;
    if (rootUri == null) break;
    return Uri.parse(rootUri).toFilePath(windows: Platform.isWindows);
  }

  throw StateError('lua_dardo_plus is not present in package_config.json.');
}

String _join(String root, String relative) => Directory(
  root,
).uri.resolve(relative).toFilePath(windows: Platform.isWindows);

void _patchLuaState(String path) {
  final file = File(path);
  var source = file.readAsStringSync();

  if (!source.contains('Future<void> _callLuaClosureAsync(')) {
    const callSite = '''      if (c.proto != null) {
        _callLuaClosure(nArgs, nResults, c);
      } else if (c.isAsync) {
      ''';
    const patchedCallSite = '''      if (c.proto != null) {
        await _callLuaClosureAsync(nArgs, nResults, c);
      } else if (c.isAsync) {
      ''';
    source = _replaceOnce(source, callSite, patchedCallSite, path);

    const marker = '''  /// Asynchronously call an async Dart closure.
    ''';
    const asyncLuaClosure =
        '''  /// Run a Lua closure through the async interpreter so nested async
  /// Dart calls keep the closure's registers and stack intact.
  Future<void> _callLuaClosureAsync(int nArgs, int nResults, Closure c) async {
    final nRegs = c.proto!.maxStackSize;
    final nParams = c.proto!.numParams!;
    final newStack = LuaStack()..state = this..closure = c;
    final funcAndArgs = _stack!.popN(nArgs + 1);
    newStack.pushN(funcAndArgs.sublist(1), nParams);
    if (nArgs > nParams && c.proto!.isVararg == 1) {
      newStack.varargs = funcAndArgs.sublist(nParams + 1);
    }
    _pushLuaStack(newStack);
    setTop(nRegs);
    try {
      while (true) {
        final instruction = fetch();
        final opcode = Instruction.getOpCode(instruction);
        if (opcode.name == 'CALL' || opcode.name == 'TAILCALL') {
          final a = Instruction.getA(instruction) + 1;
          final b = Instruction.getB(instruction);
          final count =
              opcode.name == 'TAILCALL' ? 0 : Instruction.getC(instruction);
          final args = Instructions.pushFuncAndArgs(a, b, this);
          await callAsync(args, count - 1);
          Instructions.popResults(a, count, this);
        } else if (opcode.name == 'TFORCALL') {
          final a = Instruction.getA(instruction) + 1;
          final count = Instruction.getC(instruction);
          Instructions.pushFuncAndArgs(a, 3, this);
          await callAsync(2, count);
          Instructions.popResults(a + 3, count + 1, this);
        } else {
          opcode.action!.call(instruction, this);
        }
        if (opcode.name == 'RETURN') break;
      }
    } finally {
      _popLuaStack();
    }
    if (nResults != 0) {
      _stack!.pushN(newStack.popN(newStack.top() - nRegs), nResults);
    }
  }

  /// Asynchronously call an async Dart closure.
    ''';
    source = _replaceOnce(source, marker, asyncLuaClosure, path);
    file.writeAsStringSync(source);
  }
}

void _patchStringLibrary(String path) {
  final file = File(path);
  final source = file.readAsStringSync();
  if (source.contains("ls.pushString(s.split('').reversed.join());")) return;

  const original = '''    var strLen = s.length;
    if (strLen > 1) {
      var a = [];
      for (var i = 0; i < strLen; i++) {
        a[i] = s[strLen - 1 - i];
      }
      ls.pushString(a.join());
    }
    ''';
  const replacement = '''    ls.pushString(s.split('').reversed.join());
    ''';
  file.writeAsStringSync(_replaceOnce(source, original, replacement, path));
}

String _replaceOnce(
  String source,
  String original,
  String replacement,
  String path,
) {
  final needle = original.trimRight();
  final replacementText = replacement.trimRight();
  final first = source.indexOf(needle);
  if (first < 0) {
    throw StateError(
      'Expected lua_dardo_plus source block was not found: $path',
    );
  }
  final second = source.indexOf(needle, first + needle.length);
  if (second >= 0) {
    throw StateError('Expected source block occurs more than once: $path');
  }
  return source.replaceRange(first, first + needle.length, replacementText);
}
