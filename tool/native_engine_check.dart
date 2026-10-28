// Runs the engine's pure-Dart contracts with plain Dart (no Flutter toolchain).
//
//   dart tool/native_engine_check.dart
//
// Covers the worker message shapes and the format summary. Real playback and the
// FFI calls themselves need a built engine and a host with an output device; see
// docs/audio-engine.md.
import 'dart:io';

import 'native/engine_contract_checks.dart';

void main() {
  final List<String> failures = verifyEngineContracts();
  if (failures.isEmpty) {
    stdout.writeln('engine contract check passed');
    return;
  }
  stderr.writeln('engine contract check failed:');
  for (final String failure in failures) {
    stderr.writeln('  $failure');
  }
  exitCode = 1;
}
