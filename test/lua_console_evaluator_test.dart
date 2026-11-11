import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/plugins/lua_console_evaluator.dart';

void main() {
  test(
    'console evaluates expressions and keeps variables in its session',
    () async {
      final lua = ConsoleCapableLuaState();
      expect(await lua.evaluate('x = 40'), isEmpty);
      expect(await lua.evaluate('x + 2'), ['42']);
      expect(await lua.evaluate('print("hello", x)'), ['hello\t40']);
    },
  );

  test('console rejects oversized input before compiling it', () async {
    final lua = ConsoleCapableLuaState();
    await expectLater(
      lua.evaluate('x' * (16 * 1024 + 1)),
      throwsA(isA<ArgumentError>()),
    );
  });
}
