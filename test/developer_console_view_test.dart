import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/diagnostics/console_session.dart';
import 'package:lazer_nextgen/diagnostics/developer_console.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/developer_console_page.dart';
import 'package:lazer_nextgen/widgets/settings_detail.dart';

class _Session extends ConsoleSession {
  @override
  bool enabled = true;
  @override
  bool busy = false;
  @override
  List<ConsoleEntry> entries = [
    const ConsoleEntry('/status', input: true),
    const ConsoleEntry('playing: true\ntrack: 音乐与生活\nposition: 42.5 s'),
  ];
  @override
  List<String> history = ['/status'];
  @override
  String logs = '[player] ready\n[debugPrint] console log marker';
  @override
  Future<void> execute(String input) async {
    history.add(input);
    entries.add(ConsoleEntry(input, input: true));
    notifyListeners();
  }

  @override
  Future<void> clearLogs() async {
    logs = '';
    notifyListeners();
  }

  @override
  Future<String> report() async => logs;
}

void main() {
  for (final embedded in [false, true]) {
    testWidgets(
      'console ${embedded ? "view" : "page"} shows and filters live logs',
      (tester) async {
        tester.view.physicalSize = embedded
            ? const Size(1100, 760)
            : const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await (FontLoader(
          'MiSans',
        )..addFont(rootBundle.load('assets/fonts/MiSans-Regular.ttf'))).load();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
        await (FontLoader(
          'monospace',
        )..addFont(rootBundle.load('assets/fonts/MiSans-Regular.ttf'))).load();
        final session = _Session();
        final boundary = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppleTheme(),
            home: RepaintBoundary(
              key: boundary,
              child: embedded
                  ? Scaffold(
                      body: SettingsDetailHost(
                        compact: false,
                        child: Builder(
                          builder: (context) => TextButton(
                            onPressed: () => SettingsDetailHost.open(
                              context,
                              page: (_) =>
                                  throw StateError('expected embedded view'),
                              view: (_) =>
                                  DeveloperConsoleView.remote(session: session),
                            ),
                            child: const Text('Open'),
                          ),
                        ),
                      ),
                    )
                  : DeveloperConsoleView.remote(session: session),
            ),
          ),
        );
        if (embedded) await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(find.byType(Scaffold), findsOneWidget);
        await tester.enterText(
          find.byKey(const ValueKey('developer-console-input')),
          '1 + 2',
        );
        await tester.tap(find.byKey(const ValueKey('developer-console-run')));
        await tester.pumpAndSettle();
        expect(session.history.last, '1 + 2');
        await tester.tap(find.text('实时日志'));
        await tester.pumpAndSettle();
        expect(find.text('[debugPrint] console log marker'), findsOneWidget);
        if (const bool.fromEnvironment('SAVE_UI_PROBES')) {
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              '.dart_tool/console-${embedded ? "desktop" : "mobile"}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.enterText(find.byType(TextField), 'marker');
        await tester.pumpAndSettle();
        expect(find.text('[player] ready'), findsNothing);
        expect(find.text('[debugPrint] console log marker'), findsOneWidget);
        session.enabled = false;
        session.notifyListeners();
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        session.dispose();
      },
    );
  }
}
