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
  late bool Function() isCanceled;
  late void Function(int, String) progress;

  @override
  Future<LocalScanResult> scan(
    Directory root, {
    Iterable<LocalTrack> existing = const [],
    bool Function()? isCanceled,
    void Function(int, String)? onProgress,
  }) {
    this.isCanceled = isCanceled!;
    progress = onProgress!;
    return completion.future;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('navigator teardown cancels scan progress before late results', (
    tester,
  ) async {
    final state = AppState(localLibrary: _Library());
    addTearDown(state.dispose);
    final scanner = _Scanner();
    Future<LocalScanResult?>? scan;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => scan = scanMusicFolder(
                context,
                state,
                Directory('fixture'),
                rememberRoot: false,
                scanner: scanner,
              ),
              child: const Text('Scan'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Scan'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox.shrink());
    scanner.progress(1, 'late.mp3');
    await tester.pump(const Duration(milliseconds: 110));
    final cancelled = scanner.isCanceled();
    final lateError = tester.takeException();
    scanner.completion.complete(const LocalScanResult(tracks: []));
    await tester.pump();
    await scan;
    expect(lateError, isNull);
    expect(cancelled, isTrue);
  });
}
