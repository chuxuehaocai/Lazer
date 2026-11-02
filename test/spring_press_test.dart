import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/widgets/accessible_controls.dart';
import 'package:lazer_nextgen/widgets/interaction_feedback.dart';
import 'package:lazer_nextgen/widgets/spring_buttons.dart';

Widget _host(Widget child, {bool reduceMotion = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: Scaffold(body: Center(child: child)),
  ),
);

double _scale(WidgetTester tester) => tester
    .widget<Transform>(
      find
          .descendant(
            of: find.byType(SpringPress).first,
            matching: find.byType(Transform),
          )
          .first,
    )
    .transform
    .entry(0, 0);

void main() {
  testWidgets('all standard and icon variants retain a Material button', (
    tester,
  ) async {
    var actions = 0;
    final buttons = <Widget>[
      SpringTextButton(onPressed: () => actions++, child: const Text('Text')),
      SpringTextButton.icon(
        onPressed: () => actions++,
        icon: const Icon(Icons.add),
        label: const Text('Text icon'),
      ),
      SpringFilledButton(
        onPressed: () => actions++,
        child: const Text('Filled'),
      ),
      SpringFilledButton.icon(
        onPressed: () => actions++,
        icon: const Icon(Icons.add),
        label: const Text('Filled icon'),
      ),
      SpringFilledButton.tonal(
        onPressed: () => actions++,
        child: const Text('Tonal'),
      ),
      SpringFilledButton.tonalIcon(
        onPressed: () => actions++,
        icon: const Icon(Icons.add),
        label: const Text('Tonal icon'),
      ),
      SpringOutlinedButton(
        onPressed: () => actions++,
        child: const Text('Outlined'),
      ),
      SpringOutlinedButton.icon(
        onPressed: () => actions++,
        icon: const Icon(Icons.add),
        label: const Text('Outlined icon'),
      ),
      SpringElevatedButton(
        onPressed: () => actions++,
        child: const Text('Elevated'),
      ),
      SpringElevatedButton.icon(
        onPressed: () => actions++,
        icon: const Icon(Icons.add),
        label: const Text('Elevated icon'),
      ),
    ];
    for (final button in buttons) {
      await tester.pumpWidget(_host(button));
      final material = find.byWidgetPredicate(
        (widget) => widget is ButtonStyleButton,
      );
      expect(material, findsOneWidget);
      await tester.tap(material);
      await tester.pumpAndSettle();
    }
    expect(actions, buttons.length);
  });

  testWidgets(
    'press release and repeated presses retain their presented value',
    (tester) async {
      var actions = 0;
      await tester.pumpWidget(
        _host(
          SpringTextButton(
            onPressed: () => actions++,
            child: const Text('Press'),
          ),
        ),
      );
      final target = find.byType(TextButton);
      final gesture = await tester.startGesture(tester.getCenter(target));
      await tester.pump(const Duration(milliseconds: 110));
      await tester.pump(const Duration(milliseconds: 80));
      final held = _scale(tester);
      expect(held, lessThan(1));
      await gesture.up();
      await tester.pump();
      expect(_scale(tester), closeTo(held, .00001));
      expect(actions, 1);
      await tester.pump(const Duration(milliseconds: 20));
      final released = _scale(tester);
      final next = await tester.startGesture(tester.getCenter(target));
      await tester.pump();
      expect(_scale(tester), closeTo(released, .00001));
      await next.cancel();
      await tester.pumpAndSettle();
      expect(_scale(tester), 1);
      expect(actions, 1);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets('drag cancellation releases the spring without activating', (
    tester,
  ) async {
    var actions = 0;
    await tester.pumpWidget(
      _host(
        SpringFilledButton.icon(
          onPressed: () => actions++,
          icon: const Icon(Icons.play_arrow),
          label: const Text('Play'),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(FilledButton)),
    );
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_scale(tester), lessThan(1));
    await gesture.moveBy(const Offset(0, 180));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_scale(tester), 1);
    expect(actions, 0);
  });

  testWidgets('keyboard and semantics retain one Material activation', (
    tester,
  ) async {
    var actions = 0;
    final node = FocusNode();
    addTearDown(node.dispose);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(
        SpringOutlinedButton(
          onPressed: () => actions++,
          focusNode: node,
          child: const Text('Keyboard'),
        ),
      ),
    );
    node.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(actions, 1);
    expect(find.byType(OutlinedButton), findsOneWidget);
    expect(find.bySemanticsLabel('Keyboard'), findsOneWidget);
    expect(node.hasFocus, true);
    semantics.dispose();
  });

  testWidgets('Reduce Motion removes press movement and leaves no frame loop', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        SpringElevatedButton(onPressed: () {}, child: const Text('Still')),
        reduceMotion: true,
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ElevatedButton)),
    );
    await tester.pump(const Duration(milliseconds: 140));
    await tester.pump(const Duration(milliseconds: 200));
    expect(_scale(tester), 1);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_scale(tester), 1);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets(
    'selected and disabled icon initialization cannot notify in build',
    (tester) async {
      var enabled = true;
      var selected = false;
      late StateSetter update;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return AccessibleIconButton(
                isSelected: selected,
                onPressed: enabled ? () {} : null,
                icon: const Icon(Icons.favorite),
              );
            },
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(IconButton)),
      );
      await tester.pump(const Duration(milliseconds: 160));
      update(() {
        selected = true;
        enabled = false;
      });
      await tester.pump();
      expect(tester.takeException(), isNull);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(_scale(tester), 1);
      expect(tester.takeException(), isNull);
    },
  );
}
