import 'build_safe_state.dart';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../state/ui_preferences.dart';
import '../theme/apple_design.dart';
import '../theme/lazer_theme.dart';
import '../theme/adaptive_contrast.dart';
import '../theme/font_preferences.dart';
import '../tv/tv_mode.dart';
import 'interaction_feedback.dart';
import 'window_chrome.dart';
import '../theme/shape_scale.dart';

/// A translucent Apple material: blur plus a semantic glass tint and hairline.
///
/// Used for navigation chrome and transient panels only. Content surfaces stay
/// opaque so text contrast never depends on the artwork behind the window.
class AppleGlass extends StatelessWidget {
  const AppleGlass({
    super.key,
    required this.child,
    this.color,
    this.borderRadius = BorderRadius.zero,
    this.blurSigma,
    this.border,
  });

  final Widget child;
  final Color? color;
  final BorderRadius borderRadius;
  final double? blurSigma;
  final Border? border;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final LazerThemeTokens themeTokens = LazerThemeTokens.of(context);
    final Color tint = color ?? apple.glass;
    final Widget decorated = DecoratedBox(
      decoration: BoxDecoration(
        color: tint,
        borderRadius: borderRadius,
        border: border,
      ),
      child: child,
    );
    // A 95%-opaque tint hides almost all of the blurred backdrop, but the
    // full-screen Gaussian still runs every time the flowing background
    // repaints. Skip the layer when it cannot be seen — and skip it entirely
    // when the skin turns glass off (`glassBlurSigma == 0`), which is what a
    // paper design wants: no blur cost at all.
    final double sigma = blurSigma ?? themeTokens.glassBlurSigma;
    if (tint.a >= .9 || sigma <= 0) {
      return ClipRRect(borderRadius: borderRadius, child: decorated);
    }
    final Widget material = BackdropFilter(
      filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      child: decorated,
    );
    // The clip is not decoration: a BackdropFilter applies to the whole
    // screen when nothing clips it, so dropping it for a square panel blurs
    // every widget painted before the panel. A zero radius still clips as a
    // plain rect, so square panels cost no rounded-corner geometry.
    return ClipRRect(borderRadius: borderRadius, child: material);
  }
}

/// Apple large-title page header. It is deliberately independent of
/// [AppBar]: pages scroll under the chrome while their title scrolls away,
/// following the iOS large-title pattern.
class ApplePageTitle extends StatelessWidget {
  const ApplePageTitle({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(24, 20, 24, 8),
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final LazerThemeTokens ui = LazerThemeTokens.of(context);
    final bool compact = MediaQuery.sizeOf(context).width < kTabletBreakpoint;
    final TextStyle style = context.fonts.apply(
      FontCategory.pageTitle,
      (theme.textTheme.displayLarge ?? const TextStyle()).copyWith(
        fontSize: compact ? ui.pageTitleCompactSize : ui.pageTitleRegularSize,
        height:
            (compact ? 41 : 38) /
            (compact ? ui.pageTitleCompactSize : ui.pageTitleRegularSize),
        // 字重可以单独给：parchment 那一版的大标题是半粗，不是 display 的 400。
        fontWeight: ui.pageTitleWeight > 0
            ? FontWeight.values[(ui.pageTitleWeight / 100).round().clamp(1, 9) - 1]
            : ui.displayFontWeight,
        letterSpacing: .37,
        color: apple.label,
      ),
    );
    return WindowDragArea(
      child: Padding(
        padding: padding,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Semantics(
                    header: true,
                    child: Text(
                      context.tr(title),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: style,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...<Widget>[
                    // 标题与副标题之间的空隙也归主题：负值表示没指定，用 5 px。
                    SizedBox(
                      height: ui.pageTitleSubtitleGap >= 0
                          ? ui.pageTitleSubtitleGap
                          : 5,
                    ),
                    Text(
                      context.tr(subtitle!),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: apple.secondaryLabel,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...<Widget>[
              const SizedBox(width: 16),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Section heading used by every browse/library/search page.
class AppleSectionHeader extends StatelessWidget {
  const AppleSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(24, 24, 24, 12),
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final LazerThemeTokens ui = LazerThemeTokens.of(context);
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Flexible(
                  child: Text(
                    context.tr(title),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.fonts.apply(
                      FontCategory.controls,
                      (theme.textTheme.titleLarge ?? const TextStyle())
                          .copyWith(
                            color: apple.label,
                            fontWeight: ui.titleFontWeight,
                            fontSize: ui.sectionHeaderSize,
                            letterSpacing: -.4,
                          ),
                    ),
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...<Widget>[
                  const SizedBox(width: 10),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 1),
                    child: Text(
                      context.tr(subtitle!),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: apple.secondaryLabel,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// An inset grouped card, the core of iOS Settings and Music's library lists.
class AppleGroupedCard extends StatelessWidget {
  const AppleGroupedCard({
    super.key,
    required this.child,
    this.margin = const EdgeInsets.symmetric(horizontal: 24),
    this.padding = EdgeInsets.zero,
    this.color,
    this.radius,
  });

  final Widget child;
  final EdgeInsetsGeometry margin;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final LazerThemeTokens ui = LazerThemeTokens.of(context);
    return Container(
      margin: margin,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: color ?? apple.secondaryGroupedBackground,
        borderRadius: BorderRadius.circular(radius ?? AppleShape.cardRadiusOf(context, ui)),
        border: Border.all(color: apple.separator, width: .5),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

/// A single list row with Apple's vertical rhythm and press highlight.
class AppleListTile extends StatefulWidget {
  const AppleListTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.showChevron = false,
    this.padding,
    this.minHeight,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool showChevron;
  final EdgeInsetsGeometry? padding;
  final double? minHeight;

  @override
  State<AppleListTile> createState() => _AppleListTileState();
}

class _AppleListTileState extends State<AppleListTile>
    with BuildSafeState<AppleListTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final LazerThemeTokens ui = LazerThemeTokens.of(context);
    final Widget row = ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: widget.minHeight ?? ui.listTileMinHeight,
      ),
      child: Padding(
        padding:
            widget.padding ??
            EdgeInsets.symmetric(
              horizontal: 16,
              vertical: ui.listTileVerticalPadding,
            ),
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
            children: <Widget>[
              if (widget.leading != null) ...<Widget>[
                widget.leading!,
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.fonts.apply(
                        FontCategory.title,
                        (theme.textTheme.bodyLarge ?? const TextStyle())
                            .copyWith(
                              color: apple.label,
                              fontWeight: ui.bodyFontWeight,
                            ),
                      ),
                    ),
                    if (widget.subtitle != null &&
                        widget.subtitle!.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 1),
                      Text(
                        widget.subtitle!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.fonts.apply(
                          FontCategory.caption,
                          (theme.textTheme.bodySmall ?? const TextStyle())
                              .copyWith(
                                color: apple.secondaryLabel,
                                fontWeight: ui.bodyFontWeight,
                              ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (widget.trailing != null) ...<Widget>[
                const SizedBox(width: 12),
                // Long version labels and actions can wrap without consuming
                // the title's entire width in a narrow settings panel.
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: constraints.maxWidth * .6,
                  ),
                  child: widget.trailing!,
                ),
              ],
              if (widget.showChevron) ...<Widget>[
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: apple.tertiaryLabel,
                ),
              ],
            ],
          ),
        ),
      ),
    );
    if (widget.onTap == null && widget.onLongPress == null) return row;
    return Material(
      color: Colors.transparent,
      child: SpringPress(
        pressedScale: .99,
        builder: (context, states) => InkWell(
          statesController: states,
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          onFocusChange: (bool value) => setState(() => _focused = value),
          highlightColor: apple.fill,
          splashFactory: NoSplash.splashFactory,
          child: Stack(
            children: <Widget>[
              row,
              if (_focused && TvScope.isActive(context))
                Positioned.fill(
                  child: IgnorePointer(
                    child: TvFocusOutline(
                      borderRadius: BorderRadius.circular(10 * AppleShape.scaleOf(context)),
                      width: 2,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Rounded leading glyph used in library rows and settings account cards.
class AppleIconTile extends StatelessWidget {
  const AppleIconTile({
    super.key,
    required this.icon,
    this.color = AppleColors.musicRed,
    this.size = 30,
    this.iconSize = 17,
    this.radius = 7,
  });

  final IconData icon;
  final Color color;
  final double size;
  final double iconSize;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final apple = AppleSemanticColors.of(context);
    final tileColor = adaptiveAccent(
      color,
      apple.secondaryGroupedBackground,
      minimum: 3,
    );
    final iconColor = contrastingLabel(tileColor);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Color.lerp(tileColor, iconColor, .15)!, tileColor],
        ),
        borderRadius: BorderRadius.circular(radius * AppleShape.scaleOf(context)),
      ),
      child: Icon(icon, size: iconSize, color: iconColor),
    );
  }
}

class AppleEmptyState extends StatelessWidget {
  const AppleEmptyState({
    super.key,
    required this.message,
    this.icon = Icons.music_note_rounded,
    this.action,
  });

  final String message;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: apple.fill,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 28, color: apple.secondaryLabel),
            ),
            const SizedBox(height: 16),
            Text(
              context.tr(message),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: apple.secondaryLabel,
              ),
            ),
            if (action != null) ...<Widget>[
              const SizedBox(height: 18),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// The shell's search input: Material 3's stock [SearchBar], nothing else.
///
/// No custom fill, border or icon tint — the bar takes its shape, color,
/// elevation, focus overlay and text field straight from the Material theme,
/// so it matches any `searchBarTheme` the app installs. The toolbar and the
/// mobile search row only decide how wide and tall it is.
class AppleSearchField extends StatefulWidget {
  const AppleSearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    this.onSubmitted,
    this.hintText,
    this.onClear,
    this.autofocus = false,
    this.height = 56,
    this.textInputAction = TextInputAction.search,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  /// Runs only when the user submits the field (Enter / IME search action).
  final ValueChanged<String>? onSubmitted;
  final String? hintText;
  final VoidCallback? onClear;
  final bool autofocus;

  /// How tall the bar draws. 56 is Material's own search bar height.
  final double height;
  final TextInputAction textInputAction;

  @override
  State<AppleSearchField> createState() => _AppleSearchFieldState();
}

class _AppleSearchFieldState extends State<AppleSearchField> {
  late final FocusNode _focusNode = FocusNode(
    debugLabel: 'search-input',
    onKeyEvent: _onKeyEvent,
  );

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (!TvScope.isActive(context) || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final bool keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.gameButtonA ||
        (!keyboardVisible &&
            (key == LogicalKeyboardKey.enter ||
                key == LogicalKeyboardKey.numpadEnter))) {
      // Directional focus does not open the Android TV IME. Request it even
      // when the input already has focus (including after dismissing it).
      node.context
          ?.findAncestorStateOfType<EditableTextState>()
          ?.requestKeyboard();
      return KeyEventResult.handled;
    }
    if (!keyboardVisible &&
        (key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowDown)) {
      node.focusInDirection(
        key == LogicalKeyboardKey.arrowUp
            ? TraversalDirection.up
            : TraversalDirection.down,
      );
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _clear() {
    widget.controller.clear();
    if (widget.onClear case final clear?) {
      clear();
    } else {
      widget.onChanged('');
    }
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final height = (MediaQuery.textScalerOf(context).scale(16) * 1.4 + 20)
        .clamp(widget.height, double.infinity);
    return TvFocusHighlight(
      child: SizedBox(
        height: height,
        child: SearchBar(
          focusNode: _focusNode,
          controller: widget.controller,
          onChanged: widget.onChanged,
          onSubmitted: widget.onSubmitted,
          hintText: context.tr(widget.hintText ?? '搜索歌曲、歌手或歌单'),
          autoFocus: widget.autofocus,
          // A search field, not a button: no elevation, no shadow and no hover
          // wash. Users who want it will click it.
          elevation: const WidgetStatePropertyAll<double>(0),
          shadowColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
          surfaceTintColor: const WidgetStatePropertyAll<Color>(
            Colors.transparent,
          ),
          overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
          textInputAction: widget.textInputAction,
          leading: const Icon(Icons.search),
          // A rounded rectangle rather than Material's default stadium: the bar
          // spans the page width, so a pill would read as a button.
          shape: const WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(12)),
            ),
          ),
          trailing: <Widget>[
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: widget.controller,
              builder: (BuildContext context, TextEditingValue value, _) =>
                  value.text.isEmpty
                  ? const SizedBox.shrink()
                  : IconButton(
                      tooltip: context.tr('清除'),
                      onPressed: _clear,
                      icon: const Icon(Icons.close),
                    ),
            ),
          ],
          // Stock Material reserves 360 px of width; here the toolbar and the
          // mobile row own the width, and the bar fills whatever they give it.
          constraints: BoxConstraints(
            minWidth: 0,
            maxWidth: double.infinity,
            minHeight: height,
            maxHeight: height,
          ),
        ),
      ),
    );
  }
}
