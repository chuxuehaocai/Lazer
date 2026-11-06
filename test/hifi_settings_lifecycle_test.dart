import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/hifi_controller.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/hifi_settings.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/widgets/hifi_settings_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Hifi extends HifiController {
  _Hifi(this.message)
    : super(const HifiSettings(), engine: null, persist: (_) async {});

  String message;
  final refreshPhases = <SchedulerPhase>[];
  bool get observed => hasListeners;

  @override
  HifiStatus get status => HifiStatus(
    nativeAvailable: false,
    nativeReason: message,
    engineDescription: 'test engine',
  );

  @override
  Future<void> refreshDevices() async {
    refreshPhases.add(SchedulerBinding.instance.schedulerPhase);
    notifyListeners();
  }

  void report(String next) {
    message = next;
    notifyListeners();
  }
}

Widget _host(Widget first, {Widget? second}) => MaterialApp(
  theme: buildAppleTheme(),
  home: Scaffold(
    body: SelectionArea(
      child: Row(
        children: [
          Expanded(child: first),
          if (second != null) Expanded(child: second),
        ],
      ),
    ),
  ),
);

Widget _section(AppState state, {Key? key}) => SingleChildScrollView(
  child: HifiSettingsSection(key: key, state: state),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('new HiFi sections do not dirty retained selection subtrees', (
    tester,
  ) async {
    final hifi = _Hifi('shared output');
    final state = AppState(hifi: hifi);
    addTearDown(state.dispose);
    addTearDown(hifi.dispose);
    final firstKey = GlobalKey();
    final first = _section(state, key: firstKey);
    await tester.pumpWidget(_host(first));
    await tester.pumpAndSettle();
    final retainedElement = firstKey.currentContext;
    expect(hifi.refreshPhases, [SchedulerPhase.postFrameCallbacks]);

    await tester.pumpWidget(_host(first, second: _section(state)));
    await tester.pumpAndSettle();
    expect(firstKey.currentContext, same(retainedElement));
    expect(hifi.refreshPhases, [
      SchedulerPhase.postFrameCallbacks,
      SchedulerPhase.postFrameCallbacks,
    ]);
    expect(find.text('shared output'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('HiFi sections detach old controllers when AppState changes', (
    tester,
  ) async {
    final first = _Hifi('first output');
    final second = _Hifi('second output');
    final firstApp = AppState(hifi: first);
    final secondApp = AppState(hifi: second);
    final localApp = AppState();
    addTearDown(firstApp.dispose);
    addTearDown(secondApp.dispose);
    addTearDown(localApp.dispose);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    final key = GlobalKey();
    await tester.pumpWidget(_host(_section(firstApp, key: key)));
    await tester.pumpAndSettle();
    final retainedElement = key.currentContext;
    expect(first.observed, isTrue);

    await tester.pumpWidget(_host(_section(secondApp, key: key)));
    await tester.pumpAndSettle();
    expect(key.currentContext, same(retainedElement));
    expect(first.observed, isFalse);
    expect(second.observed, isTrue);
    expect(find.text('first output'), findsNothing);
    expect(find.text('second output'), findsOneWidget);
    first.report('stale output');
    second.report('new output status');
    await tester.pump();
    expect(find.text('stale output'), findsNothing);
    expect(find.text('new output status'), findsOneWidget);
    expect(first.refreshPhases, [SchedulerPhase.postFrameCallbacks]);
    expect(second.refreshPhases, [SchedulerPhase.postFrameCallbacks]);

    await tester.pumpWidget(_host(_section(localApp, key: key)));
    await tester.pumpAndSettle();
    expect(second.observed, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
