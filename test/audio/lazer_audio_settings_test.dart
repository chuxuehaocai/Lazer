// CI wrapper for the native engine's pure-Dart contracts.
//
// The assertions live in `tool/native/engine_contract_checks.dart` so they also run
// with plain Dart (`dart tool/native_engine_check.dart`) on hosts without the
// Flutter toolchain or the engine binary, which is how they were verified.
import 'package:flutter_test/flutter_test.dart';

import '../../tool/native/engine_contract_checks.dart';

void main() {
  test('worker messages and format summaries hold their contracts', () {
    expect(verifyEngineContracts(), isEmpty);
  });
}
