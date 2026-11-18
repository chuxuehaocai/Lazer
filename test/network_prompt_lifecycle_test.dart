import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/network/network_widgets.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';

void main() {
  for (final save in [false, true]) {
    testWidgets(
      'network prompt controller survives ${save ? "save" : "cancel"} exit',
      (tester) async {
        String? result;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppleTheme(),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await showNetworkTextPrompt(
                      context,
                      title: 'Feed',
                      label: 'Address',
                      description: 'Subscribe to a feed.',
                      initialValue: '  https://example.test/feed.xml  ',
                      confirmLabel: 'Subscribe',
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        final controller = tester
            .widget<TextField>(find.byType(TextField))
            .controller!;
        await tester.tap(find.text(save ? 'Subscribe' : '取消'));
        await tester.pump();
        expect(find.byType(TextField), findsOneWidget);
        void listener() {}
        expect(() => controller.addListener(listener), returnsNormally);
        controller.removeListener(listener);
        await tester.pumpAndSettle();
        expect(() => controller.addListener(listener), throwsFlutterError);
        expect(result, save ? 'https://example.test/feed.xml' : isNull);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
