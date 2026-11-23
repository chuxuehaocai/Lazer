import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../diagnostics/app_log.dart';
import 'overlay_protocol.dart';

typedef LyricsOverlayReadyHandler = Future<dynamic> Function(MethodCall call);

/// The main-engine window boundary, replaceable by a deterministic host in tests.
abstract class LyricsOverlayWindowHost {
  bool get supported;
  Future<void> setReadyHandler(LyricsOverlayReadyHandler? handler);
  Future<LyricsOverlayWindow> create(LyricsOverlayLaunch launch);
}

/// A host whose windows outlive the isolate that created them.
///
/// A hot restart replaces the main isolate and nothing else: an overlay window
/// created by the previous run keeps its own engine, keeps running the build
/// that no longer exists, and stays on screen. Nothing outside that engine can
/// dispose it, so the next run has to send it the same close message the
/// previous run would have sent on shutdown.
///
/// Kept separate from [LyricsOverlayWindowHost] on purpose: a host that cannot
/// produce such windows (a test double, for instance) simply does not implement
/// this, and the controller skips the sweep.
abstract class LyricsOverlayOrphanSweeper {
  Future<void> closeOrphans();
}

abstract class LyricsOverlayWindow {
  String get id;
  Future<void> send(String method, [Object? arguments]);

  /// False retains ownership of an unresponsive window: another must not be
  /// created while the previous engine may still be alive.
  Future<bool> close();
}

class DesktopLyricsWindowHost
    implements LyricsOverlayWindowHost, LyricsOverlayOrphanSweeper {
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

  @override
  Future<void> closeOrphans() async {
    if (!supported) return;
    final List<WindowController> windows;
    try {
      windows = await WindowController.getAll().timeout(
        const Duration(seconds: 1),
      );
    } catch (error) {
      // A window we cannot see is a leaked engine, not a reason to postpone the
      // first frame; report it and let this run create its own overlay.
      AppLog.shared.record('desktop lyrics: window inventory failed: $error');
      return;
    }
    final List<String> orphans = <String>[
      for (final WindowController window in windows)
        // The launch argument is what tells an overlay window apart from the
        // app's own window, which carries none.
        if (LyricsOverlayLaunch.tryParse(window.arguments) != null)
          window.windowId,
    ];
    if (orphans.isEmpty) return;
    final List<bool> closed = await Future.wait(<Future<bool>>[
      for (final String id in orphans) _closeOrphan(id),
    ]).timeout(const Duration(seconds: 2), onTimeout: () => const <bool>[]);
    final int count = closed.where((bool accepted) => accepted).length;
    AppLog.shared.record(
      'desktop lyrics: closed $count of ${orphans.length} overlay window(s) '
      'left behind by the previous run',
    );
    // Printed as well as logged: the count is the fastest way to see, while
    // pressing R in a live session, that each restart stops adding an engine.
    debugPrint(
      'desktop lyrics: closed $count of ${orphans.length} overlay window(s) '
      'from the previous run',
    );
  }

  /// Asks one stale overlay engine to destroy its own window.
  ///
  /// The message has to travel through that engine — only it owns the window —
  /// so an engine that is wedged cannot be recovered from here, and the window
  /// inventory keeps naming windows the plugin never unregistered. Both are
  /// reported as "not closed" rather than as failures: what matters is that this
  /// run sends the message before it creates an overlay of its own.
  Future<bool> _closeOrphan(String windowId) async {
    try {
      await WindowMethodChannel(
        '$kLyricsOverlayChannelPrefix$windowId',
        mode: ChannelMode.unidirectional,
      ).invokeMethod<void>('close').timeout(const Duration(milliseconds: 500));
      return true;
    } catch (_) {
      return false;
    }
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
