import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart';

import '../diagnostics/app_log.dart';
import '../lyrics/interlude.dart';
import '../lyrics/lyric_document.dart';
import '../state/app_state.dart';
import 'overlay_protocol.dart';

/// Owns the one desktop-lyrics window and keeps it in sync with [AppState].
///
/// The controller lives in the main engine. Every message is serialized so a
/// burst of playback ticks cannot interleave a window close with a state push.
class DesktopLyricsController {
  DesktopLyricsController(this._state) {
    _state.addListener(_scheduleSync);
    _positionTimer = Timer.periodic(
      const Duration(milliseconds: 50),
      (_) => _schedulePositionPush(),
    );
    _scheduleSync();
  }

  final AppState _state;

  WindowController? _window;
  WindowMethodChannel? _channel;
  String? _windowId;
  LyricsOverlayMode? _mode;
  bool _overlayReady = false;
  String? _pendingReadyId;
  bool _readyHandlerInstalled = false;
  bool _unavailable = false;
  bool _disposed = false;
  bool _queued = false;
  bool _positionPushQueued = false;
  Future<void> _queue = Future<void>.value();
  Timer? _positionTimer;

  Object? _lastFullIdentity;
  LyricsOverlaySettings? _lastSettings;
  int? _lastPositionMs;
  bool? _lastPlaying;

  static bool get _desktopPlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS);

  LyricsOverlayMode? get _desiredMode {
    if (!_desktopPlatform) return null;
    if (_state.desktopLyricsEnabled && _state.desktopLyricsSupported) {
      return LyricsOverlayMode.desktop;
    }
    if (_state.floatingLyricsEnabled) return LyricsOverlayMode.floating;
    return null;
  }

  LyricsOverlaySettings get _settings {
    final family = _state.fontPreferences.family;
    return LyricsOverlaySettings(
      lineCount: _state.lyricsOverlayLines,
      fontSize: _state.lyricFontSize,
      fontWeight: _state.lyricFontWeight,
      fontFamily: family.resolvedFamily,
      fontPath: family.path,
      blurEnabled: _state.lyricBlurEnabled,
      blurIntensity: _state.lyricBlurIntensity,
      animationSpeed: _state.animationSpeed,
    );
  }

  void _scheduleSync() {
    if (_disposed || _queued) return;
    _queued = true;
    scheduleMicrotask(() {
      _queued = false;
      if (_disposed) return;
      _queue = _queue.then((_) => _sync()).catchError((
        Object error,
        StackTrace stack,
      ) {
        AppLog.shared.record('desktop lyrics: $error\n$stack');
      });
    });
  }

  Future<void> _sync() async {
    if (_disposed) return;
    final LyricsOverlayMode? mode = _desiredMode;
    if (mode == null) {
      await _close();
      return;
    }
    if (_unavailable) return;
    if (_window == null || _mode != mode) {
      await _close();
      await _open(mode);
      return;
    }
    if (!_overlayReady) return;
    await _push();
  }

  Future<void> _open(LyricsOverlayMode mode) async {
    await _ensureReadyHandler();
    final launch = LyricsOverlayLaunch(mode: mode, settings: _settings);
    final WindowController window;
    try {
      window = await WindowController.create(
        WindowConfiguration(arguments: launch.encode(), hiddenAtLaunch: true),
      );
    } on MissingPluginException catch (error) {
      _unavailable = true;
      AppLog.shared.record('desktop lyrics unavailable: $error');
      return;
    }
    if (_disposed) {
      unawaited(_closeWindow(window));
      return;
    }
    _window = window;
    _windowId = window.windowId;
    _mode = mode;
    _channel = WindowMethodChannel(
      '$kLyricsOverlayChannelPrefix${window.windowId}',
      mode: ChannelMode.unidirectional,
    );
    _overlayReady = false;
    _lastFullIdentity = null;
    _lastSettings = null;
    _lastPositionMs = null;
    _lastPlaying = null;
    if (_pendingReadyId == window.windowId) {
      _pendingReadyId = null;
      _overlayReady = true;
      _scheduleSync();
    }
  }

  Future<void> _ensureReadyHandler() async {
    if (_readyHandlerInstalled) return;
    _readyHandlerInstalled = true;
    try {
      await const WindowMethodChannel(
        kLyricsOverlayReadyChannel,
        mode: ChannelMode.unidirectional,
      ).setMethodCallHandler(_onOverlayReady);
    } catch (error) {
      _readyHandlerInstalled = false;
      AppLog.shared.record('desktop lyrics ready channel: $error');
    }
  }

  Future<dynamic> _onOverlayReady(MethodCall call) async {
    if (call.method != 'ready') return null;
    final Object? arguments = call.arguments;
    if (arguments is! Map) return null;
    final Object? windowId = arguments['windowId'];
    if (windowId is! String) return false;
    if (windowId != _windowId) {
      if (_windowId == null) _pendingReadyId = windowId;
      return false;
    }
    _pendingReadyId = null;
    _overlayReady = true;
    _scheduleSync();
    return true;
  }

  void _schedulePositionPush() {
    if (_disposed || !_overlayReady || _channel == null) return;
    if (_positionPushQueued) return;
    _positionPushQueued = true;
    _queue = _queue
        .then((_) async {
          _positionPushQueued = false;
          await _pushPosition();
        })
        .catchError((Object error, StackTrace stack) {
          _positionPushQueued = false;
          AppLog.shared.record('desktop lyrics position: $error\n$stack');
        });
  }

  Future<void> _pushPosition() async {
    final WindowMethodChannel? channel = _channel;
    if (channel == null || !_overlayReady || _disposed) return;
    final int position = _state.precisePosition.inMilliseconds;
    final bool playing = _state.playing;
    // While playing, send the playhead every 50 ms even when the rounded
    // millisecond value happens to repeat; the overlay re-anchors its local
    // clock on each packet. While paused, one packet is enough.
    if (!playing && position == _lastPositionMs && playing == _lastPlaying) {
      return;
    }
    try {
      await channel.invokeMethod<void>('position', <String, Object?>{
        'position': position,
        'playing': playing,
      });
      _lastPositionMs = position;
      _lastPlaying = playing;
    } on WindowChannelException {
      _overlayReady = false;
    }
  }

  Future<void> _push() async {
    final WindowMethodChannel? channel = _channel;
    if (channel == null || !_overlayReady) return;
    final Object identity = _identity;
    final LyricsOverlaySettings settings = _settings;
    try {
      if (identity != _lastFullIdentity) {
        await channel.invokeMethod<void>('state', _payload(settings).toMap());
        _lastFullIdentity = identity;
        _lastSettings = settings;
      } else if (settings != _lastSettings) {
        await channel.invokeMethod<void>('settings', settings.toMap());
        _lastSettings = settings;
      }
      final int position = _state.precisePosition.inMilliseconds;
      final bool playing = _state.playing;
      if (position != _lastPositionMs || playing != _lastPlaying) {
        await channel.invokeMethod<void>('position', <String, Object?>{
          'position': position,
          'playing': playing,
        });
        _lastPositionMs = position;
        _lastPlaying = playing;
      }
    } on WindowChannelException {
      // The overlay registered its handler after this push, or it is closing.
      // A fresh ready message will schedule the next full push.
      _overlayReady = false;
    }
  }

  Object get _identity => (
    _state.current,
    _state.lyrics,
    _state.lyricsLoading,
    _state.lyricsError,
    _state.lyricsPureMusic,
  );

  LyricsOverlayPayload _payload(LyricsOverlaySettings settings) {
    final track = _state.current;
    final List<LyricLine> lines = lyricsWithInterludes(
      _state.lyrics,
      track?.duration ?? Duration.zero,
    );
    return LyricsOverlayPayload(
      title: track?.title ?? '',
      artist: track?.artist ?? '',
      notice: _notice(lines),
      lines: lines,
      settings: settings,
      position: _state.precisePosition,
      duration: track?.duration ?? Duration.zero,
      playing: _state.playing,
    );
  }

  String? _notice(List<LyricLine> lines) {
    if (_state.current == null) return '未在播放';
    if (lines.any((LyricLine line) => line.text.trim().isNotEmpty)) return null;
    if (_state.lyricsLoading) return '歌词加载中…';
    final String? error = _state.lyricsError;
    if (error != null && error.isNotEmpty) return error;
    if (_state.lyricsPureMusic) return '纯音乐，请欣赏';
    return '暂无歌词';
  }

  Future<void> _close() async {
    final WindowController? window = _window;
    final WindowMethodChannel? channel = _channel;
    _window = null;
    _channel = null;
    _windowId = null;
    _mode = null;
    _overlayReady = false;
    _pendingReadyId = null;
    _lastFullIdentity = null;
    _lastSettings = null;
    _lastPositionMs = null;
    _lastPlaying = null;
    if (window != null) await _closeWindow(window, channel);
  }

  Future<void> _closeWindow(
    WindowController window, [
    WindowMethodChannel? channel,
  ]) async {
    // The subwindow registers its handler from its own Dart entrypoint, which
    // can lag a freshly created window. Retry briefly so toggling the setting
    // right after enabling cannot leave a hidden engine behind.
    for (var attempt = 0; attempt < 10; attempt++) {
      try {
        // The overlay handles `close` on its own channel. WindowController's
        // default channel has no handler in the sub-engine, so using it here
        // would leave the visible overlay running after the switch is turned
        // off.
        if (channel != null) {
          await channel.invokeMethod<void>('close');
        } else {
          await window.invokeMethod<void>('close');
        }
        return;
      } on WindowChannelException {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    AppLog.shared.record(
      'desktop lyrics: overlay ${window.windowId} did not acknowledge close',
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _positionTimer?.cancel();
    _positionTimer = null;
    _state.removeListener(_scheduleSync);
    final WindowController? window = _window;
    final WindowMethodChannel? channel = _channel;
    _window = null;
    _channel = null;
    if (window != null) unawaited(_closeWindow(window, channel));
  }
}
