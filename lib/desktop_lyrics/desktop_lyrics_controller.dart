import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../diagnostics/app_log.dart';
import '../lyrics/interlude.dart';
import '../lyrics/lyric_document.dart';
import '../state/app_state.dart';
import 'overlay_protocol.dart';
import 'overlay_window_host.dart';

/// Owns at most one overlay engine, with one running and one coalesced update.
class DesktopLyricsController {
  DesktopLyricsController(this._state, {LyricsOverlayWindowHost? windowHost})
    : _host = windowHost ?? DesktopLyricsWindowHost() {
    _state.addListener(_scheduleSync);
    // Started before the first sync so that a later [AppState.desktopLyricsEnabled]
    // change cannot create this run's overlay before the previous run's is gone.
    _orphanSweep = _closeOrphans();
    _scheduleSync();
  }

  final AppState _state;
  final LyricsOverlayWindowHost _host;
  LyricsOverlayWindow? _window;
  LyricsOverlayMode? _mode;
  bool _overlayReady = false;
  String? _pendingReadyId;
  bool _readyHandlerInstalled = false;
  bool _unavailable = false;
  bool _disposed = false;
  bool _closingWindow = false;
  bool _closeUnconfirmed = false;
  bool _transportFailed = false;
  bool _syncRequested = false;
  bool _positionRequested = false;
  bool _drainScheduled = false;
  bool _running = false;
  Future<void> _idle = Future<void>.value();
  Future<void> _closed = Future<void>.value();

  /// Completes once the overlay windows of an earlier run are closed.
  late final Future<void> _orphanSweep;
  Timer? _positionTimer;
  Timer? _retryTimer;
  final Set<(String, String)> _fontRegistrations = {};
  Object? _lastFullIdentity;
  LyricsOverlaySettings? _lastSettings;
  int? _lastPositionMs;
  bool? _lastPlaying;

  @visibleForTesting
  Future<void> get idle => _idle;
  Future<void> get closed => _closed;
  @visibleForTesting
  bool get debugPositionPolling => _positionTimer?.isActive ?? false;

  LyricsOverlayMode? get _desiredMode {
    if (!_host.supported) return null;
    if (_state.desktopLyricsEnabled && _state.desktopLyricsSupported) {
      return LyricsOverlayMode.desktop;
    }
    return _state.floatingLyricsEnabled ? LyricsOverlayMode.floating : null;
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
      lineSpacing: _state.lyricLineSpacing,
      locked: _state.floatingLyricsLocked,
      showRomanization: _state.showLyricRomanization,
      theme: _state.pluginTheme?.toJson(),
    );
  }

  void _scheduleSync() {
    if (_disposed) return;
    _syncRequested = true;
    _updatePositionTimer();
    _scheduleDrain();
  }

  void _scheduleDrain() {
    if (_disposed || _running || _drainScheduled) return;
    _drainScheduled = true;
    final completion = Completer<void>();
    _idle = completion.future;
    scheduleMicrotask(() async {
      _drainScheduled = false;
      _running = true;
      try {
        while (!_disposed && (_syncRequested || _positionRequested)) {
          final full = _syncRequested;
          _syncRequested = false;
          _positionRequested = false;
          try {
            if (full) {
              await _sync();
            } else {
              await _pushPosition();
            }
          } catch (error, stack) {
            AppLog.shared.record('desktop lyrics: $error\n$stack');
          }
        }
      } finally {
        _running = false;
        completion.complete();
      }
    });
  }

  Future<void> _sync() async {
    final mode = _desiredMode;
    if (mode == null) {
      await _close();
      return;
    }
    if (_disposed || _unavailable) return;
    final settings = _settings;
    final font = _customFont(settings);
    // Registered fonts cannot be unloaded. Recycle before loading another
    // custom family/path; toggling built-in fonts, size or lock keeps the engine.
    final recycle =
        font != null &&
        _fontRegistrations.isNotEmpty &&
        !_fontRegistrations.contains(font);
    if (_window == null || _mode != mode || recycle || _closeUnconfirmed) {
      if (!await _close() || _disposed || _desiredMode != mode) return;
      await _open(mode);
      return;
    }
    if (_overlayReady) await _push();
    _updatePositionTimer();
  }

  /// Overlay windows of an earlier run live in this process but outside this
  /// isolate, so a hot restart changes nothing about them: they keep their own
  /// engine and keep drawing. Closing them at start-up is what keeps one restart
  /// from adding one more engine, and what stops a stale overlay from surviving
  /// the setting being switched off.
  Future<void> _closeOrphans() async {
    // Typed as Object so the sweep is promoted: a host that cannot own orphan
    // windows only implements the plain interface.
    final Object host = _host;
    if (host is! LyricsOverlayOrphanSweeper) return;
    try {
      await host.closeOrphans();
    } catch (error) {
      AppLog.shared.record('desktop lyrics: overlay sweep failed: $error');
    }
  }

  Future<void> _open(LyricsOverlayMode mode) async {
    if (!await _ensureReadyHandler() || _disposed || _desiredMode != mode) {
      return;
    }
    // Order matters more than start-up speed here: this run must not create its
    // overlay while the previous run's engine still draws one on top of it.
    await _orphanSweep;
    if (_disposed || _desiredMode != mode) return;
    final LyricsOverlayWindow window;
    final launchSettings = _settings;
    try {
      window = await _host.create(
        LyricsOverlayLaunch(mode: mode, settings: launchSettings),
      );
    } on MissingPluginException catch (error) {
      _unavailable = true;
      AppLog.shared.record('desktop lyrics unavailable: $error');
      return;
    }
    _window = window;
    _mode = mode;
    _closeUnconfirmed = false;
    _transportFailed = false;
    _fontRegistrations.clear();
    // Account for the launch configuration independently of when the child
    // engine first registers it. A ready-before-settings race must not place
    // two different custom fonts in a single engine.
    _recordFont(launchSettings);
    _overlayReady = false;
    _resetSentState();
    if (_disposed || _desiredMode != mode) {
      await _close();
      return;
    }
    if (_pendingReadyId == window.id) {
      _pendingReadyId = null;
      _overlayReady = true;
      _scheduleSync();
    }
  }

  Future<bool> _ensureReadyHandler() async {
    if (_readyHandlerInstalled) return true;
    try {
      await _host.setReadyHandler(_onOverlayReady);
      _readyHandlerInstalled = true;
      return true;
    } catch (error) {
      AppLog.shared.record('desktop lyrics ready channel: $error');
      return false;
    }
  }

  Future<dynamic> _onOverlayReady(MethodCall call) async {
    if (_disposed || _closingWindow || call.method != 'ready') return false;
    final arguments = call.arguments;
    if (arguments is! Map || arguments['windowId'] is! String) return false;
    final windowId = arguments['windowId'] as String;
    if (windowId != _window?.id) {
      if (_window == null) _pendingReadyId = windowId;
      return false;
    }
    _pendingReadyId = null;
    _overlayReady = true;
    _transportFailed = false;
    _scheduleSync();
    return true;
  }

  void _updatePositionTimer() {
    final needed =
        !_disposed &&
        _overlayReady &&
        !_transportFailed &&
        !_closingWindow &&
        _window != null &&
        _desiredMode == _mode &&
        _state.playing;
    if (!needed) {
      _positionTimer?.cancel();
      _positionTimer = null;
    } else {
      _positionTimer ??= Timer.periodic(const Duration(milliseconds: 50), (_) {
        _positionRequested = true;
        _scheduleDrain();
      });
    }
  }

  Future<void> _pushPosition() async {
    final window = _window;
    if (window == null || !_overlayReady || _disposed) return;
    final position = _state.precisePosition.inMilliseconds;
    final playing = _state.playing;
    if (!_transportFailed &&
        !playing &&
        position == _lastPositionMs &&
        playing == _lastPlaying) {
      return;
    }
    try {
      await window.send('position', {'position': position, 'playing': playing});
      _lastPositionMs = position;
      _lastPlaying = playing;
      _transportSucceeded();
      _updatePositionTimer();
    } catch (error) {
      _retryTransport();
      AppLog.shared.record('desktop lyrics position: $error');
    }
  }

  Future<void> _push() async {
    final window = _window;
    if (window == null || !_overlayReady || _disposed) return;
    final identity = _identity;
    final settings = _settings;
    try {
      if (identity != _lastFullIdentity) {
        _recordFont(settings);
        await window.send('state', _payload(settings).toMap());
        _transportSucceeded();
        _lastFullIdentity = identity;
        _lastSettings = settings;
      } else if (settings != _lastSettings) {
        _recordFont(settings);
        await window.send('settings', settings.toMap());
        _transportSucceeded();
        _lastSettings = settings;
      }
      if (_disposed || !identical(window, _window) || _desiredMode != _mode) {
        return;
      }
      if (_transportFailed ||
          _state.precisePosition.inMilliseconds != _lastPositionMs ||
          _state.playing != _lastPlaying) {
        await _pushPosition();
      }
    } catch (error) {
      _retryTransport();
      AppLog.shared.record('desktop lyrics state: $error');
    }
  }

  (String, String)? _customFont(LyricsOverlaySettings settings) =>
      settings.fontPath == null
      ? null
      : (settings.fontFamily, settings.fontPath!);

  void _recordFont(LyricsOverlaySettings settings) {
    final font = _customFont(settings);
    if (font != null) _fontRegistrations.add(font);
  }

  void _retryTransport() {
    _transportFailed = true;
    _updatePositionTimer();
    if (_disposed || _closingWindow || _window == null) return;
    // One backoff timer replaces all failed position packets. Readiness is a
    // one-time handshake, so a transient IPC failure must not require another
    // ready message that the overlay will never send.
    _retryTimer ??= Timer(const Duration(seconds: 1), () {
      _retryTimer = null;
      _scheduleSync();
    });
  }

  void _transportSucceeded() {
    _transportFailed = false;
    _retryTimer?.cancel();
    _retryTimer = null;
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
    final lines = lyricsWithInterludes(
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
    if (lines.any((line) => line.text.trim().isNotEmpty)) return null;
    if (_state.lyricsLoading) return '歌词加载中…';
    final error = _state.lyricsError;
    if (error != null && error.isNotEmpty) return error;
    return _state.lyricsPureMusic ? '纯音乐，请欣赏' : '暂无歌词';
  }

  void _resetSentState() {
    _lastFullIdentity = null;
    _lastSettings = null;
    _lastPositionMs = null;
    _lastPlaying = null;
  }

  Future<bool> _close() async {
    final window = _window;
    if (window == null) return true;
    _closingWindow = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    _overlayReady = false;
    _updatePositionTimer();
    try {
      if (!await window.close()) {
        _closeUnconfirmed = true;
        AppLog.shared.record(
          'desktop lyrics: overlay ${window.id} did not acknowledge close',
        );
        return false;
      }
      _window = null;
      _closeUnconfirmed = false;
      _transportFailed = false;
      _fontRegistrations.clear();
      _mode = null;
      _pendingReadyId = null;
      _resetSentState();
      return true;
    } catch (_) {
      _closeUnconfirmed = true;
      rethrow;
    } finally {
      _closingWindow = false;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _syncRequested = false;
    _positionRequested = false;
    _positionTimer?.cancel();
    _positionTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _state.removeListener(_scheduleSync);
    _closed =
        () async {
          await _idle;
          try {
            await _close();
          } finally {
            if (_readyHandlerInstalled) {
              await _host.setReadyHandler(null);
              _readyHandlerInstalled = false;
            }
          }
        }().catchError((Object error) {
          AppLog.shared.record('desktop lyrics shutdown: $error');
        });
  }
}
