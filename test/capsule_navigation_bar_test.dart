import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/widgets/capsule_navigation_bar.dart';

void main() {
  testWidgets('tab motion keeps text cached and retargets without a jump', (
    tester,
  ) async {
    final selected = ValueNotifier(0);
    addTearDown(selected.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 288,
              child: ValueListenableBuilder<int>(
                valueListenable: selected,
                builder: (context, value, _) => CapsuleNavigationBar(
                  selectedIndex: value,
                  onDestinationSelected: (index) => selected.value = index,
                  destinations: const [
                    NavigationDestination(icon: Icon(Icons.home), label: '主页'),
                    NavigationDestination(
                      icon: Icon(Icons.search),
                      label: '搜索',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.library_music),
                      label: '音乐库',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.favorite),
                      label: '我喜欢',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.settings),
                      label: '设置',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final indicator = find.byKey(
      const ValueKey('capsule-navigation-indicator'),
    );
    final initial = tester.getRect(indicator);
    await tester.tap(find.byTooltip('设置'));
    await tester.pump();
    var textBuilds = 0;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      if (element.widget is Text || element.widget is CapsuleNavigationBar) {
        textBuilds++;
      }
    };
    try {
      var previous = initial.left;
      for (var frame = 0; frame < 4; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        final left = tester.getRect(indicator).left;
        expect(left, greaterThan(previous));
        previous = left;
      }
      expect(
        textBuilds,
        0,
        reason: 'animation frames must reuse the navigation contents',
      );
      final interrupted = tester.getRect(indicator);
      selected.value = 1;
      await tester.pump();
      expect(tester.getRect(indicator).left, closeTo(interrupted.left, .01));
      await tester.pumpAndSettle();
      expect(selected.value, 1);
      expect(tester.getRect(indicator).left, greaterThan(initial.left));
      expect(tester.getRect(indicator).left, lessThan(interrupted.left));
      expect(tester.takeException(), isNull);
    } finally {
      debugOnRebuildDirtyWidget = null;
    }
  });
}
