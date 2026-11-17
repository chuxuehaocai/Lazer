import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/tv/tv_mode.dart';
import 'package:lazer_nextgen/widgets/settings_choice.dart';

const _choices = <DropdownMenuItem<String>>[
  DropdownMenuItem(value: 'auto', child: Text('Automatic')),
  DropdownMenuItem(value: 'mobile', child: Text('Mobile')),
  DropdownMenuItem(value: 'desktop', child: Text('Desktop')),
  DropdownMenuItem(value: 'tv', child: Text('Television')),
];

Widget _host({
  String? value = 'desktop',
  List<DropdownMenuItem<String>> items = _choices,
  ValueChanged<String?>? onChanged,
  bool tv = false,
  Alignment alignment = Alignment.center,
  double width = 280,
}) => MaterialApp(
  theme: buildAppleTheme(),
  home: TvScope(
    active: tv,
    child: Scaffold(
      body: Align(
        alignment: alignment,
        child: SizedBox(
          width: width,
          child: SettingsChoice<String>(
            value: value,
            items: items,
            onChanged: onChanged,
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('TV Select opens the selected item and skips disabled choices', (
    tester,
  ) async {
    final changes = <String?>[];
    await tester.pumpWidget(
      _host(
        tv: true,
        onChanged: changes.add,
        items: const [
          DropdownMenuItem(value: 'desktop', child: Text('Desktop')),
          DropdownMenuItem(
            value: 'unavailable',
            enabled: false,
            child: Text('Unavailable'),
          ),
          DropdownMenuItem(value: 'tv', child: Text('Television')),
        ],
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(changes, ['tv']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opening starts arrow navigation at the current value', (
    tester,
  ) async {
    final changes = <String?>[];
    await tester.pumpWidget(_host(onChanged: changes.add));
    await tester.tap(find.byType(SettingsChoice<String>));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(changes, ['tv']);
  });

  testWidgets('Escape cancels and returns keyboard focus to the selector', (
    tester,
  ) async {
    final changes = <String?>[];
    await tester.pumpWidget(_host(onChanged: changes.add));
    await tester.tap(find.byType(SettingsChoice<String>));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Automatic'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(changes, ['desktop']);
  });

  testWidgets('replacing the selector removes its open menu', (tester) async {
    final changes = <String?>[];
    late StateSetter rebuild;
    var showChoice = true;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return showChoice
                  ? SizedBox(
                      width: 280,
                      child: SettingsChoice<String>(
                        value: 'desktop',
                        items: _choices,
                        onChanged: changes.add,
                      ),
                    )
                  : const Text('New layout');
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byType(SettingsChoice<String>));
    await tester.pumpAndSettle();
    rebuild(() => showChoice = false);
    await tester.pumpAndSettle();
    expect(find.text('Automatic'), findsNothing);
    expect(changes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('null is selectable while dismissal never submits a value', (
    tester,
  ) async {
    final changes = <String?>[];
    await tester.pumpWidget(
      _host(
        onChanged: changes.add,
        items: const [
          DropdownMenuItem<String>(child: Text('System default')),
          DropdownMenuItem(value: 'desktop', child: Text('Desktop')),
        ],
      ),
    );
    await tester.tap(find.byType(SettingsChoice<String>));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
    await tester.tap(find.byType(SettingsChoice<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('System default'));
    await tester.pumpAndSettle();
    expect(changes, [null]);
  });

  testWidgets('long lists reveal the current value in a small edge window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(340, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final changes = <String?>[];
    await tester.pumpWidget(
      _host(
        value: '35',
        width: 500,
        alignment: Alignment.bottomRight,
        onChanged: changes.add,
        items: [
          for (var index = 0; index < 40; index++)
            DropdownMenuItem(value: '$index', child: Text('Device $index')),
        ],
      ),
    );
    await tester.tap(find.text('Device 35'));
    await tester.pumpAndSettle();
    expect(find.text('Device 35').hitTestable(), findsAtLeastNWidgets(1));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(find.text('Device 36').hitTestable(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(changes, ['36']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('menu stays compact and opens below when there is room', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(width: 650, alignment: Alignment.topCenter, onChanged: (_) {}),
    );
    final anchor = tester.getRect(find.text('Desktop'));
    await tester.tap(find.text('Desktop'));
    await tester.pumpAndSettle();
    final option = tester.getRect(find.byType(MenuItemButton).first);
    expect(option.width, lessThanOrEqualTo(320));
    expect(option.top, greaterThan(anchor.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('choosing a layout may immediately replace the entire selector', (
    tester,
  ) async {
    var changed = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => changed
                ? const Text('Television layout')
                : SizedBox(
                    width: 280,
                    child: SettingsChoice<String>(
                      value: 'desktop',
                      items: _choices,
                      onChanged: (_) => setState(() => changed = true),
                    ),
                  ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(SettingsChoice<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Television'));
    await tester.pumpAndSettle();
    expect(find.text('Television layout'), findsOneWidget);
    expect(find.text('Automatic'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabled controls cannot open a menu', (tester) async {
    await tester.pumpWidget(_host());
    await tester.tap(find.byType(SettingsChoice<String>));
    await tester.pumpAndSettle();
    expect(find.text('Automatic'), findsNothing);
  });
}
