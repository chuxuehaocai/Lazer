import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/desktop_lyrics/desktop_lyrics_controller.dart';
import 'package:lazer_nextgen/desktop_lyrics/overlay_protocol.dart';
import 'package:lazer_nextgen/desktop_lyrics/overlay_window_host.dart';
import 'package:lazer_nextgen/lyrics/lyric_document.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/font_preferences.dart';

class _State extends AppState {
  bool running = false;
  @override
  bool get playing => running;
  void changed() => notifyListeners();
}

class _Window implements LyricsOverlayWindow {
  @override
  final String id = 'fixture-overlay';
  final messages = <(String, Object?)>[];
  int closes = 0;
  bool closeResult = true;
  Completer<void>? blockedState;
  String? failNext;
  @override
  Future<void> send(String method, [Object? arguments]) async {
    messages.add((method, arguments));
    if (failNext == method) {
      failNext = null;
      throw PlatformException(code: 'fixture-transient-failure');
    }
    if (method == 'state') await blockedState?.future;
  }

  @override
  Future<bool> close() async {
    closes++;
    return closeResult;
  }
}

class _Host implements LyricsOverlayWindowHost {
  @override
  bool get supported => true;
  LyricsOverlayReadyHandler? handler;
  Completer<LyricsOverlayWindow>? creation;
  final window = _Window();
  int creates = 0;
  @override
  Future<void> setReadyHandler(LyricsOverlayReadyHandler? value) async =>
      handler = value;
  @override
  Future<LyricsOverlayWindow> create(LyricsOverlayLaunch launch) async {
    creates++;
    return creation?.future ?? window;
  }

  Future<void> ready() async =>
      handler?.call(MethodCall('ready', {'windowId': window.id}));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'disabled and paused lyrics never keep the position poller alive',
    (tester) async {
      final state = _State();
      final host = _Host();
      final controller = DesktopLyricsController(state, windowHost: host);
      await tester.pump();
      expect(controller.debugPositionPolling, isFalse);
      expect(host.creates, 0);
      state.floatingLyricsEnabled = true;
      state.changed();
      await tester.pump();
      await host.ready();
      await tester.pump();
      expect(controller.debugPositionPolling, isFalse);
      state.running = true;
      state.changed();
      await tester.pump();
      expect(controller.debugPositionPolling, isTrue);
      state.running = false;
      state.changed();
      expect(controller.debugPositionPolling, isFalse);
      controller.dispose();
      await tester.pump();
      await controller.closed;
      expect(host.handler, isNull);
      expect(host.window.closes, 1);
      state.dispose();
    },
  );

  for (final disposed in [false, true]) {
    testWidgets(
      '${disposed ? 'dispose' : 'disable'} during creation closes the late overlay',
      (tester) async {
        final state = _State()..floatingLyricsEnabled = true;
        final host = _Host()..creation = Completer<LyricsOverlayWindow>();
        final controller = DesktopLyricsController(state, windowHost: host);
        await tester.pump();
        expect(host.creates, 1);
        if (disposed) {
          controller.dispose();
        } else {
          state.floatingLyricsEnabled = false;
          state.changed();
        }
        host.creation!.complete(host.window);
        await tester.pump();
        await controller.idle;
        expect(host.window.closes, 1);
        expect(host.window.messages, isEmpty);
        controller.dispose();
        await tester.pump();
        await controller.closed;
        expect(host.handler, isNull);
        state.dispose();
      },
    );
  }

  testWidgets(
    'slow IPC coalesces a notification burst into the newest settings',
    (tester) async {
      final state = _State()..floatingLyricsEnabled = true;
      final host = _Host();
      final controller = DesktopLyricsController(state, windowHost: host);
      await tester.pump();
      await host.ready();
      await tester.pump();
      host.window.blockedState = Completer<void>();
      state.lyrics = const [LyricLine(Duration.zero, 'New document')];
      state.changed();
      await tester.pump();
      for (var index = 0; index < 100; index++) {
        state.lyricFontSize = 14 + (index % 20).toDouble();
        state.changed();
        await tester.pump();
      }
      expect(
        host.window.messages.where((item) => item.$1 == 'state'),
        hasLength(2),
      );
      host.window.blockedState!.complete();
      await tester.pump();
      await controller.idle;
      final settings = host.window.messages
          .where((item) => item.$1 == 'settings')
          .toList();
      expect(settings, hasLength(1));
      expect((settings.single.$2 as Map)['fontSize'], state.lyricFontSize);
      controller.dispose();
      await tester.pump();
      await controller.closed;
      state.dispose();
    },
  );

  testWidgets('an unacknowledged close cannot create another native engine', (
    tester,
  ) async {
    final state = _State()..floatingLyricsEnabled = true;
    final host = _Host();
    final controller = DesktopLyricsController(state, windowHost: host);
    await tester.pump();
    host.window.closeResult = false;
    state.floatingLyricsEnabled = false;
    state.changed();
    await tester.pump();
    state.floatingLyricsEnabled = true;
    state.changed();
    await tester.pump();
    expect(host.creates, 1);
    host.window.closeResult = true;
    controller.dispose();
    await tester.pump();
    await controller.closed;
    state.dispose();
  });

  testWidgets(
    'the production host closes through the overlay channel before readiness',
    (tester) async {
      final messenger = tester.binding.defaultBinaryMessenger;
      const windows = MethodChannel('mixin.one/desktop_multi_window');
      const channels = MethodChannel('mixin.one/desktop_multi_window/channels');
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(
        windows,
        (call) async => call.method == 'getAllWindows' ? [] : 'late-window',
      );
      messenger.setMockMethodCallHandler(channels, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(windows, null);
        messenger.setMockMethodCallHandler(channels, null);
      });
      final state = _State();
      final window = await DesktopLyricsWindowHost().create(
        LyricsOverlayLaunch(
          mode: LyricsOverlayMode.floating,
          settings: LyricsOverlaySettings.fromMap(const {}),
        ),
      );
      expect(await window.close(), isTrue);
      expect(calls.single.method, 'invokeMethod');
      expect(
        (calls.single.arguments as Map)['channel'],
        '${kLyricsOverlayChannelPrefix}late-window',
      );
      expect((calls.single.arguments as Map)['method'], 'close');
      state.dispose();
    },
  );

  testWidgets(
    'a transient IPC failure retries without a second ready handshake',
    (tester) async {
      final state = _State()
        ..floatingLyricsEnabled = true
        ..running = true;
      final host = _Host();
      final controller = DesktopLyricsController(state, windowHost: host);
      await tester.pump();
      await host.ready();
      await tester.pump();
      expect(controller.debugPositionPolling, isTrue);
      host.window.failNext = 'position';
      await tester.pump(const Duration(milliseconds: 50));
      expect(controller.debugPositionPolling, isFalse);
      await tester.pump(const Duration(seconds: 1));
      expect(controller.debugPositionPolling, isTrue);
      expect(host.creates, 1);
      controller.dispose();
      await tester.pump();
      await controller.closed;
      state.dispose();
    },
  );

  testWidgets('a close acknowledgement waits for actual engine destruction', (
    tester,
  ) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    const windows = MethodChannel('mixin.one/desktop_multi_window');
    const channels = MethodChannel('mixin.one/desktop_multi_window/channels');
    var gone = false;
    messenger.setMockMethodCallHandler(windows, (call) async {
      if (call.method == 'createWindow') return 'closing-window';
      return gone
          ? []
          : [
              {'windowId': 'closing-window', 'windowArgument': ''},
            ];
    });
    messenger.setMockMethodCallHandler(channels, (_) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(windows, null);
      messenger.setMockMethodCallHandler(channels, null);
    });
    final window = await DesktopLyricsWindowHost().create(
      LyricsOverlayLaunch(
        mode: LyricsOverlayMode.floating,
        settings: LyricsOverlaySettings.fromMap(const {}),
      ),
    );
    var finished = false;
    final closing = window.close().then((value) {
      finished = true;
      return value;
    });
    await tester.pump();
    expect(finished, isFalse);
    gone = true;
    await tester.pump(const Duration(milliseconds: 200));
    expect(await closing, isTrue);
  });

  testWidgets(
    'custom font changes recycle only after a different registration',
    (tester) async {
      final state = _State()..floatingLyricsEnabled = true;
      void font(int i) {
        state.fontPreferences = state.fontPreferences.withFamily(
          FontFamilyPreference(
            source: FontSource.imported,
            family: 'Custom$i',
            path: 'font$i.ttf',
          ),
        );
        state.changed();
      }

      font(1);
      final host = _Host();
      final controller = DesktopLyricsController(state, windowHost: host);
      await tester.pump();
      await host.ready();
      await tester.pump();
      font(1);
      state.lyricFontSize = 30;
      state.changed();
      await tester.pump();
      expect(host.creates, 1);
      font(2);
      await tester.pump();
      expect(host.window.closes, 1);
      expect(host.creates, 2);
      await host.ready();
      await tester.pump();
      font(2);
      await tester.pump();
      expect(host.creates, 2);
      controller.dispose();
      await tester.pump();
      await controller.closed;
      state.dispose();
    },
  );

  testWidgets(
    'a custom font changed before ready replaces the launched engine',
    (tester) async {
      final state = _State()..floatingLyricsEnabled = true;
      state.fontPreferences = state.fontPreferences.withFamily(
        const FontFamilyPreference(
          source: FontSource.imported,
          family: 'BeforeReadyA',
          path: 'a.ttf',
        ),
      );
      final host = _Host();
      final controller = DesktopLyricsController(state, windowHost: host);
      await tester.pump();
      expect(host.creates, 1);
      expect(host.window.messages, isEmpty);
      state.fontPreferences = state.fontPreferences.withFamily(
        const FontFamilyPreference(
          source: FontSource.imported,
          family: 'BeforeReadyB',
          path: 'b.ttf',
        ),
      );
      state.changed();
      await tester.pump();
      expect(host.window.closes, 1);
      expect(host.creates, 2);
      await host.ready();
      await tester.pump();
      final payload =
          host.window.messages.firstWhere((item) => item.$1 == 'state').$2
              as Map;
      expect((payload['settings'] as Map)['fontFamily'], 'BeforeReadyB');
      controller.dispose();
      await tester.pump();
      await controller.closed;
      state.dispose();
    },
  );
}
