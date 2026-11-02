import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/widgets/retained_content_switcher.dart';

void main() {
  testWidgets('parked history does no frame work during another page switch', (
    tester,
  ) async {
    final counts = <String, int>{};
    var current = 'page-0';
    var retained = <String>{};
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            final pageKey = current;
            return RetainedContentSwitcher(
              currentKey: current,
              retainKeys: retained,
              page: Builder(
                builder: (context) {
                  counts.update(pageKey, (n) => n + 1, ifAbsent: () => 1);
                  return Text(pageKey);
                },
              ),
            );
          },
        ),
      ),
    );
    for (var page = 1; page < 8; page++) {
      update(() {
        retained = {...retained, current};
        current = 'page-$page';
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 440));
      await tester.pump();
    }
    update(() {
      retained = {...retained, current};
      current = 'page-8';
    });
    await tester.pump();
    final parkedSlides = <Element>{
      for (var page = 0; page < 7; page++)
        tester.element(
          find
              .ancestor(
                of: find.text('page-$page', skipOffstage: false),
                matching: find.byType(SlideTransition, skipOffstage: false),
              )
              .first,
        ),
    };
    var parkedFrameBuilds = 0;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      if (parkedSlides.contains(element)) parkedFrameBuilds++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    final outgoing = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.text('page-7'),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    final incoming = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.text('page-8'),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(incoming.opacity.value, greaterThan(.5));
    expect(incoming.opacity.value, lessThan(1));
    expect(outgoing.opacity.value, greaterThan(0));
    expect(outgoing.opacity.value, lessThan(.5));
    expect(
      parkedFrameBuilds,
      0,
      reason:
          'Seven invisible ancestors must not rebuild on every motion tick.',
    );
    expect(counts.keys, hasLength(9));
    await tester.pump(const Duration(milliseconds: 440));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

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
      final hiddenSlide = tester.element(
        find
            .ancestor(
              of: hiddenRoot,
              matching: find.byType(SlideTransition, skipOffstage: false),
            )
            .first,
      );
      var hiddenFrameBuilds = 0;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        if (element == hiddenSlide) hiddenFrameBuilds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = null);
      for (var report = 0; report < 6; report++) {
        update(() {});
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(counts['root'], rootBuilds);
      expect(
        hiddenFrameBuilds,
        0,
        reason: 'Reports must not rebuild the wrappers of an invisible page.',
      );
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

  testWidgets('parked pages still follow inherited theme and window changes', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.reset);
    Widget app(String current, Brightness brightness) => MaterialApp(
      theme: ThemeData(brightness: brightness),
      themeAnimationDuration: Duration.zero,
      home: RetainedContentSwitcher(
        currentKey: current,
        retainKeys: current == 'detail' ? const {'root'} : const {},
        page: Builder(
          builder: (context) => Text(
            '$current/${Theme.of(context).brightness.name}/'
            '${MediaQuery.sizeOf(context).width}',
          ),
        ),
      ),
    );
    await tester.pumpWidget(app('root', Brightness.dark));
    final rootElement = tester.element(find.text('root/dark/800.0'));
    await tester.pumpWidget(app('detail', Brightness.dark));
    await tester.pump(const Duration(milliseconds: 440));
    await tester.pump();
    // Exercise the cached hidden view before changing its inherited inputs.
    await tester.pumpWidget(app('detail', Brightness.dark));
    tester.view.physicalSize = const Size(1000, 700);
    await tester.pumpWidget(app('detail', Brightness.light));
    expect(
      tester.element(find.text('root/light/1000.0', skipOffstage: false)),
      same(rootElement),
    );
    await tester.pumpWidget(app('root', Brightness.light));
    await tester.pump(const Duration(milliseconds: 440));
    await tester.pump();
    expect(tester.element(find.text('root/light/1000.0')), same(rootElement));
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
