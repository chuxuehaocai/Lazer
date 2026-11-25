import 'package:flutter/cupertino.dart'
    show CupertinoTextThemeData, CupertinoThemeData;
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'font_preferences.dart';
import 'adaptive_contrast.dart';
import '../animation/view_transitions.dart';

import 'tokens.dart';
import 'lazer_theme.dart';

/// The resolved presentation travels with the theme through route overlays
/// and retained pages. A forced phone layout must keep its phone surfaces
/// even when the window has enough space for the desktop composition.
@immutable
class AppThemePresentation extends ThemeExtension<AppThemePresentation> {
  const AppThemePresentation({required this.compact});

  final bool compact;

  @override
  AppThemePresentation copyWith({bool? compact}) =>
      AppThemePresentation(compact: compact ?? this.compact);

  @override
  AppThemePresentation lerp(AppThemePresentation? other, double t) =>
      other == null || t < .5 ? this : other;
}

/// Apple-platform semantic colours and typography.
///
/// The values follow the Human Interface Guidelines rather than Material's
/// tonal palette: grouped backgrounds, label/fill hierarchy, hairline
/// separators, and one translucent system accent. The surrounding app still
/// exposes a Material [ThemeData] so existing widgets and the Windows
/// accessibility bridge keep working; every surface, though, uses these
/// semantic roles instead of Material's elevation tints.
abstract final class AppleColors {
  const AppleColors._();

  static const Color musicRed = Color(0xFFFA2D48);
  static const Color lazerBlue = Color(0xFF99B9E3);
  static const Color systemRed = Color(0xFFFF3B30);
  static const Color systemPink = Color(0xFFFF2D55);
  static const Color systemBlue = Color(0xFF007AFF);
  static const Color systemGreen = Color(0xFF34C759);
  static const Color systemOrange = Color(0xFFFF9500);
  static const Color systemYellow = Color(0xFFFFCC00);
  static const Color systemPurple = Color(0xFFAF52DE);
  static const Color systemTeal = Color(0xFF5AC8FA);
  static const Color systemGray = Color(0xFF8E8E93);
  static const Color systemGray2 = Color(0xFFAEAEB2);
  static const Color systemGray3 = Color(0xFFC7C7CC);
  static const Color systemGray4 = Color(0xFFD1D1D6);
  static const Color systemGray5 = Color(0xFFE5E5EA);
  static const Color systemGray6 = Color(0xFFF2F2F7);

  /// The empty canvas behind the shell when the artwork backdrop is off.
  ///
  /// A cool charcoal canvas keeps empty areas distinct from the blue-grey
  /// navigation and grouped surfaces, including when artwork is disabled.
  static const Color darkCanvas = Color(0xFF191C23);
}

/// Dynamic semantic colours for the current brightness.
@immutable
class AppleSemanticColors extends ThemeExtension<AppleSemanticColors> {
  const AppleSemanticColors({
    required this.background,
    required this.secondaryBackground,
    required this.tertiaryBackground,
    required this.groupedBackground,
    required this.secondaryGroupedBackground,
    required this.tertiaryGroupedBackground,
    required this.label,
    required this.secondaryLabel,
    required this.tertiaryLabel,
    required this.quaternaryLabel,
    required this.fill,
    required this.secondaryFill,
    required this.tertiaryFill,
    required this.separator,
    required this.opaqueSeparator,
    required this.accent,
    required this.accentSoft,
    required this.glass,
    required this.glassStrong,
  });

  final Color background;
  final Color secondaryBackground;
  final Color tertiaryBackground;
  final Color groupedBackground;
  final Color secondaryGroupedBackground;
  final Color tertiaryGroupedBackground;
  final Color label;
  final Color secondaryLabel;
  final Color tertiaryLabel;
  final Color quaternaryLabel;
  final Color fill;
  final Color secondaryFill;
  final Color tertiaryFill;
  final Color separator;
  final Color opaqueSeparator;
  final Color accent;
  final Color accentSoft;
  final Color glass;
  final Color glassStrong;

  static const AppleSemanticColors light = AppleSemanticColors(
    background: Color(0xFFFFFFFF),
    secondaryBackground: Color(0xFFF2F2F7),
    tertiaryBackground: Color(0xFFFFFFFF),
    groupedBackground: Color(0xFFF2F2F7),
    secondaryGroupedBackground: Color(0xFFFFFFFF),
    tertiaryGroupedBackground: Color(0xFFF2F2F7),
    label: Color(0xFF000000),
    secondaryLabel: Color(0x993C3C43),
    tertiaryLabel: Color(0x4D3C3C43),
    quaternaryLabel: Color(0x2E3C3C43),
    fill: Color(0x1F767680),
    secondaryFill: Color(0x29767680),
    tertiaryFill: Color(0x14767680),
    separator: Color(0x4A3C3C43),
    opaqueSeparator: Color(0xFFC6C6C8),
    accent: Color(0xFF426DAB),
    accentSoft: Color(0x18426DAB),
    glass: Color(0xDFFBFBFD),
    glassStrong: Color(0xF2FFFFFF),
  );

  static const AppleSemanticColors dark = AppleSemanticColors(
    background: Color(0xFF191C23),
    secondaryBackground: Color(0xFF242832),
    tertiaryBackground: Color(0xFF303642),
    groupedBackground: Color(0xFF191C23),
    secondaryGroupedBackground: Color(0xFF242832),
    tertiaryGroupedBackground: Color(0xFF303642),
    label: Color(0xFFF5F6FA),
    secondaryLabel: Color(0xFFB5BDCD),
    tertiaryLabel: Color(0xFF858FA3),
    quaternaryLabel: Color(0x667C879B),
    fill: Color(0x246F7D98),
    secondaryFill: Color(0x326F7D98),
    tertiaryFill: Color(0x146F7D98),
    separator: Color(0x326F7D98),
    opaqueSeparator: Color(0xFF3A4252),
    accent: AppleColors.lazerBlue,
    accentSoft: Color(0x2699B9E3),
    glass: Color(0xC920242D),
    glassStrong: Color(0xED222731),
  );

  static AppleSemanticColors of(BuildContext context) =>
      Theme.of(context).extension<AppleSemanticColors>() ??
      (Theme.of(context).brightness == Brightness.dark ? dark : light);

  @override
  AppleSemanticColors copyWith({
    Color? background,
    Color? secondaryBackground,
    Color? tertiaryBackground,
    Color? groupedBackground,
    Color? secondaryGroupedBackground,
    Color? tertiaryGroupedBackground,
    Color? label,
    Color? secondaryLabel,
    Color? tertiaryLabel,
    Color? quaternaryLabel,
    Color? fill,
    Color? secondaryFill,
    Color? tertiaryFill,
    Color? separator,
    Color? opaqueSeparator,
    Color? accent,
    Color? accentSoft,
    Color? glass,
    Color? glassStrong,
  }) {
    return AppleSemanticColors(
      background: background ?? this.background,
      secondaryBackground: secondaryBackground ?? this.secondaryBackground,
      tertiaryBackground: tertiaryBackground ?? this.tertiaryBackground,
      groupedBackground: groupedBackground ?? this.groupedBackground,
      secondaryGroupedBackground:
          secondaryGroupedBackground ?? this.secondaryGroupedBackground,
      tertiaryGroupedBackground:
          tertiaryGroupedBackground ?? this.tertiaryGroupedBackground,
      label: label ?? this.label,
      secondaryLabel: secondaryLabel ?? this.secondaryLabel,
      tertiaryLabel: tertiaryLabel ?? this.tertiaryLabel,
      quaternaryLabel: quaternaryLabel ?? this.quaternaryLabel,
      fill: fill ?? this.fill,
      secondaryFill: secondaryFill ?? this.secondaryFill,
      tertiaryFill: tertiaryFill ?? this.tertiaryFill,
      separator: separator ?? this.separator,
      opaqueSeparator: opaqueSeparator ?? this.opaqueSeparator,
      accent: accent ?? this.accent,
      accentSoft: accentSoft ?? this.accentSoft,
      glass: glass ?? this.glass,
      glassStrong: glassStrong ?? this.glassStrong,
    );
  }

  @override
  AppleSemanticColors lerp(
    covariant ThemeExtension<AppleSemanticColors>? other,
    double t,
  ) {
    if (other is! AppleSemanticColors) return this;
    return AppleSemanticColors(
      background: Color.lerp(background, other.background, t)!,
      secondaryBackground: Color.lerp(
        secondaryBackground,
        other.secondaryBackground,
        t,
      )!,
      tertiaryBackground: Color.lerp(
        tertiaryBackground,
        other.tertiaryBackground,
        t,
      )!,
      groupedBackground: Color.lerp(
        groupedBackground,
        other.groupedBackground,
        t,
      )!,
      secondaryGroupedBackground: Color.lerp(
        secondaryGroupedBackground,
        other.secondaryGroupedBackground,
        t,
      )!,
      tertiaryGroupedBackground: Color.lerp(
        tertiaryGroupedBackground,
        other.tertiaryGroupedBackground,
        t,
      )!,
      label: Color.lerp(label, other.label, t)!,
      secondaryLabel: Color.lerp(secondaryLabel, other.secondaryLabel, t)!,
      tertiaryLabel: Color.lerp(tertiaryLabel, other.tertiaryLabel, t)!,
      quaternaryLabel: Color.lerp(quaternaryLabel, other.quaternaryLabel, t)!,
      fill: Color.lerp(fill, other.fill, t)!,
      secondaryFill: Color.lerp(secondaryFill, other.secondaryFill, t)!,
      tertiaryFill: Color.lerp(tertiaryFill, other.tertiaryFill, t)!,
      separator: Color.lerp(separator, other.separator, t)!,
      opaqueSeparator: Color.lerp(opaqueSeparator, other.opaqueSeparator, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      glass: Color.lerp(glass, other.glass, t)!,
      glassStrong: Color.lerp(glassStrong, other.glassStrong, t)!,
    );
  }
}

/// Applies a skin's semantic colour overrides on top of a built-in preset.
///
/// Only the slots the skin actually supplies are replaced. When a skin sets
/// `label`/`background` but leaves the fill and separator roles out, those are
/// re-derived from the supplied ink so highlights and hairlines stay coherent
/// instead of inheriting the Apple tint.
AppleSemanticColors applySemanticColorOverrides(
  AppleSemanticColors base,
  Map<String, Color> overrides, {
  required bool dark,
}) {
  if (overrides.isEmpty) return base;
  final Color label = overrides['label'] ?? base.label;
  final Color background = overrides['background'] ?? base.background;
  final bool ink = overrides.containsKey('label');
  Color pick(String slot, [Color? fallback]) => overrides[slot] ?? fallback ?? base.label;
  return base.copyWith(
    background: background,
    secondaryBackground: pick(
      'secondaryBackground',
      overrides['background'] == null
          ? base.secondaryBackground
          : Color.alphaBlend(
              label.withValues(alpha: dark ? .08 : .03),
              background,
            ),
    ),
    tertiaryBackground: pick('tertiaryBackground', base.tertiaryBackground),
    groupedBackground: pick(
      'groupedBackground',
      overrides['background'] ?? base.groupedBackground,
    ),
    secondaryGroupedBackground: pick(
      'secondaryGroupedBackground',
      overrides['background'] == null
          ? base.secondaryGroupedBackground
          : Color.alphaBlend(
              label.withValues(alpha: dark ? .10 : .04),
              background,
            ),
    ),
    tertiaryGroupedBackground: pick(
      'tertiaryGroupedBackground',
      base.tertiaryGroupedBackground,
    ),
    label: label,
    secondaryLabel: pick(
      'secondaryLabel',
      ink ? label.withValues(alpha: .72) : base.secondaryLabel,
    ),
    tertiaryLabel: pick(
      'tertiaryLabel',
      ink ? label.withValues(alpha: .50) : base.tertiaryLabel,
    ),
    quaternaryLabel: pick(
      'quaternaryLabel',
      ink ? label.withValues(alpha: .30) : base.quaternaryLabel,
    ),
    fill: pick(
      'fill',
      ink ? label.withValues(alpha: dark ? .14 : .06) : base.fill,
    ),
    secondaryFill: pick(
      'secondaryFill',
      ink ? label.withValues(alpha: dark ? .10 : .04) : base.secondaryFill,
    ),
    tertiaryFill: pick(
      'tertiaryFill',
      ink ? label.withValues(alpha: dark ? .07 : .03) : base.tertiaryFill,
    ),
    separator: pick(
      'separator',
      ink ? label.withValues(alpha: .18) : base.separator,
    ),
    opaqueSeparator: pick(
      'opaqueSeparator',
      ink ? label.withValues(alpha: .32) : base.opaqueSeparator,
    ),
    accent: pick('accent', base.accent),
    accentSoft: pick('accentSoft', base.accentSoft),
    glass: pick(
      'glass',
      overrides['background'] == null
          ? base.glass
          : background.withValues(alpha: dark ? .62 : .72),
    ),
    glassStrong: pick(
      'glassStrong',
      overrides['background'] == null
          ? base.glassStrong
          : background.withValues(alpha: dark ? .82 : .88),
    ),
  );
}

/// Apple HIG type ramp with bundled MiSans on every platform.
const List<String> appleFontFallback = <String>[
  'SF Pro Display',
  'SF Pro Text',
  'PingFang SC',
  'Segoe UI Variable',
  'Segoe UI',
  'Microsoft YaHei UI',
  'Microsoft YaHei',
  'MiSans',
  'sans-serif',
];

TextTheme appleTextTheme({
  Color? color,
  String? fontFamily = AppFonts.sans,
  LazerThemeTokens ui = LazerThemeTokens.apple,
  /// 全局圆角强度（见 theme/shape_scale.dart）。主题层形状同样缩放。
  double cornerScale = 1,
}) {
  TextStyle s(
    double size,
    double height,
    FontWeight weight, {
    double spacing = 0,
  }) => TextStyle(
    fontFamily: fontFamily,
    fontSize: size,
    height: height / size,
    fontWeight: weight,
    letterSpacing: spacing,
    color: color,
    fontFamilyFallback: appleFontFallback,
  );

  return TextTheme(
    displayLarge: s(34, 41, ui.displayFontWeight, spacing: .37),
    displayMedium: s(28, 34, ui.displayFontWeight, spacing: .36),
    displaySmall: s(24, 30, ui.displayFontWeight, spacing: .35),
    headlineLarge: s(34, 41, ui.headingFontWeight, spacing: .37),
    headlineMedium: s(28, 34, ui.headingFontWeight, spacing: .36),
    headlineSmall: s(22, 28, ui.headingFontWeight, spacing: .35),
    titleLarge: s(20, 25, ui.titleFontWeight, spacing: .38),
    titleMedium: s(17, 22, ui.titleFontWeight, spacing: -.24),
    titleSmall: s(15, 20, ui.titleFontWeight, spacing: -.23),
    bodyLarge: s(17, 22, ui.bodyFontWeight, spacing: -.24),
    bodyMedium: s(15, 20, ui.bodyFontWeight, spacing: -.23),
    bodySmall: s(13, 18, ui.bodyFontWeight, spacing: -.18),
    labelLarge: s(15, 20, ui.labelFontWeight, spacing: -.23),
    labelMedium: s(13, 18, ui.labelFontWeight, spacing: -.18),
    labelSmall: s(11, 13, ui.labelFontWeight, spacing: .06),
  );
}

/// Builds the app-wide Apple surface theme.
///
/// One palette serves every endpoint. The compact (phone) layout changes
/// spacing, navigation and hit areas — never the colours — so the same library
/// looks the same whether it is opened in a window, on a tablet or on a phone.
///
/// Pass [seedAccent] when the listener chose the cover-derived palette; the
/// accent then follows the art while the neutral system backgrounds remain
/// stable, exactly as Apple's tint-color model separates chrome from content.
ThemeData buildAppleTheme({
  Brightness brightness = Brightness.light,
  bool compact = false,
  Color? seedAccent,
  FontPreferences fonts = const FontPreferences(),
  LazerThemeTokens ui = LazerThemeTokens.apple,
  /// 全局圆角强度（见 theme/shape_scale.dart）：主题层的卡片、对话框、输入框
  /// 形状一起缩放。0 = 全直角，1 = 原样。
  double cornerScale = 1,
}) {
  final bool dark = brightness == Brightness.dark;
  final AppleSemanticColors preset = dark
      ? AppleSemanticColors.dark
      : AppleSemanticColors.light;
  // A Lua skin supplies semantic colours; the host keeps ownership of
  // contrast, focus and every widget, it only honours the tones.
  // A skin may ship a separate dark set; without one its light colours are
  // reused verbatim (a paper skin without a night variant still renders).
  final Map<String, Color> skinColors = dark
      ? (ui.darkColors.isEmpty ? ui.colors : ui.darkColors)
      : ui.colors;
  final AppleSemanticColors skinned = applySemanticColorOverrides(
    preset,
    skinColors,
    dark: dark,
  );
  final Color accent = seedAccent == null
      ? (skinColors['accent'] ?? skinned.accent)
      : adaptiveAccent(seedAccent, skinned.background);
  final AppleSemanticColors apple = skinned.copyWith(
    accent: accent,
    accentSoft:
        skinColors['accentSoft'] ??
        accent.withValues(alpha: dark ? .18 : .12),
  );
  final ColorScheme scheme = ColorScheme(
    brightness: brightness,
    primary: accent,
    onPrimary: contrastingLabel(accent),
    primaryContainer: apple.accentSoft,
    onPrimaryContainer: apple.label,
    primaryFixed: apple.accentSoft,
    primaryFixedDim: accent.withValues(alpha: .7),
    onPrimaryFixed: apple.label,
    onPrimaryFixedVariant: apple.secondaryLabel,
    secondary: AppleColors.systemPink,
    onSecondary: Colors.white,
    secondaryContainer: AppleColors.systemPink.withValues(alpha: .14),
    onSecondaryContainer: apple.label,
    secondaryFixed: AppleColors.systemPink.withValues(alpha: .2),
    secondaryFixedDim: AppleColors.systemPink.withValues(alpha: .6),
    onSecondaryFixed: apple.label,
    onSecondaryFixedVariant: apple.secondaryLabel,
    tertiary: AppleColors.systemBlue,
    onTertiary: Colors.white,
    tertiaryContainer: AppleColors.systemBlue.withValues(alpha: .14),
    onTertiaryContainer: apple.label,
    tertiaryFixed: AppleColors.systemBlue.withValues(alpha: .2),
    tertiaryFixedDim: AppleColors.systemBlue.withValues(alpha: .6),
    onTertiaryFixed: apple.label,
    onTertiaryFixedVariant: apple.secondaryLabel,
    error: AppleColors.systemRed,
    onError: Colors.white,
    errorContainer: AppleColors.systemRed.withValues(alpha: .14),
    onErrorContainer: apple.label,
    surface: apple.background,
    onSurface: apple.label,
    surfaceDim: apple.groupedBackground,
    surfaceBright: apple.tertiaryBackground,
    surfaceContainerLowest: apple.background,
    surfaceContainerLow: apple.secondaryGroupedBackground,
    surfaceContainer: apple.tertiaryGroupedBackground,
    surfaceContainerHigh: apple.tertiaryGroupedBackground,
    surfaceContainerHighest: apple.secondaryFill,
    onSurfaceVariant: apple.secondaryLabel,
    outline: apple.separator,
    outlineVariant: apple.separator,
    inverseSurface: apple.label,
    onInverseSurface: apple.background,
    inversePrimary: accent,
    surfaceTint: Colors.transparent,
    shadow: Colors.black,
    scrim: Colors.black,
  );
  final String uiFont = fonts.family.resolvedFamily;
  final TextTheme text = fonts.applyTo(
    appleTextTheme(color: apple.label, fontFamily: uiFont, ui: ui),
  );
  final TextTheme hintText = fonts.applyTo(
    appleTextTheme(color: apple.secondaryLabel, fontFamily: uiFont, ui: ui),
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    typography: Typography.material2021(platform: defaultTargetPlatform),
    textTheme: text,
    primaryTextTheme: text,
    fontFamily: uiFont,
    fontFamilyFallback: fonts.family.fallbackFor(appleFontFallback),
    scaffoldBackgroundColor: apple.background,
    canvasColor: apple.background,
    cardColor: apple.secondaryGroupedBackground,
    dividerColor: apple.separator,
    shadowColor: Colors.black,
    splashFactory: NoSplash.splashFactory,
    highlightColor: apple.fill,
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    extensions: <ThemeExtension<dynamic>>[
      apple,
      fonts,
      ui,
      AppThemePresentation(compact: compact),
    ],
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        // Both sides must use the same fade-through contract. Platform-default
        // outgoing pages otherwise remain visible under transparent settings.
        TargetPlatform.iOS: LazerPageTransitionsBuilder(),
        TargetPlatform.macOS: LazerPageTransitionsBuilder(),
        TargetPlatform.android: LazerPageTransitionsBuilder(),
        TargetPlatform.fuchsia: LazerPageTransitionsBuilder(),
        TargetPlatform.windows: LazerPageTransitionsBuilder(),
        TargetPlatform.linux: LazerPageTransitionsBuilder(),
      },
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: apple.label,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge,
    ),
    cardTheme: CardThemeData(
      color: apple.secondaryGroupedBackground,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12 * cornerScale)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: apple.tertiaryBackground,
      surfaceTintColor: Colors.transparent,
      elevation: 24,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20 * cornerScale)),
      titleTextStyle: text.headlineSmall,
      contentTextStyle: text.bodyMedium?.copyWith(color: apple.secondaryLabel),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: apple.background,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: apple.background,
      elevation: 0,
      showDragHandle: true,
      dragHandleColor: apple.tertiaryLabel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(20 * cornerScale),
        ),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      indicatorColor: Colors.transparent,
      elevation: 0,
      height: 56,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      iconTheme: WidgetStateProperty.resolveWith<IconThemeData>(
        (Set<WidgetState> states) => IconThemeData(
          size: 24,
          color: states.contains(WidgetState.selected)
              ? apple.accent
              : apple.secondaryLabel,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith<TextStyle?>(
        (Set<WidgetState> states) => text.labelSmall?.copyWith(
          color: states.contains(WidgetState.selected)
              ? apple.accent
              : apple.secondaryLabel,
          fontWeight: fonts.weightFor(FontCategory.controls, FontWeight.w500),
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: Colors.transparent,
      indicatorColor: apple.fill,
      selectedIconTheme: IconThemeData(color: apple.accent),
      unselectedIconTheme: IconThemeData(color: apple.secondaryLabel),
      selectedLabelTextStyle: text.bodyMedium?.copyWith(
        color: apple.label,
        fontWeight: fonts.weightFor(FontCategory.controls, FontWeight.w600),
      ),
      unselectedLabelTextStyle: text.bodyMedium?.copyWith(
        color: apple.secondaryLabel,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: apple.secondaryLabel,
        highlightColor: apple.fill,
        hoverColor: apple.fill,
        shape: const CircleBorder(),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(52, 44),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        backgroundColor: accent,
        foregroundColor: contrastingLabel(accent),
        disabledBackgroundColor: apple.fill,
        disabledForegroundColor: apple.tertiaryLabel,
        shape: const StadiumBorder(),
        textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        elevation: 0,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        minimumSize: const Size(52, 44),
        elevation: 0,
        backgroundColor: apple.secondaryGroupedBackground,
        foregroundColor: apple.label,
        shape: const StadiumBorder(),
        textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(52, 44),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        foregroundColor: apple.accent,
        side: BorderSide(color: apple.separator),
        shape: const StadiumBorder(),
        textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(44, 40),
        foregroundColor: apple.accent,
        shape: const StadiumBorder(),
        textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith<Color?>(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? apple.secondaryGroupedBackground
              : Colors.transparent,
        ),
        foregroundColor: WidgetStatePropertyAll<Color?>(apple.label),
        side: WidgetStatePropertyAll<BorderSide?>(
          BorderSide(color: apple.separator),
        ),
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8 * cornerScale)),
          ),
        ),
        textStyle: WidgetStatePropertyAll<TextStyle?>(text.labelLarge),
        elevation: const WidgetStatePropertyAll<double?>(0),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith<Color?>(
        (Set<WidgetState> states) => states.contains(WidgetState.disabled)
            ? Colors.white.withValues(alpha: .5)
            : Colors.white,
      ),
      trackColor: WidgetStateProperty.resolveWith<Color?>(
        (Set<WidgetState> states) => states.contains(WidgetState.disabled)
            ? apple.tertiaryFill
            : states.contains(WidgetState.selected)
            ? apple.accent
            : apple.tertiaryFill,
      ),
      trackOutlineColor: const WidgetStatePropertyAll<Color?>(
        Colors.transparent,
      ),
      overlayColor: WidgetStatePropertyAll<Color?>(apple.fill),
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 4,
      activeTrackColor: apple.accent,
      inactiveTrackColor: apple.tertiaryFill,
      secondaryActiveTrackColor: apple.accent.withValues(alpha: .3),
      thumbColor: Colors.white,
      disabledThumbColor: apple.tertiaryLabel,
      disabledActiveTrackColor: apple.tertiaryLabel,
      disabledInactiveTrackColor: apple.tertiaryFill,
      overlayColor: apple.accent.withValues(alpha: .12),
      valueIndicatorColor: apple.secondaryGroupedBackground,
      valueIndicatorTextStyle: text.labelMedium?.copyWith(color: apple.label),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
      trackShape: const RoundedRectSliderTrackShape(),
      tickMarkShape: SliderTickMarkShape.noTickMark,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: apple.fill,
      hintStyle: hintText.bodyMedium,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10 * cornerScale),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10 * cornerScale),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10 * cornerScale),
        borderSide: BorderSide(color: apple.accent, width: 1.5),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: apple.tertiaryBackground,
      surfaceTintColor: Colors.transparent,
      elevation: 18,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12 * cornerScale)),
      textStyle: text.bodyMedium,
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll<Color?>(
          apple.tertiaryBackground,
        ),
        surfaceTintColor: const WidgetStatePropertyAll<Color?>(
          Colors.transparent,
        ),
        elevation: const WidgetStatePropertyAll<double?>(18),
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(12 * cornerScale)),
          ),
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: apple.tertiaryBackground,
      contentTextStyle: text.bodyMedium,
      actionTextColor: apple.accent,
      behavior: SnackBarBehavior.floating,
      elevation: 16,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12 * cornerScale)),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: brightness == Brightness.dark
            ? const Color(0xF22C2C2E)
            : const Color(0xF2F2F2F7),
        borderRadius: BorderRadius.circular(6 * cornerScale),
        border: Border.all(color: apple.separator),
      ),
      textStyle: text.labelSmall?.copyWith(color: apple.label),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      waitDuration: const Duration(milliseconds: 420),
    ),
    dividerTheme: DividerThemeData(
      color: apple.separator,
      thickness: .5,
      space: .5,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll<Color>(apple.tertiaryLabel),
      radius: const Radius.circular(999),
      thickness: const WidgetStatePropertyAll<double>(5),
      crossAxisMargin: 2,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: apple.accent,
      selectionColor: apple.accent.withValues(alpha: .25),
      selectionHandleColor: apple.accent,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: apple.accent,
      linearTrackColor: apple.tertiaryFill,
      circularTrackColor: apple.tertiaryFill,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: apple.fill,
      selectedColor: apple.accentSoft,
      surfaceTintColor: Colors.transparent,
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8 * cornerScale)),
      labelStyle: text.labelLarge?.copyWith(color: apple.label),
      secondaryLabelStyle: text.labelLarge?.copyWith(color: apple.label),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    ),
    listTileTheme: ListTileThemeData(
      textColor: apple.label,
      iconColor: apple.accent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10 * cornerScale)),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith<Color?>(
        (Set<WidgetState> states) => states.contains(WidgetState.selected)
            ? apple.accent
            : Colors.transparent,
      ),
      side: BorderSide(color: apple.separator),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4 * cornerScale)),
    ),
    cupertinoOverrideTheme: CupertinoThemeData(
      brightness: brightness,
      primaryColor: accent,
      barBackgroundColor: apple.glass,
      scaffoldBackgroundColor: apple.background,
      textTheme: CupertinoTextThemeData(
        textStyle: text.bodyLarge,
        actionTextStyle: text.bodyLarge?.copyWith(color: accent),
        navActionTextStyle: text.bodyLarge?.copyWith(color: accent),
        navTitleTextStyle: text.titleLarge,
        navLargeTitleTextStyle: text.displayLarge,
        tabLabelTextStyle: text.labelSmall,
        pickerTextStyle: text.titleLarge,
        dateTimePickerTextStyle: text.titleLarge,
      ),
    ),
  );
}
