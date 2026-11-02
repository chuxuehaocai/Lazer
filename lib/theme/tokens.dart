import 'package:flutter/material.dart';
import '../animation/apple_spring.dart';

/// Typography families bundled with the app.
///
/// MiSans is the UI face on every platform: it has the CJK coverage the
/// catalogue needs, and it is hinted + antialiased on Windows, macOS and
/// Linux. The fallbacks only cover exotic glyphs MiSans lacks.
abstract final class AppFonts {
  static const String sans = 'MiSans';
  static const List<String> sansFallback = <String>[
    'Segoe UI',
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'sans-serif',
  ];

  /// Serif role — kept for cover-art lyric exports only; the interface itself
  /// is one sans family.
  static const String serif = 'MiSans';
  static const List<String> serifFallback = <String>[
    'Georgia',
    'Microsoft YaHei',
    'serif',
  ];

  /// Monospace role — MiSans first so timecodes match the rest of the chrome.
  static const String mono = 'MiSans';
  static const List<String> monoFallback = <String>[
    'Consolas',
    'Courier New',
    'monospace',
  ];
}

/// Material 3 shape scale used by the whole interface. One radius vocabulary
/// avoids the old mix of 8/11/12/14/15/16/18/24/28 dp corners.
abstract final class AppShape {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 28;

  static const BorderRadius xsRadius = BorderRadius.all(Radius.circular(xs));
  static const BorderRadius smRadius = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdRadius = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgRadius = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius xlRadius = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius xxlRadius = BorderRadius.all(Radius.circular(xxl));
  static const BorderRadius full = BorderRadius.all(Radius.circular(999));
}

/// Shared response times and bounded spring easing for Apple-style motion.
/// Interactive geometry uses AppleSpring simulations to retain its velocity.
abstract final class AppMotion {
  static const Duration instant = Duration(milliseconds: 90);
  static const Duration quick = Duration(milliseconds: 140);
  static const Duration standard = Duration(milliseconds: 200);
  static const Duration emphasized = Duration(milliseconds: 320);

  static const Curve standardCurve = AppleSpringCurve();
  static const Curve emphasizedCurve = AppleSpringCurve();

  static const Curve emphasizedDecelerate = AppleSpringCurve();
  static const Curve emphasizedAccelerate = AppleSpringCurve();

  /// The minimum frame budget the app is tuned for: 100 fps.
  static const double frameBudgetMs = 1000 / 100;
}

/// The design tokens the shell is built from.
///
/// The palette is the Lazer blue-grey: lake blue by day, pale ice blue at
/// night, warm paper neutrals and a clay tertiary. It is a complete Material 3
/// role set — every surface role has an explicit tone, so no widget can fall
/// back to Flutter's purple baseline scheme.
class AppTokens {
  const AppTokens._();

  // Light neutrals.
  static const Color paper = Color(0xFFF7F5EF);
  static const Color paperRaised = Color(0xFFFCFAF5);
  static const Color paperContainer = Color(0xFFF0ECE3);
  static const Color ink = Color(0xFF1B2A30);
  static const Color quietInk = Color(0xFF5B6B71);

  // Brand hues.
  static const Color lakeBlue = Color(0xFF5F91AC);
  static const Color deepBlue = Color(0xFF365F73);
  static const Color warmClay = Color(0xFFB88769);

  // Dark neutrals.
  static const Color nightPaper = Color(0xFF141C20);
  static const Color nightRaised = Color(0xFF1A2327);
  static const Color nightContainer = Color(0xFF1E282C);
  static const Color nightInk = Color(0xFFE2E8E9);
  static const Color nightQuietInk = Color(0xFFB7C3C7);
  static const Color nightBlue = Color(0xFF9CCDE4);

  /// Rail width and page padding the desktop shell uses.
  static const double railWidth = 208;
  static const double pagePadding = 28;
  static const double playerBarHeight = 84;
  static const double compactPlayerBarHeight = 64;
}
