import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/diagnostics/console_session.dart';
import 'package:lazer_nextgen/diagnostics/developer_console.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/developer_console_page.dart';

const _transcriptKey = ValueKey('developer-console-transcript');

class _Session extends ConsoleSession {
  _Session(this.entries, {this.logs = ''});

  @override
  final List<ConsoleEntry> entries;
  @override
  final String logs;
  @override
  bool get enabled => true;
  @override
  bool get busy => false;
  @override
  List<String> get history => const <String>[];
  @override
  Future<void> execute(String input) async {}
  @override
  Future<void> clearLogs() async {}
  @override
  Future<String> report() async => logs;
}

Widget _host(Widget child) => MaterialApp(
  theme: buildAppleTheme().copyWith(platform: TargetPlatform.windows),
  home: Scaffold(body: child),
);

Finder _inTranscript(Finder matching) =>
    find.descendant(of: find.byKey(_transcriptKey), matching: matching);

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

void main() {
  late List<MethodCall> platformCalls;

  setUp(() {
    platformCalls = <MethodCall>[];
  });

  void captureClipboard(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        platformCalls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
  }

  String? copiedText() {
    for (final call in platformCalls.reversed) {
      if (call.method == 'Clipboard.setData') {
        return (call.arguments as Map<Object?, Object?>)['text'] as String?;
      }
    }
    return null;
  }

  testWidgets('console transcript paints every line into one text block', (
    tester,
  ) async {
    final session = _Session(
      const <ConsoleEntry>[
        ConsoleEntry('1 + 2', input: true),
        ConsoleEntry('3'),
        ConsoleEntry('bad argument', error: true),
      ],
    );
    addTearDown(session.dispose);

    await tester.pumpWidget(_host(DeveloperConsoleView.remote(session: session)));
    await tester.pump();

    // One text widget carries the whole transcript; nothing is one box per line.
    expect(find.byKey(_transcriptKey), findsOneWidget);
    expect(_inTranscript(find.byType(SelectableText)), findsNothing);
    final text = tester.widget<Text>(_inTranscript(find.byType(Text)));
    expect(text.textSpan!.toPlainText(), '> 1 + 2\n3\nbad argument');
  });

  testWidgets('selection and copy span several lines of the transcript', (
    tester,
  ) async {
    captureClipboard(tester);
    final session = _Session(
      const <ConsoleEntry>[ConsoleEntry('north line'), ConsoleEntry('south line')],
    );
    addTearDown(session.dispose);

    await tester.pumpWidget(_host(DeveloperConsoleView.remote(session: session)));
    await tester.pump();

    // Ctrl+A takes the whole block, not just the line under the cursor.
    await tester.tap(find.byKey(_transcriptKey));
    await tester.pump();
    await _press(tester, LogicalKeyboardKey.keyA);
    await _press(tester, LogicalKeyboardKey.keyC);
    expect(copiedText(), 'north line\nsouth line');

    // A single mouse drag selects across the line break.
    await tester.pump(const Duration(milliseconds: 400));
    final rect = tester.getRect(_inTranscript(find.byType(Text)));
    final drag = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await drag.down(Offset(rect.left + 2, rect.top + rect.height * 0.25));
    await tester.pump();
    await drag.moveTo(Offset(rect.left + 70, rect.top + rect.height * 0.75));
    await tester.pump();
    await drag.up();
    await tester.pump();
    await _press(tester, LogicalKeyboardKey.keyC);
    final dragged = copiedText();
    expect(dragged, isNotNull);
    expect(dragged, contains('north'));
    expect(dragged, contains('\n'));
    expect(dragged, contains('south'));
  });

  testWidgets('live log tab also renders as a single selectable block', (
    tester,
  ) async {
    final session = _Session(
      const <ConsoleEntry>[],
      logs: '[a] one\n[b] two\n[c] three',
    );
    addTearDown(session.dispose);

    await tester.pumpWidget(_host(DeveloperConsoleView.remote(session: session)));
    await tester.pump();
    await tester.tap(find.text('实时日志'));
    await tester.pump();

    final text = tester.widget<Text>(_inTranscript(find.byType(Text)));
    expect(text.textSpan!.toPlainText(), '[a] one\n[b] two\n[c] three');
  });
}
