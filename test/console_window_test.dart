import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/diagnostics/app_log.dart';
import 'package:lazer_nextgen/diagnostics/console_window.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const transport = MethodChannel('mixin.one/desktop_multi_window/channels');
  const windows = MethodChannel('mixin.one/desktop_multi_window');
  const codec = StandardMethodCodec();

  test('window arguments do not accidentally boot another audio engine', () {
    expect(
      isConsoleWindow(['multi_window', '1', '{"kind":"developer_console"}']),
      isTrue,
    );
    expect(
      isConsoleWindow(['multi_window', '1', '{"kind":"lyrics_overlay"}']),
      isFalse,
    );
    expect(isConsoleWindow(['multi_window', '1', 'invalid']), isFalse);
    expect(isConsoleWindow([]), isFalse);
  });

  testWidgets('remote console shares owner state, logs and disable gate', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    var created = 0;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(windows, (
      call,
    ) async {
      if (call.method == 'createWindow') return 'console-${++created}';
      return null;
    });
    // Exercise the real cross-engine codec and both ends of the protocol.
    binding.defaultBinaryMessenger.setMockMethodCallHandler(transport, (
      call,
    ) async {
      if (call.method != 'invokeMethod') return null;
      final reply = Completer<ByteData?>();
      await binding.defaultBinaryMessenger.handlePlatformMessage(
        transport.name,
        codec.encodeMethodCall(MethodCall('methodCall', call.arguments)),
        reply.complete,
      );
      return codec.decodeEnvelope((await reply.future)!);
    });
    final state = AppState();
    await state.setDeveloperConsoleEnabled(true);
    final host = ConsoleWindowController(state);
    final remote = RemoteConsoleSession();
    await Future.wait([host.open(), host.open()]);
    expect(created, 1);
    var shows = 0;
    const window = WindowMethodChannel(
      'lazer/console/window/console-1',
      mode: ChannelMode.unidirectional,
    );
    await window.setMethodCallHandler((call) async {
      if (call.method == 'show') shows++;
      return null;
    });
    await host.open();
    expect(created, 1);
    expect(shows, 1);
    await remote.refresh();
    expect(remote.enabled, isTrue);
    await remote.execute('/volume 37');
    expect(state.volume, .37);
    expect(remote.history.last, '/volume 37');
    expect(remote.entries.last.text, '指令已执行。');
    AppLog.shared.record('console-window-test-marker');
    await tester.pump(const Duration(milliseconds: 120));
    await remote.refresh();
    expect(remote.logs, contains('console-window-test-marker'));
    expect(await remote.report(), contains('console-window-test-marker'));
    await state.setDeveloperConsoleEnabled(false);
    // Even before the window receives the setting change, the host rejects it.
    await remote.execute('/volume 99');
    expect(state.volume, .37);
    await tester.pump(const Duration(milliseconds: 120));
    await remote.refresh();
    expect(remote.enabled, isFalse);
    expect(remote.entries, isEmpty);
    remote.dispose();
    host.dispose();
    await tester.pump();
    await window.setMethodCallHandler(null);
    state.dispose();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(transport, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(windows, null);
  });
}
