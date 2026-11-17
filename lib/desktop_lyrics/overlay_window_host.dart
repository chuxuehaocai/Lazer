import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'overlay_protocol.dart';

typedef LyricsOverlayReadyHandler = Future<dynamic> Function(MethodCall call);

/// The main-engine window boundary, replaceable by a deterministic host in tests.
abstract class LyricsOverlayWindowHost {
  bool get supported;
  Future<void> setReadyHandler(LyricsOverlayReadyHandler? handler);
  Future<LyricsOverlayWindow> create(LyricsOverlayLaunch launch);
}

abstract class LyricsOverlayWindow {
  String get id;
  Future<void> send(String method, [Object? arguments]);

  /// False retains ownership of an unresponsive window: another must not be
  /// created while the previous engine may still be alive.
  Future<bool> close();
}

class DesktopLyricsWindowHost implements LyricsOverlayWindowHost {
  @override
  bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS);

  @override
  Future<void> setReadyHandler(LyricsOverlayReadyHandler? handler) =>
      const WindowMethodChannel(
        kLyricsOverlayReadyChannel,
        mode: ChannelMode.unidirectional,
      ).setMethodCallHandler(handler);

  @override
  Future<LyricsOverlayWindow> create(LyricsOverlayLaunch launch) async {
    final controller = await WindowController.create(
      WindowConfiguration(arguments: launch.encode(), hiddenAtLaunch: true),
    );
    return _DesktopLyricsWindow(controller);
  }
}

class _DesktopLyricsWindow implements LyricsOverlayWindow {
  _DesktopLyricsWindow(this.controller)
    : channel = WindowMethodChannel(
        '$kLyricsOverlayChannelPrefix${controller.windowId}',
        mode: ChannelMode.unidirectional,
      );

  final WindowController controller;
  final WindowMethodChannel channel;

  @override
  String get id => controller.windowId;

  @override
  Future<void> send(String method, [Object? arguments]) => channel
      .invokeMethod<void>(method, arguments)
      .timeout(const Duration(seconds: 2));

  @override
  Future<bool> close() async {
    // Even creation/disposal races use the overlay's own channel. The default
    // WindowController channel has no close handler in the lyrics engine.
    for (var attempt = 0; attempt < 10; attempt++) {
      try {
        await channel
            .invokeMethod<void>('close')
            .timeout(const Duration(milliseconds: 500));
        // window_manager acknowledges PostMessage(SC_CLOSE), before Windows
        // has actually destroyed the engine. Retain ownership until inventory
        // confirms destruction, especially before recycling font registries.
        if (await _isGone()) return true;
      } on WindowChannelException {
        // Closing may destroy the engine before its acknowledgement arrives.
        if (await _isGone()) {
          return true;
        }
      } on TimeoutException {
        if (await _isGone()) {
          return true;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return false;
  }

  Future<bool> _isGone() async {
    try {
      return !(await WindowController.getAll().timeout(
        const Duration(seconds: 1),
      )).any((window) => window.windowId == id);
    } catch (_) {
      // A failed inventory cannot prove that the engine was destroyed.
      return false;
    }
  }
}
