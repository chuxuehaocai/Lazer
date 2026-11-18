import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/widgets/app_scroll_behavior.dart';

void main() {
  for (final background in [false, true]) {
    testWidgets(
      '${background ? "background" : "hidden"} scroll views discard old wheel momentum',
      (tester) async {
        final controller = ScrollController();
        addTearDown(controller.dispose);
        Future<void> show(bool visible) => tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.windows),
            scrollBehavior: const AppScrollBehavior(),
            home: TickerMode(
              enabled: visible,
              child: ListView.builder(
                controller: controller,
                itemExtent: 50,
                itemCount: 100,
                itemBuilder: (_, index) => Text('Row $index'),
              ),
            ),
          ),
        );

        await show(true);
        await tester.sendEventToBinding(
          const PointerScrollEvent(
            position: Offset(200, 200),
            scrollDelta: Offset(0, 120),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        expect(controller.offset, greaterThan(0));
        if (background) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
        } else {
          await show(false);
        }
        final stopped = controller.offset;
        await tester.pump(const Duration(seconds: 1));
        if (background) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        } else {
          await show(true);
        }
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(controller.offset, stopped);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
