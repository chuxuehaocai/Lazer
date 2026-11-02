import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/animation/apple_modal.dart';
import 'package:lazer_nextgen/animation/apple_spring.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';

Future<GlobalKey<NavigatorState>> _host(
  WidgetTester tester, {
  bool reduced = false,
}) async {
  final nav = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: nav,
      theme: buildAppleTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
        child: child!,
      ),
      home: const SizedBox.expand(),
    ),
  );
  return nav;
}

void main() {
  testWidgets('dialog reverse continues its presented spring', (tester) async {
    final nav = await _host(tester);
    final route = AppleDialogRoute<void>(
      context: nav.currentContext!,
      builder: (_) => const AlertDialog(content: Text('A dialog')),
    );
    nav.currentState!.push(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    final before = route.animation!.value;
    expect(
      before,
      closeTo(AppleSpring.responsive.simulation(0, 1).x(.09), .00001),
    );
    nav.currentState!.pop();
    await tester.pump();
    expect(route.animation!.value, closeTo(before, .00001));
    await tester.pump(const Duration(milliseconds: 1));
    expect(route.animation!.value, greaterThan(before));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('sheet uses physical progress and can reverse before arriving', (
    tester,
  ) async {
    final nav = await _host(tester);
    TransitionRoute<dynamic>? route;
    showAppleModalBottomSheet<void>(
      context: nav.currentContext!,
      showDragHandle: true,
      builder: (context) {
        route = ModalRoute.of(context)! as TransitionRoute<dynamic>;
        return const SizedBox(
          height: 320,
          child: Center(child: Text('A sheet')),
        );
      },
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final before = route!.animation!.value;
    expect(
      before,
      closeTo(
        const AppleSpring(
          duration: Duration(milliseconds: 350),
        ).simulation(0, 1).x(.12),
        .00001,
      ),
    );
    nav.currentState!.pop();
    await tester.pump();
    expect(route!.animation!.value, closeTo(before, .00001));
    await tester.pump(const Duration(milliseconds: 1));
    expect(route!.animation!.value, greaterThan(before));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets(
    'a small sheet drag returns from its release position without a jump',
    (tester) async {
      final nav = await _host(tester);
      TransitionRoute<dynamic>? route;
      showAppleModalBottomSheet<void>(
        context: nav.currentContext!,
        showDragHandle: true,
        builder: (context) {
          route = ModalRoute.of(context)! as TransitionRoute<dynamic>;
          return const SizedBox(height: 320);
        },
      );
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.byType(BottomSheet));
      final gesture = await tester.startGesture(
        Offset(rect.center.dx, rect.top + 20),
      );
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump();
      await gesture.moveBy(
        const Offset(0, 40),
        timeStamp: const Duration(milliseconds: 200),
      );
      await tester.pump();
      final before = route!.animation!.value;
      expect(before, inExclusiveRange(.5, 1));
      await gesture.up(timeStamp: const Duration(milliseconds: 400));
      await tester.pump();
      expect(route!.animation!.value, closeTo(before, .00001));
      await tester.pumpAndSettle();
      expect(route!.animation!.value, 1);
      nav.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets('Reduce Motion releases the sheet route immediately', (
    tester,
  ) async {
    final nav = await _host(tester, reduced: true);
    showAppleModalBottomSheet<void>(
      context: nav.currentContext!,
      builder: (_) => const SizedBox(height: 320),
    );
    await tester.pumpAndSettle();
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
  });
}
