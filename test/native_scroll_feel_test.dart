import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/widgets/app_scroll_behavior.dart';

void main() {
  testWidgets(
    'desktop wheels ease into motion while precise deltas stay direct',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          scrollBehavior: const AppScrollBehavior(),
          home: ListView.builder(
            controller: controller,
            itemCount: 200,
            itemExtent: 60,
            itemBuilder: (_, i) => Text('Row $i'),
          ),
        ),
      );
      final center = tester.getCenter(find.byType(ListView));
      await tester.sendEventToBinding(
        PointerScrollEvent(position: center, scrollDelta: const Offset(0, 120)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(controller.offset, inExclusiveRange(0, 40));
      final first = controller.offset;
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.offset, greaterThan(first));
      await tester.pumpAndSettle();
      final before = controller.offset;
      await tester.sendEventToBinding(
        PointerScrollEvent(position: center, scrollDelta: const Offset(0, 8)),
      );
      await tester.pump();
      expect(controller.offset, closeTo(before + 8, .01));
      await tester.pump(const Duration(milliseconds: 300));
      expect(controller.offset, closeTo(before + 8, .01));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('Apple touch scrolling uses the platform bouncing simulation', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.iOS),
        scrollBehavior: const AppScrollBehavior(),
        home: ListView.builder(
          controller: controller,
          itemCount: 100,
          itemExtent: 60,
          itemBuilder: (_, i) => Text('Row $i'),
        ),
      ),
    );
    expect(controller.position.physics, isA<BouncingScrollPhysics>());
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
