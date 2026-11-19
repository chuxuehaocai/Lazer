import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/widgets/window_chrome.dart';

class _Host extends StatefulWidget {
  const _Host({required this.commandWidth, required this.declared});
  final double commandWidth;
  final double declared;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with TickerProviderStateMixin {
  late final WindowChromeController _chrome = WindowChromeController(
    vsync: this,
  );

  @override
  void dispose() {
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
}
