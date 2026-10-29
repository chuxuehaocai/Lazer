// i18n:data — interface strings declared here are translated at their render sites.
/// Interface preferences shared by the shell and the settings page: which
/// presentation the app forces, how large the interface is drawn, and which
/// device form the density is tuned for.
library;

import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart' show TargetPlatform;

/// Window width below which the shell normally switches to its compact
/// (phone) presentation: bottom tab bar, floating transport, pushed details.
const double kCompactBreakpoint = 720;

/// How many cards the library lays its playlists out in per row.
///
/// `0` asks the grid to follow the window width — the density the library
/// opens with — while the other entries are the fixed counts 歌单排列 offers.
const List<int> kPlaylistColumnChoices = <int>[0, 2, 3, 4, 5, 6];

/// Widest fixed count 歌单排列 offers.
const int kPlaylistColumnsMax = 6;

/// How the shell picks its accent palette.
///
/// [fixed] is the Apple Music red accent. [nowPlaying] derives the accent and
/// ambient tint from the current cover, matching the app's album-led chrome.
/// [custom] uses the colour the listener picked in Settings.
enum LegacyPaletteMode { fixed, nowPlaying, custom }

extension LegacyPaletteModeLabels on LegacyPaletteMode {
  /// Chinese source string, translated through `context.tr`.
  String get label => switch (this) {
    LegacyPaletteMode.fixed => '默认',
    LegacyPaletteMode.nowPlaying => '跟随当前歌曲',
    LegacyPaletteMode.custom => '自定义',
  };

  String get detail => switch (this) {
    LegacyPaletteMode.fixed => 'Apple Music 红色强调色',
    LegacyPaletteMode.nowPlaying => '由当前封面主色生成强调色与浏览背景',
    LegacyPaletteMode.custom => '使用你挑选的强调色',
  };

  /// Parses a persisted [name]; unknown or missing values keep the fixed
  /// scheme.
  static LegacyPaletteMode parse(String? name) =>
      LegacyPaletteMode.values.firstWhere(
        (LegacyPaletteMode mode) => mode.name == name,
        orElse: () => LegacyPaletteMode.fixed,
      );
}

/// How the legacy shell paints its page backdrop.
///
/// The flowing album-colour canvas is ported from the Lazer project's
/// `AlbumFlowBackground`; [nowPlayingDynamic] animates it, [nowPlayingStatic]
/// freezes the palette to one flat base, [customImage] paints a picture the
/// listener chose, and [off] leaves the theme surface.
enum LegacyBackgroundMode {
  nowPlayingDynamic,
  nowPlayingStatic,
  customImage,
  off,
}

extension LegacyBackgroundModeLabels on LegacyBackgroundMode {
  /// Chinese source string, translated through `context.tr`.
  String get label => switch (this) {
    LegacyBackgroundMode.nowPlayingDynamic => '跟随当前歌曲（流动）',
    LegacyBackgroundMode.nowPlayingStatic => '当前歌曲纯色',
    LegacyBackgroundMode.customImage => '自定义图片',
    LegacyBackgroundMode.off => '不使用',
  };

  String get detail => switch (this) {
    LegacyBackgroundMode.nowPlayingDynamic => '使用当前歌曲封面主色渲染整页画布',
    LegacyBackgroundMode.nowPlayingStatic => '以当前歌曲封面主色铺满整页',
    LegacyBackgroundMode.customImage => '使用你选择的图片铺满整页',
    LegacyBackgroundMode.off => '关闭画布，只保留主题底色',
  };

  /// Parses a persisted [name]; unknown or missing values keep the flowing
  /// canvas the port ships with.
  static LegacyBackgroundMode parse(String? name) =>
      LegacyBackgroundMode.values.firstWhere(
        (LegacyBackgroundMode mode) => mode.name == name,
        orElse: () => LegacyBackgroundMode.nowPlayingDynamic,
      );
}

// ---------------------------------------------------------------------------
// Dynamic background precision
// ---------------------------------------------------------------------------

/// Mesh the flowing album canvas is authored at full precision: 28x18 quads,
/// i.e. 551 warped vertices over the whole page.
const int kFlowMeshColumns = 28;
const int kFlowMeshRows = 18;

/// Update cadence at full precision. A 60 Hz cap keeps the mesh motion smooth
/// on high-refresh displays without running the painter faster than the UI can
/// present useful frames.
const Duration kFlowFrameIntervalFull = Duration(milliseconds: 16);

/// Update cadence at the lowest precision — three times cheaper, still a
/// drifting canvas.
const Duration kFlowFrameIntervalLow = Duration(milliseconds: 100);

/// Smallest precision the `动态背景渲染精度` slider offers.
const double kDynamicBackgroundQualityMin = 0.1;

/// Largest precision: the mesh exactly as it is authored.
const double kDynamicBackgroundQualityMax = 1;

/// One slider notch, five percent.
const double kDynamicBackgroundQualityStep = 0.05;

/// Default precision. 80% draws the same colour field with 22x14 vertices and
/// refreshes at roughly 50 Hz, leaving the mesh visibly smooth while keeping
/// its vertex count below the authored maximum.
const double kDynamicBackgroundQualityDefault = 0.8;

/// Clamps to the supported range and snaps to [kDynamicBackgroundQualityStep],
/// so the slider and a persisted value always agree.
double normalizeDynamicBackgroundQuality(double value) {
  if (!value.isFinite) return kDynamicBackgroundQualityDefault;
  final double snapped =
      (value / kDynamicBackgroundQualityStep).roundToDouble() *
      kDynamicBackgroundQualityStep;
  final double clamped = snapped.clamp(
    kDynamicBackgroundQualityMin,
    kDynamicBackgroundQualityMax,
  );
  return (clamped * 100).roundToDouble() / 100;
}

/// What one precision setting actually draws: the mesh geometry handed to
/// `drawVertices` and the interval between two mesh updates.
///
/// This is the whole meaning of the setting — there is no hidden second knob.
/// At 10% the canvas is a 4x3 field refreshed about ten times per second; at
/// 100% it is the 28x18 field refreshed at 60 Hz. The cadence accelerates
/// earlier than the mesh density so the default 80% setting stays fluid.
class DynamicBackgroundPrecision {
  const DynamicBackgroundPrecision({
    required this.quality,
    required this.columns,
    required this.rows,
    required this.frameInterval,
  });

  /// The normalized 0.1 … 1.0 setting this plan was derived from.
  final double quality;

  /// Mesh quads across and down the canvas.
  final int columns;
  final int rows;

  /// Delay between two mesh updates.
  final Duration frameInterval;

  factory DynamicBackgroundPrecision.of(double quality) {
    final double q = normalizeDynamicBackgroundQuality(quality);
    final double qualityProgress =
        (q - kDynamicBackgroundQualityMin) /
        (kDynamicBackgroundQualityMax - kDynamicBackgroundQualityMin);
    // Most of the perceptual gain comes from moving the mesh above 30 fps.
    // Spend more of the cadence budget in the middle of the slider range,
    // where its grid is still substantially cheaper than the full mesh.
    final double cadenceProgress = math.pow(qualityProgress, 0.2).toDouble();
    final int span =
        kFlowFrameIntervalLow.inMicroseconds -
        kFlowFrameIntervalFull.inMicroseconds;
    return DynamicBackgroundPrecision(
      quality: q,
      // Four quads across and three down is the floor: below that the warp
      // stops reading as a mesh and the vertices become visible corners.
      columns: math.max(4, (kFlowMeshColumns * q).round()),
      rows: math.max(3, (kFlowMeshRows * q).round()),
      frameInterval: Duration(
        microseconds:
            (kFlowFrameIntervalLow.inMicroseconds - span * cadenceProgress)
                .round(),
      ),
    );
  }

  /// Vertices the painter uploads per frame.
  int get vertexCount => (columns + 1) * (rows + 1);

  /// Mesh updates per second.
  double get updatesPerSecond =>
      Duration.microsecondsPerSecond / frameInterval.inMicroseconds;

  @override
  bool operator ==(Object other) =>
      other is DynamicBackgroundPrecision &&
      other.quality == quality &&
      other.columns == columns &&
      other.rows == rows &&
      other.frameInterval == frameInterval;

  @override
  int get hashCode => Object.hash(quality, columns, rows, frameInterval);
}

/// How the shell picks between the desktop and the mobile presentation.
enum AppUiMode {
  /// Follow the window width — the desktop shell on wide windows, the compact
  /// one on narrow windows.
  auto,

  /// Always draw the desktop shell, whatever the window width.
  desktop,

  /// Always draw the compact shell, whatever the window width.
  mobile,
}

extension AppUiModeLabels on AppUiMode {
  /// Chinese source string, translated through `context.tr`.
  String get label => switch (this) {
    AppUiMode.auto => '自动选择',
    AppUiMode.desktop => '强制桌面端',
    AppUiMode.mobile => '强制移动端',
  };

  String get detail => switch (this) {
    AppUiMode.auto => '按窗口宽度在桌面端和移动端之间切换',
    AppUiMode.desktop => '始终显示左侧导航栏和桌面播放条',
    AppUiMode.mobile => '始终显示底部标签栏和紧凑播放条',
  };

  /// Parses a persisted [name]; unknown or missing values fall back to
  /// [AppUiMode.auto].
  static AppUiMode parse(String? name) => AppUiMode.values.firstWhere(
    (AppUiMode mode) => mode.name == name,
    orElse: () => AppUiMode.auto,
  );
}

/// Whether the shell should draw its compact presentation.
///
/// [width] is the width available to the shell in logical pixels.
bool useCompactLayout(AppUiMode mode, double width) => switch (mode) {
  AppUiMode.mobile => true,
  AppUiMode.desktop => false,
  AppUiMode.auto => width < kCompactBreakpoint,
};

// ---------------------------------------------------------------------------
// DPI scaling
// ---------------------------------------------------------------------------

/// Smallest interface scale the settings slider offers.
const double kDpiScaleMin = 0.8;

/// Largest interface scale the settings slider offers.
const double kDpiScaleMax = 1.75;

/// Grid the scale snaps to — one slider notch, i.e. five percent.
const double kDpiScaleStep = 0.05;

/// The 1× baseline: logical pixels exactly as the platform reports them.
const double kDpiScaleDefault = 1;

/// Clamps to the supported range and snaps to [kDpiScaleStep] so the slider
/// and a persisted value always agree.
double normalizeDpiScale(double value) {
  if (!value.isFinite) return kDpiScaleDefault;
  final double snapped =
      (value / kDpiScaleStep).roundToDouble() * kDpiScaleStep;
  final double clamped = snapped.clamp(kDpiScaleMin, kDpiScaleMax);
  return (clamped * 100).roundToDouble() / 100;
}

/// Largest scale the automatic mode will pick. The estimate only ever grows
/// the interface, so this is the ceiling for very large workspaces.
const double kAutoDpiScaleMax = 1.75;

/// The workspace the 1× layout is tuned for: a 1920×1080 logical desktop.
const double kDpiReferenceArea = 1920 * 1080;

/// Estimates the interface scale a workspace needs.
///
/// High-resolution displays running at a 100% system scale report a large
/// logical workspace, which renders the app physically small. The estimate
/// therefore scales with the square root of the workspace area relative to a
/// 1080p reference — the same factor as the diagonal, so 2560×1440 lands at
/// about 1.35× and 3840×2160 at the 1.75× ceiling. Small workspaces keep 1×,
/// and the result is never below it: an explicit user or system choice to
/// shrink the interface is respected instead of being second-guessed.
double dpiScaleForWorkspace(Size workspace) {
  final double area = workspace.width * workspace.height;
  if (!area.isFinite || area <= 0) return kDpiScaleDefault;
  final double estimate = math.sqrt(area / kDpiReferenceArea);
  if (estimate <= 1) return kDpiScaleDefault;
  return normalizeDpiScale(estimate.clamp(1, kAutoDpiScaleMax));
}

// ---------------------------------------------------------------------------
// Device form
// ---------------------------------------------------------------------------

/// Which device the interface is drawn for.
///
/// The interface is designed at desktop density: a 15 px body, 48 px controls,
/// rows a mouse can hit. A car head unit is a different place to use it — the
/// screen is large but sits an arm's length away behind glass, it is touched in
/// motion, and its pixels are not dense (a 1280×720 or 1920×720 panel reports a
/// 100% density, so the same logical pixels are physically big but far away).
/// The car profile answers that with a larger interface floor and roomier
/// controls. A television keeps the standard interface scale — its panel is
/// already large — and instead adds remote navigation: the TV profile turns
/// every tap target into a directional focus stop.
enum AppSurface {
  /// Recognise a head unit or television from the platform and switch by
  /// itself.
  auto,

  /// Whatever density the platform reports.
  standard,

  /// Large, arm's-length controls, whatever the platform reports.
  car,

  /// Ten-foot interface for a television, driven by a D-pad remote.
  tv,
}

extension AppSurfaceLabels on AppSurface {
  /// Chinese source string, translated through `context.tr`.
  String get label => switch (this) {
    AppSurface.auto => '自动选择',
    AppSurface.standard => '标准',
    AppSurface.car => '车机',
    AppSurface.tv => '大屏幕模式',
  };

  String get detail => switch (this) {
    AppSurface.auto => '在 Android 车机或电视上自动切换；电视默认进入大屏幕模式',
    AppSurface.standard => '按平台上报的密度显示，桌面与手机默认如此',
    AppSurface.car => '放大界面与控件，适合远距离、行进中的触控',
    AppSurface.tv => '十英尺界面：方向键浏览，封面与文字为沙发距离重排',
  };

  /// Parses a persisted [name]; unknown or missing values fall back to
  /// [AppSurface.auto].
  static AppSurface parse(String? name) => AppSurface.values.firstWhere(
    (AppSurface surface) => surface.name == name,
    orElse: () => AppSurface.auto,
  );
}

/// Smallest interface scale the car profile allows.
///
/// A head unit is read from a metre away, through glass, while the car moves:
/// 1× desktop density is what made the interface look tiny there. The floor is
/// a starting point the DPI slider can still raise.
const double kCarScaleMin = 1.35;

/// Physical pixels below which a display is never a head unit.
const Size kCarMinPhysicalSize = Size(960, 540);

/// Highest device pixel ratio a head unit reports. Phones report 2–3.5×, so a
/// 1× panel is either an embedded/10-foot display or an old, low-density one —
/// both of which want the larger treatment.
const double kCarMaxDevicePixelRatio = 1.5;

/// Best-effort head-unit recognition.
///
/// The app cannot ask Android whether it is running on a vehicle head unit
/// without platform code, so this reads the shape such a device always has:
/// an embedded Android panel that renders at (or near) one physical pixel per
/// logical pixel, is landscape, and is at least 960×540. Android TV boxes pass
/// the same test and want the same large, far-viewed interface, so they share
/// it; phones (density ≥ 2) and portrait tablets never match. Desktop
/// platforms are excluded on purpose — a window's size says nothing about the
/// display behind it, so there the choice stays manual.
bool looksLikeCarDisplay({
  required TargetPlatform platform,
  required Size physicalSize,
  required double devicePixelRatio,
}) {
  if (platform != TargetPlatform.android) return false;
  if (!devicePixelRatio.isFinite || devicePixelRatio <= 0) return false;
  if (devicePixelRatio > kCarMaxDevicePixelRatio) return false;
  if (physicalSize.width < kCarMinPhysicalSize.width) return false;
  if (physicalSize.height < kCarMinPhysicalSize.height) return false;
  // Head units are mounted in landscape; a portrait window is not one.
  return physicalSize.width > physicalSize.height;
}

/// Whether the car profile is in effect for [surface], given the platform's
/// own answer ([detected]).
bool carSurfaceActive(AppSurface surface, {required bool detected}) =>
    switch (surface) {
      AppSurface.car => true,
      AppSurface.standard || AppSurface.tv => false,
      AppSurface.auto => detected,
    };

/// Whether the television interaction profile is in effect for [surface].
///
/// [detected] is the platform's answer — a Leanback/television Android device.
bool tvSurfaceActive(AppSurface surface, {required bool detected}) =>
    switch (surface) {
      AppSurface.tv => true,
      AppSurface.standard || AppSurface.car => false,
      AppSurface.auto => detected,
    };

/// The density profile the shell draws for.
enum DeviceProfile { standard, car, tv }

/// Resolves [surface] against what the platform reports.
///
/// An explicit choice always wins. In [AppSurface.auto] a television takes
/// priority over the car heuristic: both have large, low-density landscape
/// panels, but only the television is driven by a D-pad remote.
DeviceProfile resolveDeviceProfile(
  AppSurface surface, {
  required bool television,
  required bool car,
}) => switch (surface) {
  AppSurface.tv => DeviceProfile.tv,
  AppSurface.car => DeviceProfile.car,
  AppSurface.standard => DeviceProfile.standard,
  AppSurface.auto =>
    television
        ? DeviceProfile.tv
        : car
        ? DeviceProfile.car
        : DeviceProfile.standard,
};

/// The smallest interface scale the active profile allows.
///
/// Only the car profile raises the floor. A television keeps the standard
/// scale: its panel is already large, and the user can still enlarge it with
/// the DPI slider.
double dpiScaleFloor({required bool car}) => car ? kCarScaleMin : kDpiScaleMin;
