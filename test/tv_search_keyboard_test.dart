import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/tv/tv_mode.dart';
import 'package:lazer_nextgen/widgets/apple_ui.dart';

void main() {
  testWidgets('TV confirm opens and reopens the IME; Down leaves search', (
    tester,
  ) async {
    final controller = TextEditingController();
    final resultFocus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(resultFocus.dispose);
    String? submitted;
    await tester.pumpWidget(
      MaterialApp(
        home: TvScope(
          active: true,
          child: MediaQuery(
            data: const MediaQueryData(
              navigationMode: NavigationMode.directional,
            ),
            child: Scaffold(
              body: TvTraversalScope(
                child: Column(
                  children: [
                    AppleSearchField(
                      controller: controller,
                      onChanged: (_) {},
                      onSubmitted: (value) => submitted = value,
                    ),
                    TextButton(
                      focusNode: resultFocus,
                      onPressed: () {},
                      child: const Text('Result'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final field = tester.widget<EditableText>(find.byType(EditableText));
    field.focusNode.requestFocus();
    await tester.pump();
    tester.testTextInput.hide();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);
    tester.testTextInput.hide();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.enterText(find.byType(TextField), '夜航');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(submitted, '夜航');
    field.focusNode.requestFocus();
    await tester.pump();
    tester.testTextInput.hide();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(resultFocus.hasPrimaryFocus, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
