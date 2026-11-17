import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../animation/apple_spring.dart';
import '../diagnostics/app_log.dart';
import '../lyrics/interlude.dart';
import '../lyrics/line_content.dart';
import '../lyrics/lyric_document.dart';
import '../lyrics/spacing.dart';
import '../lyrics/spring.dart';
import '../theme/lazer_theme.dart';
import 'overlay_protocol.dart';
import 'overlay_motion.dart';
import 'overlay_font_loader.dart';

part 'overlay_presentation.dart';

const double _horizontalPadding = 34;
const double _verticalPadding = 18;
const double _floatingBottomGap = 72;
const double _overlayMinWidth = 320;
const double _overlayDefaultWidth = 420;
const double _overlayMaxWidth = 760;
const double _dragHandleWidth = 28;
const double _dragHandleHeight = 64;

/// The native window and Flutter use exactly the same logical hit regions.
/// Empty lyric slots, shadow padding and the rest of the transparent window
/// remain click-through; a locked floating overlay exposes no mouse targets.
List<Rect> lyricsOverlayInteractiveRegions(
  Size size, {
  required bool desktop,
  required bool locked,
  List<Rect> lyricBounds = const <Rect>[],
}) {
  if (!desktop && locked) return const <Rect>[];
  final Rect window = Offset.zero & size;
  return <Rect>[
    Rect.fromLTWH(
      0,
      (size.height - _dragHandleHeight) / 2,
      _dragHandleWidth,
      _dragHandleHeight,
    ).intersect(window),
    if (!desktop)
      for (final Rect bounds in lyricBounds)
        if (bounds.overlaps(window)) bounds.intersect(window),
  ].where((rect) => !rect.isEmpty).toList(growable: false);
}

double lyricsOverlaySlotHeight(double fontSize) =>
    (fontSize * 3.0).clamp(48.0, 144.0);

double lyricsOverlaySlotHeightWithSpacing(
  double fontSize, {
  double lineSpacing = kLyricsLineSpacingDefault,
}) => (fontSize * 2.0 + lineSpacing).clamp(48.0, 160.0);

Size lyricsOverlayWindowSize(LyricsOverlayLaunch launch) => Size(
  _overlayDefaultWidth,
  lyricsOverlaySlotHeightWithSpacing(
            launch.settings.fontSize,
            lineSpacing: launch.settings.lineSpacing,
          ) *
          launch.settings.lineCount +
      _verticalPadding * 2,
);

class OverlayBridge {
  Future<dynamic> Function(MethodCall call)? handler;
}

/// Entrypoint of a desktop-multi-window sub-engine.
Future<void> runLyricsOverlay(
  WindowController controller,
  LyricsOverlayLaunch launch,
) async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  final channel = WindowMethodChannel(
    '$kLyricsOverlayChannelPrefix${controller.windowId}',
    mode: ChannelMode.unidirectional,
  );
  final bridge = OverlayBridge();
  await channel.setMethodCallHandler((MethodCall call) async {
    if (call.method == 'close') {
      await windowManager.close();
      return true;
    }
    final handler = bridge.handler;
    if (handler == null) return null;
    return handler(call);
  });
  final LazerThemeTokens ui = launch.settings.theme == null
      ? LazerThemeTokens.apple
      : LazerThemeTokens.fromJson(launch.settings.theme!);
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      color: Colors.transparent,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.transparent,
        canvasColor: Colors.transparent,
        fontFamily: launch.settings.fontFamily,
        extensions: <ThemeExtension<dynamic>>[ui],
      ),
      home: LyricsOverlayApp(
        controller: controller,
        launch: launch,
        channel: channel,
        bridge: bridge,
      ),
    ),
  );
  await _configureOverlayWindow(launch);
}

Future<void> _configureOverlayWindow(LyricsOverlayLaunch launch) async {
  final Size size = lyricsOverlayWindowSize(launch);
  try {
    await windowManager.setAsFrameless();
    await windowManager.setResizable(false);
    await windowManager.setHasShadow(false);
    await windowManager.setBackgroundColor(Colors.transparent);
    if (launch.mode == LyricsOverlayMode.desktop) {
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setAlwaysOnBottom(false);
      await windowManager.waitUntilReadyToShow(
        WindowOptions(
          size: size,
          backgroundColor: Colors.transparent,
          skipTaskbar: true,
        ),
      );
      final bool attached = Platform.isWindows && await _attachToDesktop();
      if (!attached) {
        // Explorer did not accept the desktop placement. Keep a normal,
        // click-through bottom window instead of an always-on-bottom window:
        // HWND_BOTTOM sits below Progman on Windows 11 and would be invisible.
        await windowManager.setIgnoreMouseEvents(true);
        await windowManager.setAlignment(Alignment.bottomCenter);
        final Offset position = await windowManager.getPosition();
        await windowManager.setPosition(position - const Offset(0, 24));
        await windowManager.show(inactive: true);
      }
    } else {
      if (!Platform.isWindows) {
        await windowManager.setIgnoreMouseEvents(launch.settings.locked);
      }
      await windowManager.waitUntilReadyToShow(
        WindowOptions(
          size: size,
          backgroundColor: Colors.transparent,
          skipTaskbar: true,
          alwaysOnTop: true,
        ),
      );
      await windowManager.setAsFrameless();
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setAlignment(Alignment.bottomCenter);
      final Offset position = await windowManager.getPosition();
      await windowManager.setPosition(
        position - const Offset(0, _floatingBottomGap),
      );
      await windowManager.show(inactive: true);
    }
  } catch (error, stack) {
    AppLog.shared.record('desktop lyrics window: $error\n$stack');
  }
}

Future<bool> _attachToDesktop() async {
  try {
    return await const MethodChannel(
          kDesktopLyricsChannel,
        ).invokeMethod<bool>('attachToDesktop') ??
        false;
  } on MissingPluginException {
    return false;
  } catch (error) {
    AppLog.shared.record('desktop lyrics attach: $error');
    return false;
  }
}

class LyricsOverlayApp extends StatefulWidget {
  const LyricsOverlayApp({
    super.key,
    required this.controller,
    required this.launch,
    required this.channel,
    required this.bridge,
    this.fontLoader,
  });

  final WindowController controller;
  final LyricsOverlayLaunch launch;
  final WindowMethodChannel channel;
  final OverlayBridge bridge;
  final OverlayFontLoader? fontLoader;

  @override
  State<LyricsOverlayApp> createState() => _LyricsOverlayAppState();
}

class _LyricsOverlayAppState extends State<LyricsOverlayApp>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final Stopwatch _clock = Stopwatch()..start();
  final OverlayMotionBuffer _motions = OverlayMotionBuffer();
  final Map<int, ui.ImageFilter> _blurFilters = <int, ui.ImageFilter>{};
  final ValueNotifier<int> _frames = ValueNotifier<int>(0);

  late LyricsOverlayMode _mode;
  late LyricsOverlaySettings _settings;
  LyricsOverlayPayload? _payload;
  List<LyricLine> _lines = const <LyricLine>[];
  Ticker? _ticker;
  Duration _lastTick = Duration.zero;
  Size? _windowSize;
  bool _windowConfigured = false;
  bool _resizeRunning = false;
  Size? _pendingSize;
  bool _visible = true;
  bool _reducedMotion = false;
  bool _lifecycleVisible = true;
  double? _cachedWidth;
  double? _cachedSlotHeight;
  bool _seekPending = false;
  bool _playing = false;
  bool _dragHovered = false;
  bool _dragRunning = false;
  bool _interactionSyncScheduled = false;
  bool _interactionConfigured = false;
  List<Rect> _interactionRegions = const <Rect>[];
  int _focus = 0;
  double _anchorMs = 0;
  int _anchorMicros = 0;
  late TextStyle _lyricStyle;
  late LazerThemeTokens _theme;
  (String, String)? _requestedFont;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _mode = widget.launch.mode;
    _settings = widget.launch.settings;
    _windowSize = lyricsOverlayWindowSize(widget.launch);
    _windowConfigured = true;
    _applyAnimationSpeed(_settings);
    widget.bridge.handler = _handle;
    unawaited(_announceReady());
  }

  void _applyAnimationSpeed(LyricsOverlaySettings settings) {
    MotionTiming.speed = settings.animationSpeed;
  }

  void _refreshTextStyles() {
    _theme = _settings.theme == null
        ? LazerThemeTokens.apple
        : LazerThemeTokens.fromJson(_settings.theme!);
    _lyricStyle = _textStyle(1);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    _refreshTextStyles();
    _invalidateLayout();
    _retarget(instant: true);
    _ensureTicker();
    if (_payload != null) unawaited(_resizeOverlay());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleVisible = state == AppLifecycleState.resumed;
    _ensureTicker();
  }

  @override
  void dispose() {
    widget.bridge.handler = null;
    WidgetsBinding.instance.removeObserver(this);
    _clock.stop();
    _pendingSize = null;
    _ticker?.dispose();
    _frames.dispose();
    super.dispose();
  }

  double get _currentPositionMs {
    final value = _playing
        ? _anchorMs + (_clock.elapsedMicroseconds - _anchorMicros) / 1000
        : _anchorMs;
    final duration = _payload?.duration.inMilliseconds ?? 0;
    return value.clamp(
      0.0,
      duration > 0 ? duration.toDouble() : double.infinity,
    );
  }

  Future<dynamic> _handle(MethodCall call) async {
    switch (call.method) {
      case 'state':
        final Object? arguments = call.arguments;
        if (arguments is Map) {
          _applyPayload(LyricsOverlayPayload.fromMap(arguments));
        }
        return true;
      case 'settings':
        final Object? arguments = call.arguments;
        if (arguments is Map) {
          _applySettings(LyricsOverlaySettings.fromMap(arguments));
        }
        return true;
      case 'position':
        final Object? arguments = call.arguments;
        if (arguments is Map) {
          final Object? position = arguments['position'];
          final Object? playing = arguments['playing'];
          _applyPosition(
            position is num ? position.toInt() : 0,
            playing is bool ? playing : _playing,
          );
        }
        return true;
    }
    return null;
  }

  void _applyPayload(LyricsOverlayPayload payload) {
    // Payloads describe a new document. Index keys alone must not carry the
    // previous track's springs or accessibility nodes into it.
    const reset = true;
    _motions.clear();
    setState(() {
      _payload = payload;
      _settings = payload.settings;
      _applyAnimationSpeed(_settings);
      _refreshTextStyles();
      _lines = payload.lines;
      _invalidateLayout();
      _anchorMs = payload.position.inMilliseconds.toDouble();
      _anchorMicros = _clock.elapsedMicroseconds;
      _playing = payload.playing;
      _seekPending = reset;
      _focus = _focusFor(_anchorMs);
    });
    _retarget(instant: reset);
    _seekPending = false;
    unawaited(_loadFont(payload.settings));
    unawaited(_resizeOverlay());
    _ensureTicker();
    _frames.value++;
  }

  void _applySettings(LyricsOverlaySettings settings) {
    setState(() {
      final previous = _settings;
      _settings = settings;
      if (previous.fontFamily != settings.fontFamily ||
          previous.fontPath != settings.fontPath ||
          previous.fontSize != settings.fontSize ||
          previous.fontWeight != settings.fontWeight ||
          previous.showRomanization != settings.showRomanization ||
          previous.lineSpacing != settings.lineSpacing ||
          previous.theme?.toString() != settings.theme?.toString()) {
        _invalidateLayout();
      }
      _applyAnimationSpeed(settings);
      _refreshTextStyles();
    });
    if (_mode == LyricsOverlayMode.floating && !Platform.isWindows) {
      unawaited(windowManager.setIgnoreMouseEvents(settings.locked));
    }
    _retarget(instant: true);
    unawaited(_loadFont(settings));
    unawaited(_resizeOverlay());
    _ensureTicker();
    _frames.value++;
  }

  void _applyPosition(int positionMs, bool playing) {
    final double next = positionMs.toDouble();
    final double predicted = _currentPositionMs;
    final bool wasPlaying = _playing;
    final double delta = next - predicted;
    final bool seek = delta.abs() > 700;
    _playing = playing;
    // Re-anchor only on a seek, a transport change, or a meaningful drift.
    // Re-anchoring on every 50 ms packet would pull the local clock backwards
    // by a few milliseconds each time and make the line switch shiver.
    if (seek || !playing || !wasPlaying || delta > 100 || delta < -150) {
      _anchorMs = next;
      _anchorMicros = _clock.elapsedMicroseconds;
    }
    _seekPending = seek;
    final int focus = _focusFor(next);
    // Focus follows the playhead forwards; a stale packet must not drag the
    // highlighted line back for one frame at the boundary.
    final bool backwards = focus < _focus && (!playing || delta < -150);
    if (seek || focus > _focus || backwards) {
      _focus = focus;
      _retarget(instant: false);
      if (mounted) setState(() {});
    }
    _seekPending = false;
    if (_visible && _lifecycleVisible && (!_playing || _reducedMotion)) {
      _frames.value++;
    }
    _ensureTicker();
  }

  int _focusFor(double positionMs) {
    if (_lines.isEmpty) return 0;
    var low = 0;
    var high = _lines.length - 1;
    var result = 0;
    while (low <= high) {
      final int middle = (low + high) >> 1;
      if (_lines[middle].time.inMilliseconds <= positionMs) {
        result = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return result;
  }

  void _retarget({required bool instant}) {
    if (_lines.isEmpty) {
      _motions.clear();
      return;
    }
    final int count = _settings.lineCount.clamp(1, 5);
    final double slot = _slotHeight;
    final int focus = _focus.clamp(0, _lines.length - 1);
    final bool atEdge = focus == 0 || focus == _lines.length - 1;
    final bool interlude =
        _lines[focus].text.trim().isEmpty &&
        _currentPositionMs <
            (_lines[focus].end ?? _lines[focus].time).inMilliseconds;
    final Duration total = _payload?.duration ?? Duration.zero;
    final bool endOfSong =
        total > Duration.zero &&
        _currentPositionMs >= total.inMilliseconds.toDouble();
    // Mirror the Now Playing lyric sheet exactly: edge rows use its damped
    // baseline, everything else uses lyricPositionPolicy, and the stagger
    // delays come from the same helper.
    final LyricSpringParams params = !_seekPending && atEdge
        ? const LyricSpringParams(mass: .9, stiffness: 170, damping: 29)
        : lyricPositionPolicy(
            seeking: _seekPending,
            interlude: interlude,
            intervalMs: focus > 0
                ? (_lines[focus].time - _lines[focus - 1].time).inMilliseconds
                : null,
            endOfSong: endOfSong,
          );

    _motions.retarget(
      focus: focus,
      lineCount: count,
      documentLength: _lines.length,
      slot: slot,
      padding: _verticalPadding,
      inactiveScale: 100 - _theme.lyricFocusScaleDelta,
      params: params,
      seeking: _seekPending,
      instant: instant || _reducedMotion || !_visible || !_lifecycleVisible,
    );
  }

  bool get _continuousFrames {
    if (!_playing || _lines.isEmpty) return false;
    final line = _lines[_focus.clamp(0, _lines.length - 1)];
    final position = _currentPositionMs;
    if (line.text.trim().isEmpty) {
      return position < (line.end ?? line.time).inMilliseconds;
    }
    return line.words.any(
      (word) => position < (word.start + word.duration).inMilliseconds,
    );
  }

  void _ensureTicker() {
    final needed =
        _visible &&
        _lifecycleVisible &&
        !_reducedMotion &&
        (_continuousFrames || _motions.values.any((motion) => !motion.arrived));
    if (!needed) {
      _ticker?.stop();
      _lastTick = Duration.zero;
      return;
    }
    _ticker ??= createTicker(_onTick);
    if (!_ticker!.isActive) {
      _lastTick = Duration.zero;
      _ticker!.start();
    }
  }

  void _onTick(Duration elapsed) {
    final double seconds = _lastTick == Duration.zero
        ? 0
        : (elapsed - _lastTick).inMicroseconds / 1000000;
    _lastTick = elapsed;
    for (final motion in _motions.values) {
      motion.y.update(seconds);
      motion.scale.update(seconds);
    }
    if (_playing) {
      final focus = _focusFor(_currentPositionMs);
      if (focus != _focus) {
        _focus = focus;
        _retarget(instant: false);
        setState(() {});
      }
    }
    // Paint the final settled frame too; otherwise a stopped ticker can leave
    // the text a fraction of a pixel away from its final position.
    _frames.value++;
    _ensureTicker();
  }

  Future<void> _announceReady() async {
    try {
      await const WindowMethodChannel(
        kLyricsOverlayReadyChannel,
        mode: ChannelMode.unidirectional,
      ).invokeMethod<void>('ready', <String, Object?>{
        'windowId': widget.controller.windowId,
      });
    } catch (error) {
      AppLog.shared.record('desktop lyrics ready: $error');
    }
  }

  void _invalidateLayout() {
    _cachedWidth = null;
    _cachedSlotHeight = null;
  }

  Future<void> _resizeOverlay() async {
    if (!_windowConfigured || !mounted) return;
    _pendingSize = Size(
      _desiredOverlayWidth(),
      _slotHeight * _settings.lineCount + _verticalPadding * 2,
    );
    if (_resizeRunning) return;
    _resizeRunning = true;
    try {
      while (mounted && _pendingSize != null) {
        final size = _pendingSize!;
        _pendingSize = null;
        final previous = _windowSize;
        if (size == previous) continue;
        try {
          if (_mode == LyricsOverlayMode.floating) {
            final position = await windowManager.getPosition();
            if (!mounted) return;
            await windowManager.setSize(size);
            if (!mounted) return;
            // The resize succeeded even if a subsequent positioning request
            // fails. Record reality so the next request anchors correctly.
            _windowSize = size;
            if (previous != null) {
              await windowManager.setPosition(
                position +
                    Offset(
                      (previous.width - size.width) / 2,
                      -(size.height - previous.height),
                    ),
              );
            }
          } else {
            await windowManager.setSize(size);
            if (!mounted) return;
            _windowSize = size;
            await _attachToDesktop();
          }
        } catch (error) {
          AppLog.shared.record('desktop lyrics resize: $error');
        }
      }
    } finally {
      _resizeRunning = false;
    }
  }

  double get _slotHeight => _cachedSlotHeight ??= _measureSlotHeight();

  double _measureSlotHeight() {
    final theme = _theme;
    final secondaryLines = _lines.fold<int>(
      0,
      (maximum, line) => math.max(
        maximum,
        (line.translation == null ? 0 : 1) +
            (_settings.showRomanization && line.romanization != null ? 1 : 0),
      ),
    );
    final textScaler = MediaQuery.textScalerOf(context);
    final originalHeight =
        textScaler.scale(_settings.fontSize * theme.lyricFontScale) *
        theme.lyricLineHeight;
    final secondaryHeight =
        textScaler.scale(
              (_settings.fontSize * theme.lyricTranslationScale).clamp(12, 30),
            ) *
            theme.lyricTranslationLineHeight +
        theme.lyricTranslationGap;
    return math.max(
      lyricsOverlaySlotHeightWithSpacing(
        _settings.fontSize,
        lineSpacing: _settings.lineSpacing,
      ),
      originalHeight + secondaryLines * secondaryHeight + _settings.lineSpacing,
    );
  }

  double _desiredOverlayWidth() => _cachedWidth ??= _measureOverlayWidth();

  double _measureOverlayWidth() {
    double widest = 0;
    final TextPainter painter = TextPainter(
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    );
    try {
      for (final LyricLine line in _lines) {
        for (final String text in <String?>[
          line.text,
          line.translation,
          if (_settings.showRomanization) line.romanization,
        ].whereType<String>()) {
          painter.text = TextSpan(text: text, style: _lyricStyle);
          painter.layout();
          widest = math.max(widest, painter.width);
        }
      }
    } finally {
      painter.dispose();
    }
    return (widest + _horizontalPadding * 2).clamp(
      _overlayMinWidth,
      _overlayMaxWidth,
    );
  }

  Future<void> _loadFont(LyricsOverlaySettings settings) async {
    final String? path = settings.fontPath;
    if (path == null) {
      _requestedFont = null;
      return;
    }
    final key = (settings.fontFamily, path);
    if (_requestedFont == key) return;
    _requestedFont = key;
    try {
      await (widget.fontLoader ?? OverlayFontLoader.shared).load(
        settings.fontFamily,
        path,
      );
      if (mounted &&
          _settings.fontFamily == settings.fontFamily &&
          _settings.fontPath == path) {
        setState(() {
          _refreshTextStyles();
          _invalidateLayout();
        });
        _retarget(instant: true);
        unawaited(_resizeOverlay());
        _frames.value++;
      }
    } catch (error) {
      if (_requestedFont == key) _requestedFont = null;
      AppLog.shared.record('desktop lyrics font: $error');
    }
  }

  ui.ImageFilter _blur(double sigma) {
    final int key = (sigma.clamp(0.0, 6.0) * 8).round();
    return _blurFilters.putIfAbsent(
      key,
      () => ui.ImageFilter.blur(
        sigmaX: key / 8,
        sigmaY: key / 8,
        tileMode: ui.TileMode.decal,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: Theme.of(
      context,
    ).copyWith(extensions: <ThemeExtension<dynamic>>[_theme]),
    child: _buildOverlay(context),
  );

  void _setDragHovered(bool value) {
    if (_dragHovered != value) setState(() => _dragHovered = value);
  }

  void _syncInteractionRegions(List<Rect> regions) {
    if (!Platform.isWindows ||
        (_interactionConfigured && listEquals(_interactionRegions, regions))) {
      return;
    }
    _interactionConfigured = true;
    _interactionRegions = regions;
    if (_interactionSyncScheduled) return;
    _interactionSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _interactionSyncScheduled = false;
      if (!mounted) return;
      try {
        await const MethodChannel(kDesktopLyricsChannel).invokeMethod<void>(
          'setInteractionRegions',
          <String, Object?>{
            'locked': _interactionRegions.isEmpty,
            'regions': <List<double>>[
              for (final rect in _interactionRegions)
                <double>[rect.left, rect.top, rect.right, rect.bottom],
            ],
          },
        );
      } on MissingPluginException {
        // Other desktop platforms retain the normal window-manager behavior.
      } catch (error) {
        AppLog.shared.record('desktop lyrics interaction: $error');
      }
    });
  }

  Future<void> _startDrag() async {
    if (_dragRunning ||
        (_mode == LyricsOverlayMode.floating && _settings.locked)) {
      return;
    }
    _dragRunning = true;
    try {
      if (_mode == LyricsOverlayMode.desktop && Platform.isWindows) {
        final bool moved =
            await const MethodChannel(
              kDesktopLyricsChannel,
            ).invokeMethod<bool>('startDesktopDrag') ??
            false;
        if (moved) return;
      }
      await windowManager.startDragging();
    } catch (error) {
      AppLog.shared.record('desktop lyrics drag: $error');
    } finally {
      _dragRunning = false;
    }
  }
}
