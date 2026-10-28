// Verifies that the Dart mirror of `lazer_audio_api.h` matches the layout the C
// compiler produces. Run with plain Dart (no Flutter toolchain required):
//
//   dart tool/native_abi_check.dart
//
// Exits non-zero when any struct size or field offset disagrees with
// `native/lazer-audio-bridge/tools/abi_layout_probe.cpp`.
import 'dart:io';

import 'native/abi_layout.dart';

void main() {
  final List<String> problems = verifyAbiLayout();
  disposeAbiLayoutProbes();
  if (problems.isEmpty) {
    stdout.writeln(
      'native ABI layout OK (${abiCStructSizes.length} structs checked)',
    );
    return;
  }
  stderr.writeln('native ABI layout mismatches:');
  for (final String problem in problems) {
    stderr.writeln('  $problem');
  }
  exitCode = 1;
}
