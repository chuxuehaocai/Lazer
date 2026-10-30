import 'package:flutter/cupertino.dart'
    show
        CupertinoPageTransitionsBuilder,
        CupertinoTextThemeData,
        CupertinoThemeData;
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'font_preferences.dart';
import 'adaptive_contrast.dart';
import '../animation/view_transitions.dart';

import 'tokens.dart';

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
  /// The dark theme's system background is pure black, which reads as a hole
  /// in a desktop window; with nothing painted behind the interface this deep
  /// warm grey keeps the window visibly a surface while still sitting below
  /// the grouped-card tone.
  static const Color darkCanvas = Color(0xFF141413);
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
    accent: AppleColors.musicRed,
    accentSoft: Color(0x14FA2D48),
    glass: Color(0xDFFBFBFD),
    glassStrong: Color(0xF2FFFFFF),
  );

  static const AppleSemanticColors dark = AppleSemanticColors(
    background: Color(0xFF000000),
    secondaryBackground: Color(0xFF1C1C1E),
    tertiaryBackground: Color(0xFF2C2C2E),
    groupedBackground: Color(0xFF000000),
    secondaryGroupedBackground: Color(0xFF1C1C1E),
    tertiaryGroupedBackground: Color(0xFF2C2C2E),
    label: Color(0xFFFFFFFF),
    secondaryLabel: Color(0x99EBEBF5),
    tertiaryLabel: Color(0x4DEBEBF5),
    quaternaryLabel: Color(0x2EEBEBF5),
    fill: Color(0x1F767680),
    secondaryFill: Color(0x29767680),
    tertiaryFill: Color(0x14767680),
    separator: Color(0x4A545458),
    opaqueSeparator: Color(0xFF38383A),
    accent: AppleColors.musicRed,
    accentSoft: Color(0x1FFA2D48),
    glass: Color(0xCC1C1C1E),
    glassStrong: Color(0xF21C1C1E),
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

TextTheme appleTextTheme({Color? color, String? fontFamily = AppFonts.sans}) {
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
    displayLarge: s(34, 41, FontWeight.w700, spacing: .37),
    displayMedium: s(28, 34, FontWeight.w700, spacing: .36),
    displaySmall: s(24, 30, FontWeight.w700, spacing: .35),
    headlineLarge: s(34, 41, FontWeight.w700, spacing: .37),
    headlineMedium: s(28, 34, FontWeight.w700, spacing: .36),
    headlineSmall: s(22, 28, FontWeight.w700, spacing: .35),
    titleLarge: s(20, 25, FontWeight.w600, spacing: .38),
    titleMedium: s(17, 22, FontWeight.w600, spacing: -.24),
    titleSmall: s(15, 20, FontWeight.w600, spacing: -.23),
    bodyLarge: s(17, 22, FontWeight.w400, spacing: -.24),
    bodyMedium: s(15, 20, FontWeight.w400, spacing: -.23),
    bodySmall: s(13, 18, FontWeight.w400, spacing: -.18),
    labelLarge: s(15, 20, FontWeight.w500, spacing: -.23),
    labelMedium: s(13, 18, FontWeight.w500, spacing: -.18),
    labelSmall: s(11, 13, FontWeight.w500, spacing: .06),
  );
}

/// Builds the app-wide Apple surface theme.
///
/// Pass [seedAccent] when the listener chose the cover-derived palette; the
/// accent then follows the art while the neutral system backgrounds remain
/// stable, exactly as Apple's tint-color model separates chrome from content.
ThemeData buildAppleTheme({
  Brightness brightness = Brightness.light,
  Color? seedAccent,
  FontPreferences fonts = const FontPreferences(),
}) {
  final AppleSemanticColors base = brightness == Brightness.dark
      ? AppleSemanticColors.dark
      : AppleSemanticColors.light;
  final Color accent = seedAccent == null
      ? base.accent
      : adaptiveAccent(seedAccent, base.background);
  final AppleSemanticColors apple = base.copyWith(
    accent: accent,
    accentSoft: accent.withValues(
      alpha: brightness == Brightness.dark ? .18 : .12,
    ),
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
  const String uiFont = AppFonts.sans;
  final TextTheme text = fonts.applyTo(
    appleTextTheme(color: apple.label, fontFamily: uiFont),
  );
  final TextTheme hintText = fonts.applyTo(
    appleTextTheme(color: apple.secondaryLabel, fontFamily: uiFont),
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    typography: Typography.material2021(platform: defaultTargetPlatform),
    textTheme: text,
    primaryTextTheme: text,
    fontFamily: uiFont,
    fontFamilyFallback: appleFontFallback,
    scaffoldBackgroundColor: apple.background,
    canvasColor: apple.background,
    cardColor: apple.secondaryGroupedBackground,
    dividerColor: apple.separator,
    shadowColor: Colors.black,
    splashFactory: NoSplash.splashFactory,
    highlightColor: apple.fill,
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    extensions: <ThemeExtension<dynamic>>[apple, fonts],
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        TargetPlatform.fuchsia: CupertinoPageTransitionsBuilder(),
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: apple.tertiaryBackground,
      surfaceTintColor: Colors.transparent,
      elevation: 24,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
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
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
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
        shape: const WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
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
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: apple.accent, width: 1.5),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: apple.tertiaryBackground,
      surfaceTintColor: Colors.transparent,
      elevation: 18,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
        shape: const WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: brightness == Brightness.dark
            ? const Color(0xF22C2C2E)
            : const Color(0xF2F2F2F7),
        borderRadius: BorderRadius.circular(6),
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      labelStyle: text.labelLarge?.copyWith(color: apple.label),
      secondaryLabelStyle: text.labelLarge?.copyWith(color: apple.label),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    ),
    listTileTheme: ListTileThemeData(
      textColor: apple.label,
      iconColor: apple.accent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith<Color?>(
        (Set<WidgetState> states) => states.contains(WidgetState.selected)
            ? apple.accent
            : Colors.transparent,
      ),
      side: BorderSide(color: apple.separator),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
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
