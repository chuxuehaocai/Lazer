import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/audio_operation_queue.dart';

void main() {
  test(
    'latest source wins a 1000 request burst without retiring active work',
    () async {
      final queue = AudioOperationQueue(maximumPending: 2);
      final gate = Completer<int>();
      final active = queue.run(
        () => gate.future,
        key: 'source',
        onSuperseded: () => -1,
      );
      await Future<void>.delayed(Duration.zero);
      var completedActive = false;
      unawaited(active.then((_) => completedActive = true));
      final executed = <int>[];
      final waiting = <Future<int>>[];
      for (var index = 0; index < 1000; index++) {
        final value = index;
        waiting.add(
          queue.run(
            () async {
              executed.add(value);
              return value;
            },
            key: 'source',
            onSuperseded: () => value,
          ),
        );
      }
      expect(completedActive, isFalse);
      expect(executed, isEmpty);
      gate.complete(42);
      expect(await active, 42);
      expect(await Future.wait(waiting), List.generate(1000, (index) => index));
      await queue.idle;
      expect(executed, [999]);
    },
  );

  test(
    'essential stop keeps the fixed waiting budget and cannot be rejected',
    () async {
      final queue = AudioOperationQueue(maximumPending: 2);
      final gate = Completer<void>();
      final active = queue.run(() => gate.future);
      await Future<void>.delayed(Duration.zero);
      final retired = queue.run(() async => true, onSuperseded: () => false);
      final second = queue.run(() async => true, onSuperseded: () => false);
      await expectLater(queue.run(() async => true), throwsStateError);
      var stops = 0;
      final stop = queue.run(
        () async {
          stops++;
        },
        key: 'source',
        onSuperseded: () {},
        essential: true,
      );
      expect(await retired, isFalse);
      gate.complete();
      await active;
      expect(await second, isTrue);
      await stop;
      await queue.idle;
      expect(stops, 1);
    },
  );

  test(
    'cancelPending releases waiting closures and waits for active cleanup',
    () async {
      final queue = AudioOperationQueue(maximumPending: 2);
      final gate = Completer<void>();
      final active = queue.run(() => gate.future);
      await Future<void>.delayed(Duration.zero);
      var ran = false;
      final canceled = queue.run(() async {
        ran = true;
        return true;
      }, onSuperseded: () => false);
      queue.cancelPending();
      expect(await canceled, isFalse);
      var idle = false;
      unawaited(queue.idle.then((_) => idle = true));
      await Future<void>.delayed(Duration.zero);
      expect(idle, isFalse);
      gate.complete();
      await active;
      await queue.idle;
      expect(ran, isFalse);
    },
  );
}
