import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/animation/view_transitions.dart';
import 'package:lazer_nextgen/animation/apple_spring.dart';

Widget _host(ValueNotifier<bool> selected, {bool reduced = false}) =>
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
        child: child!,
      ),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 240,
            height: 120,
            child: ValueListenableBuilder(
              valueListenable: selected,
              builder: (context, second, _) => ViewTransitionSwitcher(
                child: Center(
                  key: ValueKey(second),
                  child: Text(second ? 'Second view' : 'First view'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets(
    'shared view switch arrives nonlinearly and removes the departing view',
    (tester) async {
      final selected = ValueNotifier(false);
      addTearDown(selected.dispose);
      await tester.pumpWidget(_host(selected));
      selected.value = true;
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final fade = tester.widget<FadeTransition>(
        find
            .ancestor(
              of: find.text('Second view'),
              matching: find.byType(FadeTransition),
            )
            .first,
      );
      final slide = tester.widget<SlideTransition>(
        find
            .ancestor(
              of: find.text('Second view'),
              matching: find.byType(SlideTransition),
            )
            .first,
      );
      expect(
        slide.position.value.dy,
        closeTo(
          .025 *
              (1 -
                  const AppleSpring(
                    duration: ViewMotion.duration,
                  ).simulation(0, 1).x(.08)),
          .00001,
        ),
        reason: 'The view uses the same spring response as other transitions.',
      );
      expect(
        fade.opacity.value,
        0,
        reason: 'The new view waits for the old text to fade away.',
      );
      await tester.pump(const Duration(milliseconds: 80));
      expect(fade.opacity.value, greaterThan(0));
      final outgoingFade = tester.widget<FadeTransition>(
        find
            .ancestor(
              of: find.text('First view'),
              matching: find.byType(FadeTransition),
            )
            .first,
      );
      expect(outgoingFade.opacity.value, 0);
      final departing = find.ancestor(
        of: find.text('First view'),
        matching: find.byType(IgnorePointer),
      );
      expect(tester.widget<IgnorePointer>(departing.first).ignoring, isTrue);
      await tester.pumpAndSettle();
      expect(find.text('First view'), findsNothing);
      expect(find.text('Second view'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reduced motion switches the view immediately', (tester) async {
    final selected = ValueNotifier(false);
    addTearDown(selected.dispose);
    await tester.pumpWidget(_host(selected, reduced: true));
    selected.value = true;
    await tester.pump();
    await tester.pump();
    expect(find.text('First view'), findsNothing);
    expect(find.text('Second view'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
    expect(tester.takeException(), isNull);
  });
}
