import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;

import 'design_tokens.dart';
import 'app_palette.dart';
import 'font_preferences.dart';
import 'adaptive_contrast.dart';
import '../animation/view_transitions.dart';

/// Builds the [ThemeData] for the parchment system.
///
/// Most surfaces are hand-built from the design tokens rather than leaning on
/// Material defaults, but the theme still sets sane colors, text scaling, and
/// removes Material's elevation shadows so nothing cool-toned or shadowed
/// leaks in from framework defaults.
ThemeData buildAppTheme({
  Brightness brightness = Brightness.light,
  Color? accent,
  FontPreferences fonts = const FontPreferences(),
}) {
  final bool dark = brightness == Brightness.dark;
  final palette = AppPalette(
    dark,
    accent: accent == null
        ? null
        : adaptiveAccent(accent, AppPalette(dark).ivoryMedium),
  );
  final ColorScheme scheme = ColorScheme(
    brightness: brightness,
    primary: palette.clay,
    onPrimary: contrastingLabel(palette.clay),
    secondary: palette.oatWarm,
    onSecondary: palette.slateDark,
    surface: palette.ivoryLight,
    onSurface: palette.slateDark,
    error: palette.clayDeep,
    onError: Colors.white,
    // The dark player draws its own surfaces, but a snack bar shown from it
    // still resolves through this local theme. Without these the framework
    // falls back to `onPrimary` (white) for the action label, which is what
    // made 查看 look like a white button.
    inverseSurface: palette.ivoryLight,
    onInverseSurface: palette.slateDark,
    inversePrimary: palette.clayDeep,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: palette.ivoryMedium,
    canvasColor: palette.ivoryMedium,
    dividerColor: palette.stone,
    splashFactory: InkRipple.splashFactory,
    splashColor: palette.slateDark.withValues(alpha: 0.09),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.windows: LazerPageTransitionsBuilder(),
        TargetPlatform.linux: LazerPageTransitionsBuilder(),
      },
    ),
    highlightColor: Colors.transparent,
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: palette.slateDark),
      textStyle: TextStyle(
        fontFamily: AppFonts.sans,
        color: palette.onInk,
        fontSize: 12,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: palette.ivoryLight,
      contentTextStyle: TextStyle(
        fontFamily: AppFonts.sans,
        fontFamilyFallback: AppFonts.sansFallback,
        fontSize: 14,
        height: 1.4,
        color: palette.slateDark,
      ),
      actionTextColor: palette.clayDeep,
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    // Global safety net: any Text without an explicit AppText style still
    // renders in bundled MiSans instead of the system fallback.
    fontFamily: AppFonts.sans,
    fontFamilyFallback: AppFonts.sansFallback,
    textTheme: fonts.applyTo(
      ThemeData(brightness: brightness).textTheme.apply(
        fontFamily: AppFonts.sans,
        bodyColor: palette.slateDark,
        displayColor: palette.slateDark,
      ),
    ),
    extensions: <ThemeExtension<dynamic>>[fonts],
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: palette.clayDeep,
      selectionColor: palette.oatWarm,
      selectionHandleColor: palette.clayDeep,
    ),
    // Flat everywhere: elevation is expressed through tone, not shadow.
    dialogTheme: const DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      elevation: 0,
      modalElevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
    ),
    cardTheme: CardThemeData(
      color: palette.ivoryLight,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(AppRadius.card)),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: palette.ivoryMedium,
      foregroundColor: palette.slateDark,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: palette.clay,
      linearTrackColor: palette.oatWarm,
      circularTrackColor: palette.oatWarm,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll<Color>(palette.cloudMedium),
      thickness: const WidgetStatePropertyAll<double>(8),
      radius: const Radius.circular(0),
    ),
  );
}
