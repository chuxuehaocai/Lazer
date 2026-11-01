import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/widgets/retained_content_switcher.dart';

void main() {
  testWidgets(
    'hidden ancestors keep their state without rebuilding on reports',
    (tester) async {
      final counts = <String, int>{};
      var current = 'root';
      var retain = <String>{};
      late StateSetter update;
      Widget page(String key) => Builder(
        builder: (context) {
          counts.update(key, (value) => value + 1, ifAbsent: () => 1);
          return Center(child: Text(key));
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return RetainedContentSwitcher(
                  currentKey: current,
                  page: page(current),
                  retainKeys: retain,
                );
              },
            ),
          ),
        ),
      );
      final rootElement = tester.element(find.text('root'));
      update(() {
        current = 'detail';
        retain = {'root'};
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 440));
      await tester.pump();
      final rootBuilds = counts['root'];
      expect(find.text('root'), findsNothing);
      final hiddenRoot = find.text('root', skipOffstage: false);
      expect(hiddenRoot, findsOneWidget);
      expect(tester.element(hiddenRoot), same(rootElement));
      final ticker = tester.widget<TickerMode>(
        find
            .ancestor(
              of: hiddenRoot,
              matching: find.byType(TickerMode, skipOffstage: false),
            )
            .first,
      );
      expect(ticker.enabled, isFalse);
      final focus = tester.widget<ExcludeFocus>(
        find
            .ancestor(
              of: hiddenRoot,
              matching: find.byType(ExcludeFocus, skipOffstage: false),
            )
            .first,
      );
      expect(focus.excluding, isTrue);
      for (var report = 0; report < 6; report++) {
        update(() {});
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(counts['root'], rootBuilds);
      update(() {
        current = 'root';
        retain = {};
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 440));
      await tester.pump();
      expect(tester.element(find.text('root')), same(rootElement));
      expect(find.text('detail', skipOffstage: false), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('clearing navigation ancestors disposes their hidden pages', (
    tester,
  ) async {
    Widget app(String current, Set<String> retain) => MaterialApp(
      home: RetainedContentSwitcher(
        currentKey: current,
        page: Text(current),
        retainKeys: retain,
      ),
    );
    await tester.pumpWidget(app('root', {}));
    await tester.pumpWidget(app('detail', {'root'}));
    await tester.pump(const Duration(milliseconds: 440));
    await tester.pump();
    expect(find.text('root', skipOffstage: false), findsOneWidget);
    await tester.pumpWidget(app('detail', {}));
    await tester.pump();
    expect(find.text('root', skipOffstage: false), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('return restores focus to the card that opened the detail', (
    tester,
  ) async {
    final rootFocus = FocusNode();
    final detailFocus = FocusNode();
    addTearDown(rootFocus.dispose);
    addTearDown(detailFocus.dispose);
    Widget app(String key, Set<String> retain) => MaterialApp(
      home: RetainedContentSwitcher(
        currentKey: key,
        retainKeys: retain,
        page: Focus(
          focusNode: key == 'root' ? rootFocus : detailFocus,
          child: Text(key),
        ),
      ),
    );
    await tester.pumpWidget(app('root', {}));
    rootFocus.requestFocus();
    await tester.pump();
    expect(rootFocus.hasFocus, isTrue);
    await tester.pumpWidget(app('detail', {'root'}));
    await tester.pump(const Duration(milliseconds: 440));
    await tester.pump();
    detailFocus.requestFocus();
    await tester.pump();
    expect(rootFocus.hasFocus, isFalse);
    await tester.pumpWidget(app('root', {}));
    await tester.pump(const Duration(milliseconds: 440));
    await tester.pump();
    await tester.pump();
    expect(rootFocus.hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });
}
