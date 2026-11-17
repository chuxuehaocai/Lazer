import 'dart:async';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_worker.dart';
import 'package:lazer_nextgen/audio/native/native_engine_ownership.dart';

void _holdReplies(SendPort replies) {
  final inbox = ReceivePort();
  replies.send(inbox.sendPort);
  inbox.listen((_) {});
}

void _exitBeforeReply(SendPort replies) {
  final inbox = ReceivePort();
  replies.send(inbox.sendPort);
  inbox.listen((_) => inbox.close());
}

void _exitBeforeReady(SendPort replies) {}

void main() {
  test(
    '1000 concurrent engine admissions start only one spawn and transfer ownership',
    () async {
      final budget = NativeEngineOwnershipBudget();
      final gate = Completer<void>();
      var spawns = 0;
      final owner = Object();
      final attempts = [
        for (var i = 0; i < 1000; i++)
          budget.admit<Object>((token) async {
            spawns++;
            await gate.future;
            budget.claim(owner, reservation: token);
            return owner;
          }),
      ];
      expect(spawns, 1);
      expect(budget.busy, isTrue);
      gate.complete();
      final results = await Future.wait(attempts);
      expect(results.whereType<Object>(), [owner]);
      expect(budget.busy, isTrue);
      budget.release(owner);
      expect(budget.busy, isFalse);
    },
  );

  test(
    'a failed spawn releases its reservation for the next attempt',
    () async {
      final budget = NativeEngineOwnershipBudget();
      await expectLater(
        budget.admit<Object>((_) async {
          throw StateError('spawn failed');
        }),
        throwsStateError,
      );
      expect(budget.busy, isFalse);
      expect(await budget.admit<Object>((_) async => Object()), isNotNull);
      expect(budget.busy, isFalse);
    },
  );
  test(
    'worker admission is bounded with two reserved teardown slots',
    () async {
      final worker = await LazerAudioWorker.spawnForTesting(_holdReplies);
      final pending = [
        for (var i = 0; i < LazerAudioWorker.maximumPending; i++)
          worker
              .call(LazerWorkerOp.setVolume, [1, 1.0])
              .then<Object?>(
                (value) => value,
                onError: (Object error) => error,
              ),
      ];
      await expectLater(
        worker.call(LazerWorkerOp.seek, [1, 0]),
        throwsA(isA<LazerWorkerNotSubmitted>()),
      );
      for (final op in [LazerWorkerOp.stop, LazerWorkerOp.destroy]) {
        pending.add(
          worker
              .call(op, [1])
              .then<Object?>(
                (value) => value,
                onError: (Object error) => error,
              ),
        );
      }
      await expectLater(
        worker.call(LazerWorkerOp.stop, [1]),
        throwsA(isA<LazerWorkerNotSubmitted>()),
      );
      await worker.close();
      expect(await Future.wait(pending), everyElement(isA<StateError>()));
      await worker.exited;
    },
  );

  test(
    'an exit without an RPC reply fails its waiter and confirms close',
    () async {
      final worker = await LazerAudioWorker.spawnForTesting(_exitBeforeReply);
      await expectLater(
        worker
            .call(LazerWorkerOp.stop, [1])
            .timeout(const Duration(seconds: 2)),
        throwsStateError,
      );
      await worker.close();
      await worker.exited;
    },
  );

  test('an exit before readiness rejects startup instead of hanging', () async {
    await expectLater(
      LazerAudioWorker.spawnForTesting(
        _exitBeforeReady,
      ).timeout(const Duration(seconds: 2)),
      throwsStateError,
    );
  });
}
