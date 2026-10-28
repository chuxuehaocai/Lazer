// Runs the audio cache checks with plain Dart (no Flutter toolchain).
//
//   dart tool/native_cache_check.dart
//
// Exercises the same scenarios as `test/audio/audio_stream_cache_test.dart`
// against a local HTTP server: whole download, range resume, a server that
// ignores the range, a failed download and cache eviction.
import 'dart:io';

import 'native/cache_checks.dart';

Future<void> main() async {
  final Directory root = await Directory.systemTemp.createTemp(
    'lazer-cache-check',
  );
  try {
    final List<String> failures = await verifyAudioStreamCache(root);
    if (failures.isEmpty) {
      stdout.writeln('audio cache check passed');
      return;
    }
    stderr.writeln('audio cache check failed:');
    for (final String failure in failures) {
      stderr.writeln('  $failure');
    }
    exitCode = 1;
  } finally {
    await root.delete(recursive: true);
  }
}
