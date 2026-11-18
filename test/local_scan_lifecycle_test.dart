import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/local/local_library.dart';
import 'package:lazer_nextgen/local/local_music_scan.dart';
import 'package:lazer_nextgen/local/local_music_scanner.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';

class _Library extends LocalLibrary {
  @override
  Future<void> addTracks(Iterable<LocalTrack> entries) async {}
  @override
  Future<void> refreshMissing() async {}
}

class _Scanner extends LocalMusicScanner {
  final completion = Completer<LocalScanResult>();
  bool Function()? cancelled;
  @override
  Future<LocalScanResult> scan(
    Directory root, {
    Iterable<LocalTrack> existing = const [],
    bool Function()? isCanceled,
    void Function(int, String)? onProgress,
  }) {
    cancelled = isCanceled;
    return completion.future;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final dismissEarly in [false, true]) {
    testWidgets(
      'scan ${dismissEarly ? "cancel" : "completion"} owns its route and progress lifetime',
      (tester) async {
        final state = AppState(localLibrary: _Library());
        addTearDown(state.dispose);
        final scanner = _Scanner();
        final navigator = GlobalKey<NavigatorState>();
        Future<LocalScanResult?>? scan;
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            theme: buildAppleTheme(),
            home: const Scaffold(body: Text('Root')),
          ),
        );
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () {
                  scan = scanMusicFolder(
                    context,
                    state,
                    Directory('fixture'),
                    rememberRoot: false,
                    scanner: scanner,
                  );
                },
                child: const Text('Scan page'),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Scan page'));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        final progress = tester
            .widget<ValueListenableBuilder<int>>(
              find.byType(ValueListenableBuilder<int>),
            )
            .valueListenable;
        if (dismissEarly) {
          navigator.currentState!.pop();
          await tester.pump();
          expect(scanner.cancelled!(), isTrue);
          void listener() {}
          expect(() => progress.addListener(listener), returnsNormally);
          progress.removeListener(listener);
          await tester.pumpAndSettle();
        }
        scanner.completion.complete(const LocalScanResult(tracks: []));
        await tester.pump();
        await scan;
        await tester.pumpAndSettle();
        expect(find.text('Scan page'), findsOneWidget);
        expect(navigator.currentState!.canPop(), isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
