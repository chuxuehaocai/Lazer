import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/state/build_safe_notifier.dart';
import 'package:lazer_nextgen/widgets/build_safe_state.dart';

class _Signal extends ChangeNotifier {
  void pulse() => notifyListeners();
}

class _CounterModel extends ChangeNotifier with BuildSafeNotifier {
  int value = 0;

  void increment() {
    value++;
    notifyListeners();
  }
}

class _Counter extends StatefulWidget {
  const _Counter({super.key, required this.signal});
  final ChangeNotifier signal;

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> with BuildSafeState<_Counter> {
  int value = 0;
  int builds = 0;

  @override
  void initState() {
    super.initState();
    widget.signal.addListener(increment);
  }

  void increment() => setState(() => value++);

  void update(VoidCallback callback) => setState(callback);

  @override
  void dispose() {
    widget.signal.removeListener(increment);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    builds++;
    return Text('state: $value');
  }
}

Widget _siblings(Widget retained, {VoidCallback? duringBuild}) =>
    Directionality(
      textDirection: TextDirection.ltr,
      child: Column(
        children: [
          retained,
          Builder(
            builder: (_) {
              duringBuild?.call();
              return const SizedBox.shrink();
            },
          ),
        ],
      ),
    );

void main() {
  testWidgets(
    'sibling builds apply local mutations now and rebuild once later',
    (tester) async {
      final signal = _Signal();
      addTearDown(signal.dispose);
      final key = GlobalKey<_CounterState>();
      final retained = _Counter(key: key, signal: signal);
      await tester.pumpWidget(_siblings(retained));
      final state = key.currentState!;
      final initialBuilds = state.builds;

      await tester.pumpWidget(
        _siblings(
          retained,
          duringBuild: () {
            for (var i = 1; i <= 3; i++) {
              signal.pulse();
              expect(
                state.value,
                i,
                reason: 'mutations must preserve ordering',
              );
            }
            expect(state.builds, initialBuilds);
          },
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('state: 0'), findsOneWidget);
      await tester.pump();
      expect(find.text('state: 3'), findsOneWidget);
      expect(state.builds, initialBuilds + 1);
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );

  testWidgets(
    'model notifications protect framework AnimatedBuilder listeners',
    (tester) async {
      final model = _CounterModel();
      addTearDown(model.dispose);
      final delivered = <int>[];
      model.addListener(() => delivered.add(model.value));
      final retained = AnimatedBuilder(
        animation: model,
        builder: (_, _) => Text('model: ${model.value}'),
      );
      await tester.pumpWidget(_siblings(retained));
      await tester.pumpWidget(
        _siblings(
          retained,
          duringBuild: () {
            model.increment();
            model.increment();
            model.increment();
            expect(model.value, 3);
            expect(delivered, isEmpty);
          },
        ),
      );
      expect(tester.takeException(), isNull);
      expect(delivered, [3]);
      await tester.pump();
      expect(find.text('model: 3'), findsOneWidget);
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );

  testWidgets(
    'value notifications retain equality and synchronous value reads',
    (tester) async {
      final value = BuildSafeValueNotifier(0);
      addTearDown(value.dispose);
      var notifications = 0;
      value.addListener(() => notifications++);
      final retained = ValueListenableBuilder<int>(
        valueListenable: value,
        builder: (_, current, _) => Text('value: $current'),
      );
      await tester.pumpWidget(_siblings(retained));
      await tester.pumpWidget(
        _siblings(
          retained,
          duringBuild: () {
            value.value = 1;
            expect(value.value, 1);
            value.value = 2;
            value.value = 2;
            expect(value.value, 2);
            expect(notifications, 0);
          },
        ),
      );
      expect(tester.takeException(), isNull);
      expect(notifications, 1);
      await tester.pump();
      expect(find.text('value: 2'), findsOneWidget);
      value.value = 2;
      expect(notifications, 1);
      value.value = 3;
      expect(notifications, 2, reason: 'idle updates notify immediately');
      await tester.pump();
      expect(find.text('value: 3'), findsOneWidget);
    },
  );

  testWidgets(
    'animation ticks update both state and listeners in the same frame',
    (tester) async {
      final signal = _Signal();
      final model = _CounterModel();
      addTearDown(signal.dispose);
      addTearDown(model.dispose);
      final key = GlobalKey<_CounterState>();
      var notifications = 0;
      model.addListener(() => notifications++);
      await tester.pumpWidget(_siblings(_Counter(key: key, signal: signal)));
      SchedulerBinding.instance.scheduleFrameCallback((_) {
        expect(
          SchedulerBinding.instance.schedulerPhase,
          SchedulerPhase.transientCallbacks,
        );
        signal.pulse();
        model.increment();
        expect(key.currentState!.value, 1);
        expect(notifications, 1);
      });
      await tester.pump();
      expect(find.text('state: 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'frame microtasks coalesce updates without losing the last value',
    (tester) async {
      final signal = _Signal();
      final model = _CounterModel();
      addTearDown(signal.dispose);
      addTearDown(model.dispose);
      final key = GlobalKey<_CounterState>();
      var notifications = 0;
      model.addListener(() => notifications++);
      await tester.pumpWidget(_siblings(_Counter(key: key, signal: signal)));
      SchedulerBinding.instance.scheduleFrameCallback((_) {
        scheduleMicrotask(() {
          expect(
            SchedulerBinding.instance.schedulerPhase,
            SchedulerPhase.midFrameMicrotasks,
          );
          signal.pulse();
          signal.pulse();
          model.increment();
          model.increment();
          expect(key.currentState!.value, 2);
          expect(model.value, 2);
          expect(notifications, 0);
        });
      });
      await tester.pump();
      expect(notifications, 1);
      await tester.pump();
      expect(find.text('state: 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('queued local rebuilds stop when their widget is removed', (
    tester,
  ) async {
    final signal = _Signal();
    addTearDown(signal.dispose);
    final key = GlobalKey<_CounterState>();
    await tester.pumpWidget(_siblings(_Counter(key: key, signal: signal)));
    final state = key.currentState!;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (_) {
            state.increment();
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pump();
    expect(state.mounted, isFalse);
    expect(tester.takeException(), isNull);
    expect(state.increment, throwsFlutterError);
  });

  testWidgets('disposing a source cancels deferred notifications', (
    tester,
  ) async {
    final model = _CounterModel();
    var notifications = 0;
    model.addListener(() => notifications++);
    await tester.pumpWidget(
      Builder(
        builder: (_) {
          model.increment();
          model.dispose();
          return const SizedBox.shrink();
        },
      ),
    );
    await tester.pump();
    expect(notifications, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('build-time state updates still reject asynchronous callbacks', (
    tester,
  ) async {
    final signal = _Signal();
    addTearDown(signal.dispose);
    final key = GlobalKey<_CounterState>();
    final retained = _Counter(key: key, signal: signal);
    await tester.pumpWidget(_siblings(retained));
    await tester.pumpWidget(
      _siblings(
        retained,
        duringBuild: () => expect(
          // Deliberately violate the callback contract to check its assertion.
          () => key.currentState!.update(() async {}),
          throwsFlutterError,
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
