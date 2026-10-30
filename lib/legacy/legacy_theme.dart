import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import '../animation/view_transitions.dart';

export '../theme/tokens.dart';

/// The fixed Lazer Material 3 scheme.
ColorScheme legacyColorScheme(Brightness brightness) =>
    brightness == Brightness.dark ? _legacyDark : _legacyLight;

/// Page canvas for the active scheme.
Color legacyPageBackground(Brightness brightness) =>
    brightness == Brightness.dark
    ? LegacyTokens.nightPaper
    : LegacyTokens.paper;

/// The same page tone for whichever scheme is active — fixed or cover-seeded.
Color legacyPageBackgroundOf(ColorScheme scheme) => scheme.surface;

const ColorScheme _legacyLight = ColorScheme(
  brightness: Brightness.light,
  primary: Color(0xFF35657D),
  onPrimary: Color(0xFFFFFFFF),
  primaryContainer: Color(0xFFC6E7F5),
  onPrimaryContainer: Color(0xFF0B3442),
  primaryFixed: Color(0xFFC6E7F5),
  primaryFixedDim: Color(0xFF8FC4DA),
  onPrimaryFixed: Color(0xFF0B3442),
  onPrimaryFixedVariant: Color(0xFF1C4C60),
  secondary: Color(0xFF50646B),
  onSecondary: Color(0xFFFFFFFF),
  secondaryContainer: Color(0xFFD3E6EC),
  onSecondaryContainer: Color(0xFF0D2026),
  secondaryFixed: Color(0xFFD3E6EC),
  secondaryFixedDim: Color(0xFFB4CBD1),
  onSecondaryFixed: Color(0xFF0D2026),
  onSecondaryFixedVariant: Color(0xFF374A50),
  tertiary: Color(0xFF8A5A3C),
  onTertiary: Color(0xFFFFFFFF),
  tertiaryContainer: Color(0xFFF7DCCB),
  onTertiaryContainer: Color(0xFF341100),
  tertiaryFixed: Color(0xFFF7DCCB),
  tertiaryFixedDim: Color(0xFFE4BD9F),
  onTertiaryFixed: Color(0xFF341100),
  onTertiaryFixedVariant: Color(0xFF5C3D29),
  error: Color(0xFFB3261E),
  onError: Color(0xFFFFFFFF),
  errorContainer: Color(0xFFF9DEDC),
  onErrorContainer: Color(0xFF410E0B),
  surface: LegacyTokens.paperRaised,
  onSurface: LegacyTokens.ink,
  surfaceDim: Color(0xFFDCD9D0),
  surfaceBright: LegacyTokens.paperRaised,
  surfaceContainerLowest: Color(0xFFFFFFFF),
  surfaceContainerLow: Color(0xFFF5F1E9),
  surfaceContainer: Color(0xFFF0ECE3),
  surfaceContainerHigh: Color(0xFFEAE5DC),
  surfaceContainerHighest: Color(0xFFE3DED4),
  onSurfaceVariant: LegacyTokens.quietInk,
  outline: Color(0xFF8A989C),
  outlineVariant: Color(0xFFD5DCD8),
  inverseSurface: Color(0xFF2E3A3F),
  onInverseSurface: Color(0xFFEFF3F2),
  inversePrimary: LegacyTokens.nightBlue,
  surfaceTint: Color(0xFF35657D),
  shadow: Color(0xFF000000),
  scrim: Color(0xFF000000),
);

const ColorScheme _legacyDark = ColorScheme(
  brightness: Brightness.dark,
  primary: LegacyTokens.nightBlue,
  onPrimary: Color(0xFF003543),
  primaryContainer: Color(0xFF1E4D61),
  onPrimaryContainer: Color(0xFFC6E7F5),
  primaryFixed: Color(0xFFC6E7F5),
  primaryFixedDim: Color(0xFF8FC4DA),
  onPrimaryFixed: Color(0xFF0B3442),
  onPrimaryFixedVariant: Color(0xFF1C4C60),
  secondary: Color(0xFFB4C9D1),
  onSecondary: Color(0xFF1F333A),
  secondaryContainer: Color(0xFF364A51),
  onSecondaryContainer: Color(0xFFD3E6EC),
  secondaryFixed: Color(0xFFD3E6EC),
  secondaryFixedDim: Color(0xFFB4CBD1),
  onSecondaryFixed: Color(0xFF0D2026),
  onSecondaryFixedVariant: Color(0xFF374A50),
  tertiary: Color(0xFFE0B79B),
  onTertiary: Color(0xFF452A18),
  tertiaryContainer: Color(0xFF5C3D29),
  onTertiaryContainer: Color(0xFFF7DCCB),
  tertiaryFixed: Color(0xFFF7DCCB),
  tertiaryFixedDim: Color(0xFFE4BD9F),
  onTertiaryFixed: Color(0xFF341100),
  onTertiaryFixedVariant: Color(0xFF5C3D29),
  error: Color(0xFFF2B8B5),
  onError: Color(0xFF601410),
  errorContainer: Color(0xFF8C1D18),
  onErrorContainer: Color(0xFFF9DEDC),
  surface: LegacyTokens.nightPaper,
  onSurface: LegacyTokens.nightInk,
  surfaceDim: Color(0xFF0F1619),
  surfaceBright: Color(0xFF394448),
  surfaceContainerLowest: Color(0xFF0D1316),
  surfaceContainerLow: Color(0xFF1A2327),
  surfaceContainer: LegacyTokens.nightContainer,
  surfaceContainerHigh: Color(0xFF283237),
  surfaceContainerHighest: Color(0xFF333D42),
  onSurfaceVariant: LegacyTokens.nightQuietInk,
  outline: Color(0xFF849398),
  outlineVariant: Color(0xFF3F4C51),
  inverseSurface: LegacyTokens.nightInk,
  onInverseSurface: Color(0xFF283034),
  inversePrimary: Color(0xFF35657D),
  surfaceTint: LegacyTokens.nightBlue,
  shadow: Color(0xFF000000),
  scrim: Color(0xFF000000),
);

/// Material 3 type ramp, rendered with MiSans. Line heights are slightly
/// taller than the Latin baseline so stacked CJK lines stay legible.
const TextTheme legacyTextTheme = TextTheme(
  displayLarge: TextStyle(
    fontFamily: AppFonts.sans,
    fontWeight: FontWeight.w400,
    fontSize: 57,
    height: 64 / 57,
    letterSpacing: -0.25,
  ),
  displayMedium: TextStyle(
    fontFamily: AppFonts.sans,
    fontWeight: FontWeight.w400,
    fontSize: 45,
    height: 52 / 45,
  ),
  displaySmall: TextStyle(
    fontFamily: AppFonts.sans,
    fontWeight: FontWeight.w400,
    fontSize: 36,
    height: 44 / 36,
    letterSpacing: -0.5,
  ),
  headlineLarge: TextStyle(
    fontFamily: AppFonts.sans,
    fontWeight: FontWeight.w400,
    fontSize: 32,
    height: 40 / 32,
  ),
  headlineMedium: TextStyle(
    fontFamily: AppFonts.sans,
    fontWeight: FontWeight.w600,
    fontSize: 28,
    height: 36 / 28,
    letterSpacing: -0.25,
  ),
  headlineSmall: TextStyle(
    fontFamily: AppFonts.sans,
    fontWeight: FontWeight.w600,
    fontSize: 24,
    height: 32 / 24,
  ),
  titleLarge: TextStyle(
    fontFamily: AppFonts.sans,
    fontWeight: FontWeight.w600,
    fontSize: 22,
    height: 28 / 22,
  ),
  titleMedium: TextStyle(
    fontFamily: AppFonts.sans,
    fontWeight: FontWeight.w500,
    fontSize: 16,
    height: 24 / 16,
  ),
  titleSmall: TextStyle(
    fontFamily: AppFonts.sans,
    fontWeight: FontWeight.w500,
    fontSize: 14,
    height: 20 / 14,
  ),
  bodyLarge: TextStyle(
    fontFamily: AppFonts.sans,
    fontWeight: FontWeight.w400,
    fontSize: 16,
    height: 24 / 16,
  ),
  bodyMedium: TextStyle(
    fontFamily: AppFonts.sans,
    fontWeight: FontWeight.w400,
    fontSize: 14,
    height: 20 / 14,
  ),
  bodySmall: TextStyle(
    fontFamily: AppFonts.sans,
    fontWeight: FontWeight.w400,
    fontSize: 12,
    height: 16 / 12,
  ),
  labelLarge: TextStyle(
    fontFamily: AppFonts.sans,
    fontWeight: FontWeight.w500,
    fontSize: 14,
    height: 20 / 14,
  ),
  labelMedium: TextStyle(
    fontFamily: AppFonts.sans,
    fontWeight: FontWeight.w500,
    fontSize: 12,
    height: 16 / 12,
  ),
  labelSmall: TextStyle(
    fontFamily: AppFonts.sans,
    fontWeight: FontWeight.w500,
    fontSize: 11,
    height: 16 / 11,
  ),
);

/// The app's single Material 3 theme.
///
/// Pass [seed] to derive the whole scheme from the current cover — the legacy
/// `LazerPalette.NowPlaying`. Without a seed the fixed Lazer palette is used.
ThemeData buildLegacyTheme({
  Brightness brightness = Brightness.light,
  Color? seed,
}) {
  final ColorScheme scheme = seed == null
      ? legacyColorScheme(brightness)
      : ColorScheme.fromSeed(
          seedColor: seed,
          brightness: brightness,
          dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
        );
  final TextTheme textTheme = legacyTextTheme.apply(
    bodyColor: scheme.onSurface,
    displayColor: scheme.onSurface,
  );
  final Color surface = scheme.surface;
  final Color onSurface = scheme.onSurface;
  final Color onSurfaceVariant = scheme.onSurfaceVariant;

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: AppFonts.sans,
    fontFamilyFallback: AppFonts.sansFallback,
    textTheme: textTheme,
    primaryTextTheme: textTheme.apply(
      bodyColor: scheme.onPrimary,
      displayColor: scheme.onPrimary,
    ),
    scaffoldBackgroundColor: surface,
    canvasColor: surface,
    cardColor: scheme.surfaceContainerLow,
    dividerColor: scheme.outlineVariant,
    shadowColor: scheme.shadow,
    splashFactory: InkSparkle.splashFactory,
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.windows: LazerPageTransitionsBuilder(),
        TargetPlatform.linux: LazerPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
      },
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: surface,
      foregroundColor: onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: textTheme.titleLarge,
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: const RoundedRectangleBorder(borderRadius: AppShape.lgRadius),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shape: const RoundedRectangleBorder(borderRadius: AppShape.xxlRadius),
      titleTextStyle: textTheme.headlineSmall,
      contentTextStyle: textTheme.bodyMedium?.copyWith(color: onSurfaceVariant),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: scheme.surfaceContainerLow,
      elevation: 3,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppShape.xxl)),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.secondaryContainer,
      elevation: 0,
      height: 72,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStateProperty.resolveWith<TextStyle?>(
        (Set<WidgetState> states) => textTheme.labelMedium?.copyWith(
          color: states.contains(WidgetState.selected)
              ? scheme.onSurface
              : onSurfaceVariant,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w500,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      indicatorColor: scheme.secondaryContainer,
      selectedIconTheme: IconThemeData(color: scheme.onSecondaryContainer),
      unselectedIconTheme: IconThemeData(color: onSurfaceVariant),
      selectedLabelTextStyle: textTheme.labelLarge?.copyWith(
        color: scheme.onSurface,
      ),
      unselectedLabelTextStyle: textTheme.labelMedium?.copyWith(
        color: onSurfaceVariant,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 48),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        shape: const StadiumBorder(),
        textStyle: textTheme.labelLarge,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        minimumSize: const Size(64, 48),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        shape: const StadiumBorder(),
        textStyle: textTheme.labelLarge,
        elevation: 1,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 48),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        shape: const StadiumBorder(),
        textStyle: textTheme.labelLarge,
        side: BorderSide(color: scheme.outline),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 40),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        shape: const StadiumBorder(),
        textStyle: textTheme.labelLarge,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: onSurfaceVariant,
        shape: const StadiumBorder(),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        textStyle: WidgetStatePropertyAll<TextStyle?>(textTheme.labelLarge),
        shape: const WidgetStatePropertyAll<OutlinedBorder>(StadiumBorder()),
        side: WidgetStatePropertyAll<BorderSide>(
          BorderSide(color: scheme.outlineVariant),
        ),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith<Color?>(
        (Set<WidgetState> states) => states.contains(WidgetState.selected)
            ? scheme.onPrimary
            : scheme.outline,
      ),
      trackColor: WidgetStateProperty.resolveWith<Color?>(
        (Set<WidgetState> states) => states.contains(WidgetState.selected)
            ? scheme.primary
            : scheme.surfaceContainerHighest,
      ),
      trackOutlineColor: const WidgetStatePropertyAll<Color>(
        Colors.transparent,
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith<Color?>(
        (Set<WidgetState> states) => states.contains(WidgetState.selected)
            ? scheme.primary
            : Colors.transparent,
      ),
      shape: const RoundedRectangleBorder(borderRadius: AppShape.xsRadius),
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 4,
      activeTrackColor: scheme.primary,
      inactiveTrackColor: scheme.surfaceContainerHighest,
      secondaryActiveTrackColor: scheme.primary.withValues(alpha: 0.38),
      thumbColor: scheme.primary,
      overlayColor: scheme.primary.withValues(alpha: 0.12),
      valueIndicatorColor: scheme.inverseSurface,
      valueIndicatorTextStyle: textTheme.labelMedium?.copyWith(
        color: scheme.onInverseSurface,
      ),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
      trackShape: const RoundedRectSliderTrackShape(),
      tickMarkShape: SliderTickMarkShape.noTickMark,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: Colors.transparent,
      selectedColor: scheme.secondaryContainer,
      disabledColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      side: BorderSide(color: scheme.outlineVariant),
      shape: const RoundedRectangleBorder(borderRadius: AppShape.smRadius),
      labelStyle: textTheme.labelLarge?.copyWith(color: onSurfaceVariant),
      secondaryLabelStyle: textTheme.labelLarge?.copyWith(
        color: scheme.onSecondaryContainer,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      hintStyle: textTheme.bodyMedium?.copyWith(color: onSurfaceVariant),
      helperStyle: textTheme.bodySmall?.copyWith(color: onSurfaceVariant),
      errorStyle: textTheme.bodySmall?.copyWith(color: scheme.error),
      border: const OutlineInputBorder(
        borderRadius: AppShape.lgRadius,
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: AppShape.lgRadius,
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: AppShape.lgRadius,
        borderSide: BorderSide(color: scheme.primary, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: AppShape.lgRadius,
        borderSide: BorderSide(color: scheme.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: AppShape.lgRadius,
        borderSide: BorderSide(color: scheme.error, width: 1.6),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      elevation: 3,
      shape: const RoundedRectangleBorder(borderRadius: AppShape.mdRadius),
      textStyle: textTheme.bodyMedium,
      labelTextStyle: WidgetStatePropertyAll<TextStyle?>(textTheme.bodyMedium),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll<Color?>(
          scheme.surfaceContainer,
        ),
        surfaceTintColor: const WidgetStatePropertyAll<Color?>(
          Colors.transparent,
        ),
        elevation: const WidgetStatePropertyAll<double?>(3),
        shape: const WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(borderRadius: AppShape.mdRadius),
        ),
      ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      textStyle: textTheme.bodyMedium,
      inputDecorationTheme: const InputDecorationTheme(
        filled: false,
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        border: OutlineInputBorder(
          borderRadius: AppShape.mdRadius,
          borderSide: BorderSide.none,
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: textTheme.bodyMedium?.copyWith(
        color: scheme.onInverseSurface,
      ),
      actionTextColor: scheme.inversePrimary,
      behavior: SnackBarBehavior.floating,
      elevation: 3,
      shape: const RoundedRectangleBorder(borderRadius: AppShape.mdRadius),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: scheme.inverseSurface,
        borderRadius: AppShape.smRadius,
      ),
      textStyle: textTheme.labelMedium?.copyWith(
        color: scheme.onInverseSurface,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      waitDuration: const Duration(milliseconds: 420),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.surfaceContainerHighest,
      circularTrackColor: scheme.surfaceContainerHighest,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll<Color>(
        onSurface.withValues(alpha: 0.26),
      ),
      radius: const Radius.circular(999),
      thickness: const WidgetStatePropertyAll<double>(6),
      crossAxisMargin: 3,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: scheme.primary,
      selectionColor: scheme.primary.withValues(alpha: 0.26),
      selectionHandleColor: scheme.primary,
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    listTileTheme: ListTileThemeData(
      iconColor: onSurfaceVariant,
      textColor: onSurface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      shape: const RoundedRectangleBorder(borderRadius: AppShape.mdRadius),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: scheme.primary,
      unselectedLabelColor: onSurfaceVariant,
      indicatorColor: scheme.primary,
      dividerColor: scheme.outlineVariant,
      labelStyle: textTheme.labelLarge,
      unselectedLabelStyle: textTheme.labelLarge,
      indicatorSize: TabBarIndicatorSize.label,
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: AppShape.xlRadius),
    ),
    searchBarTheme: SearchBarThemeData(
      backgroundColor: WidgetStatePropertyAll<Color?>(
        scheme.surfaceContainerHigh,
      ),
      surfaceTintColor: const WidgetStatePropertyAll<Color?>(
        Colors.transparent,
      ),
      elevation: const WidgetStatePropertyAll<double?>(0),
      shape: const WidgetStatePropertyAll<OutlinedBorder>(StadiumBorder()),
      textStyle: WidgetStatePropertyAll<TextStyle?>(textTheme.bodyMedium),
      hintStyle: WidgetStatePropertyAll<TextStyle?>(
        textTheme.bodyMedium?.copyWith(color: onSurfaceVariant),
      ),
    ),
    splashColor: scheme.primary.withValues(alpha: 0.10),
    highlightColor: scheme.primary.withValues(alpha: 0.06),
  );
}
