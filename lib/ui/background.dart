import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../cache/media_cache.dart';
import '../data/models.dart';
import '../state/ui_preferences.dart';
import '../utils/artwork.dart';
import '../theme/tokens.dart';
import '../theme/adaptive_contrast.dart';

export '../player/player_backdrop.dart' show AlbumBlurFlow;

/// Every flow surface uses these motion and palette constants.
const albumFlowConfiguration = AlbumFlowConfiguration();

class AlbumFlowConfiguration {
  const AlbumFlowConfiguration();
  Duration get paletteTransition => const Duration(milliseconds: 650);
  int get paletteCacheEntries => 24;
  int get paletteImageEdge => 96;
  int get meshCacheEntries => 4;
  int get frameCacheEntries => 8;
}

/// One clock preserves the flow phase when switching between browsing and the
/// player. Hidden, static and paused surfaces detach and consume no frames.
final albumFlowClock = _AlbumFlowClock();

class _AlbumFlowClock extends ChangeNotifier {
  late final _AlbumFlowTicker _ticker = _AlbumFlowTicker(_advance);
  final Map<VoidCallback, Duration> _subscribers = {};
  Duration _completed = Duration.zero;
  Duration elapsed = Duration.zero;
  int _intervalUs = 0;
  int _nextTickUs = 0;
  int _ticks = 0;

  @visibleForTesting
  int get debugTicks => _ticks;

  void _advance(Duration value) {
    assert(() {
      _ticks++;
      return true;
    }());
    elapsed = _completed + value;
    notifyListeners();
    // Deadlines stay on the shared time base. Waiting a whole interval after
    // each delivered vsync would add the display's scheduling latency and
    // turn, for example, 30 fps into 20 fps on a 60 Hz screen.
    final now = elapsed.inMicroseconds;
    if (_intervalUs == 0) {
      _ticker.delay = Duration.zero;
    } else {
      if (now >= _nextTickUs) {
        _nextTickUs += _intervalUs * ((now - _nextTickUs) ~/ _intervalUs + 1);
      }
      _ticker.delay = Duration(microseconds: _nextTickUs - now);
    }
  }

  @override
  void addListener(VoidCallback listener) => _listen(listener, Duration.zero);

  void _listen(VoidCallback listener, Duration interval) {
    final previous = _subscribers[listener];
    if (previous == interval) return;
    _subscribers[listener] = interval;
    if (previous == null) super.addListener(listener);
    _configureCadence();
    if (!_ticker.isActive) _ticker.start();
  }

  @override
  void removeListener(VoidCallback listener) {
    if (_subscribers.remove(listener) == null) return;
    super.removeListener(listener);
    if (_subscribers.isEmpty) {
      _completed = elapsed;
      _ticker.stop();
    } else {
      _configureCadence();
    }
  }

  void _configureCadence() {
    final interval = _subscribers.values
        .map((value) => value.inMicroseconds)
        .reduce(math.min);
    if (interval == _intervalUs) return;
    _intervalUs = interval;
    _nextTickUs = elapsed.inMicroseconds;
    _ticker.wake();
  }
}

/// Sleep between requested background frames, then let Flutter deliver the
/// actual paint on vsync. A normal Ticker would request every display frame
/// even when all consumers subsequently discard it for their 10/30 fps cap.
class _AlbumFlowTicker extends Ticker {
  _AlbumFlowTicker(super.onTick) : super(debugLabel: 'Shared album flow');

  Duration delay = Duration.zero;
  Timer? _wake;

  @override
  bool get scheduled => _wake != null || super.scheduled;

  void wake() {
    _wake?.cancel();
    _wake = null;
    if (shouldScheduleTick) super.scheduleTick();
  }

  @override
  void scheduleTick({bool rescheduling = false}) {
    if (!rescheduling || delay == Duration.zero) {
      super.scheduleTick(rescheduling: rescheduling);
      return;
    }
    _wake = Timer(delay, () {
      _wake = null;
      if (shouldScheduleTick) super.scheduleTick();
    });
  }

  @override
  void unscheduleTick() {
    _wake?.cancel();
    _wake = null;
    super.unscheduleTick();
  }
}

/// Ported from the Lazer project:
/// `shared/src/commonMain/.../AlbumFlowBackground.kt` (the flowing palette) and
/// `.../LazerBackgrounds.kt` (the artwork-seed extractor).
///
/// The album's dominant hue becomes a five-step ramp from a near-white tint to
/// a deep shade. Four of those colours drift across the page as large radial
/// gradients — each on its own orbit, scale pulse and rotation — while the
/// fifth paints the base and a slow overlay. A change of track crossfades the
/// whole palette instead of cutting.

/// Five colours derived from one seed, matching `flowColorsFromSeed`.
List<Color> albumFlowColors(Color seed) {
  final HSLColor hsl = HSLColor.fromColor(seed);
  final double chroma = (hsl.saturation * 0.72 + 0.12).clamp(0.20, 0.58);
  Color step(double saturation, double lightness) => HSLColor.fromAHSL(
    1,
    hsl.hue,
    saturation.clamp(0.0, 1.0),
    lightness.clamp(0.0, 1.0),
  ).toColor();
  return <Color>[
    step(chroma * 0.55, 0.90),
    step(chroma * 0.72, 0.76),
    step(chroma, 0.58),
    step(chroma * 0.86, 0.43),
    step(chroma * 0.74, 0.31),
  ];
}

/// The seed the app starts from before any artwork is decoded.
const Color kAlbumDefaultSeed = AppTokens.lakeBlue;

/// Stable fallback while the current track's artwork is still loading.
Color albumFallbackSeedForTrack(Track? track) {
  final int seed = track?.coverSeed ?? 0;
  if (seed == 0) return kAlbumDefaultSeed;
  return HSLColor.fromAHSL(1, (seed % 360).toDouble(), .46, .44).toColor();
}

/// `normalizeFlowPalette`: always five colours.
List<Color> normalizeFlowPalette(List<Color> colors) {
  if (colors.isEmpty) return albumFlowColors(kAlbumDefaultSeed);
  return List<Color>.generate(5, (int i) => colors[i % colors.length]);
}

/// The animated album-colour renderer.
///
/// This is a Flutter port of AMLL's `MeshGradientRenderer`: a dense triangle
/// mesh is warped inside the viewport and painted with smoothly interpolated
/// album-palette vertex colours. The original WebGL renderer samples a heavily
/// treated cover texture through a bicubic Hermite mesh; here the already
/// extracted cover palette supplies the colour field and the actual cover
/// bloom continues to provide the photographic detail. The result keeps the
/// characteristic slow Apple Music mesh flow without a per-layer widget tree.
class AlbumFlowBackground extends StatefulWidget {
  const AlbumFlowBackground({
    super.key,
    required this.colors,
    this.veil = const Color(0x00000000),
    this.animated = true,
    this.solid = false,
    this.cornerRadius = 0,
    this.quality = kDynamicBackgroundQualityDefault,
    this.preview = false,
    this.frameRate = 30,
  });

  final List<Color> colors;

  /// Tinted veil composited over the flow; transparent leaves it untouched.
  final Color veil;

  /// `false` freezes the layers, matching the compatibility "static" mode.
  final bool animated;

  /// `true` paints the base colour only.
  final bool solid;

  final double cornerRadius;

  /// `动态背景渲染精度`, 0.1 … 1.0: mesh density, independent of [frameRate].
  final double quality;

  /// Paints one vertical ramp instead of the warped mesh.
  ///
  /// The player is slid in and out as a full-window layer, and every frame of
  /// that slide re-executes the page's display list. A single gradient keeps
  /// that frame affordable; the real mesh takes over the moment the page
  /// stops moving, using the same five colours, so the handover is a warp
  /// appearing rather than a colour change.
  final bool preview;
  final double? frameRate;

  @override
  State<AlbumFlowBackground> createState() => _AlbumFlowBackgroundState();
}

class _AlbumFlowBackgroundState extends State<AlbumFlowBackground>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  /// Mesh density and frame rate have separate controls, so lowering detail
  /// preserves the chosen background cadence.
  late DynamicBackgroundPrecision _precision = DynamicBackgroundPrecision.of(
    widget.quality,
  );

  late List<Color> _from = normalizeFlowPalette(widget.colors);
  late List<Color> _to = _from;
  late final AnimationController _palette = AnimationController(
    vsync: this,
    duration: albumFlowConfiguration.paletteTransition,
    value: 1,
  );
  final ValueNotifier<int> _frames = ValueNotifier<int>(0);
  bool _flowClockAttached = false;
  double _nextFrameUs = 0;
  Duration _frameInterval = const Duration(microseconds: 33333);
  bool _paintEveryVsync = false;
  double _phase = 0;
  bool _reduceMotion = false;
  bool _tickerAllowed = true;
  bool _appActive = true;
  ui.FlutterView? _view;
  double? _paintedPaletteFraction;
  List<Color>? _paintedPalette;
  _FlowPainter? _cachedPainter;
  (int, int, Color, bool, bool)? _painterConfiguration;

  @override
  void initState() {
    super.initState();
    albumFlowRenderer._retain();
    WidgetsBinding.instance.addObserver(this);
    _palette
      ..addListener(_onPaletteFrame)
      ..addStatusListener(_onPaletteStatus);
    _syncPlayback();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bool active = state == AppLifecycleState.resumed;
    if (active == _appActive) return;
    _appActive = active;
    _syncPlayback();
  }

  @override
  void didHaveMemoryPressure() => albumFlowRenderer._clear();

  /// Palette changes share the mesh's selected cadence.
  final Stopwatch _paletteClock = Stopwatch()..start();
  int _lastPaletteFrameUs = 0;
  Timer? _paletteTrailing;

  void _onPaletteFrame() {
    final int now = _paletteClock.elapsedMicroseconds;
    final int since = now - _lastPaletteFrameUs;
    final int interval = _frameInterval.inMicroseconds;
    if (since < interval) {
      _paletteTrailing ??= Timer(
        Duration(microseconds: interval - since),
        _invalidatePaletteFrame,
      );
      return;
    }
    _invalidatePaletteFrame();
  }

  void _invalidatePaletteFrame() {
    _paletteTrailing?.cancel();
    _paletteTrailing = null;
    if (!mounted) return;
    _lastPaletteFrameUs = _paletteClock.elapsedMicroseconds;
    _frames.value++;
  }

  void _onPaletteStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      _frames.value++;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _view = View.of(context);
    final bool reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final bool allowed = TickerMode.valuesOf(context).enabled;
    _configureFrameRate();
    if (reduce != _reduceMotion || allowed != _tickerAllowed) {
      _reduceMotion = reduce;
      _tickerAllowed = allowed;
      _syncPlayback();
    }
  }

  void _configureFrameRate() {
    final double reported = _view?.display.refreshRate ?? 60;
    final double refresh = reported.isFinite && reported > 0 ? reported : 60;
    final double requested = widget.frameRate?.clamp(10, 1000) ?? refresh;
    _paintEveryVsync = widget.frameRate == null || requested >= refresh;
    _frameInterval = Duration(
      microseconds: (1000000 / math.min(refresh, requested)).round(),
    );
    if (_flowClockAttached) {
      albumFlowClock._listen(
        _advance,
        _paintEveryVsync ? Duration.zero : _frameInterval,
      );
    }
  }

  @override
  void didChangeMetrics() {
    if (mounted) _configureFrameRate();
  }

  @override
  void didUpdateWidget(AlbumFlowBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    final List<Color> next = normalizeFlowPalette(widget.colors);
    if (!_samePalette(next, _to)) {
      _from = _rawPalette();
      _to = next;
      _paintedPaletteFraction = null;
      if (_reduceMotion ||
          !widget.animated ||
          widget.solid ||
          widget.preview ||
          !_tickerAllowed ||
          !_appActive) {
        _palette.value = 1;
      } else {
        _palette.forward(from: 0);
      }
      _frames.value++;
    }
    final DynamicBackgroundPrecision precision = DynamicBackgroundPrecision.of(
      widget.quality,
    );
    if (precision != _precision) {
      _precision = precision;
      // Rebuild the painter with the new mesh density on this frame.
      _frames.value++;
    }
    if (oldWidget.animated != widget.animated ||
        oldWidget.solid != widget.solid ||
        oldWidget.preview != widget.preview ||
        oldWidget.frameRate != widget.frameRate) {
      _configureFrameRate();
      _syncPlayback();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _paletteTrailing?.cancel();
    _paletteTrailing = null;
    if (_flowClockAttached) albumFlowClock.removeListener(_advance);
    _cachedPainter?.releaseResources();
    _palette
      ..removeListener(_onPaletteFrame)
      ..removeStatusListener(_onPaletteStatus)
      ..dispose();
    _frames.dispose();
    albumFlowRenderer._release();
    super.dispose();
  }

  bool get _runs =>
      widget.animated &&
      !_reduceMotion &&
      !widget.solid &&
      !widget.preview &&
      _tickerAllowed &&
      _appActive;

  void _syncPlayback() {
    if (!_runs && (_palette.isAnimating || _palette.value != 1)) {
      _palette.stop();
      _palette.value = 1;
    }
    if (_runs) {
      if (!_flowClockAttached) {
        _nextFrameUs = 0;
        _phase =
            albumFlowClock.elapsed.inMicroseconds /
            Duration.microsecondsPerSecond %
            10000;
        _flowClockAttached = true;
        albumFlowClock._listen(
          _advance,
          _paintEveryVsync ? Duration.zero : _frameInterval,
        );
      }
    } else {
      if (_flowClockAttached) albumFlowClock.removeListener(_advance);
      _flowClockAttached = false;
    }
  }

  void _advance() {
    final int now = albumFlowClock.elapsed.inMicroseconds;
    if (!_paintEveryVsync && now < _nextFrameUs) return;
    final int interval = _frameInterval.inMicroseconds;
    _nextFrameUs +=
        interval * math.max(1, ((now - _nextFrameUs) / interval).floor() + 1);
    // Slowly rotating/breathing mesh: AMLL drives its WebGL mesh from a
    // 10-second time base, with a volume-responsive UV rotation.
    _phase = (now / Duration.microsecondsPerSecond) % 10000;
    _frames.value++;
  }

  /// The palette before the per-colour vibrancy treatment, used as the
  /// crossfade origin so the adjustment is never applied twice.
  List<Color> _rawPalette() {
    if (_palette.value == 1) return _to;
    final double t = _palette.value == 0 && !_palette.isAnimating
        ? 1
        : _fluidEase(_palette.value);
    return List<Color>.generate(
      5,
      (int i) => Color.lerp(_from[i], _to[i], t) ?? _to[i],
    );
  }

  /// The palette actually painted: saturation and lightness are nudged once
  /// per colour instead of once per mesh vertex. The old per-vertex HSL
  /// conversion cost ~550 round trips through HSL every frame; doing it here
  /// leaves the mesh with plain colour lerps and looks the same.
  List<Color> _currentPalette() {
    final double fraction = _palette.value;
    if (_paintedPaletteFraction == fraction && _paintedPalette != null) {
      return _paintedPalette!;
    }
    _paintedPaletteFraction = fraction;
    assert(() {
      AlbumFlowRenderer._paletteBuilds++;
      return true;
    }());
    // Mesh motion changes every frame, but the cover colours usually do not.
    // Retain the exact treated result until the fade or its endpoints change.
    return _paintedPalette = <Color>[
      for (final Color color in _rawPalette()) _vivid(color),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final configuration = (
      _precision.columns,
      _precision.rows,
      widget.veil,
      widget.solid,
      widget.preview,
    );
    if (_painterConfiguration != configuration) {
      _cachedPainter?.releaseResources();
      _painterConfiguration = configuration;
      _cachedPainter = _FlowPainter(
        palette: _currentPalette,
        phase: () => _phase,
        veil: widget.veil,
        solid: widget.solid,
        preview: widget.preview,
        columns: _precision.columns,
        rows: _precision.rows,
        repaint: _frames,
      );
    }
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.cornerRadius),
        child: CustomPaint(
          key: ValueKey<String>(widget.solid ? 'solid' : 'flow'),
          painter: _cachedPainter,
          isComplex: true,
          willChange: _runs,
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

Color _vivid(Color color) {
  final HSLColor hsl = HSLColor.fromColor(color);
  return hsl
      .withSaturation((hsl.saturation * 1.08).clamp(0.0, 1.0))
      .withLightness((hsl.lightness * .92).clamp(0.0, 1.0))
      .toColor();
}

/// Shared renderer used by every flowing surface. A frame is recorded once in
/// unit coordinates, then the same picture is scaled into each page's canvas.
/// The cache is bounded even when pages request different precision or cadence.
const albumFlowRenderer = AlbumFlowRenderer();

typedef _AlbumFlowFrameKey = (
  int,
  int,
  double,
  Color,
  Color,
  Color,
  Color,
  Color,
);

class AlbumFlowRenderer {
  const AlbumFlowRenderer();

  static final Map<(int, int), _AlbumFlowMesh> _meshes = {};
  static final Map<_AlbumFlowFrameKey, ui.Picture> _pictures = {};
  static int _frameBuilds = 0;
  static int _paletteBuilds = 0;
  static int _consumers = 0;

  @visibleForTesting
  int get debugFrameBuilds => _frameBuilds;

  @visibleForTesting
  int get debugPaletteBuilds => _paletteBuilds;

  @visibleForTesting
  List<ui.Picture> get debugCachedFrames => List.unmodifiable(_pictures.values);

  void _retain() => _consumers++;

  void _release() {
    assert(_consumers > 0);
    if (--_consumers == 0) _clear();
  }

  void _clear() {
    for (final picture in _pictures.values) {
      picture.dispose();
    }
    _pictures.clear();
    _meshes.clear();
  }

  void paint(
    Canvas canvas,
    Size size,
    List<Color> colors,
    double phase,
    int columns,
    int rows,
  ) {
    final key = (
      columns,
      rows,
      phase,
      colors[0],
      colors[1],
      colors[2],
      colors[3],
      colors[4],
    );
    var picture = _pictures.remove(key);
    if (picture == null) {
      final meshKey = (columns, rows);
      final mesh = _meshes.remove(meshKey) ?? _AlbumFlowMesh(columns, rows);
      _meshes[meshKey] = mesh;
      if (_meshes.length > albumFlowConfiguration.meshCacheEntries) {
        _meshes.remove(_meshes.keys.first);
      }
      picture = mesh.record(colors, phase);
      _frameBuilds++;
    }
    _pictures[key] = picture;
    if (_pictures.length > albumFlowConfiguration.frameCacheEntries) {
      _pictures.remove(_pictures.keys.first)!.dispose();
    }
    canvas.save();
    canvas.scale(size.width, size.height);
    canvas.drawPicture(picture);
    canvas.restore();
  }
}

/// A surface only composites the shared frame and its own opacity veil.
class _FlowPainter extends CustomPainter {
  _FlowPainter({
    required this.palette,
    required this.phase,
    required this.veil,
    required this.solid,
    required this.preview,
    required this.columns,
    required this.rows,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final List<Color> Function() palette;
  final double Function() phase;
  final Color veil;
  final bool solid, preview;
  final int columns, rows;

  ui.Shader? _veilShader;
  Size? _veilSize;
  Color? _veilTint;

  void releaseResources() {
    _veilShader?.dispose();
    _veilShader = null;
  }

  ui.Shader _veilShaderFor(Size size, Color veil) {
    final double extent = size.shortestSide;
    if (_veilShader == null || _veilSize != size || _veilTint != veil) {
      _veilShader?.dispose();
      _veilSize = size;
      _veilTint = veil;
      _veilShader = ui.Gradient.radial(
        size.center(Offset.zero),
        extent * 0.5,
        <Color>[
          veil.withValues(alpha: 0),
          veil.withValues(alpha: veil.a * 0.28),
          veil.withValues(alpha: veil.a * 0.72),
        ],
        const <double>[0, 0.5, 1],
      );
    }
    return _veilShader!;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final colors = palette();
    final bounds = Offset.zero & size;
    if (preview && !solid) {
      final shader = ui.Gradient.linear(
        bounds.topCenter,
        bounds.bottomCenter,
        [colors[0], colors[2], colors[4]],
        const [0, .55, 1],
      );
      canvas.drawRect(bounds, Paint()..shader = shader);
      shader.dispose();
    } else if (solid) {
      canvas.drawRect(bounds, Paint()..color = colors[4]);
    } else {
      albumFlowRenderer.paint(canvas, size, colors, phase(), columns, rows);
    }
    if (veil.a > 0) {
      canvas.drawRect(bounds, Paint()..shader = _veilShaderFor(size, veil));
      canvas.drawRect(
        bounds,
        Paint()..color = veil.withValues(alpha: veil.a * 0.72),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FlowPainter oldDelegate) =>
      oldDelegate.solid != solid ||
      oldDelegate.veil != veil ||
      oldDelegate.preview != preview ||
      oldDelegate.columns != columns ||
      oldDelegate.rows != rows;
}

class _AlbumFlowMesh {
  _AlbumFlowMesh(this.columns, this.rows);
  final int columns, rows;

  Float32List? _positions;
  Int32List? _colors;
  Uint16List? _indices;
  Float64List? _uEnvelope;
  Float64List? _uSinOuter;
  Float64List? _uCosOuter;
  Float64List? _uSinNested;
  Float64List? _uCosNested;
  Float64List? _uSinWaveX;
  Float64List? _uCosWaveX;
  Float64List? _uSinWaveY;
  Float64List? _uCosWaveY;
  Float64List? _uSinMix;
  Float64List? _uCosMix;
  Float64List? _vEnvelope;
  Float64List? _vSinNested;
  Float64List? _vCosNested;
  Float64List? _vSinOuter;
  Float64List? _vCosOuter;
  Float64List? _vSinWaveX;
  Float64List? _vCosWaveX;
  Float64List? _vSinWaveY;
  Float64List? _vCosWaveY;
  Float64List? _vSinMix;
  Float64List? _vCosMix;
  Float64List? _rowWaveX;
  Float64List? _rowWaveY;
  Float64List? _rowOffsetASin;
  Float64List? _rowOffsetACos;
  Float64List? _columnWaveX;
  Float64List? _columnWaveY;
  Float64List? _columnOffsetBSin;
  Float64List? _columnOffsetBCos;
  int _builtColumns = 0;
  int _builtRows = 0;

  int get _vertexCount => (columns + 1) * (rows + 1);

  /// Rebuilds the triangle strip only when the precision setting moved to a
  /// different mesh: the buffers and their indices are pure geometry.
  void _ensureMesh() {
    if (_positions != null && _builtColumns == columns && _builtRows == rows) {
      return;
    }
    _builtColumns = columns;
    _builtRows = rows;
    _positions = Float32List(_vertexCount * 2);
    _colors = Int32List(_vertexCount);
    _indices = Uint16List(columns * rows * 6);
    final int columnCount = columns + 1;
    final int rowCount = rows + 1;
    _uEnvelope = Float64List(columnCount);
    _uSinOuter = Float64List(columnCount);
    _uCosOuter = Float64List(columnCount);
    _uSinNested = Float64List(columnCount);
    _uCosNested = Float64List(columnCount);
    _uSinWaveX = Float64List(columnCount);
    _uCosWaveX = Float64List(columnCount);
    _uSinWaveY = Float64List(columnCount);
    _uCosWaveY = Float64List(columnCount);
    _uSinMix = Float64List(columnCount);
    _uCosMix = Float64List(columnCount);
    _vEnvelope = Float64List(rowCount);
    _vSinNested = Float64List(rowCount);
    _vCosNested = Float64List(rowCount);
    _vSinOuter = Float64List(rowCount);
    _vCosOuter = Float64List(rowCount);
    _vSinWaveX = Float64List(rowCount);
    _vCosWaveX = Float64List(rowCount);
    _vSinWaveY = Float64List(rowCount);
    _vCosWaveY = Float64List(rowCount);
    _vSinMix = Float64List(rowCount);
    _vCosMix = Float64List(rowCount);
    _rowWaveX = Float64List(rowCount);
    _rowWaveY = Float64List(rowCount);
    _rowOffsetASin = Float64List(rowCount);
    _rowOffsetACos = Float64List(rowCount);
    _columnWaveX = Float64List(columnCount);
    _columnWaveY = Float64List(columnCount);
    _columnOffsetBSin = Float64List(columnCount);
    _columnOffsetBCos = Float64List(columnCount);

    // The mesh topology and the phase-free trigonometric terms stay the same
    // for every animation tick. Keep them beside the vertex buffers so a frame
    // only combines cached values with the current phase.
    for (int column = 0; column < columnCount; column++) {
      final double u = column / columns;
      _uEnvelope![column] = math.sin(math.pi * u);
      _uSinOuter![column] = math.sin(u * 3.35);
      _uCosOuter![column] = math.cos(u * 3.35);
      _uSinNested![column] = math.sin(u * 3.7);
      _uCosNested![column] = math.cos(u * 3.7);
      _uSinWaveX![column] = math.sin(u * math.pi * 4.2);
      _uCosWaveX![column] = math.cos(u * math.pi * 4.2);
      _uSinWaveY![column] = math.sin(u * math.pi * 2.3);
      _uCosWaveY![column] = math.cos(u * math.pi * 2.3);
      _uSinMix![column] = math.sin(u * 2.35);
      _uCosMix![column] = math.cos(u * 2.35);
    }
    for (int row = 0; row < rowCount; row++) {
      final double v = row / rows;
      _vEnvelope![row] = math.sin(math.pi * v);
      _vSinNested![row] = math.sin(v * 2.75);
      _vCosNested![row] = math.cos(v * 2.75);
      _vSinOuter![row] = math.sin(v * 3.05);
      _vCosOuter![row] = math.cos(v * 3.05);
      _vSinWaveX![row] = math.sin(v * math.pi * 2.4);
      _vCosWaveX![row] = math.cos(v * math.pi * 2.4);
      _vSinWaveY![row] = math.sin(v * math.pi * 3.7);
      _vCosWaveY![row] = math.cos(v * math.pi * 3.7);
      _vSinMix![row] = math.sin(v * 2.35);
      _vCosMix![row] = math.cos(v * 2.35);
    }
    var cursor = 0;
    for (var row = 0; row < rows; row++) {
      for (var column = 0; column < columns; column++) {
        final int topLeft = row * (columns + 1) + column;
        final int topRight = topLeft + 1;
        final int bottomLeft = topLeft + columns + 1;
        final int bottomRight = bottomLeft + 1;
        _indices![cursor++] = topLeft;
        _indices![cursor++] = topRight;
        _indices![cursor++] = bottomLeft;
        _indices![cursor++] = topRight;
        _indices![cursor++] = bottomRight;
        _indices![cursor++] = bottomLeft;
      }
    }
  }

  static int _blendChannel(
    double a,
    double b,
    double c,
    double d,
    double ta,
    double tb,
    double mix,
  ) {
    final upper = a + (b - a) * ta;
    final lower = c + (d - c) * tb;
    return ((upper + (lower - upper) * mix) * 255).round().clamp(0, 255);
  }

  int _meshColorArgb(
    List<Color> colors,
    double waveA,
    double waveB,
    double waveMix,
  ) {
    final double sampleA = (.08 + waveA * .58).clamp(0.0, .999999) * 4;
    final double sampleB = (.38 + waveB * .60).clamp(0.0, .999999) * 4;
    final int ia = sampleA.floor(), ib = sampleB.floor();
    final double ta = sampleA - ia, tb = sampleB - ib;
    final a = colors[ia],
        b = colors[ia + 1],
        c = colors[ib],
        d = colors[ib + 1];
    final double mix = (.42 + .25 * waveMix).clamp(0.0, 1.0);
    // Blend straight into the vertex buffer, avoiding three Color allocations
    // per vertex on every display frame.
    return (_blendChannel(a.a, b.a, c.a, d.a, ta, tb, mix) << 24) |
        (_blendChannel(a.r, b.r, c.r, d.r, ta, tb, mix) << 16) |
        (_blendChannel(a.g, b.g, c.g, d.g, ta, tb, mix) << 8) |
        _blendChannel(a.b, b.b, c.b, d.b, ta, tb, mix);
  }

  ui.Picture record(List<Color> colors, double time) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, 1, 1));
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 1, 1),
      Paint()..color = colors[4],
    );
    _ensureMesh();
    final Float32List positions = _positions!;
    final Int32List vertexColors = _colors!;
    final Float64List uEnvelope = _uEnvelope!;
    final Float64List uSinOuter = _uSinOuter!;
    final Float64List uCosOuter = _uCosOuter!;
    final Float64List uSinNested = _uSinNested!;
    final Float64List uCosNested = _uCosNested!;
    final Float64List uSinWaveX = _uSinWaveX!;
    final Float64List uCosWaveX = _uCosWaveX!;
    final Float64List uSinWaveY = _uSinWaveY!;
    final Float64List uCosWaveY = _uCosWaveY!;
    final Float64List uSinMix = _uSinMix!;
    final Float64List uCosMix = _uCosMix!;
    final Float64List vEnvelope = _vEnvelope!;
    final Float64List vSinNested = _vSinNested!;
    final Float64List vCosNested = _vCosNested!;
    final Float64List vSinOuter = _vSinOuter!;
    final Float64List vCosOuter = _vCosOuter!;
    final Float64List vSinWaveX = _vSinWaveX!;
    final Float64List vCosWaveX = _vCosWaveX!;
    final Float64List vSinWaveY = _vSinWaveY!;
    final Float64List vCosWaveY = _vCosWaveY!;
    final Float64List vSinMix = _vSinMix!;
    final Float64List vCosMix = _vCosMix!;
    final Float64List rowWaveX = _rowWaveX!;
    final Float64List rowWaveY = _rowWaveY!;
    final Float64List rowOffsetASin = _rowOffsetASin!;
    final Float64List rowOffsetACos = _rowOffsetACos!;
    final Float64List columnWaveX = _columnWaveX!;
    final Float64List columnWaveY = _columnWaveY!;
    final Float64List columnOffsetBSin = _columnOffsetBSin!;
    final Float64List columnOffsetBCos = _columnOffsetBCos!;

    final double sinWaveXRowShift = math.sin(time * .20 + 1.1);
    final double cosWaveXRowShift = math.cos(time * .20 + 1.1);
    final double sinWaveXColumnShift = math.sin(-time * .13 + .7);
    final double cosWaveXColumnShift = math.cos(-time * .13 + .7);
    final double sinWaveYColumnShift = math.sin(-time * .18 + 2.2);
    final double cosWaveYColumnShift = math.cos(-time * .18 + 2.2);
    final double sinWaveYRowShift = math.sin(time * .11);
    final double cosWaveYRowShift = math.cos(time * .11);
    final double sinNestedARowShift = math.sin(-time * .19);
    final double cosNestedARowShift = math.cos(-time * .19);
    final double sinNestedBColumnShift = math.sin(time * .17);
    final double cosNestedBColumnShift = math.cos(time * .17);
    final double sinMixShift = math.sin(time * .14);
    final double cosMixShift = math.cos(time * .14);

    for (int row = 0; row <= rows; row++) {
      rowWaveX[row] =
          vSinWaveX[row] * cosWaveXRowShift + vCosWaveX[row] * sinWaveXRowShift;
      rowWaveY[row] =
          vCosWaveY[row] * cosWaveYRowShift - vSinWaveY[row] * sinWaveYRowShift;
      final double nestedA =
          vSinNested[row] * cosNestedARowShift +
          vCosNested[row] * sinNestedARowShift;
      final double rowOffsetA = nestedA * 1.15 + time * .21;
      rowOffsetASin[row] = math.sin(rowOffsetA);
      rowOffsetACos[row] = math.cos(rowOffsetA);
    }
    for (int column = 0; column <= columns; column++) {
      columnWaveX[column] =
          uSinWaveX[column] * cosWaveXColumnShift +
          uCosWaveX[column] * sinWaveXColumnShift;
      columnWaveY[column] =
          uCosWaveY[column] * cosWaveYColumnShift -
          uSinWaveY[column] * sinWaveYColumnShift;
      final double nestedB =
          uSinNested[column] * cosNestedBColumnShift +
          uCosNested[column] * sinNestedBColumnShift;
      final double columnOffsetB = nestedB * 1.05 - time * .16;
      columnOffsetBSin[column] = math.sin(columnOffsetB);
      columnOffsetBCos[column] = math.cos(columnOffsetB);
    }

    var vertex = 0;
    for (var row = 0; row <= rows; row++) {
      final double v = row / rows;
      final double envelopeY = vEnvelope[row];
      for (var column = 0; column <= columns; column++) {
        final double u = column / columns;
        final double envelope = uEnvelope[column] * envelopeY;
        final double waveX = rowWaveX[row] * .115 + columnWaveX[column] * .055;
        final double waveY = columnWaveY[column] * .12 + rowWaveY[row] * .065;
        positions[vertex * 2] = (u + waveX * envelope);
        positions[vertex * 2 + 1] = (v + waveY * envelope);
        final double waveA =
            .5 +
            .5 *
                (uSinOuter[column] * rowOffsetACos[row] +
                    uCosOuter[column] * rowOffsetASin[row]);
        final double waveB =
            .5 +
            .5 *
                (vCosOuter[row] * columnOffsetBCos[column] -
                    vSinOuter[row] * columnOffsetBSin[column]);
        final double baseMixSin =
            uSinMix[column] * vCosMix[row] - uCosMix[column] * vSinMix[row];
        final double baseMixCos =
            uCosMix[column] * vCosMix[row] + uSinMix[column] * vSinMix[row];
        final double waveMix =
            baseMixSin * cosMixShift + baseMixCos * sinMixShift;
        vertexColors[vertex] = _meshColorArgb(colors, waveA, waveB, waveMix);
        vertex++;
      }
    }
    final ui.Vertices vertices = ui.Vertices.raw(
      ui.VertexMode.triangles,
      positions,
      colors: vertexColors,
      indices: _indices,
    );
    canvas.drawVertices(vertices, BlendMode.srcOver, Paint());
    vertices.dispose();
    return recorder.endRecording();
  }
}

double _fluidEase(double fraction) {
  final double f = fraction.clamp(0.0, 1.0);
  return (1 - math.cos(math.pi * f)) / 2;
}

bool _samePalette(List<Color> a, List<Color> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// Artwork seed extraction (LazerBackgrounds.kt)
// ---------------------------------------------------------------------------

/// Samples the artwork down to 48×48 and picks the dominant *vibrant* hue,
/// boosting its saturation — the compatibility `seedFromArtwork`.
Color albumSeedFromPixels(Uint8List rgba, int width, int height) {
  if (width <= 0 || height <= 0) return kAlbumDefaultSeed;
  final int stepX = math.max(1, width ~/ 48);
  final int stepY = math.max(1, height ~/ 48);
  final List<double> red = List<double>.filled(24, 0);
  final List<double> green = List<double>.filled(24, 0);
  final List<double> blue = List<double>.filled(24, 0);
  final List<double> weights = List<double>.filled(24, 0);
  double averageRed = 0, averageGreen = 0, averageBlue = 0;
  double averageCount = 0;
  for (int y = 0; y < height; y += stepY) {
    for (int x = 0; x < width; x += stepX) {
      final int index = (y * width + x) * 4;
      if (index + 3 >= rgba.length) continue;
      if (rgba[index + 3] < 128) continue;
      final int r = rgba[index];
      final int g = rgba[index + 1];
      final int b = rgba[index + 2];
      averageRed += r;
      averageGreen += g;
      averageBlue += b;
      averageCount++;
      final HSLColor hsl = HSLColor.fromColor(Color.fromARGB(255, r, g, b));
      final double saturation = hsl.saturation;
      final double lightness = hsl.lightness;
      if (saturation >= 0.15 && lightness >= 0.12 && lightness <= 0.92) {
        final double weight =
            saturation * math.max(0.05, 1.0 - (lightness - 0.5).abs() * 1.6);
        final int bucket = math.min(23, (hsl.hue / 360 * 24).toInt());
        red[bucket] += r * weight;
        green[bucket] += g * weight;
        blue[bucket] += b * weight;
        weights[bucket] += weight;
      }
    }
  }
  int best = 0;
  for (int i = 1; i < weights.length; i++) {
    if (weights[i] > weights[best]) best = i;
  }
  if (weights[best] > 0.5) {
    final Color seed = Color.fromARGB(
      255,
      (red[best] / weights[best]).round().clamp(0, 255),
      (green[best] / weights[best]).round().clamp(0, 255),
      (blue[best] / weights[best]).round().clamp(0, 255),
    );
    final HSLColor hsl = HSLColor.fromColor(seed);
    return HSLColor.fromAHSL(
      1,
      hsl.hue,
      math.min(1, hsl.saturation * 1.25),
      hsl.lightness,
    ).toColor();
  }
  if (averageCount > 0) {
    return Color.fromARGB(
      255,
      (averageRed / averageCount).round().clamp(0, 255),
      (averageGreen / averageCount).round().clamp(0, 255),
      (averageBlue / averageCount).round().clamp(0, 255),
    );
  }
  return kAlbumDefaultSeed;
}

/// Multi-colour mesh palette extracted from the artwork itself.
///
/// AMLL's mesh renderer uses the cover texture rather than a single-hue ramp.
/// Flutter's `drawVertices` port paints with vertex colours, so we preserve the
/// dominant cover hues here and let the flowing mesh interpolate between them.
class _ColorBucket {
  int count = 0;
  double red = 0;
  double green = 0;
  double blue = 0;
  double saturation = 0;
  double lightness = 0;
  double score = 0;
}

List<Color> albumMeshColorsFromPixels(Uint8List rgba, int width, int height) {
  if (width <= 0 || height <= 0) {
    return albumFlowColors(kAlbumDefaultSeed);
  }
  final int stepX = math.max(1, width ~/ 72);
  final int stepY = math.max(1, height ~/ 72);
  final Map<int, _ColorBucket> buckets = <int, _ColorBucket>{};
  for (var y = 0; y < height; y += stepY) {
    for (var x = 0; x < width; x += stepX) {
      final int index = (y * width + x) * 4;
      if (index + 3 >= rgba.length || rgba[index + 3] < 128) continue;
      final int r = rgba[index];
      final int g = rgba[index + 1];
      final int b = rgba[index + 2];
      final HSLColor hsl = HSLColor.fromColor(Color.fromARGB(255, r, g, b));
      if (hsl.lightness < .07 || hsl.lightness > .95) continue;
      // Quantise to 32 levels per channel. The bucket score favours vibrant
      // pixels near mid-lightness, matching the contrast/saturation treatment
      // used by AMLL's WebGL cover texture.
      final int key = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3);
      final _ColorBucket bucket = buckets.putIfAbsent(key, _ColorBucket.new);
      bucket
        ..count += 1
        ..red += r
        ..green += g
        ..blue += b
        ..saturation += hsl.saturation
        ..lightness += hsl.lightness;
    }
  }
  if (buckets.isEmpty) return albumFlowColors(kAlbumDefaultSeed);

  final List<_ColorBucket> candidates = <_ColorBucket>[];
  for (final _ColorBucket bucket in buckets.values) {
    final double saturation = bucket.saturation / bucket.count;
    final double lightness = bucket.lightness / bucket.count;
    bucket.score =
        bucket.count *
        (.28 + saturation * 1.25) *
        (.35 + 1 - (lightness - .5).abs() * 1.4);
    candidates.add(bucket);
  }
  candidates.sort((a, b) => b.score.compareTo(a.score));

  final List<Color> selected = <Color>[];
  for (final _ColorBucket bucket in candidates) {
    final Color raw = Color.fromARGB(
      255,
      (bucket.red / bucket.count).round().clamp(0, 255),
      (bucket.green / bucket.count).round().clamp(0, 255),
      (bucket.blue / bucket.count).round().clamp(0, 255),
    );
    final HSLColor hsl = HSLColor.fromColor(raw);
    final Color vivid = HSLColor.fromAHSL(
      1,
      hsl.hue,
      (hsl.saturation * 1.32 + .06).clamp(0.0, 1.0),
      (hsl.lightness * .84 + .16).clamp(.16, .78),
    ).toColor();
    if (selected.every(
      (Color existing) => _colorDistance(existing, vivid) > 46,
    )) {
      selected.add(vivid);
      if (selected.length == 5) break;
    }
  }

  final List<Color> fallback = albumFlowColors(
    selected.isEmpty ? kAlbumDefaultSeed : selected.first,
  );
  for (final Color color in fallback) {
    if (selected.length == 5) break;
    if (selected.every(
      (Color existing) => _colorDistance(existing, color) > 28,
    )) {
      selected.add(color);
    }
  }
  for (final Color color in fallback) {
    if (selected.length == 5) break;
    selected.add(color);
  }
  selected.sort(
    (a, b) => HSLColor.fromColor(
      b,
    ).lightness.compareTo(HSLColor.fromColor(a).lightness),
  );
  return selected;
}

double _colorDistance(Color a, Color b) {
  final double dr = (a.r - b.r) * 255;
  final double dg = (a.g - b.g) * 255;
  final double db = (a.b - b.b) * 255;
  return math.sqrt(dr * dr + dg * dg + db * db);
}

/// Seed and mesh colours are published together, so the accent and every
/// backdrop consume one immutable result from one decode.
@immutable
class AlbumCoverPalette {
  AlbumCoverPalette({required this.seed, required List<Color> mesh})
    : mesh = List.unmodifiable(mesh);
  final Color seed;
  final List<Color> mesh;
}

typedef AlbumPaletteLoader =
    Future<AlbumCoverPalette?> Function(String? coverUrl);

final Map<String, AlbumCoverPalette> _artworkPalettes = {};
final Map<String, Future<AlbumCoverPalette?>> _paletteRequests = {};

Future<AlbumCoverPalette?> albumPaletteForCover(String? coverUrl) {
  final url = albumPaletteArtworkUrl(coverUrl);
  if (url == null) return Future.value(null);
  final cached = _artworkPalettes.remove(url);
  if (cached != null) {
    _artworkPalettes[url] = cached;
    return Future.value(cached);
  }
  final normalized = normalizedArtworkUrl(coverUrl);
  if (normalized != null && normalized != url) {
    final fallbackCached = _artworkPalettes.remove(normalized);
    if (fallbackCached != null) {
      _artworkPalettes[normalized] = fallbackCached;
      return Future.value(fallbackCached);
    }
  }
  final candidates = <String>[url];
  if (normalized != null && normalized != url) candidates.add(normalized);
  return _paletteRequests.putIfAbsent(
    url,
    () => _readCoverPalette(candidates).whenComplete(() {
      // Map.remove returns the very Future stored by putIfAbsent. Returning
      // it from whenComplete would make that Future wait for itself forever.
      _paletteRequests.remove(url);
    }),
  );
}

Future<AlbumCoverPalette?> albumPaletteForCoverWhenReady(
  AlbumPaletteLoader loader,
  String? coverUrl, {
  int attempts = 5,
  Duration delay = const Duration(milliseconds: 160),
}) async {
  if ((coverUrl ?? '').trim().isEmpty) return null;
  for (int attempt = 0; attempt < attempts; attempt++) {
    AlbumCoverPalette? palette;
    try {
      palette = await loader(coverUrl);
    } catch (error) {
      debugPrint('Album palette unavailable for $coverUrl: $error');
    }
    if (palette != null) return palette;
    if (attempt < attempts - 1) {
      await Future<void>.delayed(delay * (attempt + 1));
    }
  }
  return null;
}

Future<List<Color>?> albumMeshColorsForCover(String? coverUrl) async =>
    (await albumPaletteForCover(coverUrl))?.mesh;

Future<AlbumCoverPalette?> _readCoverPalette(List<String> candidates) async {
  for (final candidate in candidates) {
    final palette = await _readOneCoverPalette(candidate);
    if (palette != null) return palette;
  }
  return null;
}

Future<AlbumCoverPalette?> _readOneCoverPalette(String url) async {
  final ui.Image? image = await decodeAlbumPaletteImage(url);
  if (image == null) return null;
  try {
    final ByteData? pixels = await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    if (pixels == null) return null;
    final rgba = pixels.buffer.asUint8List(
      pixels.offsetInBytes,
      pixels.lengthInBytes,
    );
    final palette = AlbumCoverPalette(
      seed: albumSeedFromPixels(rgba, image.width, image.height),
      mesh: albumMeshColorsFromPixels(rgba, image.width, image.height),
    );
    if (_artworkPalettes.length >= albumFlowConfiguration.paletteCacheEntries) {
      _artworkPalettes.remove(_artworkPalettes.keys.first);
    }
    _artworkPalettes[url] = palette;
    return palette;
  } finally {
    image.dispose();
  }
}

/// Resize only providers that support NetEase's rendition parameter. Local
/// covers and authenticated third-party artwork URLs retain their exact URI.
String? albumPaletteArtworkUrl(String? raw) =>
    enlargedArtworkUrl(raw, sizePx: albumFlowConfiguration.paletteImageEdge);

Future<Color?> albumSeedForCover(String? coverUrl) async =>
    (await albumPaletteForCover(coverUrl))?.seed;

/// Palette extraction only samples a small colour field. Decode that field
/// directly, including when a server ignores the rendition or the cover is a
/// local file. The display artwork keeps its own full-quality provider.
///
/// These short-lived pixels do not belong in Flutter's display image cache;
/// only the five colours and seed survive the extraction. Animated artwork
/// also stops after its first frame instead of retaining a streaming codec.
@visibleForTesting
Future<ui.Image?> decodeAlbumPaletteImage(String url) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    buffer = await ArtworkCache.shared.buffer(url);
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final int edge = albumFlowConfiguration.paletteImageEdge;
      final double scale = math.min(
        1,
        edge / math.max(descriptor.width, descriptor.height),
      );
      codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (descriptor.width * scale).round()),
        targetHeight: math.max(1, (descriptor.height * scale).round()),
      );
      return (await codec.getNextFrame()).image;
    } catch (_) {
      // A corrupt persisted cover must remain retryable when it is replaced.
      await ArtworkCache.shared.evict(url);
      rethrow;
    }
  } catch (_) {
    return null;
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// The album-tinted page backdrop: flowing palette derived from the current
/// track, softened by the content-opacity veil.
class AppAlbumBackdrop extends StatefulWidget {
  const AppAlbumBackdrop({
    super.key,
    required this.track,
    required this.mode,
    required this.uiAlpha,
    this.imagePath,
    this.veil,
    this.pageColor,
    this.quality = kDynamicBackgroundQualityDefault,
    this.onSeed,
    this.frameRate = 30,
    this.solidColor,
    this.paletteLoader = albumPaletteForCover,
  });

  final Track? track;
  final AppBackgroundMode mode;

  /// Stored copy of the listener's picture, painted in
  /// [AppBackgroundMode.customImage].
  final String? imagePath;

  /// `内容不透明度` — 0.4 … 1.0. The veil over the palette is its square.
  final double uiAlpha;

  /// When set, the flow carries this veil itself and no content scrim is drawn
  /// — the now-playing page uses the compatibility `background @ 0.38`.
  final Color? veil;

  /// Painted under the flow (compatibility `colors.background`), and on its own when
  /// the backdrop is off.
  final Color? pageColor;

  /// `动态背景渲染精度` from Settings, handed to the flow canvas.
  final double quality;

  /// Reports the extracted artwork seed so the shell can seed its palette even
  /// when the backdrop itself is off.
  final ValueChanged<Color>? onSeed;
  final double? frameRate;
  final Color? solidColor;
  final AlbumPaletteLoader paletteLoader;

  @override
  State<AppAlbumBackdrop> createState() => _AppAlbumBackdropState();
}

class _AppAlbumBackdropState extends State<AppAlbumBackdrop> {
  List<Color> _colors = albumFlowColors(kAlbumDefaultSeed);
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(AppAlbumBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track?.id != widget.track?.id ||
        oldWidget.track?.coverUrl != widget.track?.coverUrl) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final int generation = ++_generation;
    final String? coverUrl = widget.track?.coverUrl;
    _colors = albumFlowColors(albumFallbackSeedForTrack(widget.track));
    final palette = await albumPaletteForCoverWhenReady(
      widget.paletteLoader,
      coverUrl,
    );
    if (!mounted || generation != _generation) return;
    if (palette != null) setState(() => _colors = palette.mesh);
    widget.onSeed?.call(palette?.seed ?? kAlbumDefaultSeed);
  }

  @override
  Widget build(BuildContext context) {
    final Color? pageColor = widget.pageColor;
    if (widget.mode == AppBackgroundMode.off) {
      return pageColor == null
          ? const SizedBox.shrink()
          : ColoredBox(color: pageColor);
    }
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (widget.mode == AppBackgroundMode.solidColor) {
      return ColoredBox(
        color:
            widget.solidColor ??
            backgroundFromTheme(scheme.primary, scheme.brightness),
      );
    }
    if (widget.mode == AppBackgroundMode.customImage) {
      return CustomImageBackdrop(
        path: widget.imagePath,
        pageColor: pageColor ?? scheme.surface,
      );
    }
    final double veil = (widget.uiAlpha * widget.uiAlpha).clamp(0.0, 1.0);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (pageColor != null) ColoredBox(color: pageColor),
        AlbumFlowBackground(
          colors: _colors,
          animated: widget.mode == AppBackgroundMode.nowPlayingDynamic,
          solid: false,
          frameRate: widget.frameRate,
          quality: widget.quality,
          veil: widget.veil ?? const Color(0x00000000),
        ),
        if (widget.veil == null)
          ColoredBox(color: scheme.surface.withValues(alpha: veil)),
      ],
    );
  }
}

/// Paints the listener's picture edge to edge.
///
/// A missing or undecodable file falls back to [pageColor], so a stale
/// preference never leaves a hole in the window. The content veil that keeps
/// labels readable is drawn by the shell above this widget.
class CustomImageBackdrop extends StatelessWidget {
  const CustomImageBackdrop({
    super.key,
    required this.path,
    required this.pageColor,
  });

  final String? path;
  final Color pageColor;

  @override
  Widget build(BuildContext context) {
    final String? source = path;
    return RepaintBoundary(
      child: ColoredBox(
        color: pageColor,
        child: source == null || source.isEmpty
            ? const SizedBox.expand()
            : Image.file(
                File(source),
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
                gaplessPlayback: true,
                errorBuilder:
                    (BuildContext context, Object error, StackTrace? stack) =>
                        const SizedBox.expand(),
              ),
      ),
    );
  }
}
