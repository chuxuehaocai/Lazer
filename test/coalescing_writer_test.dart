import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/local/coalescing_writer.dart';

void main() {
  test(
    'overlapping requests write the latest state before callers complete',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final writes = <int>[];
      var value = 1;
      final writer = CoalescingWriter(() async {
        writes.add(value);
        if (writes.length == 1) {
          started.complete();
          await release.future;
        }
      });
      final first = writer.request();
      await started.future;
      value = 2;
      final second = writer.request();
      value = 3;
      final third = writer.request();
      release.complete();
      await Future.wait([first, second, third]);
      expect(writes, [1, 3]);
      value = 4;
      await writer.request();
      expect(writes, [1, 3, 4]);
    },
  );

  test('a failed batch does not prevent a later request', () async {
    var calls = 0;
    final writer = CoalescingWriter(() async {
      if (++calls == 1) throw StateError('write failed');
    });
    await expectLater(writer.request(), throwsStateError);
    await writer.request();
    expect(calls, 2);
  });
}
