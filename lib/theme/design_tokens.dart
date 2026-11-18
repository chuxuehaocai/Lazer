/// Design tokens transcribed from DESIGN.md — "Anthropic Style Reference".
///
/// The system reads like a scientific field journal on warm parchment:
/// quiet ivory surfaces, editorial serif headlines, hairline borders instead
/// of shadows, and a single clay accent reserved for moments of action.
library;

import 'package:flutter/material.dart';

import 'tokens.dart' show AppFonts;
export 'tokens.dart' show AppFonts;

// ---------------------------------------------------------------------------
// Colors
// ---------------------------------------------------------------------------

/// Warm earth-tone palette with one cool accent. Never use
/// pure white (#ffffff) as a surface — the system is ivory-tinted throughout.
abstract final class AppColors {
  /// Primary text, headings, footer/player-bar background, hairline borders.
  /// Near-black with a hint of warmth, never pure black.
  static const Color slateDark = Color(0xFF141413);

  /// Page canvas — the parchment that everything sits on.
  static const Color ivoryMedium = Color(0xFFF0EEE6);

  /// Card surfaces and elevated panels — one tonal step above canvas.
  static const Color ivoryLight = Color(0xFFFAF9F5);

  /// Muted helper text, inactive nav items, secondary labels.
  static const Color cloudMedium = Color(0xFFB0AEA5);

  /// Outlined button borders, mid-contrast dividers.
  static const Color cloudDark = Color(0xFF87867F);

  /// Hairline borders and dividers between sections.
  static const Color stone = Color(0xFFCCCBC8);

  /// Dark-on-dark borders inside the inversion surface (footer / player bar).
  static const Color slateMedium = Color(0xFF3D3D3A);

  /// Secondary warm surface for grouped panels — a deeper paper tone.
  static const Color oatWarm = Color(0xFFE3DACC);

  /// Featured hero card background — vintage manilla paper tone.
  static const Color manilla = Color(0xFFF5E3C7);

  /// The single chromatic accent — terracotta clay, filled CTA buttons only.
  /// Restored to the #d97757 earth tone of the style reference (an earlier
  /// ink-blue experiment is retired; the token name keeps every call site
  /// picking the hue up automatically).
  static const Color clay = Color(0xFFD97757);

  /// Hover / pressed state for accent CTAs.
  static const Color clayDeep = Color(0xFFC6613F);

  /// Text color on dark utility bands (footer spec: #faf9f5 text).
  static const Color onDark = Color(0xFFFAF9F5);

  /// Muted text on dark utility bands.
  static const Color onDarkMuted = Color(0xFFB0AEA5);
}

// ---------------------------------------------------------------------------
// Typography
// ---------------------------------------------------------------------------

/// Type scale from DESIGN.md. Roles: caption / body-sm / body / subheading /
/// heading / display.
abstract final class AppText {
  // caption — sans 12px, lh 1.4, ls -0.24px
  static const TextStyle caption = TextStyle(
    fontFamily: AppFonts.sans,
    fontFamilyFallback: AppFonts.sansFallback,
    fontSize: 12,
    height: 1.4,
    letterSpacing: -0.24,
    color: AppColors.slateDark,
  );

  static const TextStyle captionMuted = TextStyle(
    fontFamily: AppFonts.sans,
    fontFamilyFallback: AppFonts.sansFallback,
    fontSize: 12,
    height: 1.4,
    letterSpacing: -0.24,
    color: AppColors.cloudMedium,
  );

  static const TextStyle captionStrong = TextStyle(
    fontFamily: AppFonts.sans,
    fontFamilyFallback: AppFonts.sansFallback,
    fontSize: 12,
    fontWeight: FontWeight.w600,
    height: 1.4,
    letterSpacing: -0.24,
    color: AppColors.slateDark,
  );

  // body-sm — sans 16px (UI chrome). Line height relaxed slightly from the
  // 1.0 reference for CJK legibility.
  static const TextStyle bodySm = TextStyle(
    fontFamily: AppFonts.sans,
    fontFamilyFallback: AppFonts.sansFallback,
    fontSize: 16,
    height: 1.3,
    letterSpacing: -0.08,
    color: AppColors.slateDark,
  );

  static const TextStyle bodySmMuted = TextStyle(
    fontFamily: AppFonts.sans,
    fontFamilyFallback: AppFonts.sansFallback,
    fontSize: 16,
    height: 1.3,
    letterSpacing: -0.08,
    color: AppColors.cloudMedium,
  );

  // body — serif 20px, lh 1.4. All prose must be serif; sans is chrome only.
  static const TextStyle body = TextStyle(
    fontFamily: AppFonts.serif,
    fontFamilyFallback: AppFonts.serifFallback,
    fontSize: 20,
    height: 1.4,
    color: AppColors.slateDark,
  );

  static const TextStyle bodyMuted = TextStyle(
    fontFamily: AppFonts.serif,
    fontFamilyFallback: AppFonts.serifFallback,
    fontSize: 20,
    height: 1.4,
    color: AppColors.cloudDark,
  );

  // subheading — serif 24px, w600, lh 1.3
  static const TextStyle subheading = TextStyle(
    fontFamily: AppFonts.serif,
    fontFamilyFallback: AppFonts.serifFallback,
    fontSize: 24,
    fontWeight: FontWeight.w600,
    height: 1.3,
    letterSpacing: -0.05,
    color: AppColors.slateDark,
  );

  // heading — sans 61px, w700, lh 1.1 (declarative statements)
  static const TextStyle heading = TextStyle(
    fontFamily: AppFonts.sans,
    fontFamilyFallback: AppFonts.sansFallback,
    fontSize: 61,
    fontWeight: FontWeight.w700,
    height: 1.1,
    letterSpacing: -0.12,
    color: AppColors.slateDark,
  );

  // display — serif 68px, w400, lh 1.1 (editorial reflection)
  static const TextStyle display = TextStyle(
    fontFamily: AppFonts.serif,
    fontFamilyFallback: AppFonts.serifFallback,
    fontSize: 68,
    height: 1.1,
    color: AppColors.slateDark,
  );

  // mono — 16px, lh 1.4, for cookie strings and timecodes
  static const TextStyle mono = TextStyle(
    fontFamily: AppFonts.mono,
    fontFamilyFallback: AppFonts.monoFallback,
    fontSize: 16,
    height: 1.4,
    color: AppColors.slateDark,
  );

  static const TextStyle monoSm = TextStyle(
    fontFamily: AppFonts.mono,
    fontFamilyFallback: AppFonts.monoFallback,
    fontSize: 12,
    height: 1.4,
    color: AppColors.cloudDark,
  );

  /// Wordmark style — nav logo: sans 12px w700, all caps, letter-spaced.
  static const TextStyle wordmark = TextStyle(
    fontFamily: AppFonts.sans,
    fontFamilyFallback: AppFonts.sansFallback,
    fontSize: 12,
    fontWeight: FontWeight.w700,
    letterSpacing: 3.2,
    height: 1.0,
    color: AppColors.slateDark,
  );
}

// ---------------------------------------------------------------------------
// Spacing, radius, elevation
// ---------------------------------------------------------------------------

/// Base unit 4px, compact density. Page max-width 1280px.
abstract final class AppSpacing {
  static const double unit = 4;
  static const double xs = 4;
  static const double sm = 8; // element gap
  static const double md = 16;
  static const double lg = 24; // card padding lower bound
  static const double xl = 32; // card padding upper bound
  static const double xxl = 48;
  static const double section = 80; // section gap lower bound
  static const double pageMaxWidth = 1280;
}

/// Surfaces and artwork are square; buttons retain their existing treatment.
abstract final class AppRadius {
  static const double card = 0;
  static const double outlined = 12;
  static const double filledButtonBottom = 8;
  static const double none = 0;

  /// Signature treatment for filled buttons: sharp top corners, rounded
  /// bottom — "a tab pulled from a stack", not a generic pill.
  static const BorderRadius filledButton = BorderRadius.vertical(
    bottom: Radius.circular(filledButtonBottom),
  );

  static const BorderRadius cardBorder = BorderRadius.all(
    Radius.circular(card),
  );
  static const BorderRadius outlinedBorder = BorderRadius.all(
    Radius.circular(outlined),
  );
}

/// Elevation: none. Surfaces lift through tone shifts
/// (#f0eee6 → #faf9f5 → #f5e3c7) and 1px hairline borders only.
abstract final class AppElevation {
  static const List<BoxShadow> none = <BoxShadow>[];
}

/// Hairline border helpers.
abstract final class AppBorders {
  static const BorderSide hairline = BorderSide(
    color: AppColors.stone,
    width: 1,
  );
  static const BorderSide hairlineDark = BorderSide(
    color: AppColors.slateDark,
    width: 1,
  );
  static const BorderSide onDark = BorderSide(
    color: AppColors.slateMedium,
    width: 1,
  );
  static const BorderSide outlined = BorderSide(
    color: AppColors.cloudDark,
    width: 1,
  );
}
