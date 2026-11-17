import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/state/station_session.dart';

class _Subscriptions {
  int count = 0;
}

/// Observe listeners on the outstanding provider chain, not provider invocations.
/// Forward completion transforms so a reused chain remains observable.
class _ObservedFuture<T> extends Fake implements Future<T> {
  _ObservedFuture(this.inner, this.subscriptions);
  final Future<T> inner;
  final _Subscriptions subscriptions;
  @override
  Future<R> then<R>(FutureOr<R> Function(T) onValue, {Function? onError}) {
    subscriptions.count++;
    return inner.then(onValue, onError: onError);
  }

  @override
  Future<T> whenComplete(FutureOr<void> Function() action) =>
      _ObservedFuture(inner.whenComplete(action), subscriptions);
}

void main() {
  testWidgets('100 timed out waits keep one provider completion listener', (
    tester,
  ) async {
    final response = Completer<List<Track>>();
    final subscriptions = _Subscriptions();
    var calls = 0;
    final session = StationSession(() {
      calls++;
      return _ObservedFuture(response.future, subscriptions);
    }, const []);
    addTearDown(session.close);
    for (var attempt = 0; attempt < 100; attempt++) {
      final expired = expectLater(
        session.nextBatch(),
        throwsA(isA<TimeoutException>()),
      );
      await tester.pump(const Duration(seconds: 20));
      await expired;
    }
    expect(calls, 1);
    expect(subscriptions.count, 1);
    final latest = session.nextBatch();
    response.complete(const []);
    expect(await latest, isEmpty);
    expect(subscriptions.count, 1);
  });

  testWidgets(
    'timed out station waits reuse the outstanding provider request',
    (tester) async {
      var calls = 0;
      final response = Completer<List<Track>>();
      final session = StationSession(() {
        calls++;
        return response.future;
      }, const []);
      addTearDown(session.close);
      final expired = expectLater(
        session.nextBatch(),
        throwsA(isA<TimeoutException>()),
      );
      await tester.pump(const Duration(seconds: 20));
      await expired;
      final retried = session.nextBatch();
      expect(calls, 1);
      response.complete(const []);
      expect(await retried, isEmpty);
      await session.nextBatch();
      expect(calls, 2);
    },
  );
  testWidgets(
    'concurrent waits share the deadline and late failure reaches only current wait',
    (tester) async {
      final response = Completer<List<Track>>();
      var calls = 0;
      final session = StationSession(() {
        calls++;
        return response.future;
      }, const []);
      addTearDown(session.close);
      final first = session.nextBatch();
      expect(identical(first, session.nextBatch()), true);
      final expired = expectLater(first, throwsA(isA<TimeoutException>()));
      await tester.pump(const Duration(seconds: 20));
      await expired;
      final current = session.nextBatch();
      final failed = expectLater(current, throwsStateError);
      response.completeError(StateError('provider failed'));
      await failed;
      expect(calls, 1);
      final retried = expectLater(session.nextBatch(), throwsStateError);
      await retried;
      expect(calls, 2);
    },
  );
}
