// CI wrapper for the audio cache checks.
//
// The scenarios themselves live in `tool/native/cache_checks.dart` so they also
// run without a Flutter toolchain (`dart tool/native_cache_check.dart`) on hosts
// that cannot build the app, which is how the download logic was verified while
// the engine itself was still uncompiled.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/native/cache_checks.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lazer-cache-test');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('the streaming cache downloads, resumes and reports failures', () async {
    expect(await verifyAudioStreamCache(root), isEmpty);
  });
}
