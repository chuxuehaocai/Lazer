import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/updates/open_external.dart';

class _DetachedProcess implements Process {
  @override
  Future<int> get exitCode =>
      throw StateError('detached process has no exit code');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('a detached desktop launcher reports success', () async {
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) return;

    final original = startExternalProcess;
    addTearDown(() => startExternalProcess = original);
    String? executable;
    List<String>? arguments;
    ProcessStartMode? startMode;
    startExternalProcess =
        (
          String command,
          List<String> args, {
          ProcessStartMode mode = ProcessStartMode.normal,
        }) async {
          executable = command;
          arguments = args;
          startMode = mode;
          return _DetachedProcess();
        };

    const String url = 'https://osu.ppy.sh/beatmapsets?q=test';
    expect(await openExternalUrl(url), isTrue);
    expect(
      executable,
      Platform.isWindows
          ? 'rundll32'
          : Platform.isMacOS
          ? 'open'
          : 'xdg-open',
    );
    expect(arguments!.last, url);
    expect(startMode, ProcessStartMode.detached);
  });

  test('a desktop launcher failure reports failure', () async {
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) return;

    final original = startExternalProcess;
    addTearDown(() => startExternalProcess = original);
    startExternalProcess =
        (
          String command,
          List<String> args, {
          ProcessStartMode mode = ProcessStartMode.normal,
        }) async {
          throw const ProcessException('open', <String>[], 'unavailable');
        };

    expect(await openExternalUrl('https://osu.ppy.sh/beatmapsets'), isFalse);
  });
}
