import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/native/cache_checks.dart';

void main() {
  test(
    'native streaming cache retries failures and preserves complete audio',
    () async {
      final Directory root = await Directory.systemTemp.createTemp(
        'lazer-stream-cache-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      expect(await verifyAudioStreamCache(root), isEmpty);
    },
  );
}
