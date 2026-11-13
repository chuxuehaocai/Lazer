import '../state/build_safe_notifier.dart';
import '../widgets/build_safe_state.dart';
import '../animation/apple_spring.dart';
import '../widgets/spring_buttons.dart';
import 'package:lazer_nextgen/theme/app_palette.dart';
// SPDX-License-Identifier: AGPL-3.0-or-later
// Adapted lyric animation; reference: README.md. License: licenses/lyric_animation/AGPL-3.0.txt.
import '../l10n/app_localizations.dart';
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../animation/lyric_spring.dart';
import '../animation/motion_snapshot.dart';
import '../data/lyrics.dart';
import '../data/lyric_selection.dart';
import '../scrolling/scroll_motion.dart';
import '../state/app_state.dart';
import 'lyrics_import.dart';
import 'interlude.dart';
import '../widgets/lyric_selection_toolbar.dart';
import '../widgets/lyric_image_dialog.dart';
import '../widgets/lyric_edge_fade.dart';
import 'line_content.dart';
import '../widgets/lyric_text_hit_region.dart';
import '../theme/lazer_theme.dart';

/// children stay cached while the ticker only updates their transforms.
class LyricViewport extends StatefulWidget {
  const LyricViewport({
    super.key,
    required this.state,
    this.backdropKey,
    this.onSelectionChanged,
  });
  final AppState state;

  /// The live player backdrop boundary, captured when exporting an image.
  final GlobalKey? backdropKey;
  final ValueChanged<bool>? onSelectionChanged;

  @override
  State<LyricViewport> createState() => _LyricViewportState();
}

class _LyricViewportState extends State<LyricViewport>
    with
        TickerProviderStateMixin,
        WidgetsBindingObserver,
        BuildSafeState<LyricViewport> {
  Ticker? _ticker;
  late final AnimationController _blur = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
    value: widget.state.lyricBlurEnabled ? 1 : 0,
  );
  final ValueNotifier<int> _frames = BuildSafeValueNotifier(0);
  final ValueNotifier<int> _emphasisFrames = BuildSafeValueNotifier(0);
  final Stopwatch _wall = Stopwatch()..start();
  List<LyricLine> _lines = [];
  List<LyricLine>? _sourceLines;
  Duration? _timelineDuration;
  List<double> _baseHeights = [];
  List<double> _interludePresence = [];
  List<Duration?> _retainedInterludePositions = [];
  bool _hasWordTimings = false;
  List<LyricSpring> _ys = [];
  List<LyricSpring> _scales = [];
  List<double> _heights = [];
  List<double> _prefix = [];
  double _rowUnit = 0;
  final Map<int, Widget> _rowCache = <int, Widget>{};
  List<ValueNotifier<int>> _rowFrames = const <ValueNotifier<int>>[];
  Size _size = Size.zero;
  double get _gutter =>
      math.min(LyricEdgeFade.horizontalExtent, _size.width * 0.1);
  double get _textWidth => math.max(1.0, _size.width - _gutter * 2);
  TextScaler? _textScaler;
  double? _fontSize;
  int? _fontWeight;
  (TextStyle, TextStyle)? _typography;
  int _active = -1;
  bool _playing = false;
  bool _manual = false;
  bool _dragging = false;
  int? _middlePointer;
  double _offset = 0;
  double _velocity = 0;
  ClampingScrollSimulation? _coast;
  double _coastTime = 0;
  Duration _lastFrame = Duration.zero;
  Duration _paintPosition = Duration.zero;
  Duration? _lastLanePosition;
  Duration? _lastMedia;
  int _lastWall = 0;
  Timer? _resume;
  double _dragCarry = 0;
  LyricSelection _selection = const LyricSelection();
  bool _copied = false;
  Timer? _copiedTimer;
  int _selectionRevision = 0;
  String? _trackId;
  int _dragArmedAt = -1000;
  bool _extendingSelection = false;
  final GlobalKey _viewportKey = GlobalKey();
  late double _blurTarget = widget.state.lyricBlurEnabled ? 1 : 0;
  late double _blurIntensity = widget.state.lyricBlurIntensity.clamp(0.0, 1.0);

  @override
  void initState() {
    super.initState();
    _trackId = widget.state.current?.id;
    widget.state.all.addListener(_onLane);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _resume?.cancel();
    _dragging = false;
    _middlePointer = null;
    _velocity = 0;
    _coast = null;
    _lastMedia = null;
    _manual = _selection.active;
    _onLane();
    if (!identical(_sourceLines, widget.state.lyrics) || _lines.isEmpty) return;
    // Discard pre-background spring trajectories instead of replaying them.
    _targets(seeking: true, stagger: false);
    if (!_manual) {
      for (final spring in [..._ys, ..._scales]) {
        spring.setPosition(spring.target);
      }
    }
    _frames.value++;
    _emphasisFrames.value++;
    if (_active >= 0 && _active < _rowFrames.length) {
      _rowFrames[_active].value++;
    }
    _updateBlur();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ticker ??= createTicker(_tick);
    MotionSnapshot.invalidate(context);
  }

  @override
  void didUpdateWidget(covariant LyricViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.all.removeListener(_onLane);
      widget.state.all.addListener(_onLane);
      _blurIntensity = widget.state.lyricBlurIntensity.clamp(0.0, 1.0);
    }
    _updateBlur();
  }

  void _followLine(Duration position) {
    if (!mounted ||
        !identical(_sourceLines, widget.state.lyrics) ||
        _lines.isEmpty) {
      return;
    }
    final active = _activeAt(position);
    if (active <= _active) return;
    setState(() {
      _rowCache.remove(_active);
      _rowCache.remove(active);
      _active = active;
      if (_manual) {
        _scaleTargets();
      } else {
        _targets();
      }
    });
  }

  int _activeAt(Duration position) {
    final lines = _lines;
    var low = 0;
    var high = lines.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (lines[middle].time <= position) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low - 1;
  }

  bool _isSeek() {
    final media = widget.state.position;
    final now = _wall.elapsedMilliseconds;
    final old = _lastMedia;
    final wallDelta = (now - _lastWall).clamp(0, 800);
    _lastMedia = media;
    _lastWall = now;
    if (old == null) return false;
    final delta = (media - old).inMilliseconds;
    return delta < -150 ||
        delta - (widget.state.playing ? wallDelta : 0) >
            (widget.state.playing ? math.max(150, wallDelta * 0.5) : 150);
  }

  void _onLane() {
    if (!mounted) return;
    _paintPosition = widget.state.precisePosition;
    final candidate = _activeAt(_paintPosition);
    final seeking = _isSeek();
    final active = widget.state.playing && !seeking && candidate < _active
        ? _active
        : candidate;
    final changed =
        !identical(_sourceLines, widget.state.lyrics) ||
        _timelineDuration != widget.state.current?.duration;
    final typographyChanged =
        _fontSize != widget.state.lyricFontSize ||
        _fontWeight != widget.state.lyricFontWeight;
    if (_trackId != widget.state.current?.id) {
      _trackId = widget.state.current?.id;
      if (_selection.active) {
        _changeSelection(const LyricSelection(), resume: false);
      }
    }
    if (changed) {
      _resume?.cancel();
      if (_selection.active) {
        final available = {
          for (final line in widget.state.lyrics) ?lyricSelectionKey(line),
        };
        final retained = _selection.keys.intersection(available);
        _changeSelection(
          retained.isEmpty
              ? const LyricSelection()
              : LyricSelection(
                  anchor: retained.contains(_selection.anchor)
                      ? _selection.anchor
                      : retained.first,
                  keys: retained,
                ),
          resume: false,
        );
      }
      _manual = _selection.active;
      _velocity = 0;
    }
    if (changed || typographyChanged || active != _active) {
      setState(() {
        if (changed || typographyChanged) {
          _rowCache.clear();
        } else {
          _rowCache.remove(_active);
          _rowCache.remove(active);
        }
        _active = active;
        if (!changed && !_manual) {
          _targets(seeking: seeking);
        } else {
          _scaleTargets();
        }
      });
      MotionSnapshot.invalidate(context);
    }
    if (_playing != widget.state.playing) {
      _playing = widget.state.playing;
      // Resuming mid-song must restart word animation even though no spring
      // is retargeted; the old code got this (and a full stagger restart) by
      // retargeting every row on the play-state change.
      if (_playing && (_hasWordTimings || _activeInterlude)) _start();
    }
    // Only a paused seek changes the word mask without a running ticker. A
    // playback tick (10 Hz) must not repaint every mounted row.
    final Duration precise = _paintPosition;
    if ((_hasWordTimings || _activeInterlude) &&
        !widget.state.playing &&
        precise != _lastLanePosition) {
      if (_active >= 0 && _active < _rowFrames.length) {
        _rowFrames[_active].value++;
      }
    }
    _lastLanePosition = precise;
    // The intensity slider lives on another page; repaint the rows now so the
    // new strength applies without waiting for the next animation frame.
    final double intensity = widget.state.lyricBlurIntensity.clamp(0.0, 1.0);
    if (_blurIntensity != intensity) {
      _blurIntensity = intensity;
      _frames.value++;
    }
    _updateBlur();
  }

  void _updateBlur() {
    final target = widget.state.lyricBlurEnabled && !_manual ? 1.0 : 0.0;
    if (_blurTarget != target) {
      _blurTarget = target;
      _blur.animateTo(target, curve: const AppleSpringCurve());
    }
  }

  /// Blur tracks how far a row sits from the focus band instead of its index
  /// gap, so it ramps in and out as rows travel rather than snapping to zero
  /// the instant a line becomes active.
  double _sigma(int i) {
    if (_rowUnit <= 0 || _blur.value <= 0) return 0;
    final centre = _ys[i].value + _heights[i] * 0.5;
    final distance = (centre - _size.height * 0.35).abs() / _rowUnit;
    return math.min(5.0, distance * 1.55) * _blur.value * _blurIntensity;
  }

  /// Dissolves rows into the viewport edges so the clip never slices a blurred
  /// line clean in half.
  Widget _edgeFade(Widget child) => LyricEdgeFade(
    verticalExtent: math.min(
      _size.height * 0.22,
      math.max(28.0, _rowUnit * 1.15),
    ),
    // The desktop canvas is wide enough for its 18 px gutter to contain the
    // blur halo, so skipping the horizontal offscreen pass saves one
    // full-pane blend per frame without changing what is visible.
    horizontal: _size.width < 520,
    child: child,
  );

  void _start() {
    final Ticker? ticker = _ticker;
    // Any new velocity (drag release, wheel impulse) starts a fresh glide
    // rather than continuing the previous spline's clock.
    _coast = null;
    _coastTime = 0;
    if (ticker != null && !ticker.isActive) {
      _lastFrame = Duration.zero;
      ticker.start();
    }
  }

  bool get _activeInterlude =>
      _active >= 0 &&
      _active < _lines.length &&
      _lines[_active].text.trim().isEmpty &&
      _paintPosition < (_lines[_active].end ?? Duration.zero);

  double _presence(int index) => _lines[index].text.trim().isEmpty
      ? Curves.fastOutSlowIn.transform(_interludePresence[index])
      : 1;

  Duration _interludePosition(int index) {
    final end = _lines[index].end ?? _lines[index].time;
    if (_paintPosition < end) {
      _retainedInterludePositions[index] = _paintPosition;
    }
    return _paintPosition < end
        ? _paintPosition
        : (_retainedInterludePositions[index] ?? end);
  }

  void _rebuildPrefixes() {
    var sum = 0.0;
    _heights = [
      for (var i = 0; i < _baseHeights.length; i++)
        _baseHeights[i] * _presence(i),
    ];
    _prefix = [
      for (final height in _heights)
        (() {
          final y = sum;
          sum += height;
          return y;
        })(),
    ];
    final ordinaryHeights = [
      for (var i = 0; i < _baseHeights.length; i++)
        if (_lines[i].text.trim().isNotEmpty) _baseHeights[i],
    ];
    _rowUnit = ordinaryHeights.isEmpty
        ? 0
        : ordinaryHeights.reduce((a, b) => a + b) / ordinaryHeights.length;
  }

  void _tick(Duration elapsed) {
    // Every vsync updates the lyric springs. The old 16 ms gate turned a
    // 100 Hz panel into 50 lyric updates per second (and 80 Hz into 40), so
    // the animation could never reach the requested 80 fps even when the UI
    // thread had headroom.
    final dt = ((elapsed - _lastFrame).inMicroseconds / 1e6).clamp(0.0, 0.1);
    _lastFrame = elapsed;
    // Native audio reads its snapshot over FFI. Sample the playhead once for
    // this frame so focus detection and every exiting/active word row agree,
    // rather than fetching another native snapshot from each painter.
    _paintPosition = widget.state.precisePosition;
    if (widget.state.playing) _followLine(_paintPosition);
    var interludesMoving = false;
    var presenceChanged = false;
    for (var i = 0; i < _interludePresence.length; i++) {
      if (_lines[i].text.trim().isNotEmpty) continue;
      final target = i == _active && _activeInterlude ? 1.0 : 0.0;
      final old = _interludePresence[i];
      final next = MediaQuery.disableAnimationsOf(context)
          ? target
          : target > old
          ? math.min(target, old + dt / .36)
          : math.max(target, old - dt / .56);
      _interludePresence[i] = next;
      presenceChanged = presenceChanged || next != old;
      interludesMoving = interludesMoving || next != target;
      if (next != old || next > 0 && widget.state.playing) {
        _rowFrames[i].value++;
      }
    }
    if (presenceChanged) {
      _rebuildPrefixes();
      if (_manual) {
        _setOffset(_offset);
      } else {
        _targets(stagger: false);
      }
    }
    if (_manual && !_dragging && _velocity.abs() > 5 && dt > 0) {
      final previous = _offset;
      if (ScrollMotion.isNative(
        retention: widget.state.scrollRetention,
        acceleration: widget.state.scrollAcceleration,
      )) {
        // At the default pair the manual glide must match a stock Flutter
        // fling, so advance the framework's own spline instead of the
        // exponential coast the inertia sliders describe.
        final ClampingScrollSimulation coast = _coast ??=
            ClampingScrollSimulation(position: _offset, velocity: _velocity);
        _coastTime += dt;
        _setOffset(coast.x(_coastTime));
        _velocity = coast.dx(_coastTime);
        if (coast.isDone(_coastTime)) _velocity = 0;
      } else {
        _coast = null;
        _coastTime = 0;
        _setOffset(_offset + _velocity * dt);
        _velocity *= math.pow(widget.state.scrollRetention, dt * 60);
      }
      if (_offset == previous) _velocity = 0;
    }
    // `_lines`, `_hasWordTimings` and the row springs still describe the
    // previous song while this one is loading or has no lyrics at all, because
    // `build` short-circuits before `_layout` can refresh them. Without this
    // test the engine keeps a full-rate ticker -- and a native playhead read
    // every frame -- for the whole track while the pane only shows a spinner or
    // "纯音乐".
    final bool sheetIsLive =
        widget.state.lyrics.isNotEmpty &&
        identical(_sourceLines, widget.state.lyrics);
    var moving =
        (_manual && _velocity.abs() > 5) ||
        (sheetIsLive &&
            widget.state.playing &&
            (_hasWordTimings || _activeInterlude)) ||
        (sheetIsLive && interludesMoving);
    var positionsChanged = presenceChanged;
    var emphasisChanged = false;
    for (var i = 0; i < _ys.length; i++) {
      final double y = _ys[i].value;
      final double scale = _scales[i].value;
      _ys[i].update(dt);
      _scales[i].update(dt);
      positionsChanged =
          positionsChanged || y != _ys[i].value || scale != _scales[i].value;
      emphasisChanged = emphasisChanged || scale != _scales[i].value;
      moving = moving || !_ys[i].arrived || !_scales[i].arrived;
    }
    // Only the active word row needs a paint every frame; a row whose scale
    // is still easing needs one for its colour fade. Everything else stays
    // behind its RepaintBoundary even though the outer stack keeps moving.
    final bool wordFrame = widget.state.playing && _hasWordTimings;
    for (var i = 0; i < _rowFrames.length && i < _scales.length; i++) {
      if (wordFrame && i == _active || !_scales[i].arrived) {
        _rowFrames[i].value++;
      }
    }
    // Word highlights repaint their own boundary. Once positions settle,
    // rebuilding the whole stack every vsync adds layout and semantics work
    // without changing the geometry.
    if (positionsChanged) _frames.value++;
    if (emphasisChanged) _emphasisFrames.value++;
    if (!moving) _ticker?.stop();
  }

  void _scaleTargets() {
    for (var i = 0; i < _scales.length; i++) {
      _scales[i].setTarget(
        i == _active ? 100 : 100 - _theme.lyricFocusScaleDelta,
      );
    }
    if (_scales.isNotEmpty) _start();
  }

  void _targets({bool seeking = false, bool stagger = true}) {
    if (_ys.isEmpty || _size.height <= 0 || _manual) return;
    final focus = _active.clamp(0, _lines.length - 1);
    final anchor = _prefix[focus] - _size.height * 0.35 + _heights[focus] / 2;
    final positions = [
      for (var i = 0; i < _lines.length; i++)
        _prefix[i] - anchor + (_heights[i] - _baseHeights[i]) / 2,
    ];
    // The first and last line have no neighbouring interval, and the upstream
    // policy gives them a soft under-damped spring. On a long sheet every row
    // then kept oscillating at the edges and the 60 fps ticker never settled.
    // Use the same damped baseline as the middle transitions instead; seeking
    // keeps its intentionally soft animation.
    final bool atEdge = focus == 0 || focus == _lines.length - 1;
    final params = !seeking && atEdge
        ? LyricSpringParams(
            mass: .9 * _theme.lyricSpringMassScale,
            stiffness: 170 * _theme.lyricSpringStiffnessScale,
            damping: 29 * _theme.lyricSpringDampingScale,
          )
        : lyricPositionPolicy(
            seeking: seeking,
            interlude: _activeInterlude,
            intervalMs: focus > 0
                ? (_lines[focus].time - _lines[focus - 1].time).inMilliseconds
                : null,
            endOfSong:
                widget.state.position >=
                (widget.state.current?.duration ?? const Duration(days: 1)),
            massScale: _theme.lyricSpringMassScale,
            stiffnessScale: _theme.lyricSpringStiffnessScale,
            dampingScale: _theme.lyricSpringDampingScale,
          );
    final delays = lyricStaggerDelays(
      positions,
      _heights,
      focus,
      disabled: seeking || !stagger,
      baseDelay: _theme.lyricStaggerDelay,
      decay: _theme.lyricStaggerDecay,
    );
    for (var i = 0; i < _ys.length; i++) {
      _ys[i].setParameters(params);
      // Rows that are nowhere near the viewport do not need a spring or a
      // stagger delay: put them at their new position immediately. This is
      // what keeps the opening and closing seconds of a long lyric sheet from
      // animating hundreds of invisible rows.
      final double target = positions[i];
      final bool nearViewport =
          target + _heights[i] >= -_size.height * 0.5 &&
          target <= _size.height * 1.5;
      if (nearViewport) {
        _ys[i].setTarget(target, delay: delays[i]);
      } else {
        _ys[i].setPosition(target);
      }
    }
    _scaleTargets();
    _start();
  }

  LazerThemeTokens get _theme => LazerThemeTokens.of(context);
  TextStyle get _originalStyle => lyricTextStyle(
    context.type.bodySm,
    widget.state.lyricFontSize * _theme.lyricFontScale,
    widget.state.lyricFontWeight,
    theme: _theme,
  );
  TextStyle get _translationStyle => lyricTextStyle(
    context.type.bodySm,
    (widget.state.lyricFontSize * _theme.lyricTranslationScale).clamp(12, 30),
    widget.state.lyricFontWeight,
    theme: _theme,
    translation: true,
  );
  List<double> _measureHeights(TextScaler scaler) {
    final originalStyle = _originalStyle;
    final translationStyle = _translationStyle;
    final originalHeights = <String, double>{};
    final translationHeights = <String, double>{};
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    );
    double measure(String text, TextStyle style, Map<String, double> heights) =>
        heights.putIfAbsent(text, () {
          painter.text = TextSpan(
            text: text.isEmpty ? ' ' : text,
            style: style,
          );
          painter.layout(maxWidth: _textWidth);
          return painter.height;
        });
    try {
      // Repeated choruses share heights for this width and typography. Keep
      // only scalar results during measurement; no paragraphs are retained.
      return [
        for (final line in _lines)
          line.text.trim().isEmpty
              ? 72
              : measure(line.text, originalStyle, originalHeights) +
                    (line.translation == null
                        ? 0
                        : _theme.lyricTranslationGap +
                              measure(
                                line.translation!,
                                translationStyle,
                                translationHeights,
                              )) +
                    widget.state.lyricLineSpacing,
      ];
    } finally {
      painter.dispose();
    }
  }

  void _layout(Size size, TextScaler scaler) {
    final firstLayout = _ys.isEmpty;
    final replaced =
        !identical(_sourceLines, widget.state.lyrics) ||
        _timelineDuration != widget.state.current?.duration;
    final typography = (_originalStyle, _translationStyle);
    final typographyChanged =
        _fontSize != widget.state.lyricFontSize ||
        _fontWeight != widget.state.lyricFontWeight ||
        _typography != typography;
    if (!replaced &&
        !typographyChanged &&
        size == _size &&
        scaler == _textScaler) {
      return;
    }
    final needsMeasure =
        replaced ||
        typographyChanged ||
        size.width != _size.width ||
        scaler != _textScaler;
    _size = size;
    _textScaler = scaler;
    _fontSize = widget.state.lyricFontSize;
    _fontWeight = widget.state.lyricFontWeight;
    _typography = typography;
    if (replaced) {
      _sourceLines = widget.state.lyrics;
      _timelineDuration = widget.state.current?.duration;
      _lines = lyricsWithInterludes(
        widget.state.lyrics,
        widget.state.current?.duration ?? Duration.zero,
      );
      _interludePresence = [for (final _ in _lines) 0];
      _retainedInterludePositions = [for (final _ in _lines) null];
    }
    _hasWordTimings = _lines.any((line) => line.words.isNotEmpty);
    _paintPosition = widget.state.precisePosition;
    _active = _activeAt(_paintPosition);
    if (needsMeasure) {
      _baseHeights = _measureHeights(scaler);
      _rebuildPrefixes();
      _rowCache.clear();
    }
    if (replaced) {
      _ys = [
        // The first reveal used to start two screens below the viewport; the
        // whole sheet then travelled that distance on the soft edge spring.
        // A shorter runway keeps the opening frame cheap and still reads as a
        // reveal.
        for (var i = 0; i < _lines.length; i++) LyricSpring(size.height * .7),
      ];
      _scales = [
        for (var i = 0; i < _lines.length; i++)
          LyricSpring(
            i == _active ? 100 : 97,
            params: const LyricSpringParams(
              mass: 2,
              damping: 25,
              stiffness: 100,
            ),
          ),
      ];
      for (final notifier in _rowFrames) {
        notifier.dispose();
      }
      // These listeners only repaint word/interlude CustomPainters. Keep them
      // synchronous; the widget-building frame lanes above are build safe.
      _rowFrames = [
        for (var i = 0; i < _lines.length; i++) ValueNotifier<int>(0),
      ];
      _manual = _selection.active;
    }
    if (_manual) {
      _setOffset(_offset);
    } else {
      _targets(stagger: false);
      if (firstLayout) {
        // The page already animates in. Start the sheet at its actual focus
        // instead of holding overlapping rows below it until tickers resume.
        for (final spring in _ys) {
          spring.setPosition(spring.target);
        }
      }
    }
  }

  void _beginManual({bool stopMomentum = true}) {
    _resume?.cancel();
    if (stopMomentum) _velocity = 0;
    if (_manual || _ys.isEmpty) return;
    final focus = _active.clamp(0, _lines.length - 1);
    _offset =
        _prefix[focus] +
        (_heights[focus] - _baseHeights[focus]) / 2 -
        _ys[focus].value;
    _manual = true;
    _updateBlur();
    _frames.value++;
  }

  void _setOffset(double value) {
    if (_ys.isEmpty) return;
    final min = -_size.height * 0.35 + _heights.first / 2;
    final max = math.max(
      min,
      _prefix.last - _size.height * 0.35 + _heights.last / 2,
    );
    _offset = value.clamp(min, max);
    for (var i = 0; i < _ys.length; i++) {
      _ys[i].setPosition(
        _prefix[i] - _offset + (_heights[i] - _baseHeights[i]) / 2,
      );
    }
    _frames.value++;
  }

  void _scheduleResume() {
    _resume?.cancel();
    if (_selection.active) return;
    _resume = Timer(
      Duration(milliseconds: (widget.state.lyricResumeSeconds * 1000).round()),
      () {
        if (!mounted || _dragging) return;
        _manual = _selection.active;
        _velocity = 0;
        _targets(seeking: true);
        _updateBlur();
      },
    );
  }

  void _wheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        _ys.isEmpty ||
        event.scrollDelta.dy == 0) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      _beginManual(stopMomentum: false);
      _velocity = ScrollMotion.addWheelImpulse(
        _velocity,
        event.scrollDelta.dy,
        acceleration: widget.state.scrollAcceleration,
      );
      _start();
      _scheduleResume();
    });
  }

  void _seek(int index) {
    final duration = widget.state.current?.duration.inMilliseconds ?? 0;
    if (duration <= 0) return;
    _resume?.cancel();
    _manual = false;
    _velocity = 0;
    widget.state.seek(_lines[index].time.inMilliseconds / duration);
    _targets(seeking: true);
    _updateBlur();
  }

  void _tapLine(int index) {
    unawaited(widget.state.feedback());
    _seek(index);
  }

  void _changeSelection(LyricSelection next, {bool resume = true}) {
    final changed = _selection.active != next.active;
    setState(() {
      _selection = next;
      _selectionRevision++;
      _copied = false;
      _rowCache.clear();
    });
    _copiedTimer?.cancel();
    if (changed) widget.onSelectionChanged?.call(next.active);
    if (!next.active && resume) _scheduleResume();
  }

  void _selectLyrics(int index) {
    if (lyricSelectionKey(_lines[index]) == null) return;
    unawaited(widget.state.feedback());
    _beginManual();
    // Freeze every row at its painted position, including unfinished springs.
    for (final spring in _ys) {
      spring.setPosition(spring.value);
    }
    _resume?.cancel();
    _dragArmedAt = _wall.elapsedMilliseconds;
    _changeSelection(
      _selection.active
          ? _selection.extend(_lines, index)
          : _selection.begin(_lines, index),
    );
  }

  void _extendSelection(Offset globalPosition) {
    final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || _lines.isEmpty) return;
    final y = box.globalToLocal(globalPosition).dy;
    var nearest = -1;
    var distance = double.infinity;
    for (var i = 0; i < _lines.length; i++) {
      if (lyricSelectionKey(_lines[i]) == null) continue;
      final delta = (_ys[i].value + _heights[i] / 2 - y).abs();
      if (delta < distance) {
        distance = delta;
        nearest = i;
      }
    }
    if (nearest >= 0) _changeSelection(_selection.extend(_lines, nearest));
  }

  Future<void> _copyLyrics() async {
    final revision = _selectionRevision;
    await Clipboard.setData(ClipboardData(text: _selection.text(_lines)));
    if (!mounted || revision != _selectionRevision) return;
    setState(() => _copied = true);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Future<void> _createImage() async {
    final track = widget.state.current;
    if (track == null) return;
    final selected = [
      for (final line in _lines)
        if (_selection.keys.contains(lyricSelectionKey(line))) line,
    ];
    if (selected.isEmpty) return;
    final backdrop = await captureLyricBackdrop(widget.backdropKey);
    if (!mounted) {
      backdrop?.dispose();
      return;
    }
    await showLyricImageDialog(
      context,
      track: track,
      lines: selected,
      background: backdrop,
    );
  }

  Widget _interactiveText(
    int index,
    String text,
    TextStyle style,
    Widget child,
  ) => LyricTextHitRegion(
    text: text,
    style: style,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _selection.active
          ? _changeSelection(_selection.toggle(_lines, index))
          : _tapLine(index),
      onLongPress: () => _selectLyrics(index),
      onLongPressMoveUpdate: (event) => _extendSelection(event.globalPosition),
      onLongPressEnd: (_) => _dragArmedAt = _wall.elapsedMilliseconds,
      child: child,
    ),
  );

  /// Builds a row lazily and keeps it across frames; only viewport rows are
  /// ever constructed, so a 1,000-line sheet no longer allocates 1,000 row
  /// widgets every time the active line changes.
  Widget _cachedRow(int index) => _rowCache[index] ??= _row(index);

  Widget _row(int index) => Semantics(
    // One stable accessibility node per line, independent of word masks,
    // opacity layers and translations entering/leaving the paint subtree.
    container: true,
    excludeSemantics: true,
    label: _lines[index].text.trim().isEmpty
        ? context.tr('间奏')
        : lyricSemanticLabel(_lines[index]),
    onTap: _lines[index].text.trim().isEmpty
        ? null
        : () => _selection.active
              ? _changeSelection(_selection.toggle(_lines, index))
              : _tapLine(index),
    onLongPress: _lines[index].text.trim().isEmpty
        ? null
        : () => _selectLyrics(index),
    selected: _selection.active
        ? _selection.keys.contains(lyricSelectionKey(_lines[index]))
        : null,
    child: TweenAnimationBuilder<double>(
      tween: Tween(
        end: _selection.keys.contains(lyricSelectionKey(_lines[index])) ? 1 : 0,
      ),
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : AppleSpring.responsive.duration,
      curve: const AppleSpringCurve(),
      builder: (context, selected, _) => AnimatedOpacity(
        curve: const AppleSpringCurve(),
        opacity: _selection.active ? 0.54 + selected * 0.46 : 1,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : AppleSpring.responsive.duration,
        child: _rowBody(index, selected),
      ),
    ),
  );

  Widget _rowBody(int index, double selected) {
    final focused = index == _active;
    final Listenable rowFrames = index < _rowFrames.length
        ? _rowFrames[index]
        : _frames;
    if (_lines[index].text.trim().isEmpty) {
      return SizedBox(
        width: _textWidth,
        height: _baseHeights[index],
        child: LyricInterludeDots(
          line: _lines[index],
          position: () => _interludePosition(index),
          presence: () => _presence(index),
          repaint: rowFrames,
          diameter: widget.state.lyricFontSize * _theme.lyricFontScale * .3,
        ),
      );
    }
    double emphasis() =>
        ((_scales[index].value - (100 - _theme.lyricFocusScaleDelta)) /
                _theme.lyricFocusScaleDelta)
            .clamp(0.0, 1.0);
    double mainAlpha() =>
        _theme.lyricDimAlpha + emphasis() * (1 - _theme.lyricDimAlpha);
    final style = _originalStyle.copyWith(color: Colors.white);
    return SizedBox(
      width: _textWidth,
      height: _baseHeights[index],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedBuilder(
            animation: _emphasisFrames,
            builder: (context, child) => ColorFiltered(
              key: ValueKey('lyric-color-$index'),
              colorFilter: ColorFilter.mode(
                Color.lerp(
                  Colors.white.withValues(alpha: mainAlpha()),
                  Colors.white,
                  selected,
                )!,
                BlendMode.srcIn,
              ),
              child: child,
            ),
            child: _interactiveText(
              index,
              _lines[index].text,
              style,
              LyricLineContent(
                line: _lines[index],
                style: style,
                active: focused,
                emphasis: emphasis,
                position: () => _paintPosition,
                repaint: rowFrames,
              ),
            ),
          ),
          if (_lines[index].translation != null) ...[
            SizedBox(height: _theme.lyricTranslationGap),
            AnimatedBuilder(
              animation: _emphasisFrames,
              builder: (context, child) => ColorFiltered(
                colorFilter: ColorFilter.mode(
                  Colors.white.withValues(
                    alpha: mainAlpha() * _theme.lyricTranslationAlpha,
                  ),
                  BlendMode.srcIn,
                ),
                child: child,
              ),
              child: _interactiveText(
                index,
                _lines[index].translation!,
                _translationStyle,
                Text(
                  _lines[index].translation!,
                  textAlign: TextAlign.left,
                  textDirection: TextDirection.ltr,
                  style: _translationStyle,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// One mounted lyric row. The index-only key keeps the element (and its
  /// painted layer) alive when the next song's lyrics arrive, instead of
  /// tearing the whole sheet down and measuring every line again.
  Widget _positionedRow(int index) {
    final double sigma = _sigma(index);
    return Positioned(
      key: ValueKey('lyric-line-$index'),
      top: 0,
      left: _gutter,
      width: _textWidth,
      height: _baseHeights[index],
      child: Transform.translate(
        offset: Offset(0, _ys[index].value),
        child: ImageFiltered(
          key: ValueKey('lyric-blur-$index'),
          enabled: sigma > 0.02,
          imageFilter: _blurFilter(sigma),
          // Every row gets its own layer: a per-word row otherwise repaints
          // the whole lyric stack on each of its animation frames.
          child: RepaintBoundary(child: _cachedRow(index)),
        ),
      ),
    );
  }

  /// Blur sigmas are quantized so neighbouring frames reuse one filter object
  /// instead of allocating and reconfiguring an `ImageFilter` per row.
  static final Map<int, ui.ImageFilter> _blurFilters = <int, ui.ImageFilter>{};

  static ui.ImageFilter _blurFilter(double sigma) {
    final int step = (sigma * 8).round();
    return _blurFilters[step] ??= ui.ImageFilter.blur(
      sigmaX: step / 8,
      sigmaY: step / 8,
    );
  }

  Widget _positionedRows() {
    final visible = <int>{
      for (var i = 0; i < _lines.length; i++)
        if ((_lines[i].text.trim().isNotEmpty || _presence(i) > 0) &&
            _ys[i].value + _baseHeights[i] >= -80 &&
            _ys[i].value <= _size.height + 80)
          i,
    };
    // Manual browsing may visit an entire long transcript without changing
    // the playback line. Retain widgets only for rows that are still mounted.
    _rowCache.removeWhere((index, _) => !visible.contains(index));
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [for (final index in visible) _positionedRow(index)],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.state.lyricsLoading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (widget.state.lyrics.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TrText(
              widget.state.lyricsError ??
                  (widget.state.lyricsPureMusic ? '纯音乐' : '这首歌暂未提供歌词'),
              style: context.type.captionMuted,
            ),
            if (!widget.state.lyricsPureMusic)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  SpringTextButton(
                    onPressed: () => unawaited(
                      widget.state.ensureCurrentLyrics(force: true),
                    ),
                    child: const TrText('重新加载歌词'),
                  ),
                  SpringTextButton(
                    key: const ValueKey<String>('import-lyrics'),
                    onPressed: () =>
                        unawaited(pickAndImportLyrics(context, widget.state)),
                    child: const TrText('导入歌词'),
                  ),
                ],
              ),
          ],
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        if (!box.hasBoundedHeight ||
            !box.hasBoundedWidth ||
            box.maxHeight <= 0 ||
            box.maxWidth <= 0) {
          return const SizedBox.shrink();
        }
        _layout(
          Size(box.maxWidth, box.maxHeight),
          MediaQuery.textScalerOf(context),
        );
        return PopScope<void>(
          canPop: !_selection.active,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop && _selection.active) {
              _changeSelection(const LyricSelection());
            }
          },
          child: Stack(
            key: _viewportKey,
            fit: StackFit.expand,
            children: [
              Listener(
                onPointerSignal: _wheel,
                onPointerDown: (event) {
                  if (event.buttons & kMiddleMouseButton != 0) {
                    _middlePointer = event.pointer;
                    _dragging = true;
                    _beginManual();
                  }
                },
                onPointerMove: (event) {
                  if (event.pointer == _middlePointer) {
                    _setOffset(_offset - event.delta.dy);
                  }
                },
                onPointerUp: (event) {
                  if (event.pointer == _middlePointer) {
                    _middlePointer = null;
                    _dragging = false;
                    _scheduleResume();
                  }
                },
                onPointerCancel: (event) {
                  if (event.pointer == _middlePointer) {
                    _middlePointer = null;
                    _dragging = false;
                    _scheduleResume();
                  }
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragStart: (_) {
                    _extendingSelection =
                        _selection.active &&
                        _wall.elapsedMilliseconds - _dragArmedAt < 900;
                    if (_extendingSelection) return;
                    _dragging = true;
                    _dragCarry = _velocity;
                    _beginManual();
                  },
                  onVerticalDragUpdate: (event) => _extendingSelection
                      ? _extendSelection(event.globalPosition)
                      : _setOffset(_offset - event.delta.dy),
                  onVerticalDragEnd: (event) {
                    if (_extendingSelection) {
                      _extendingSelection = false;
                      return;
                    }
                    _dragging = false;
                    final released = -event.velocity.pixelsPerSecond.dy;
                    _velocity =
                        released +
                        (released.sign == _dragCarry.sign
                            ? ScrollMotion.carriedVelocity(
                                _dragCarry,
                                retention: widget.state.scrollRetention,
                                acceleration: widget.state.scrollAcceleration,
                              )
                            : 0);
                    _dragCarry = 0;
                    _start();
                    _scheduleResume();
                  },
                  onVerticalDragCancel: () {
                    _extendingSelection = false;
                    _dragCarry = 0;
                    _dragging = false;
                    _scheduleResume();
                  },
                  // The edge mask is built once per layout change, not once
                  // per animation frame: rebuilding the double ShaderMask at
                  // 60 fps reconfigured a full-pane offscreen layer each frame.
                  child: _edgeFade(
                    AnimatedBuilder(
                      key: const ValueKey<String>('lyric-position-stack'),
                      animation: Listenable.merge([_frames, _blur]),
                      builder: (context, _) => _positionedRows(),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: AnimatedSwitcher(
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : AppleSpring.responsive.duration,
                      switchInCurve: const AppleSpringCurve(),
                      switchOutCurve: const AppleSpringCurve(),
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween(
                            begin: const Offset(0, .35),
                            end: Offset.zero,
                          ).animate(animation),
                          child: child,
                        ),
                      ),
                      child: _selection.active
                          ? LyricSelectionToolbar(
                              key: const ValueKey('lyric-selection-toolbar'),
                              count: _selection.keys.length,
                              copied: _copied,
                              onSelectAll: () =>
                                  _changeSelection(_selection.all(_lines)),
                              onCopy: () => unawaited(_copyLyrics()),
                              onCreateImage: () => unawaited(_createImage()),
                              onClose: () =>
                                  _changeSelection(const LyricSelection()),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _resume?.cancel();
    for (final notifier in _rowFrames) {
      notifier.dispose();
    }
    _copiedTimer?.cancel();
    widget.state.all.removeListener(_onLane);
    _ticker?.dispose();
    _blur.dispose();
    _frames.dispose();
    _emphasisFrames.dispose();
    super.dispose();
  }
}
