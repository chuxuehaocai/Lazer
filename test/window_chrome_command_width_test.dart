import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/widgets/window_chrome.dart';

class _Host extends StatefulWidget {
  const _Host({required this.commandWidth, required this.declared, this.ticks});
  final double commandWidth;
  final double declared;

  /// When set, the host rebuilds on every tick the way a settings page does
  /// while the app state publishes playback or plugin updates.
  final ValueNotifier<int>? ticks;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with TickerProviderStateMixin {
  late final WindowChromeController _chrome = WindowChromeController(
    vsync: this,
  );

  @override
  void initState() {
    super.initState();
    widget.ticks?.addListener(_rebuild);
  }

  void _rebuild() => setState(() {});

  @override
  void dispose() {
    widget.ticks?.removeListener(_rebuild);
    _chrome.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => WindowChromeScope(
    controller: _chrome,
    inline: true,
    reveal: const AlwaysStoppedAnimation<double>(0),
    chromeTheme: Theme.of(context),
    child: WindowChromeActions(
      playerDriven: false,
      // A fresh instance on every build, exactly like `SettingsDetailScaffold`
      // handing its actions row to the capsule.
      leading: SizedBox(
        key: const ValueKey('command'),
        width: widget.commandWidth,
        height: 20,
      ),
      leadingWidth: widget.declared,
      children: const <Widget>[],
    ),
  );
}

double _rowWidth(WidgetTester tester) => tester
    .getSize(find.byKey(const ValueKey('desktop-player-actions')))
    .width;

void main() {
  testWidgets('the capsule extends by what a page command measures', (
    tester,
  ) async {
    // Two short text commands used to reserve a fixed 116 dp each, so the pill
    // towered over the two buttons it painted.
    await tester.pumpWidget(
      MaterialApp(
        home: _Host(
          commandWidth: 60,
          declared: kWindowChromeTextActionWidth * 2,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      _rowWidth(tester),
      closeTo(60 + kWindowChromeActionDivider, 1.5),
      reason: 'the row is as wide as the command it paints',
    );
  });

  testWidgets('a command never grows past the width its page declared', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: _Host(commandWidth: 400, declared: kWindowChromeTextActionWidth),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      _rowWidth(tester),
      closeTo(kWindowChromeTextActionWidth + kWindowChromeActionDivider, 1.5),
      reason: 'the declared width stays the cap',
    );
  });

  // The plugin pages rebuild whenever the app state publishes (plugin loads,
  // playback position) and hand the capsule a fresh command row each time. A
  // measurement that reset on every build put itself back with a setState, and
  // that setState scheduled the next build: the window stopped answering.
  testWidgets('a page that keeps rebuilding settles instead of spinning', (
    tester,
  ) async {
    final ticks = ValueNotifier<int>(0);
    addTearDown(ticks.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: _Host(
          commandWidth: 90,
          declared: kWindowChromeTextActionWidth,
          ticks: ticks,
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (var i = 0; i < 5; i++) {
      ticks.value++;
      await tester.pumpAndSettle();
    }

    expect(
      _rowWidth(tester),
      closeTo(90 + kWindowChromeActionDivider, 1.5),
      reason: 'the width settles on the command and does not oscillate',
    );
  });
}
