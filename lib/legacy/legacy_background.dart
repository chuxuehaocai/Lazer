import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../state/ui_preferences.dart';
import '../utils/artwork.dart';
import '../widgets/artwork_image.dart';
import 'legacy_theme.dart';

export '../player/player_backdrop.dart' show AlbumBlurFlow;

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

/// The seed the legacy app starts from before any artwork is decoded.
const Color kAlbumDefaultSeed = LegacyTokens.lakeBlue;

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
  });

  final List<Color> colors;

  /// Tinted veil composited over the flow; transparent leaves it untouched.
  final Color veil;

  /// `false` freezes the layers, matching the legacy "static" mode.
  final bool animated;

  /// `true` paints the base colour only.
  final bool solid;

  final double cornerRadius;

  /// `动态背景渲染精度`, 0.1 … 1.0: the mesh density and update cadence this
  /// canvas runs at. See [DynamicBackgroundPrecision].
  final double quality;

  /// Paints one vertical ramp instead of the warped mesh.
  ///
  /// The player is slid in and out as a full-window layer, and every frame of
  /// that slide re-executes the page's display list. A single gradient keeps
  /// that frame affordable; the real mesh takes over the moment the page
  /// stops moving, using the same five colours, so the handover is a warp
  /// appearing rather than a colour change.
  final bool preview;

  @override
  State<AlbumFlowBackground> createState() => _AlbumFlowBackgroundState();
}

class _AlbumFlowBackgroundState extends State<AlbumFlowBackground>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const Duration _paletteFade = Duration(milliseconds: 650);

  /// The mesh drifts on a ten-second time base: over one 120 fps frame the
  /// change is a fraction of a percent of the warp. Re-rendering it at the
  /// display rate therefore buys nothing visible while spending the whole
  /// frame budget. The cadence actually used comes from the `动态背景渲染精度`
  /// setting — 100 ms per update at 0.1, 16 ms at 1.0 — and never faster than
  /// that, which leaves the UI thread free for page and lyric motion.
  late DynamicBackgroundPrecision _precision = DynamicBackgroundPrecision.of(
    widget.quality,
  );

  late List<Color> _from = normalizeFlowPalette(widget.colors);
  late List<Color> _to = _from;
  late final AnimationController _palette = AnimationController(
    vsync: this,
    duration: _paletteFade,
    value: 1,
  );
  final ValueNotifier<int> _frames = ValueNotifier<int>(0);
  final Stopwatch _clock = Stopwatch();
  Timer? _timer;
  Duration _lastAdvance = Duration.zero;
  double _phase = 0;
  bool _reduceMotion = false;
  bool _tickerAllowed = true;
  bool _appActive = true;

  @override
  void initState() {
    super.initState();
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

  /// The palette crossfade used to repaint the whole mesh at the display
  /// rate. It now shares the mesh's 30 fps cadence; a 650 ms colour fade is
  /// far too slow for the intermediate frames to be visible.
  final Stopwatch _paletteClock = Stopwatch()..start();
  int _lastPaletteFrameUs = 0;

  void _onPaletteFrame() {
    final int now = _paletteClock.elapsedMicroseconds;
    if (now - _lastPaletteFrameUs < _precision.frameInterval.inMicroseconds) {
      return;
    }
    _lastPaletteFrameUs = now;
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
    final bool reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final bool allowed = TickerMode.valuesOf(context).enabled;
    if (reduce != _reduceMotion || allowed != _tickerAllowed) {
      _reduceMotion = reduce;
      _tickerAllowed = allowed;
      _syncPlayback();
    }
  }

  @override
  void didUpdateWidget(AlbumFlowBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    final List<Color> next = normalizeFlowPalette(widget.colors);
    if (!_samePalette(next, _to)) {
      _from = _rawPalette();
      _to = next;
      if (_reduceMotion) {
        _palette.value = 1;
      } else {
        _palette.forward(from: 0);
      }
    }
    final DynamicBackgroundPrecision precision = DynamicBackgroundPrecision.of(
      widget.quality,
    );
    if (precision != _precision) {
      _precision = precision;
      // The timer period is fixed when it starts: drop it and start the lane
      // again so the new cadence applies immediately instead of on the next
      // rebuild.
      _timer?.cancel();
      _timer = null;
      _syncPlayback();
      _frames.value++;
    }
    if (oldWidget.animated != widget.animated ||
        oldWidget.solid != widget.solid ||
        oldWidget.preview != widget.preview) {
      _syncPlayback();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _palette
      ..removeListener(_onPaletteFrame)
      ..removeStatusListener(_onPaletteStatus)
      ..dispose();
    _frames.dispose();
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
    if (_runs) {
      if (_timer == null) {
        _clock
          ..reset()
          ..start();
        _lastAdvance = Duration.zero;
        _timer = Timer.periodic(_precision.frameInterval, (_) => _advance());
      }
    } else {
      _timer?.cancel();
      _timer = null;
      _clock.stop();
    }
  }

  void _advance() {
    final Duration elapsed = _clock.elapsed;
    final double delta =
        (elapsed - _lastAdvance).inMicroseconds /
        Duration.microsecondsPerSecond;
    _lastAdvance = elapsed;
    // Slowly rotating/breathing mesh: AMLL drives its WebGL mesh from a
    // 10-second time base, with a volume-responsive UV rotation.
    _phase = (_phase + delta.clamp(0.0, .1)) % 10000;
    _frames.value++;
  }

  /// The palette before the per-colour vibrancy treatment, used as the
  /// crossfade origin so the adjustment is never applied twice.
  List<Color> _rawPalette() {
    final double t = _fluidEase(_palette.value);
    return List<Color>.generate(
      5,
      (int i) => Color.lerp(_from[i], _to[i], t) ?? _to[i],
    );
  }

  /// The palette actually painted: saturation and lightness are nudged once
  /// per colour instead of once per mesh vertex. The old per-vertex HSL
  /// conversion cost ~550 round trips through HSL every frame; doing it here
  /// leaves the mesh with plain colour lerps and looks the same.
  List<Color> _currentPalette() => <Color>[
    for (final Color color in _rawPalette()) _vivid(color),
  ];

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.cornerRadius),
        child: CustomPaint(
          key: ValueKey<String>(widget.solid ? 'solid' : 'flow'),
          painter: _FlowPainter(
            palette: _currentPalette,
            phase: () => _phase,
            veil: widget.veil,
            solid: widget.solid,
            preview: widget.preview,
            columns: _precision.columns,
            rows: _precision.rows,
            // The palette controller reports through [_onPaletteFrame], so
            // the painter only follows the throttled mesh lane.
            repaint: _frames,
          ),
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

/// Paints the AMLL-derived animated mesh in one pass.
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
  final bool solid;
  final bool preview;

  /// Mesh quads across and down; `动态背景渲染精度` scales them.
  final int columns;
  final int rows;

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

  Color _samplePalette(List<Color> colors, double amount) {
    if (colors.length == 1) return colors.first;
    final double scaled = amount.clamp(0.0, .999999) * (colors.length - 1);
    final int low = scaled.floor();
    final int high = (low + 1).clamp(0, colors.length - 1);
    return Color.lerp(colors[low], colors[high], scaled - low) ?? colors[low];
  }

  Color _meshColor(
    List<Color> colors,
    double waveA,
    double waveB,
    double waveMix,
  ) {
    final double sampleA = (.08 + waveA * .58).clamp(0.0, 1.0);
    final double sampleB = (.38 + waveB * .60).clamp(0.0, 1.0);
    final Color upper = _samplePalette(colors, sampleA);
    final Color lower = _samplePalette(colors, sampleB);
    final double mix = (.42 + .25 * waveMix).clamp(0.0, 1.0);
    // The palette arrives already saturation/lightness-treated, so this is a
    // plain colour blend — no HSL conversion per vertex.
    return Color.lerp(upper, lower, mix) ?? lower;
  }

  ui.Shader? _veilShader;
  double _veilExtent = -1;
  Color? _veilTint;

  ui.Shader _veilShaderFor(Size size, Color veil) {
    final double extent = size.shortestSide;
    if (_veilShader == null || _veilExtent != extent || _veilTint != veil) {
      _veilExtent = extent;
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
    final List<Color> colors = palette();
    final Rect canvasRect = Offset.zero & size;
    if (preview && !solid) {
      // One ramp through the same palette, and nothing else: the expensive
      // warped mesh is not painted at all while the page carrying it is
      // still moving, so the frame costs a single full-screen fill.
      canvas.drawRect(
        canvasRect,
        Paint()
          ..shader = ui.Gradient.linear(
            canvasRect.topCenter,
            canvasRect.bottomCenter,
            <Color>[colors[0], colors[2], colors[4]],
            const <double>[0, .55, 1],
          ),
      );
    } else {
      canvas.drawRect(canvasRect, Paint()..color = colors[4]);
    }
    if (!solid && !preview) {
      _ensureMesh();
      final Float32List positions = _positions!;
      final Int32List vertexColors = _colors!;
      final double time = phase();
      final double width = size.width;
      final double height = size.height;
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
            vSinWaveX[row] * cosWaveXRowShift +
            vCosWaveX[row] * sinWaveXRowShift;
        rowWaveY[row] =
            vCosWaveY[row] * cosWaveYRowShift -
            vSinWaveY[row] * sinWaveYRowShift;
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
          final double waveX =
              rowWaveX[row] * .115 + columnWaveX[column] * .055;
          final double waveY = columnWaveY[column] * .12 + rowWaveY[row] * .065;
          positions[vertex * 2] = (u + waveX * envelope) * width;
          positions[vertex * 2 + 1] = (v + waveY * envelope) * height;
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
          vertexColors[vertex] = _meshColor(
            colors,
            waveA,
            waveB,
            waveMix,
          ).toARGB32();
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
    }
    if (veil.a > 0) {
      final Rect bounds = Offset.zero & size;
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

final Map<String, Color> _seedCache = <String, Color>{};

/// Samples the artwork down to 48×48 and picks the dominant *vibrant* hue,
/// boosting its saturation — the legacy `seedFromArtwork`.
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

final Map<String, List<Color>> _meshPaletteCache = <String, List<Color>>{};

Future<List<Color>?> albumMeshColorsForCover(String? coverUrl) async {
  final String? url = albumPaletteArtworkUrl(coverUrl);
  if (url == null) return null;
  final List<Color>? cached = _meshPaletteCache[url];
  if (cached != null) return cached;
  final ui.Image? image = await _decode(ArtworkImage(url));
  if (image == null) return null;
  try {
    final ByteData? pixels = await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    if (pixels == null) return null;
    final List<Color> colors = albumMeshColorsFromPixels(
      pixels.buffer.asUint8List(),
      image.width,
      image.height,
    );
    if (_meshPaletteCache.length >= 24) {
      _meshPaletteCache.remove(_meshPaletteCache.keys.first);
    }
    _meshPaletteCache[url] = colors;
    return colors;
  } finally {
    image.dispose();
  }
}

/// A 96 px rendition of the cover — enough for a palette, cheap to fetch.
String? albumPaletteArtworkUrl(String? raw) {
  final String? normalized = normalizedArtworkUrl(raw);
  if (normalized == null) return null;
  final RegExp param = RegExp(r'([?&]param=)\d+y\d+', caseSensitive: false);
  if (param.hasMatch(normalized)) {
    return normalized.replaceAllMapped(
      param,
      (Match match) => '${match.group(1)}96y96',
    );
  }
  return normalized +
      (normalized.contains('?') ? '&param=96y96' : '?param=96y96');
}

/// Extracts (and caches) the seed colour for a cover, or null when the artwork
/// cannot be decoded.
Future<Color?> albumSeedForCover(String? coverUrl) async {
  final String? url = albumPaletteArtworkUrl(coverUrl);
  if (url == null) return null;
  final Color? cached = _seedCache[url];
  if (cached != null) return cached;
  final ui.Image? image = await _decode(ArtworkImage(url));
  if (image == null) return null;
  try {
    final ByteData? pixels = await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    if (pixels == null) return null;
    final Color seed = albumSeedFromPixels(
      pixels.buffer.asUint8List(),
      image.width,
      image.height,
    );
    if (_seedCache.length >= 24) {
      _seedCache.remove(_seedCache.keys.first);
    }
    _seedCache[url] = seed;
    return seed;
  } finally {
    image.dispose();
  }
}

Future<ui.Image?> _decode(ImageProvider provider) {
  final Completer<ui.Image?> completer = Completer<ui.Image?>();
  final ImageStream stream = provider.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (ImageInfo info, bool synchronousCall) {
      if (!completer.isCompleted) completer.complete(info.image);
      stream.removeListener(listener);
    },
    onError: (Object error, StackTrace? stack) {
      if (!completer.isCompleted) completer.complete(null);
      stream.removeListener(listener);
    },
  );
  stream.addListener(listener);
  return completer.future;
}

/// The album-tinted page backdrop: flowing palette derived from the current
/// track, softened by the content-opacity veil.
class LegacyAlbumBackdrop extends StatefulWidget {
  const LegacyAlbumBackdrop({
    super.key,
    required this.track,
    required this.mode,
    required this.uiAlpha,
    this.imagePath,
    this.veil,
    this.pageColor,
    this.quality = kDynamicBackgroundQualityDefault,
    this.onSeed,
  });

  final Track? track;
  final LegacyBackgroundMode mode;

  /// Stored copy of the listener's picture, painted in
  /// [LegacyBackgroundMode.customImage].
  final String? imagePath;

  /// `内容不透明度` — 0.4 … 1.0. The veil over the palette is its square.
  final double uiAlpha;

  /// When set, the flow carries this veil itself and no content scrim is drawn
  /// — the now-playing page uses the legacy `background @ 0.38`.
  final Color? veil;

  /// Painted under the flow (legacy `colors.background`), and on its own when
  /// the backdrop is off.
  final Color? pageColor;

  /// `动态背景渲染精度` from Settings, handed to the flow canvas.
  final double quality;

  /// Reports the extracted artwork seed so the shell can seed its palette even
  /// when the backdrop itself is off.
  final ValueChanged<Color>? onSeed;

  @override
  State<LegacyAlbumBackdrop> createState() => _LegacyAlbumBackdropState();
}

class _LegacyAlbumBackdropState extends State<LegacyAlbumBackdrop> {
  List<Color> _colors = albumFlowColors(kAlbumDefaultSeed);
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(LegacyAlbumBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track?.id != widget.track?.id ||
        oldWidget.track?.coverUrl != widget.track?.coverUrl) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final int generation = ++_generation;
    final String? coverUrl = widget.track?.coverUrl;
    final List<Color>? mesh = await albumMeshColorsForCover(coverUrl);
    final Color? seed = await albumSeedForCover(coverUrl);
    if (!mounted || generation != _generation) return;
    setState(
      () => _colors = mesh ?? albumFlowColors(seed ?? kAlbumDefaultSeed),
    );
    widget.onSeed?.call(seed ?? kAlbumDefaultSeed);
  }

  @override
  Widget build(BuildContext context) {
    final Color? pageColor = widget.pageColor;
    if (widget.mode == LegacyBackgroundMode.off) {
      return pageColor == null
          ? const SizedBox.shrink()
          : ColoredBox(color: pageColor);
    }
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (widget.mode == LegacyBackgroundMode.customImage) {
      return _CustomImageBackdrop(
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
          animated: widget.mode == LegacyBackgroundMode.nowPlayingDynamic,
          solid: widget.mode == LegacyBackgroundMode.nowPlayingStatic,
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
class _CustomImageBackdrop extends StatelessWidget {
  const _CustomImageBackdrop({required this.path, required this.pageColor});

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
