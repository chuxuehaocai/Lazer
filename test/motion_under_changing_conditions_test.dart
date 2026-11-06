import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/animation/apple_spring.dart';
import 'package:lazer_nextgen/widgets/retained_content_switcher.dart';

/// Round-3 audit: motion under *changing* conditions.
///
/// The existing animation tests all establish reduce motion, the animation
/// speed and the app lifecycle before the animation starts. These cover what
/// happens when one of them changes while the spring is in the air, which is
/// where a retarget can be lost and a ticker stranded.
class Host extends StatefulWidget {
  const Host({super.key, required this.reduced});

  final bool reduced;

  @override
  State<Host> createState() => HostState();
}

class HostState extends State<Host> {
  final Set<String> _retained = <String>{};
  String _current = 'a';

  void go(String key) {
    setState(() {
      _retained.add(_current);
      _current = key;
    });
  }

  @override
  Widget build(BuildContext context) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(disableAnimations: widget.reduced),
    child: RetainedContentSwitcher(
      currentKey: _current,
      retainKeys: _retained,
      page: SizedBox.expand(child: Text(_current)),
    ),
  );
}

Widget host(GlobalKey<HostState> key, {bool reduced = false}) =>
    MaterialApp(home: Host(key: key, reduced: reduced));

void main() {
  testWidgets('a page switch settles when reduce motion turns on mid-flight', (
    tester,
  ) async {
    final key = GlobalKey<HostState>();
    await tester.pumpWidget(host(key));
    key.currentState!.go('b');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(
      tester.binding.transientCallbackCount,
      greaterThan(0),
      reason: 'the switch must still be in the air',
    );

    await tester.pumpWidget(host(key, reduced: true));
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
    expect(find.text('b'), findsOneWidget);
    expect(find.text('a'), findsNothing, reason: 'the outgoing page must be parked offstage');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a page switch survives being backgrounded mid-flight', (
    tester,
  ) async {
    final key = GlobalKey<HostState>();
    await tester.pumpWidget(host(key));
    key.currentState!.go('b');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(tester.binding.transientCallbackCount, 0);
    expect(find.text('b'), findsOneWidget);
    expect(find.text('a'), findsNothing, reason: 'the outgoing page must be parked offstage');
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing the animation speed mid-flight still settles', (
    tester,
  ) async {
    addTearDown(() => MotionTiming.speed = MotionTiming.defaultSpeed);
    final key = GlobalKey<HostState>();
    await tester.pumpWidget(host(key));
    key.currentState!.go('b');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    MotionTiming.speed = MotionTiming.maxSpeed;
    await tester.pump(const Duration(milliseconds: 30));
    MotionTiming.speed = MotionTiming.minSpeed;
    await tester.pump(const Duration(milliseconds: 30));

    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
    expect(find.text('b'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('six switches with no frame between them end on the last page', (
    tester,
  ) async {
    final key = GlobalKey<HostState>();
    await tester.pumpWidget(host(key));
    for (final String page in <String>['b', 'a', 'b', 'c', 'a', 'b']) {
      key.currentState!.go(page);
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(find.text('b'), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduce motion settled up front leaves no ticker behind', (
    tester,
  ) async {
    final key = GlobalKey<HostState>();
    await tester.pumpWidget(host(key, reduced: true));
    expect(tester.binding.transientCallbackCount, 0);
    key.currentState!.go('b');
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
    expect(find.text('b'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
