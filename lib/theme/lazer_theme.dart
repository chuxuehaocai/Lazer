import 'package:flutter/material.dart';

/// Declarative style tokens shared by the built-in widgets.
///
/// A Lua skin will eventually provide the same JSON-shaped values. It never
/// receives a Flutter context or a Widget callback; the host remains in charge
/// of accessibility, focus, hit testing and platform-specific rendering.
// ---------------------------------------------------------------------------
// Skin colours
// ---------------------------------------------------------------------------

/// Semantic colour slots a skin may override.
///
/// They are the same roles the built-in Apple palette uses, so a skin changes
/// tones without the host losing contrast, focus or accessibility guarantees.
const Set<String> skinColorSlots = <String>{
  'background',
  'secondaryBackground',
  'tertiaryBackground',
  'groupedBackground',
  'secondaryGroupedBackground',
  'tertiaryGroupedBackground',
  'label',
  'secondaryLabel',
  'tertiaryLabel',
  'quaternaryLabel',
  'fill',
  'secondaryFill',
  'tertiaryFill',
  'separator',
  'opaqueSeparator',
  'accent',
  'accentSoft',
  'glass',
  'glassStrong',
};

/// Aliases let a paper-style skin speak its own vocabulary.
///
/// `canvas`, `ink`, `hairline` and `playerSurface` are the names the parchment
/// design system uses; they resolve to the semantic slots above.
const Map<String, String> skinColorAliases = <String, String>{
  'page': 'background',
  'canvas': 'background',
  'ivory': 'background',
  'ivorymedium': 'background',
  'surface': 'secondaryGroupedBackground',
  'card': 'secondaryGroupedBackground',
  'ivorylight': 'secondaryGroupedBackground',
  'panel': 'secondaryGroupedBackground',
  'grouped': 'groupedBackground',
  'ink': 'label',
  'text': 'label',
  'slatedark': 'label',
  'muted': 'secondaryLabel',
  'secondaryink': 'secondaryLabel',
  'clouddark': 'secondaryLabel',
  'dim': 'tertiaryLabel',
  'tertiaryink': 'tertiaryLabel',
  'cloudmedium': 'tertiaryLabel',
  'hairline': 'separator',
  'stone': 'separator',
  'highlight': 'fill',
  'oatwarm': 'fill',
  'playerbar': 'glassStrong',
  'playersurface': 'glassStrong',
  'glassstrong': 'glassStrong',
  'glass': 'glass',
  'clay': 'accent',
  'accent': 'accent',
};

/// Resolves a skin colour key (slot or alias, case-insensitive) to a slot.
String? canonicalColorSlot(Object? name) {
  if (name is! String) return null;
  final key = name.trim().toLowerCase();
  if (key.isEmpty) return null;
  if (skinColorSlots.contains(name.trim())) return name.trim();
  final alias = skinColorAliases[key];
  if (alias != null) return alias;
  for (final slot in skinColorSlots) {
    if (slot.toLowerCase() == key) return slot;
  }
  return null;
}

/// Parses `#rgb`, `#rrggbb`, `#aarrggbb`, `0xAARRGGBB` or an integer ARGB.
Color? parseSkinColor(Object? value) {
  if (value is num) {
    final int argb = value.toInt();
    if (argb < 0 || argb > 0xFFFFFFFF) return null;
    return Color(argb);
  }
  if (value is! String) return null;
  var text = value.trim();
  if (text.isEmpty) return null;
  if (text.startsWith('#')) text = text.substring(1);
  if (text.startsWith('0x') || text.startsWith('0X')) text = text.substring(2);
  if (text.length == 3) {
    text = text.split('').map((c) => '$c$c').join();
  }
  if (text.length == 6) text = 'FF$text';
  if (text.length != 8) return null;
  final int? parsed = int.tryParse(text, radix: 16);
  if (parsed == null) return null;
  return Color(parsed);
}

/// Parses the `colors` map of a skin; unknown keys and bad values are ignored.
Map<String, Color> parseSkinColors(Object? raw) {
  if (raw is! Map) return const <String, Color>{};
  final out = <String, Color>{};
  for (final entry in raw.entries) {
    final slot = canonicalColorSlot(entry.key);
    final color = parseSkinColor(entry.value);
    if (slot == null || color == null) continue;
    out[slot] = color;
  }
  return out;
}

/// `#AARRGGBB`, the format [parseSkinColor] accepts back.
String formatSkinColor(Color color) =>
    '#${color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';


/// Normalises `backgroundPlayMode`; unknown values mean "keep the user setting".
String skinMode(Object? value) {
  if (value is! String) return '';
  switch (value.trim()) {
    case 'off':
    case 'none':
      return 'off';
    case 'nowPlayingStatic':
    case 'static':
      return 'nowPlayingStatic';
    case 'nowPlayingDynamic':
    case 'dynamic':
      return 'nowPlayingDynamic';
    default:
      return '';
  }
}

@immutable
class LazerThemeTokens extends ThemeExtension<LazerThemeTokens> {
  const LazerThemeTokens({
    this.id = 'builtin.apple',
    this.name = 'Apple',
    this.version = 1,
    this.groupedCardRadius = 14,
    this.listTileMinHeight = 50,
    this.listTileVerticalPadding = 11,
    this.pageTitleCompactSize = 34,
    this.pageTitleRegularSize = 32,
    this.sectionHeaderSize = 20,
    this.displayWeight = 700,
    this.headingWeight = 700,
    this.titleWeight = 600,
    this.bodyWeight = 400,
    this.labelWeight = 500,
    this.lyricWeight = -1,
    this.lyricTranslationWeight = -1,
    this.lyricFontScale = 1,
    this.lyricTranslationScale = .7272727,
    this.lyricLineHeight = 1.5,
    this.lyricTranslationLineHeight = 1.45,
    this.lyricTranslationGap = 5,
    this.lyricDimAlpha = .48,
    this.lyricTranslationAlpha = .58,
    this.lyricTextAlign = 'start',
    this.lyricSpringMassScale = 1,
    this.lyricSpringStiffnessScale = 1,
    this.lyricSpringDampingScale = 1,
    this.lyricStaggerDelay = .05,
    this.lyricStaggerDecay = 1.05,
    this.lyricFocusScaleDelta = 3,
    this.controlRadius = 12,
    this.glassBlurSigma = 16,
    this.colors = const <String, Color>{},
    this.darkColors = const <String, Color>{},
    this.railWidth = 0,
    this.playerBarHeight = 0,
    this.compactPlayerBarHeight = 0,
    this.cornerScale = 1,
    this.capsuleRadius = -1,
    this.navBarRadius = -1,
    this.nowPlayingArtworkMax = 0,
    this.nowPlayingArtworkMin = 0,
    this.nowPlayingArtworkFraction = 0,
    this.nowPlayingSidePadding = 0,
    this.nowPlayingSidePaddingMax = 0,
    this.nowPlayingTitleSize = 0,
    this.nowPlayingSubtitleSize = 0,
    this.nowPlayingMetaSize = 0,
    this.nowPlayingDockHeight = 0,
    this.nowPlayingCoverRadius = 0,
    this.backgroundOpacity = 1,
    this.backgroundBlurSigma = -1,
    this.backgroundVeilAlpha = -1,
    this.backgroundPlayMode = '',
    this.artworkRadius = 0,
  });


  final String id;
  final String name;
  final int version;
  final double groupedCardRadius;
  final double listTileMinHeight;
  final double listTileVerticalPadding;
  final double pageTitleCompactSize;
  final double pageTitleRegularSize;
  final double sectionHeaderSize;
  final int displayWeight;
  final int headingWeight;
  final int titleWeight;
  final int bodyWeight;
  final int labelWeight;
  final int lyricWeight;
  final int lyricTranslationWeight;
  final double lyricFontScale;
  final double lyricTranslationScale;
  final double lyricLineHeight;
  final double lyricTranslationLineHeight;
  final double lyricTranslationGap;
  final double lyricDimAlpha;
  final double lyricTranslationAlpha;
  final String lyricTextAlign;
  final double lyricSpringMassScale;
  final double lyricSpringStiffnessScale;
  final double lyricSpringDampingScale;
  final double lyricStaggerDelay;
  final double lyricStaggerDecay;
  final double lyricFocusScaleDelta;
  final double controlRadius;
  final double glassBlurSigma;

  /// Semantic colour overrides keyed by [skinColorSlots]. Empty keeps the
  /// built-in palette; aliases are normalised by [parseSkinColors].
  final Map<String, Color> colors;

  /// Colour overrides used when the host renders its dark theme. Empty keeps
  /// [colors] for both brightnesses, which is what a light-only skin wants.
  final Map<String, Color> darkColors;

  /// Sidebar rail width in logical pixels; `0` keeps the adaptive metric.
  final double railWidth;

  /// Desktop player-bar minimum height; `0` keeps the built-in 92.
  final double playerBarHeight;

  /// Compact player-bar minimum height; `0` keeps the built-in 56/60.
  final double compactPlayerBarHeight;

  /// 全局圆角强度，0 = 全直角，1 = 主题原本的圆角。
  ///
  /// 用户可以在设置里选择「跟随主题设置」用这个值，或改用自己的滑块。
  /// 所有 BorderRadius 都乘上它（见 theme/shape_scale.dart）。
  final double cornerScale;

  /// 窗口胶囊（Inline 标题栏右上角那颗玻璃药丸）的圆角，单位 px，负值表示
  /// 「按 [cornerScale] × 满圆半径算」（老皮肤的行为）。0 = 直角。
  final double capsuleRadius;

  /// 移动端底边栏那条玻璃药丸的圆角，单位 px，负值同 [capsuleRadius]。
  final double navBarRadius;

  /// Widest artwork square on the listening canvas; `0` keeps 440.
  final double nowPlayingArtworkMax;

  /// Narrowest artwork square; `0` keeps 240.
  final double nowPlayingArtworkMin;

  /// Share of the canvas the artwork column takes; `0` keeps .34.
  final double nowPlayingArtworkFraction;

  /// Base horizontal padding of the listening canvas; `0` keeps 28.
  final double nowPlayingSidePadding;

  /// Upper clamp of that padding; `0` keeps 80.
  final double nowPlayingSidePaddingMax;

  /// Track title size on the listening canvas; `0` keeps the built-in ramp.
  final double nowPlayingTitleSize;

  /// Translator line size; `0` keeps the built-in ramp.
  final double nowPlayingSubtitleSize;

  /// Artist / album line size; `0` keeps the built-in ramp.
  final double nowPlayingMetaSize;

  /// Height of the transport dock; `0` keeps the built-in metric.
  final double nowPlayingDockHeight;

  /// Artwork corner radius on the listening canvas; `0` is square.
  final double nowPlayingCoverRadius;

  /// Artwork corner radius everywhere else; `0` is square.
  final double artworkRadius;

  /// Opacity of the painted backdrop, 1 keeps it fully drawn.
  final double backgroundOpacity;

  /// Backdrop blur; negative keeps the host preference, `0` disables it.
  final double backgroundBlurSigma;

  /// Strength of the veil painted over the backdrop; negative keeps the host
  /// default (.60), `1` hides the backdrop completely.
  final double backgroundVeilAlpha;

  /// Backdrop mode the skin wants: `''` keeps the user setting, `off` paints a
  /// flat canvas (what a paper design needs), `nowPlayingStatic` /
  /// `nowPlayingDynamic` keep the album flow.
  final String backgroundPlayMode;

  static const LazerThemeTokens apple = LazerThemeTokens();

  /// 内置主题：Mio。
  ///
  /// 客户端自带的一号主题（默认选它）。名字是代号，不是皮肤来源：几何与
  /// 调色板见 [builtinThemes]，它不走 Lua 插件。
  static const LazerThemeTokens mio = LazerThemeTokens(
    id: 'builtin.mio',
    name: 'Mio',
    version: 1,
    colors: <String, Color>{
      'background': Color(0xFFF0EEE6),
      'secondaryBackground': Color(0xFFFAF9F5),
      'tertiaryBackground': Color(0xFFFAF9F5),
      'groupedBackground': Color(0xFFF0EEE6),
      'secondaryGroupedBackground': Color(0xFFFAF9F5),
      'tertiaryGroupedBackground': Color(0xFFFAF9F5),
      'label': Color(0xFF141413),
      'secondaryLabel': Color(0xFF87867F),
      'tertiaryLabel': Color(0xFFB0AEA5),
      'quaternaryLabel': Color(0xFFCCCBC8),
      'fill': Color(0xFFE3DACC),
      'secondaryFill': Color(0xFFF5E3C7),
      'tertiaryFill': Color(0xFFFAF9F5),
      'separator': Color(0xFFCCCBC8),
      'opaqueSeparator': Color(0xFF87867F),
      'accent': Color(0xFFD97757),
      'accentSoft': Color(0x26D97757),
      'glass': Color(0xE6FAF9F5),
      'glassStrong': Color(0xF2141413),
    },
    darkColors: <String, Color>{
      'background': Color(0xFF191918),
      'secondaryBackground': Color(0xFF242423),
      'tertiaryBackground': Color(0xFF242423),
      'groupedBackground': Color(0xFF191918),
      'secondaryGroupedBackground': Color(0xFF242423),
      'tertiaryGroupedBackground': Color(0xFF242423),
      'label': Color(0xFFF0EEE6),
      'secondaryLabel': Color(0xFFB5B2A9),
      'tertiaryLabel': Color(0xFFA8A69E),
      'quaternaryLabel': Color(0xFF454540),
      'fill': Color(0xFF34312D),
      'secondaryFill': Color(0xFF3E3329),
      'tertiaryFill': Color(0xFF242423),
      'separator': Color(0xFF454540),
      'opaqueSeparator': Color(0xFFB5B2A9),
      'accent': Color(0xFFE68E70),
      'accentSoft': Color(0x26E68E70),
      'glass': Color(0xE6242423),
      'glassStrong': Color(0xF2141413),
    },
    groupedCardRadius: 0,
    listTileMinHeight: 64,
    listTileVerticalPadding: 10,
    pageTitleCompactSize: 40,
    pageTitleRegularSize: 56,
    sectionHeaderSize: 12,
    displayWeight: 400,
    headingWeight: 700,
    titleWeight: 600,
    bodyWeight: 400,
    labelWeight: 600,
    lyricWeight: 500,
    lyricTranslationWeight: 400,
    lyricTranslationScale: .73,
    lyricLineHeight: 1.5,
    lyricTranslationLineHeight: 1.45,
    lyricTranslationGap: 5,
    lyricDimAlpha: .48,
    lyricTranslationAlpha: .48,
    lyricStaggerDelay: .05,
    lyricStaggerDecay: 1.05,
    lyricFocusScaleDelta: 3,
    controlRadius: 12,
    glassBlurSigma: 0,
    capsuleRadius: 0,
    navBarRadius: 0,
    railWidth: 232,
    playerBarHeight: 100,
    compactPlayerBarHeight: 72,
    nowPlayingArtworkFraction: .34,
    nowPlayingArtworkMin: 240,
    nowPlayingArtworkMax: 440,
    nowPlayingSidePadding: 32,
    nowPlayingSidePaddingMax: 32,
    nowPlayingTitleSize: 30,
    nowPlayingSubtitleSize: 15,
    nowPlayingMetaSize: 18,
    nowPlayingCoverRadius: 0,
    backgroundOpacity: 1,
    backgroundBlurSigma: 0,
    backgroundVeilAlpha: 1,
    backgroundPlayMode: 'off',
  );

  /// 客户端自带、可以在设置里挑的主题，按显示顺序。
  ///
  /// 默认只有 [mio] 一个；Lua 皮肤不走这张表（它们由插件管理器提供）。
  static const List<LazerThemeTokens> builtinThemes = <LazerThemeTokens>[mio];

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'version': version,
    'elements': <String, Object?>{
      'groupedCardRadius': groupedCardRadius,
      'listTileMinHeight': listTileMinHeight,
      'listTileVerticalPadding': listTileVerticalPadding,
      'pageTitleCompactSize': pageTitleCompactSize,
      'pageTitleRegularSize': pageTitleRegularSize,
      'sectionHeaderSize': sectionHeaderSize,
      'displayWeight': displayWeight,
      'headingWeight': headingWeight,
      'titleWeight': titleWeight,
      'bodyWeight': bodyWeight,
      'labelWeight': labelWeight,
      'lyricWeight': lyricWeight,
      'lyricTranslationWeight': lyricTranslationWeight,
      'lyricFontScale': lyricFontScale,
      'lyricTranslationScale': lyricTranslationScale,
      'lyricLineHeight': lyricLineHeight,
      'lyricTranslationLineHeight': lyricTranslationLineHeight,
      'lyricTranslationGap': lyricTranslationGap,
      'lyricDimAlpha': lyricDimAlpha,
      'lyricTranslationAlpha': lyricTranslationAlpha,
      'lyricTextAlign': lyricTextAlign,
      'lyricSpringMassScale': lyricSpringMassScale,
      'lyricSpringStiffnessScale': lyricSpringStiffnessScale,
      'lyricSpringDampingScale': lyricSpringDampingScale,
      'lyricStaggerDelay': lyricStaggerDelay,
      'lyricStaggerDecay': lyricStaggerDecay,
      'lyricFocusScaleDelta': lyricFocusScaleDelta,
      'controlRadius': controlRadius,
      'glassBlurSigma': glassBlurSigma,
      'colors': <String, Object?>{
        for (final entry in colors.entries)
          entry.key: formatSkinColor(entry.value),
      },
      'darkColors': <String, Object?>{
        for (final entry in darkColors.entries)
          entry.key: formatSkinColor(entry.value),
      },
      'railWidth': railWidth,
      'playerBarHeight': playerBarHeight,
      'compactPlayerBarHeight': compactPlayerBarHeight,
      'cornerScale': cornerScale,
      'capsuleRadius': capsuleRadius,
      'navBarRadius': navBarRadius,
      'nowPlayingArtworkMax': nowPlayingArtworkMax,
      'nowPlayingArtworkMin': nowPlayingArtworkMin,
      'nowPlayingArtworkFraction': nowPlayingArtworkFraction,
      'nowPlayingSidePadding': nowPlayingSidePadding,
      'nowPlayingSidePaddingMax': nowPlayingSidePaddingMax,
      'nowPlayingTitleSize': nowPlayingTitleSize,
      'nowPlayingSubtitleSize': nowPlayingSubtitleSize,
      'nowPlayingMetaSize': nowPlayingMetaSize,
      'nowPlayingDockHeight': nowPlayingDockHeight,
      'nowPlayingCoverRadius': nowPlayingCoverRadius,
      'artworkRadius': artworkRadius,
      'backgroundOpacity': backgroundOpacity,
      'backgroundBlurSigma': backgroundBlurSigma,
      'backgroundVeilAlpha': backgroundVeilAlpha,
      'backgroundPlayMode': backgroundPlayMode,
    },
  };

  factory LazerThemeTokens.fromJson(Map<String, Object?> json) {
    final rawElements = json['elements'];
    final elements = rawElements is Map
        ? <String, Object?>{
            for (final entry in rawElements.entries)
              if (entry.key is String) entry.key as String: entry.value,
          }
        : const <String, Object?>{};
    String text(Object? value, String fallback) =>
        value is String && value.trim().isNotEmpty ? value.trim() : fallback;
    double number(
      String key,
      double fallback, {
      double min = 0,
      double max = 200,
    }) {
      final value = elements[key] is num
          ? (elements[key]! as num).toDouble()
          : fallback;
      return value.isFinite ? value.clamp(min, max) : fallback;
    }

    int weight(String key, int fallback) {
      final value = elements[key] is num
          ? (elements[key]! as num).round()
          : fallback;
      return value.clamp(100, 900);
    }

    int optionalWeight(String key) {
      final value = elements[key];
      return value is num ? value.round().clamp(-1, 900) : -1;
    }

    String alignment(Object? value) =>
        value is String &&
            const <String>{'start', 'center', 'end', 'justify'}.contains(value)
        ? value
        : 'start';

    return LazerThemeTokens(
      id: text(json['id'], 'custom.unnamed'),
      name: text(json['name'], 'Custom'),
      version: json['version'] is num ? (json['version']! as num).toInt() : 1,
      groupedCardRadius: number('groupedCardRadius', 14, max: 40),
      listTileMinHeight: number('listTileMinHeight', 50, max: 160),
      listTileVerticalPadding: number('listTileVerticalPadding', 11, max: 48),
      pageTitleCompactSize: number('pageTitleCompactSize', 34, max: 72),
      pageTitleRegularSize: number('pageTitleRegularSize', 32, max: 72),
      sectionHeaderSize: number('sectionHeaderSize', 20, max: 48),
      displayWeight: weight('displayWeight', 700),
      headingWeight: weight('headingWeight', 700),
      titleWeight: weight('titleWeight', 600),
      bodyWeight: weight('bodyWeight', 400),
      labelWeight: weight('labelWeight', 500),
      lyricWeight: optionalWeight('lyricWeight'),
      lyricTranslationWeight: optionalWeight('lyricTranslationWeight'),
      lyricFontScale: number('lyricFontScale', 1, min: .5, max: 2),
      lyricTranslationScale: number(
        'lyricTranslationScale',
        .7272727,
        min: .4,
        max: 1.5,
      ),
      lyricLineHeight: number('lyricLineHeight', 1.5, min: .8, max: 3),
      lyricTranslationLineHeight: number(
        'lyricTranslationLineHeight',
        1.45,
        min: .8,
        max: 3,
      ),
      lyricTranslationGap: number('lyricTranslationGap', 5, min: 0, max: 48),
      lyricDimAlpha: number('lyricDimAlpha', .48, max: 1),
      lyricTranslationAlpha: number('lyricTranslationAlpha', .58, max: 1),
      lyricTextAlign: alignment(elements['lyricTextAlign']),
      lyricSpringMassScale: number('lyricSpringMassScale', 1, min: .25, max: 4),
      lyricSpringStiffnessScale: number(
        'lyricSpringStiffnessScale',
        1,
        min: .25,
        max: 4,
      ),
      lyricSpringDampingScale: number(
        'lyricSpringDampingScale',
        1,
        min: .25,
        max: 4,
      ),
      lyricStaggerDelay: number('lyricStaggerDelay', .05, max: .5),
      lyricStaggerDecay: number('lyricStaggerDecay', 1.05, min: 1, max: 2),
      lyricFocusScaleDelta: number('lyricFocusScaleDelta', 3, min: .5, max: 20),
      controlRadius: number('controlRadius', 12, max: 40),
      glassBlurSigma: number('glassBlurSigma', 16, max: 48),
      colors: parseSkinColors(elements['colors']),
      darkColors: parseSkinColors(elements['darkColors']),
      railWidth: number('railWidth', 0, max: 420),
      playerBarHeight: number('playerBarHeight', 0, max: 200),
      compactPlayerBarHeight: number('compactPlayerBarHeight', 0, max: 160),
      cornerScale: number('cornerScale', 1, max: 2),
      capsuleRadius: number('capsuleRadius', -1, max: 64),
      navBarRadius: number('navBarRadius', -1, max: 64),
      nowPlayingArtworkMax: number('nowPlayingArtworkMax', 0, max: 1200),
      nowPlayingArtworkMin: number('nowPlayingArtworkMin', 0, max: 1200),
      nowPlayingArtworkFraction: number(
        'nowPlayingArtworkFraction',
        0,
        max: .9,
      ),
      nowPlayingSidePadding: number('nowPlayingSidePadding', 0, max: 200),
      nowPlayingSidePaddingMax: number(
        'nowPlayingSidePaddingMax',
        0,
        max: 400,
      ),
      nowPlayingTitleSize: number('nowPlayingTitleSize', 0, max: 96),
      nowPlayingSubtitleSize: number('nowPlayingSubtitleSize', 0, max: 72),
      nowPlayingMetaSize: number('nowPlayingMetaSize', 0, max: 72),
      nowPlayingDockHeight: number('nowPlayingDockHeight', 0, max: 240),
      nowPlayingCoverRadius: number('nowPlayingCoverRadius', 0, max: 64),
      artworkRadius: number('artworkRadius', 0, max: 64),
      backgroundOpacity: number('backgroundOpacity', 1, max: 1),
      backgroundBlurSigma: number('backgroundBlurSigma', -1, min: -1, max: 96),
      backgroundVeilAlpha: number('backgroundVeilAlpha', -1, min: -1, max: 1),
      backgroundPlayMode: skinMode(elements['backgroundPlayMode']),
    );
  }

  static LazerThemeTokens of(BuildContext context) =>
      Theme.of(context).extension<LazerThemeTokens>() ?? apple;

  @override
  LazerThemeTokens copyWith({
    String? id,
    String? name,
    int? version,
    double? groupedCardRadius,
    double? listTileMinHeight,
    double? listTileVerticalPadding,
    double? pageTitleCompactSize,
    double? pageTitleRegularSize,
    double? sectionHeaderSize,
    int? displayWeight,
    int? headingWeight,
    int? titleWeight,
    int? bodyWeight,
    int? labelWeight,
    int? lyricWeight,
    int? lyricTranslationWeight,
    double? lyricFontScale,
    double? lyricTranslationScale,
    double? lyricLineHeight,
    double? lyricTranslationLineHeight,
    double? lyricTranslationGap,
    double? lyricDimAlpha,
    double? lyricTranslationAlpha,
    String? lyricTextAlign,
    double? lyricSpringMassScale,
    double? lyricSpringStiffnessScale,
    double? lyricSpringDampingScale,
    double? lyricStaggerDelay,
    double? lyricStaggerDecay,
    double? lyricFocusScaleDelta,
    double? controlRadius,
    double? glassBlurSigma,
    Map<String, Color>? colors,
    Map<String, Color>? darkColors,
    double? railWidth,
    double? playerBarHeight,
    double? compactPlayerBarHeight,
    double? cornerScale,
    double? capsuleRadius,
    double? navBarRadius,
    double? nowPlayingArtworkMax,
    double? nowPlayingArtworkMin,
    double? nowPlayingArtworkFraction,
    double? nowPlayingSidePadding,
    double? nowPlayingSidePaddingMax,
    double? nowPlayingTitleSize,
    double? nowPlayingSubtitleSize,
    double? nowPlayingMetaSize,
    double? nowPlayingDockHeight,
    double? nowPlayingCoverRadius,
    double? artworkRadius,
    double? backgroundOpacity,
    double? backgroundBlurSigma,
    double? backgroundVeilAlpha,
    String? backgroundPlayMode,
  }) => LazerThemeTokens(
    id: id ?? this.id,
    name: name ?? this.name,
    version: version ?? this.version,
    groupedCardRadius: groupedCardRadius ?? this.groupedCardRadius,
    listTileMinHeight: listTileMinHeight ?? this.listTileMinHeight,
    listTileVerticalPadding:
        listTileVerticalPadding ?? this.listTileVerticalPadding,
    pageTitleCompactSize: pageTitleCompactSize ?? this.pageTitleCompactSize,
    pageTitleRegularSize: pageTitleRegularSize ?? this.pageTitleRegularSize,
    sectionHeaderSize: sectionHeaderSize ?? this.sectionHeaderSize,
    displayWeight: displayWeight ?? this.displayWeight,
    headingWeight: headingWeight ?? this.headingWeight,
    titleWeight: titleWeight ?? this.titleWeight,
    bodyWeight: bodyWeight ?? this.bodyWeight,
    labelWeight: labelWeight ?? this.labelWeight,
    lyricWeight: lyricWeight ?? this.lyricWeight,
    lyricTranslationWeight:
        lyricTranslationWeight ?? this.lyricTranslationWeight,
    lyricFontScale: lyricFontScale ?? this.lyricFontScale,
    lyricTranslationScale: lyricTranslationScale ?? this.lyricTranslationScale,
    lyricLineHeight: lyricLineHeight ?? this.lyricLineHeight,
    lyricTranslationLineHeight:
        lyricTranslationLineHeight ?? this.lyricTranslationLineHeight,
    lyricTranslationGap: lyricTranslationGap ?? this.lyricTranslationGap,
    lyricDimAlpha: lyricDimAlpha ?? this.lyricDimAlpha,
    lyricTranslationAlpha: lyricTranslationAlpha ?? this.lyricTranslationAlpha,
    lyricTextAlign: lyricTextAlign ?? this.lyricTextAlign,
    lyricSpringMassScale: lyricSpringMassScale ?? this.lyricSpringMassScale,
    lyricSpringStiffnessScale:
        lyricSpringStiffnessScale ?? this.lyricSpringStiffnessScale,
    lyricSpringDampingScale:
        lyricSpringDampingScale ?? this.lyricSpringDampingScale,
    lyricStaggerDelay: lyricStaggerDelay ?? this.lyricStaggerDelay,
    lyricStaggerDecay: lyricStaggerDecay ?? this.lyricStaggerDecay,
    lyricFocusScaleDelta: lyricFocusScaleDelta ?? this.lyricFocusScaleDelta,
    controlRadius: controlRadius ?? this.controlRadius,
    glassBlurSigma: glassBlurSigma ?? this.glassBlurSigma,
    colors: colors ?? this.colors,
    darkColors: darkColors ?? this.darkColors,
    railWidth: railWidth ?? this.railWidth,
    playerBarHeight: playerBarHeight ?? this.playerBarHeight,
    compactPlayerBarHeight:
        compactPlayerBarHeight ?? this.compactPlayerBarHeight,
    cornerScale: cornerScale ?? this.cornerScale,
    capsuleRadius: capsuleRadius ?? this.capsuleRadius,
    navBarRadius: navBarRadius ?? this.navBarRadius,
    nowPlayingArtworkMax: nowPlayingArtworkMax ?? this.nowPlayingArtworkMax,
    nowPlayingArtworkMin: nowPlayingArtworkMin ?? this.nowPlayingArtworkMin,
    nowPlayingArtworkFraction:
        nowPlayingArtworkFraction ?? this.nowPlayingArtworkFraction,
    nowPlayingSidePadding:
        nowPlayingSidePadding ?? this.nowPlayingSidePadding,
    nowPlayingSidePaddingMax:
        nowPlayingSidePaddingMax ?? this.nowPlayingSidePaddingMax,
    nowPlayingTitleSize: nowPlayingTitleSize ?? this.nowPlayingTitleSize,
    nowPlayingSubtitleSize:
        nowPlayingSubtitleSize ?? this.nowPlayingSubtitleSize,
    nowPlayingMetaSize: nowPlayingMetaSize ?? this.nowPlayingMetaSize,
    nowPlayingDockHeight: nowPlayingDockHeight ?? this.nowPlayingDockHeight,
    nowPlayingCoverRadius:
        nowPlayingCoverRadius ?? this.nowPlayingCoverRadius,
    artworkRadius: artworkRadius ?? this.artworkRadius,
    backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
    backgroundBlurSigma: backgroundBlurSigma ?? this.backgroundBlurSigma,
    backgroundVeilAlpha: backgroundVeilAlpha ?? this.backgroundVeilAlpha,
    backgroundPlayMode: backgroundPlayMode ?? this.backgroundPlayMode,
  );

  @override
  LazerThemeTokens lerp(
    covariant ThemeExtension<LazerThemeTokens>? other,
    double t,
  ) {
    if (other is! LazerThemeTokens) return this;
    double mix(double a, double b) => a + (b - a) * t;
    return LazerThemeTokens(
      id: t < .5 ? id : other.id,
      name: t < .5 ? name : other.name,
      version: t < .5 ? version : other.version,
      groupedCardRadius: mix(groupedCardRadius, other.groupedCardRadius),
      listTileMinHeight: mix(listTileMinHeight, other.listTileMinHeight),
      listTileVerticalPadding: mix(
        listTileVerticalPadding,
        other.listTileVerticalPadding,
      ),
      pageTitleCompactSize: mix(
        pageTitleCompactSize,
        other.pageTitleCompactSize,
      ),
      pageTitleRegularSize: mix(
        pageTitleRegularSize,
        other.pageTitleRegularSize,
      ),
      sectionHeaderSize: mix(sectionHeaderSize, other.sectionHeaderSize),
      displayWeight: _lerpWeight(displayWeight, other.displayWeight, t),
      headingWeight: _lerpWeight(headingWeight, other.headingWeight, t),
      titleWeight: _lerpWeight(titleWeight, other.titleWeight, t),
      bodyWeight: _lerpWeight(bodyWeight, other.bodyWeight, t),
      labelWeight: _lerpWeight(labelWeight, other.labelWeight, t),
      lyricWeight: _lerpOptionalWeight(lyricWeight, other.lyricWeight, t),
      lyricTranslationWeight: _lerpOptionalWeight(
        lyricTranslationWeight,
        other.lyricTranslationWeight,
        t,
      ),
      lyricFontScale: mix(lyricFontScale, other.lyricFontScale),
      lyricTranslationScale: mix(
        lyricTranslationScale,
        other.lyricTranslationScale,
      ),
      lyricLineHeight: mix(lyricLineHeight, other.lyricLineHeight),
      lyricTranslationLineHeight: mix(
        lyricTranslationLineHeight,
        other.lyricTranslationLineHeight,
      ),
      lyricTranslationGap: mix(lyricTranslationGap, other.lyricTranslationGap),
      lyricDimAlpha: mix(lyricDimAlpha, other.lyricDimAlpha),
      lyricTranslationAlpha: mix(
        lyricTranslationAlpha,
        other.lyricTranslationAlpha,
      ),
      lyricTextAlign: t < .5 ? lyricTextAlign : other.lyricTextAlign,
      lyricSpringMassScale: mix(
        lyricSpringMassScale,
        other.lyricSpringMassScale,
      ),
      lyricSpringStiffnessScale: mix(
        lyricSpringStiffnessScale,
        other.lyricSpringStiffnessScale,
      ),
      lyricSpringDampingScale: mix(
        lyricSpringDampingScale,
        other.lyricSpringDampingScale,
      ),
      lyricStaggerDelay: mix(lyricStaggerDelay, other.lyricStaggerDelay),
      lyricStaggerDecay: mix(lyricStaggerDecay, other.lyricStaggerDecay),
      lyricFocusScaleDelta: mix(
        lyricFocusScaleDelta,
        other.lyricFocusScaleDelta,
      ),
      controlRadius: mix(controlRadius, other.controlRadius),
      glassBlurSigma: mix(glassBlurSigma, other.glassBlurSigma),
      colors: t < .5 ? colors : other.colors,
      darkColors: t < .5 ? darkColors : other.darkColors,
      railWidth: mix(railWidth, other.railWidth),
      playerBarHeight: mix(playerBarHeight, other.playerBarHeight),
      compactPlayerBarHeight: mix(
        compactPlayerBarHeight,
        other.compactPlayerBarHeight,
      ),
      cornerScale: mix(cornerScale, other.cornerScale),
      capsuleRadius: mix(capsuleRadius, other.capsuleRadius),
      navBarRadius: mix(navBarRadius, other.navBarRadius),
      nowPlayingArtworkMax: mix(
        nowPlayingArtworkMax,
        other.nowPlayingArtworkMax,
      ),
      nowPlayingArtworkMin: mix(
        nowPlayingArtworkMin,
        other.nowPlayingArtworkMin,
      ),
      nowPlayingArtworkFraction: mix(
        nowPlayingArtworkFraction,
        other.nowPlayingArtworkFraction,
      ),
      nowPlayingSidePadding: mix(
        nowPlayingSidePadding,
        other.nowPlayingSidePadding,
      ),
      nowPlayingSidePaddingMax: mix(
        nowPlayingSidePaddingMax,
        other.nowPlayingSidePaddingMax,
      ),
      nowPlayingTitleSize: mix(nowPlayingTitleSize, other.nowPlayingTitleSize),
      nowPlayingSubtitleSize: mix(
        nowPlayingSubtitleSize,
        other.nowPlayingSubtitleSize,
      ),
      nowPlayingMetaSize: mix(nowPlayingMetaSize, other.nowPlayingMetaSize),
      nowPlayingDockHeight: mix(
        nowPlayingDockHeight,
        other.nowPlayingDockHeight,
      ),
      nowPlayingCoverRadius: mix(
        nowPlayingCoverRadius,
        other.nowPlayingCoverRadius,
      ),
      artworkRadius: mix(artworkRadius, other.artworkRadius),
      backgroundOpacity: mix(backgroundOpacity, other.backgroundOpacity),
      backgroundBlurSigma: mix(backgroundBlurSigma, other.backgroundBlurSigma),
      backgroundVeilAlpha: mix(
        backgroundVeilAlpha,
        other.backgroundVeilAlpha,
      ),
      backgroundPlayMode: t < .5 ? backgroundPlayMode : other.backgroundPlayMode,
    );
  }

  static int _lerpWeight(int a, int b, double t) =>
      (a + (b - a) * t).round().clamp(100, 900);

  static int _lerpOptionalWeight(int a, int b, double t) =>
      (a < 0 && b < 0) ? -1 : _lerpWeight(a < 0 ? b : a, b < 0 ? a : b, t);

  static FontWeight fontWeight(int value) {
    final clamped = value.clamp(100, 900);
    return FontWeight.values.reduce(
      (a, b) => (a.value - clamped).abs() <= (b.value - clamped).abs() ? a : b,
    );
  }

  FontWeight get displayFontWeight => fontWeight(displayWeight);
  FontWeight get headingFontWeight => fontWeight(headingWeight);
  FontWeight get titleFontWeight => fontWeight(titleWeight);
  FontWeight get bodyFontWeight => fontWeight(bodyWeight);
  FontWeight get labelFontWeight => fontWeight(labelWeight);
  FontWeight lyricFontWeight(int fallback) =>
      fontWeight(lyricWeight < 0 ? fallback : lyricWeight);
  FontWeight lyricTranslationFontWeight(int fallback) => fontWeight(
    lyricTranslationWeight < 0 ? fallback : lyricTranslationWeight,
  );

  TextAlign get lyricAlignment => switch (lyricTextAlign) {
    'center' => TextAlign.center,
    'end' => TextAlign.end,
    'justify' => TextAlign.justify,
    _ => TextAlign.start,
  };
}

/// Registry boundary for built-in and future plugin-provided skins.
class LazerThemeRegistry {
  LazerThemeRegistry({Iterable<LazerThemeTokens> themes = const []}) {
    register(LazerThemeTokens.apple);
    for (final theme in LazerThemeTokens.builtinThemes) {
      register(theme);
    }
    for (final theme in themes) {
      register(theme);
    }
  }

  final Map<String, LazerThemeTokens> _themes = <String, LazerThemeTokens>{};

  Iterable<LazerThemeTokens> get themes => _themes.values;

  void register(LazerThemeTokens theme) {
    final id = theme.id.trim();
    if (id.isEmpty) throw ArgumentError.value(theme.id, 'theme.id');
    _themes[id] = theme;
  }

  LazerThemeTokens resolve(String id) => _themes[id] ?? LazerThemeTokens.apple;
}
