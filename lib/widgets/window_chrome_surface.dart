import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/ui_preferences.dart';
import '../theme/apple_design.dart';
import 'apple_ui.dart';

const double kWindowChromeHeight = 40.0;
const double kWindowChromeButtonWidth = 46.0;

/// Offset of the floating Inline capsule from the window's top edge.
const double kWindowChromeTop = 12.0;

/// Trailing inset of the floating Inline capsule.
const double kWindowChromeEnd = 20.0;

/// Grab area left of the capsule. Inline chrome floats over the page instead of
/// owning a header strip, so this invisible strip is the window's drag and
/// double-click-to-maximize handle; it sits outside the capsule so the capsule's
/// own geometry stays exactly the button cluster.
const double kWindowChromeGripWidth = 16.0;

/// Height of the band the floating capsule occupies (top offset + capsule + a
/// small gap). Pages keep this much space at their top edge so their first row
/// never lands under the capsule; the space is page padding, not a header, so it
/// scrolls away with the content.
const double kInlineChromeInset = kWindowChromeTop + kWindowChromeHeight + 4;

/// Vertical centre of the floating capsule's row.
const double kWindowChromeCenterY = kWindowChromeTop + kWindowChromeHeight / 2;

/// How far below the capsule's centre a page's own control sits.
///
/// The two rows read level a couple of points lower than a strict centre match:
/// the capsule draws 18 dp caption glyphs inside a 40 dp pill, while a page back
/// chevron is 24 dp inside a 48 dp target. Pinning both centres to one line
/// therefore leaves the page control looking a hair high next to the capsule.
const double kWindowChromeControlNudge = 2;

/// Top offset that centres a [height]-tall page control on the capsule's row,
/// [kWindowChromeControlNudge] below the capsule's own centre line.
double windowChromeControlTop(double height) =>
    kWindowChromeCenterY + kWindowChromeControlNudge - height / 2;

/// Height of the square back affordance a page puts on the capsule's row.
///
/// This is the Material tap target an [IconButton] takes by default, so a page
/// that hands the scaffold its normal back button needs no size of its own.
const double kPageBackControlSize = 48.0;

/// Width reserved for a text command that opens the capsule's extension, and the
/// hairline that separates it from the icon cluster and the caption buttons.
/// The widest label is the Japanese "既定値に戻す" (seven characters), which needs
/// a little over 100 dp at the capsule's type size.
const double kWindowChromeTextActionWidth = 116.0;
const double kWindowChromeActionDivider = 17.0;

/// The colour the capsule paints behind its buttons.
///
/// A listener-picked [custom] colour wins; otherwise the capsule takes the
/// theme's own background colour — the deep blue `#191C23` in dark mode, white
/// in light mode — so the chrome reads as part of the window rather than as an
/// accent-tinted panel. [opacity] scales that tint's alpha, independent of the
/// blur, which is what lets the page show through it.
Color windowChromeTint(
  AppleSemanticColors apple, {
  Color? custom,
  required double opacity,
}) {
  final double alpha = opacity.isFinite
      ? opacity.clamp(kWindowChromeOpacityMin, kWindowChromeOpacityMax)
      : kWindowChromeOpacityDefault;
  return (custom ?? apple.background).withValues(alpha: alpha);
}

/// The capsule material the listener configured: tint, backdrop blur and blur
/// strength.
///
/// The frame publishes one through `WindowChromeScope`, and every capsule in
/// the window resolves it against its own theme: the floating capsule Inline
/// mode draws, and the capsule a page draws for itself under a classic title
/// bar, read as the same material in the same window.
@immutable
class WindowChromeCapsuleStyle {
  const WindowChromeCapsuleStyle({
    this.custom,
    this.opacity = kWindowChromeOpacityDefault,
    this.blurEnabled = true,
    this.blurSigma = kWindowChromeBlurDefault,
  });

  /// Nothing configured: the theme's own background at the default strength.
  static const WindowChromeCapsuleStyle defaults = WindowChromeCapsuleStyle();

  /// A listener-picked tint; null follows the surface's background colour.
  final Color? custom;
  final double opacity;
  final bool blurEnabled;
  final double blurSigma;

  Color tintFor(AppleSemanticColors apple) =>
      windowChromeTint(apple, custom: custom, opacity: opacity);

  /// Paints [child] on the capsule material, with the capsule's own pill
  /// geometry: [kWindowChromeHeight] tall, fully rounded and clipped.
  Widget surface({
    Key? key,
    required BuildContext context,
    required Widget child,
  }) => WindowChromeSurface(
    key: key,
    tint: tintFor(AppleSemanticColors.of(context)),
    blurEnabled: blurEnabled,
    blurSigma: blurSigma,
    child: child,
  );

  @override
  bool operator ==(Object other) =>
      other is WindowChromeCapsuleStyle &&
      other.custom == custom &&
      other.opacity == opacity &&
      other.blurEnabled == blurEnabled &&
      other.blurSigma == blurSigma;

  @override
  int get hashCode => Object.hash(custom, opacity, blurEnabled, blurSigma);
}

/// The capsule material [state] asks for. A frame without a listener state — a
/// preview or a widget test — answers the defaults.
WindowChromeCapsuleStyle windowChromeCapsuleStyleOf(AppState? state) =>
    WindowChromeCapsuleStyle(
      custom: state?.windowChromeColor,
      opacity: state?.windowChromeOpacity ?? kWindowChromeOpacityDefault,
      blurEnabled: state?.windowChromeBlurEnabled ?? true,
      blurSigma: state?.windowChromeBlur ?? kWindowChromeBlurDefault,
    );

/// The shared surface for floating caption and player-action capsules: the same
/// translucent material as the phone's navigation capsule — glass tint plus a
/// backdrop blur — with the tint, the blur and the blur strength coming from the
/// listener's settings.
///
/// Two owners paint it: the frame, for the caption and player-action capsule
/// that floats over the page, and a page itself, for the capsule a classic title
/// bar leaves to it. Both go through [WindowChromeCapsuleStyle] so the pill's
/// radius, tint, blur and clipping stay one definition.
class WindowChromeSurface extends StatelessWidget {
  const WindowChromeSurface({
    super.key,
    required this.child,
    this.tint,
    this.blurEnabled = true,
    this.blurSigma = kWindowChromeBlurDefault,
  });

  final Widget child;

  /// Null falls back to the theme's glass tint.
  final Color? tint;
  final bool blurEnabled;
  final double blurSigma;

  @override
  Widget build(BuildContext context) {
    final BorderRadius radius = BorderRadius.circular(kWindowChromeHeight / 2);
    final Color color = tint ?? AppleSemanticColors.of(context).glass;
    // Blur off: paint the tint on its own. AppleGlass would still run its
    // backdrop filter, and a near-opaque tint would make that work invisible.
    if (!blurEnabled) {
      return RepaintBoundary(
        child: ClipRRect(
          borderRadius: radius,
          child: DecoratedBox(
            decoration: BoxDecoration(color: color, borderRadius: radius),
            child: child,
          ),
        ),
      );
    }
    // Same composition as the phone's navigation capsule: the blur gets its own
    // layer so page repaints never re-run the backdrop filter.
    return RepaintBoundary(
      child: AppleGlass(
        borderRadius: radius,
        color: color,
        blurSigma: blurSigma.clamp(kWindowChromeBlurMin, kWindowChromeBlurMax),
        child: child,
      ),
    );
  }
}
