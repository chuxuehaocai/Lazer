import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/plugins/plugin_event_scheduler.dart';

void main() {
  test('timers validate limits and allow cancellation/replacement', () {
    final scheduler = PluginEventScheduler((_, _) async => null);
    for (final interval in [0, 99, 100.5, 60001, double.nan]) {
      expect(
        () => scheduler.configure({'id': 'a', 'intervalMs': interval}),
        throwsFormatException,
      );
    }
    for (var i = 0; i < 4; i++) {
      scheduler.configure({'id': 'timer-$i', 'intervalMs': 100});
    }
    expect(
      () => scheduler.configure({'id': 'fifth', 'intervalMs': 100}),
      throwsFormatException,
    );
    scheduler.configure({'id': 'timer-0', 'intervalMs': 200});
    scheduler.configure({'id': 'timer-1', 'operation': 'cancel'});
    expect(scheduler.configure({'operation': 'list'}), hasLength(3));
    scheduler.cancelAll();
    expect(scheduler.configure({'operation': 'list'}), isEmpty);
  });

  test(
    'a busy VM accumulates no ticks and teardown cancels future wakeups',
    () async {
      var calls = 0;
      final gate = Completer<Object?>();
      final scheduler = PluginEventScheduler((event, args) {
        expect(event, 'timer');
        expect(args, {'id': 'bridge'});
        calls++;
        return gate.future;
      });
      addTearDown(scheduler.cancelAll);
      scheduler.configure({'id': 'bridge', 'intervalMs': 100});
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(calls, 1);
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(calls, greaterThanOrEqualTo(2));
      final beforeClose = calls;
      scheduler.cancelAll();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(calls, beforeClose);
      expect(scheduler.configure({'operation': 'list'}), isEmpty);
    },
  );

  test(
    'replacement and cancellation cannot refund in-flight dispatch slots',
    () async {
      final gate = Completer<Object?>();
      final calls = <String>[];
      final scheduler = PluginEventScheduler((_, args) {
        calls.add(args['id'] as String);
        return gate.future;
      });
      addTearDown(scheduler.cancelAll);
      scheduler.configure({'id': 'bridge', 'intervalMs': 100});
      await Future<void>.delayed(const Duration(milliseconds: 150));
      scheduler.configure({'id': 'bridge', 'intervalMs': 100});
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(calls, ['bridge']);
      scheduler.configure({'id': 'bridge', 'operation': 'cancel'});
      for (var i = 0; i < 5; i++) {
        scheduler.configure({'id': 'new-$i', 'intervalMs': 100});
        await Future<void>.delayed(const Duration(milliseconds: 150));
        scheduler.configure({'id': 'new-$i', 'operation': 'cancel'});
      }
      expect(calls, hasLength(4));
      expect(calls.toSet(), hasLength(4));
      gate.complete();
      scheduler.cancelAll();
    },
  );
}
