import '../widgets/build_safe_state.dart';
import 'package:lazer_nextgen/theme/app_palette.dart';
import '../l10n/app_localizations.dart';
import '../tv/tv_mode.dart';
import 'package:flutter/material.dart';
import '../widgets/interaction_feedback.dart';
import '../animation/apple_spring.dart';

import 'design_tokens.dart';

// ---------------------------------------------------------------------------
// Buttons — flat, no shadows. Filled variants wear the signature bottom-only
// 8px radius; outlined controls use 12px; text links have no container at all.
// ---------------------------------------------------------------------------

/// Common button chrome: press/hover feedback via tone only, no elevation.
abstract final class _ButtonSpec {
  static const EdgeInsets filledPadding = EdgeInsets.symmetric(
    horizontal: 31,
    vertical: 12,
  );
  static const EdgeInsets compactPadding = EdgeInsets.symmetric(
    horizontal: 16,
    vertical: 8,
  );
}

/// Clay Filled Button — the single chromatic CTA. Reserved for the most
/// consequential action on screen ("Sign in", "Accept"). Deepens to
/// Clay Deep on hover/press.
class ClayButton extends StatefulWidget {
  const ClayButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.expand = false,
    this.compact = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool expand;
  final bool compact;

  @override
  State<ClayButton> createState() => _ClayButtonState();
}

class _ClayButtonState extends State<ClayButton> {
  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.onPressed != null;
    return SizedBox(
      width: widget.expand ? double.infinity : null,
      child: SpringPress(
        builder: (context, states) => TextButton(
          statesController: states,
          onPressed: feedbackAction(context, widget.onPressed),
          style: ButtonStyle(
            minimumSize: const WidgetStatePropertyAll(Size(0, 48)),
            padding: WidgetStatePropertyAll(
              widget.compact
                  ? _ButtonSpec.compactPadding
                  : _ButtonSpec.filledPadding,
            ),
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (!enabled) return context.colors.stone;
              if (states.contains(WidgetState.pressed) ||
                  states.contains(WidgetState.hovered)) {
                return context.colors.clayDeep;
              }
              return context.colors.clay;
            }),
            foregroundColor: WidgetStatePropertyAll(
              enabled ? Colors.white : context.colors.cloudDark,
            ),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          ),
          child: TrText(
            widget.label,
            textAlign: TextAlign.center,
            style: context.type.bodySm.copyWith(
              color: enabled ? Colors.white : context.colors.cloudDark,
              fontWeight: FontWeight.w500,
              letterSpacing: 0,
            ),
          ),
        ),
      ),
    );
  }
}

/// Filled Ivory Button — primary action on light surfaces. Background
/// #faf9f5, bottom-only 8px radius, no border, no shadow.
class IvoryButton extends StatefulWidget {
  const IvoryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.expand = false,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool expand;
  final IconData? icon;

  @override
  State<IvoryButton> createState() => _IvoryButtonState();
}

class _IvoryButtonState extends State<IvoryButton>
    with BuildSafeState<IvoryButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.onPressed != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: TvTapTarget(
        onTap: feedbackAction(context, widget.onPressed),
        enabled: enabled,
        borderRadius: BorderRadius.circular(10),
        child: SpringPress(
          builder: (context, states) => Material(
            color: Colors.transparent,
            child: InkWell(
              statesController: states,
              canRequestFocus: !TvScope.isActive(context),
              borderRadius: BorderRadius.circular(10),
              onTap: feedbackAction(context, widget.onPressed),
              child: AnimatedContainer(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : AppleSpring.responsive.duration,
                curve: const AppleSpringCurve(),
                padding: _ButtonSpec.filledPadding,
                width: widget.expand ? double.infinity : null,
                decoration: BoxDecoration(
                  color: !enabled
                      ? context.colors.ivoryMedium
                      : _hovering
                      ? context.colors.manilla
                      : context.colors.ivoryLight,
                  borderRadius: AppRadius.filledButton,
                ),
                alignment: Alignment.center,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.icon != null) ...[
                      Icon(
                        widget.icon,
                        size: 16,
                        color: enabled
                            ? context.colors.slateDark
                            : context.colors.cloudMedium,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                    ],
                    TrText(
                      widget.label,
                      style: context.type.bodySm.copyWith(
                        fontWeight: FontWeight.w600,
                        color: enabled
                            ? context.colors.slateDark
                            : context.colors.cloudMedium,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Outlined Dark Button — secondary action, compact ghost treatment with a
/// 1px Cloud Dark border and 12px radius. Works on both light and dark
/// surfaces via [invert].
class OutlinedButton2 extends StatefulWidget {
  const OutlinedButton2({
    super.key,
    required this.label,
    this.onPressed,
    this.invert = false,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool invert;
  final IconData? icon;

  @override
  State<OutlinedButton2> createState() => _OutlinedButton2State();
}

class _OutlinedButton2State extends State<OutlinedButton2>
    with BuildSafeState<OutlinedButton2> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.onPressed != null;
    final Color fg = widget.invert
        ? context.colors.onDark
        : (enabled ? context.colors.slateDark : context.colors.cloudMedium);

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: TvTapTarget(
        onTap: feedbackAction(context, widget.onPressed),
        enabled: enabled,
        borderRadius: BorderRadius.circular(12),
        child: SpringPress(
          builder: (context, states) => Material(
            color: Colors.transparent,
            child: InkWell(
              statesController: states,
              canRequestFocus: !TvScope.isActive(context),
              borderRadius: BorderRadius.circular(12),
              onTap: feedbackAction(context, widget.onPressed),
              child: AnimatedContainer(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : AppleSpring.responsive.duration,
                curve: const AppleSpringCurve(),
                padding: _ButtonSpec.compactPadding,
                decoration: BoxDecoration(
                  color: _hovering && enabled
                      ? (widget.invert
                            ? context.colors.slateMedium
                            : context.colors.oatWarm.withValues(alpha: 0.45))
                      : Colors.transparent,
                  border: Border.all(
                    color: enabled
                        ? context.colors.cloudDark
                        : context.colors.stone,
                    width: 1,
                  ),
                  borderRadius: AppRadius.outlinedBorder,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.icon != null) ...[
                      Icon(widget.icon, size: 14, color: fg),
                      const SizedBox(width: 6),
                    ],
                    TrText(
                      widget.label,
                      style: context.type.caption.copyWith(
                        color: fg,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Text Link Button — text that happens to be clickable, not a container.
/// Transparent background, underline appears on hover.
class TextLinkButton extends StatefulWidget {
  const TextLinkButton({
    super.key,
    required this.label,
    this.onPressed,
    this.underlined = false,
    this.invert = false,
  });

  final String label;
  final VoidCallback? onPressed;

  /// Persistent underline — editorial print convention for inline links.
  final bool underlined;
  final bool invert;

  @override
  State<TextLinkButton> createState() => _TextLinkButtonState();
}

class _TextLinkButtonState extends State<TextLinkButton>
    with BuildSafeState<TextLinkButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.onPressed != null;
    final Color fg = widget.invert
        ? context.colors.onDark
        : (enabled ? context.colors.slateDark : context.colors.cloudMedium);
    final bool showUnderline = widget.underlined || _hovering;

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: TvTapTarget(
        onTap: feedbackAction(context, widget.onPressed),
        enabled: enabled,
        borderRadius: BorderRadius.circular(6),
        child: SpringPress(
          builder: (context, states) => Material(
            color: Colors.transparent,
            child: InkWell(
              statesController: states,
              canRequestFocus: !TvScope.isActive(context),
              borderRadius: BorderRadius.circular(6),
              onTap: feedbackAction(context, widget.onPressed),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: TrText(
                  widget.label,
                  style: context.type.bodySm.copyWith(
                    color: fg,
                    decoration: showUnderline
                        ? TextDecoration.underline
                        : TextDecoration.none,
                    decorationColor: fg,
                    decorationThickness: 1,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Surfaces — cards lift through tone, never shadow.
// ---------------------------------------------------------------------------

/// Standard card: Ivory Light surface, 24px radius, optional 1px Stone
/// hairline border.
class PaperCard extends StatelessWidget {
  const PaperCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.bordered = true,
    this.background,
    this.onTap,
    this.radius = AppRadius.card,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool bordered;
  final Color? background;
  final VoidCallback? onTap;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final BorderRadius br = BorderRadius.all(Radius.circular(radius));
    Widget box = AnimatedContainer(
      clipBehavior: Clip.antiAlias,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : AppleSpring.responsive.duration,
      curve: const AppleSpringCurve(),
      padding: padding,
      decoration: BoxDecoration(
        color: background ?? context.colors.ivoryLight,
        borderRadius: br,
        border: bordered
            ? Border.all(color: context.colors.stone, width: 1)
            : null,
      ),
      child: child,
    );
    if (onTap != null) {
      box = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: TvTapTarget(
          onTap: feedbackAction(context, onTap),
          borderRadius: br,
          child: _PaperCardPress(
            onTap: feedbackAction(context, onTap),
            borderRadius: br,
            child: box,
          ),
        ),
      );
    }
    return box;
  }
}

class _PaperCardPress extends StatelessWidget {
  const _PaperCardPress({
    required this.onTap,
    required this.borderRadius,
    required this.child,
  });

  final VoidCallback? onTap;
  final BorderRadius borderRadius;
  final Widget child;

  @override
  Widget build(BuildContext context) => SpringPress(
    pressedScale: .985,
    builder: (context, states) => Material(
      color: Colors.transparent,
      child: InkWell(
        statesController: states,
        canRequestFocus: !TvScope.isActive(context),
        borderRadius: borderRadius,
        onTap: onTap,
        child: child,
      ),
    ),
  );
}

/// Hairline divider — visible but never assertive.
class Hairline extends StatelessWidget {
  const Hairline({super.key, this.vertical = false, this.length, this.color});

  final bool vertical;
  final double? length;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final Color c = color ?? context.colors.stone;
    if (vertical) {
      return Container(width: 1, height: length, color: c);
    }
    return Container(height: 1, width: length, color: c);
  }
}

/// Badge / inline label — not a container, just weighted text in flow.
/// Used sparingly for categories and metadata.
class InlineLabel extends StatelessWidget {
  const InlineLabel(this.text, {super.key, this.color, this.strong = false});

  final String text;
  final Color? color;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return TrText(
      text.toUpperCase(),
      style: context.type.caption.copyWith(
        color: color ?? context.colors.cloudDark,
        fontWeight: strong ? FontWeight.w600 : FontWeight.w500,
        letterSpacing: 1.6,
      ),
    );
  }
}

/// Section heading pattern used across the app: an uppercase sans caption
/// label with a hairline rule filling the remaining width.
class SectionHeading extends StatelessWidget {
  const SectionHeading(this.label, {super.key, this.trailing});

  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        InlineLabel(label, strong: true, color: context.colors.slateDark),
        const SizedBox(width: AppSpacing.md),
        const Expanded(child: Hairline()),
        if (trailing != null) ...[
          const SizedBox(width: AppSpacing.md),
          trailing!,
        ],
      ],
    );
  }
}
