import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../animation/apple_spring.dart';
import '../animation/lyric_spring.dart';
import '../diagnostics/app_log.dart';
import '../lyrics/interlude.dart';
import '../lyrics/line_content.dart';
import '../lyrics/lyric_document.dart';
import '../lyrics/spring.dart';
import 'overlay_protocol.dart';

const double _horizontalPadding = 26;
const double _verticalPadding = 18;
const double _floatingBottomGap = 72;
const double _overlayWidth = 640;
const double _dragHandleWidth = 24;
const double _dragHandleHeight = 56;

double lyricsOverlaySlotHeight(double fontSize) =>
    (fontSize * 3.0).clamp(48.0, 144.0);

Size lyricsOverlayWindowSize(LyricsOverlayLaunch launch) => Size(
  _overlayWidth,
  lyricsOverlaySlotHeight(launch.settings.fontSize) *
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
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      color: Colors.transparent,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.transparent,
        canvasColor: Colors.transparent,
        fontFamily: launch.settings.fontFamily,
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
  });

  final WindowController controller;
  final LyricsOverlayLaunch launch;
  final WindowMethodChannel channel;
  final OverlayBridge bridge;

  @override
  State<LyricsOverlayApp> createState() => _LyricsOverlayAppState();
}

class _LyricsOverlayAppState extends State<LyricsOverlayApp>
    with SingleTickerProviderStateMixin {
  static final Set<String> _loadedFonts = <String>{};

  final Stopwatch _clock = Stopwatch()..start();
  final Map<int, _LineMotion> _motions = <int, _LineMotion>{};
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
  bool _seekPending = false;
  bool _playing = false;
  bool _dragHovered = false;
  int _focus = 0;
  double _anchorMs = 0;
  int _anchorMicros = 0;
  late TextStyle _lyricStyle;

  @override
  void initState() {
    super.initState();
    _mode = widget.launch.mode;
    _settings = widget.launch.settings;
    _windowSize = lyricsOverlayWindowSize(widget.launch);
    _windowConfigured = true;
    _applyAnimationSpeed(_settings);
    _refreshTextStyles();
    widget.bridge.handler = _handle;
    unawaited(_announceReady());
  }

  void _applyAnimationSpeed(LyricsOverlaySettings settings) {
    MotionTiming.speed = settings.animationSpeed;
  }

  void _refreshTextStyles() {
    _lyricStyle = _textStyle(1);
  }

  @override
  void dispose() {
    widget.bridge.handler = null;
    _ticker?.dispose();
    _frames.dispose();
    super.dispose();
  }

  double get _currentPositionMs {
    if (!_playing) return _anchorMs;
    return _anchorMs + (_clock.elapsedMicroseconds - _anchorMicros) / 1000;
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
      _settings = settings;
      _applyAnimationSpeed(settings);
      _refreshTextStyles();
    });
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
    final int leading = count ~/ 2;
    final double slot = lyricsOverlaySlotHeight(_settings.fontSize);
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

    final List<int> indices = <int>[];
    final List<double> positions = <double>[];
    final List<double> heights = <double>[];
    for (var offset = -leading - 1; offset <= count - leading; offset++) {
      final int index = focus + offset;
      if (index < 0 || index >= _lines.length) continue;
      indices.add(index);
      positions.add(_verticalPadding + (index - focus + leading) * slot);
      heights.add(slot);
    }
    if (indices.isEmpty) {
      _motions.clear();
      return;
    }
    final int activeIndex = indices.indexOf(focus);
    // The Now Playing sheet's rows above the focus are usually off-screen, so
    // they do not consume a stagger delay. This overlay shows only a few rows
    // around the focus; feed the helper off-screen positions for those rows so
    // the active line still starts immediately and only lower rows cascade.
    final List<double> staggerPositions = <double>[
      for (var i = 0; i < indices.length; i++)
        i < activeIndex ? -slot * 2 : (i - activeIndex) * slot,
    ];
    final List<double> delays = lyricStaggerDelays(
      staggerPositions,
      heights,
      activeIndex,
      disabled: _seekPending,
    );
    final Set<int> keep = indices.toSet();
    for (var i = 0; i < indices.length; i++) {
      final int index = indices[i];
      final double target = positions[i];
      final bool active = index == focus;
      final double scale = active ? 100 : 97;
      final double delay = delays[i];
      final _LineMotion? existing = _motions[index];
      if (existing == null) {
        final motion = _LineMotion(
          target + (i >= activeIndex ? slot : -slot),
          active: active,
        );
        _motions[index] = motion;
        if (instant) {
          motion.y.setPosition(target);
          motion.scale.setPosition(scale);
        } else {
          motion.y.setParameters(params);
          motion.y.setTarget(target, delay: delay);
          motion.scale.setTarget(scale);
        }
      } else {
        existing.y.setParameters(params);
        if (instant) {
          existing.y.setPosition(target);
          existing.scale.setPosition(scale);
        } else {
          existing.y.setTarget(target, delay: delay);
          existing.scale.setTarget(scale);
        }
      }
    }
    _motions.removeWhere(
      (int index, _LineMotion motion) =>
          !keep.contains(index) && motion.arrived,
    );
  }

  void _ensureTicker() {
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
    var moving = false;
    for (final _LineMotion motion in _motions.values) {
      motion.y.update(seconds);
      motion.scale.update(seconds);
      moving = moving || !motion.arrived;
    }
    if (_playing) {
      final int focus = _focusFor(_currentPositionMs);
      if (focus != _focus) {
        _focus = focus;
        _retarget(instant: false);
        setState(() {});
        moving = true;
      }
      // The breathing dots are painted from the playback clock, not from a
      // spring. Keep one frame per vsync while an interlude is active so they
      // breathe even after every lyric spring has settled.
      if (_lines.isNotEmpty) {
        final LyricLine line = _lines[_focus.clamp(0, _lines.length - 1)];
        final int end = (line.end ?? line.time).inMilliseconds;
        if (line.text.trim().isEmpty && _currentPositionMs < end) {
          moving = true;
        }
      }
    }
    if (moving ||
        (_playing && _lines.isNotEmpty && _lines[_focus].words.isNotEmpty)) {
      _frames.value++;
    }
    if (!_playing && !moving) {
      _ticker?.stop();
      _lastTick = Duration.zero;
    }
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

  Future<void> _resizeOverlay() async {
    if (!_windowConfigured) return;
    final Size size = lyricsOverlayWindowSize(
      LyricsOverlayLaunch(mode: _mode, settings: _settings),
    );
    final Size? previous = _windowSize;
    if (previous == size) return;
    _windowSize = size;
    try {
      if (_mode == LyricsOverlayMode.floating) {
        final Offset position = await windowManager.getPosition();
        await windowManager.setSize(size);
        if (previous != null) {
          await windowManager.setPosition(
            position - Offset(0, size.height - previous.height),
          );
        }
      } else {
        await windowManager.setSize(size);
        await _attachToDesktop();
      }
    } catch (error) {
      AppLog.shared.record('desktop lyrics resize: $error');
    }
  }

  Future<void> _loadFont(LyricsOverlaySettings settings) async {
    final String? path = settings.fontPath;
    if (path == null || _loadedFonts.contains(settings.fontFamily)) return;
    _loadedFonts.add(settings.fontFamily);
    try {
      final Uint8List bytes = await File(path).readAsBytes();
      final FontLoader loader = FontLoader(settings.fontFamily)
        ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
      await loader.load();
      if (mounted) _frames.value++;
    } catch (error) {
      _loadedFonts.remove(settings.fontFamily);
      AppLog.shared.record('desktop lyrics font: $error');
    }
  }

  ui.ImageFilter _blur(double sigma) {
    final int key = (sigma.clamp(0.0, 6.0) * 8).round();
    return _blurFilters.putIfAbsent(
      key,
      () => ui.ImageFilter.blur(sigmaX: key / 8, sigmaY: key / 8),
    );
  }

  TextStyle _textStyle(double scale) {
    final int weight = (_settings.fontWeight ~/ 100 - 1).clamp(0, 6);
    return lyricTextStyle(
      TextStyle(
        fontFamily: _settings.fontFamily,
        fontFamilyFallback: const <String>[
          'MiSans',
          'Microsoft YaHei',
          'PingFang SC',
          'Noto Sans CJK SC',
        ],
        fontSize: _settings.fontSize * scale,
        fontWeight: FontWeight.values[weight],
        height: 1.5,
        color: Colors.white,
        letterSpacing: 0,
        decoration: TextDecoration.none,
        shadows: const <Shadow>[
          Shadow(
            color: Color(0xE6000000),
            blurRadius: 14,
            offset: Offset(0, 2),
          ),
          Shadow(color: Color(0xB3000000), blurRadius: 4),
          Shadow(color: Color(0x80000000), blurRadius: 1),
        ],
      ),
      _settings.fontSize * scale,
      _settings.fontWeight,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool desktop = _mode == LyricsOverlayMode.desktop;
    final double slot = lyricsOverlaySlotHeight(_settings.fontSize);
    final int count = _settings.lineCount.clamp(1, 5);
    final Size window = MediaQuery.sizeOf(context);
    final double inset = desktop
        ? math.max(_horizontalPadding, (window.width - _overlayWidth) / 2)
        : _horizontalPadding;
    final bool hasText = _lines.any(
      (LyricLine line) => line.text.trim().isNotEmpty,
    );
    final Widget block = Stack(
      clipBehavior: Clip.hardEdge,
      children: <Widget>[
        if (!hasText) _notice(desktop),
        if (hasText)
          for (
            var offset = -(count ~/ 2);
            offset < count - count ~/ 2;
            offset++
          )
            if (_focus + offset >= 0 && _focus + offset < _lines.length)
              _row(_focus + offset, slot, inset),
      ],
    );
    final Widget content = desktop
        ? SizedBox.expand(
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[block, _desktopDragHandle(window.height)],
            ),
          )
        : SizedBox.expand(child: block);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: desktop
          ? content
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (DragStartDetails details) {
                unawaited(windowManager.startDragging());
              },
              child: content,
            ),
    );
  }

  Widget _row(int index, double slot, double inset) {
    final _LineMotion? motion = _motions[index];
    if (motion == null) return const SizedBox.shrink();
    final bool active = index == _focus;
    if (_lines[index].text.trim().isEmpty) {
      return _interludeRow(index, motion, slot, inset, active);
    }
    double emphasis() => ((motion.scale.value - 97) / 3).clamp(0.0, 1.0);
    final line = _lines[index];
    final Widget text = Semantics(
      container: true,
      excludeSemantics: true,
      label: lyricSemanticLabel(line),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          LyricLineContent(
            line: line,
            style: _lyricStyle,
            active: active,
            position: () =>
                Duration(microseconds: (_currentPositionMs * 1000).round()),
            repaint: _frames,
            emphasis: emphasis,
            maxLines: 1,
          ),
          if (line.translation != null) ...[
            const SizedBox(height: 5),
            Text(
              line.translation!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _lyricStyle.copyWith(
                fontSize: (_settings.fontSize * 16 / 22).clamp(12, 30),
                height: 1.45,
                color: Colors.white.withValues(alpha: .58),
              ),
            ),
          ],
        ],
      ),
    );
    final double activeY = _verticalPadding + (_settings.lineCount ~/ 2) * slot;
    return Positioned(
      key: ValueKey<int>(index),
      top: 0,
      left: inset,
      right: inset,
      height: slot,
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _frames,
          child: text,
          builder: (BuildContext context, Widget? child) {
            final double emphasis = ((motion.scale.value - 97) / 3).clamp(
              0.0,
              1.0,
            );
            final double opacity = 0.48 + 0.52 * emphasis;
            final double distance = ((motion.y.value - activeY).abs() / slot)
                .clamp(0.0, 6.0);
            final double sigma = _settings.blurEnabled
                ? (distance * 1.25 * _settings.blurIntensity).clamp(0.0, 6.0)
                : 0.0;
            return Transform.translate(
              offset: Offset(0, motion.y.value),
              child: ImageFiltered(
                enabled: sigma > .03,
                imageFilter: _blur(sigma),
                child: Opacity(
                  opacity: opacity,
                  child: RepaintBoundary(child: child!),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _interludeRow(
    int index,
    _LineMotion motion,
    double slot,
    double inset,
    bool active,
  ) {
    return Positioned(
      key: ValueKey<int>(index),
      top: 0,
      left: inset,
      right: inset,
      height: slot,
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _frames,
          child: LyricInterludeDots(
            line: _lines[index],
            position: () => Duration(milliseconds: _currentPositionMs.round()),
            repaint: _frames,
            diameter: _settings.fontSize * .3,
            presence: () => ((motion.scale.value - 97) / 3).clamp(0.0, 1.0),
          ),
          builder: (BuildContext context, Widget? child) {
            return Transform.translate(
              offset: Offset(0, motion.y.value),
              child: child,
            );
          },
        ),
      ),
    );
  }

  Widget _desktopDragHandle(double height) {
    return Positioned(
      left: 0,
      top: (height - _dragHandleHeight) / 2,
      width: _dragHandleWidth,
      height: _dragHandleHeight,
      child: MouseRegion(
        cursor: SystemMouseCursors.move,
        onEnter: (PointerEnterEvent event) {
          if (!_dragHovered) setState(() => _dragHovered = true);
        },
        onExit: (PointerExitEvent event) {
          if (_dragHovered) setState(() => _dragHovered = false);
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (DragStartDetails details) {
            unawaited(_startDesktopDrag());
          },
          child: AnimatedOpacity(
            opacity: _dragHovered ? 1 : .3,
            duration: MotionTiming.scale(const Duration(milliseconds: 140)),
            child: Center(
              child: Container(
                width: 4,
                height: 30,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .72),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _startDesktopDrag() async {
    try {
      await const MethodChannel(
        kDesktopLyricsChannel,
      ).invokeMethod<void>('startDesktopDrag');
    } catch (error) {
      AppLog.shared.record('desktop lyrics drag: $error');
    }
  }

  Widget _notice(bool desktop) {
    final payload = _payload;
    final String title = payload?.title ?? '';
    final String artist = payload?.artist ?? '';
    final String notice = payload?.notice ?? '';
    return Positioned.fill(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                title.isEmpty ? 'Lazer' : title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: _textStyle(.82).copyWith(fontWeight: FontWeight.w600),
              ),
              if (artist.isNotEmpty)
                Text(
                  artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: _textStyle(
                    .62,
                  ).copyWith(color: Colors.white.withValues(alpha: .72)),
                ),
              if (notice.isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  notice,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: _textStyle(
                    .58,
                  ).copyWith(color: Colors.white.withValues(alpha: .58)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _LineMotion {
  _LineMotion(double position, {required bool active})
    : y = LyricSpring(position),
      scale = LyricSpring(
        active ? 100 : 97,
        params: const LyricSpringParams(mass: 2, damping: 25, stiffness: 100),
      );

  final LyricSpring y;
  final LyricSpring scale;

  bool get arrived => y.arrived && scale.arrived;
}
