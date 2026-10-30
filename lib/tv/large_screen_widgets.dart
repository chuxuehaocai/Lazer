// i18n:data — interface strings declared here are translated at their render sites.
/// Shared building blocks of the large-screen (ten-foot) presentation.
///
/// The composition follows Apple Music on a television: a floating capsule of
/// destinations, shelves of large artwork whose captions sit on a dark plate,
/// a library rail beside an artwork grid, and a slim transport under the
/// content. Everything here is sized for a sofa, not a desk — the metrics below
/// are the single place where those sizes are decided.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../l10n/app_localizations.dart';
import '../theme/apple_design.dart';
import '../theme/font_preferences.dart';
import '../tv/tv_mode.dart';
import '../widgets/copyable_song_title.dart';
import '../utils/artwork.dart';
import '../widgets/artwork_image.dart';
import '../widgets/interaction_feedback.dart';
import '../legacy/legacy_widgets.dart';

/// Distances and type sizes of the large-screen interface.
///
/// The shell lays pages out at the workspace size (after DPI scaling), so these
/// values are logical pixels at ten feet: a 40 dp page title, a 26 dp section
/// heading and a 20 dp card title read from three metres the way the 34/20/17
/// desktop ramp reads from an arm's length.
abstract final class LargeScreenMetrics {
  const LargeScreenMetrics._();

  /// Height of the floating destination capsule.
  static const double navBarHeight = 58;

  /// Height of the floating transport strip.
  static const double transportHeight = 88;

  /// Bottom room a page reserves for the floating transport strip, so its last
  /// card can be scrolled clear of the overlay.
  static const double floatingBarInset = 124;

  /// Gap between two captioned cards in a shelf.
  static const double cardGap = 26;

  /// Gap between two shelves on a page.
  static const double shelfGap = 42;

  /// Height of a captioned feature card's dark text plate.
  static const double featurePlateHeight = 132;

  /// Horizontal page margin. Wide panels get a generous inset; a narrow window
  /// that forces the profile still keeps everything inside the frame.
  static double pageInset(double width) => (width * .043).clamp(20.0, 84.0);

  /// Width of the library rail.
  static double railWidth(double width) => (width * .21).clamp(224.0, 340.0);

  /// Width of one feature card: four across on a 1080p panel.
  static double featureCardWidth(double width) {
    final double inset = pageInset(width);
    final double available = width - inset * 2 - cardGap * 3;
    return (available / 4).clamp(232.0, 420.0);
  }

  /// Height of a feature card, artwork plus caption plate.
  static double featureCardHeight(double width) =>
      featureCardWidth(width) * .88 + featurePlateHeight;

  /// Width of a standard artwork card in a shelf or grid.
  static double artworkCardWidth(double width) =>
      (width * .13).clamp(172.0, 238.0);

  /// Height of an artwork card with its two caption lines.
  static double artworkCardHeight(double width) => artworkCardWidth(width) + 96;
}

/// A large-screen control: a remote focus stop and a pointer tap target.
///
/// [TvTapTarget] alone only answers the remote's Select; its child is drawn
/// without a gesture recogniser because the desktop widgets each bring their
/// own. The large-screen cards have no other tap surface, so this wrapper adds
/// the pointer half and keeps both input models on the same callback.
class LargeScreenTapTarget extends StatelessWidget {
  const LargeScreenTapTarget({
    super.key,
    required this.child,
    this.onTap,
    this.onFocusChange,
    this.borderRadius = const BorderRadius.all(Radius.circular(14)),
    this.focusScale = 1.04,
  });

  final Widget child;
  final VoidCallback? onTap;
  final ValueChanged<bool>? onFocusChange;
  final BorderRadius borderRadius;
  final double focusScale;

  @override
  Widget build(BuildContext context) => TvTapTarget(
    onTap: onTap,
    onFocusChange: onFocusChange,
    borderRadius: borderRadius,
    focusScale: focusScale,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: child,
    ),
  );
}

/// The type ramp of the large-screen presentation.
abstract final class LargeScreenType {
  const LargeScreenType._();

  static TextStyle display(BuildContext context) => context.fonts.apply(
    FontCategory.pageTitle,
    _base(context, Theme.of(context).textTheme.displayLarge).copyWith(
      fontSize: 40,
      height: 1.12,
      fontWeight: FontWeight.w700,
      letterSpacing: -.8,
      color: AppleSemanticColors.of(context).label,
    ),
  );

  static TextStyle section(BuildContext context) => context.fonts.apply(
    FontCategory.title,
    _base(context, Theme.of(context).textTheme.titleLarge).copyWith(
      fontSize: 26,
      height: 1.18,
      fontWeight: FontWeight.w700,
      letterSpacing: -.5,
      color: AppleSemanticColors.of(context).label,
    ),
  );

  static TextStyle cardTitle(BuildContext context) => context.fonts.apply(
    FontCategory.title,
    _base(context, Theme.of(context).textTheme.titleMedium).copyWith(
      fontSize: 20,
      height: 1.24,
      fontWeight: FontWeight.w600,
      color: AppleSemanticColors.of(context).label,
    ),
  );

  static TextStyle cardMeta(BuildContext context) => context.fonts.apply(
    FontCategory.caption,
    _base(context, Theme.of(context).textTheme.bodySmall).copyWith(
      fontSize: 15.5,
      height: 1.32,
      color: AppleSemanticColors.of(context).secondaryLabel,
    ),
  );

  static TextStyle rowTitle(BuildContext context) => context.fonts.apply(
    FontCategory.title,
    _base(context, Theme.of(context).textTheme.bodyLarge).copyWith(
      fontSize: 20,
      height: 1.26,
      fontWeight: FontWeight.w500,
      color: AppleSemanticColors.of(context).label,
    ),
  );

  static TextStyle rowMeta(BuildContext context) => context.fonts.apply(
    FontCategory.caption,
    _base(context, Theme.of(context).textTheme.bodySmall).copyWith(
      fontSize: 15.5,
      height: 1.3,
      color: AppleSemanticColors.of(context).secondaryLabel,
    ),
  );

  static TextStyle button(BuildContext context) => context.fonts.apply(
    FontCategory.controls,
    _base(
      context,
      Theme.of(context).textTheme.titleSmall,
    ).copyWith(fontSize: 17, height: 1.2, fontWeight: FontWeight.w600),
  );

  static TextStyle _base(BuildContext context, TextStyle? style) =>
      style ?? Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
}

/// Artwork at large-screen sizes with a quiet fallback.
class LargeScreenArtwork extends StatelessWidget {
  const LargeScreenArtwork({
    super.key,
    this.url,
    required this.size,
    this.height,
    this.radius = 16,
    this.circular = false,
    this.icon = Icons.music_note_rounded,
    this.iconScale = .22,
  });

  final String? url;

  /// Width, and the height too unless [height] is given.
  final double size;

  /// Taller or shorter artwork, e.g. the 8:7 canvas of a feature card.
  final double? height;
  final double radius;
  final bool circular;
  final IconData icon;
  final double iconScale;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final double artHeight = height ?? size;
    final String? resolved = artworkUrlForSize(
      url,
      logicalEdge: math.max(size, artHeight),
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
    );
    final Widget fallback = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[apple.tertiaryFill, apple.secondaryFill],
        ),
      ),
      child: Center(
        child: Icon(
          icon,
          size: math.max(22, math.min(size, artHeight) * iconScale),
          color: apple.tertiaryLabel,
        ),
      ),
    );
    final Widget art = resolved == null || resolved.isEmpty
        ? fallback
        : Image(
            image: ArtworkImage(resolved),
            fit: BoxFit.cover,
            gaplessPlayback: true,
            frameBuilder:
                (
                  BuildContext context,
                  Widget child,
                  int? frame,
                  bool wasSynchronouslyLoaded,
                ) => wasSynchronouslyLoaded || frame != null ? child : fallback,
            errorBuilder:
                (BuildContext context, Object error, StackTrace? stack) =>
                    fallback,
          );
    return ClipRRect(
      borderRadius: circular
          ? BorderRadius.circular(size / 2)
          : BorderRadius.circular(radius),
      child: SizedBox(width: size, height: artHeight, child: art),
    );
  }
}

/// A big artwork card for the "Top Picks" row: square art over a dark plate.
///
/// The caption lives on a plate rather than under the art because a television
/// is watched against moving album colours: white text on a fixed dark plate
/// keeps its contrast whatever the artwork behind it is doing.
class LargeScreenFeatureCard extends StatefulWidget {
  const LargeScreenFeatureCard({
    super.key,
    required this.width,
    required this.title,
    this.subtitle,
    this.imageUrl,
    this.onTap,
    this.icon = Icons.playlist_play_rounded,
  });

  final double width;
  final String title;
  final String? subtitle;
  final String? imageUrl;
  final VoidCallback? onTap;
  final IconData icon;

  @override
  State<LargeScreenFeatureCard> createState() => _LargeScreenFeatureCardState();
}

class _LargeScreenFeatureCardState extends State<LargeScreenFeatureCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final double artHeight = widget.width * .88;
    return SizedBox(
      width: widget.width,
      child: LargeScreenTapTarget(
        onTap: feedbackAction(context, widget.onTap),
        onFocusChange: (bool value) => setState(() => _focused = value),
        borderRadius: BorderRadius.circular(18),
        focusScale: 1.035,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E),
            borderRadius: BorderRadius.circular(18),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: _focused ? .34 : .2),
                blurRadius: _focused ? 26 : 16,
                offset: Offset(0, _focused ? 12 : 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              RepaintBoundary(
                child: LargeScreenArtwork(
                  url: widget.imageUrl,
                  size: widget.width,
                  height: artHeight,
                  radius: 0,
                  icon: widget.icon,
                  iconScale: .2,
                ),
              ),
              Container(
                height: LargeScreenMetrics.featurePlateHeight,
                color: const Color(0xFF1B1B1D),
                padding: const EdgeInsets.fromLTRB(18, 13, 18, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      widget.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 20,
                        height: 1.22,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -.2,
                        color: Colors.white,
                      ),
                    ),
                    if ((widget.subtitle ?? '').isNotEmpty) ...<Widget>[
                      const SizedBox(height: 5),
                      Expanded(
                        child: Text(
                          widget.subtitle!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            height: 1.3,
                            color: Color(0xCCEBEBF5),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A shelf card with the caption beneath the artwork (albums, playlists,
/// tracks and artists all share this shape).
class LargeScreenMediaCard extends StatefulWidget {
  const LargeScreenMediaCard({
    super.key,
    required this.width,
    required this.title,
    this.subtitle,
    this.imageUrl,
    this.onTap,
    this.circular = false,
    this.centerCaption = false,
    this.icon = Icons.music_note_rounded,
  });

  final double width;
  final String title;
  final String? subtitle;
  final String? imageUrl;
  final VoidCallback? onTap;
  final bool circular;
  final bool centerCaption;
  final IconData icon;

  @override
  State<LargeScreenMediaCard> createState() => _LargeScreenMediaCardState();
}

class _LargeScreenMediaCardState extends State<LargeScreenMediaCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final TextAlign align = widget.centerCaption
        ? TextAlign.center
        : TextAlign.start;
    final CrossAxisAlignment cross = widget.centerCaption
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start;
    return SizedBox(
      width: widget.width,
      child: LargeScreenTapTarget(
        onTap: feedbackAction(context, widget.onTap),
        onFocusChange: (bool value) => setState(() => _focused = value),
        borderRadius: BorderRadius.circular(16),
        focusScale: 1.05,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: cross,
          children: <Widget>[
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                boxShadow: <BoxShadow>[
                  if (_focused)
                    BoxShadow(
                      color: Colors.black.withValues(alpha: .3),
                      blurRadius: 22,
                      offset: const Offset(0, 10),
                    ),
                ],
              ),
              child: RepaintBoundary(
                child: LargeScreenArtwork(
                  url: widget.imageUrl,
                  size: widget.width,
                  circular: widget.circular,
                  icon: widget.icon,
                  iconScale: .24,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              widget.title,
              maxLines: 2,
              textAlign: align,
              overflow: TextOverflow.ellipsis,
              style: LargeScreenType.cardTitle(context),
            ),
            if ((widget.subtitle ?? '').isNotEmpty) ...<Widget>[
              const SizedBox(height: 2),
              Text(
                widget.subtitle!,
                maxLines: 1,
                textAlign: align,
                overflow: TextOverflow.ellipsis,
                style: LargeScreenType.cardMeta(context),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A section heading inside a page, with the smaller subtitle beside it.
class LargeScreenSectionHeader extends StatelessWidget {
  const LargeScreenSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.padding = EdgeInsets.zero,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Flexible(
            child: Text(
              context.tr(title),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: LargeScreenType.section(context),
            ),
          ),
          if ((subtitle ?? '').isNotEmpty) ...<Widget>[
            const SizedBox(width: 12),
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                context.tr(subtitle!),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: LargeScreenType.cardMeta(context),
              ),
            ),
          ],
          if (trailing != null) ...<Widget>[const Spacer(), trailing!],
        ],
      ),
    );
  }
}

/// A horizontal shelf. All cards are built, so the remote can always reach the
/// row and Flutter's focus reveal scrolls it; the cache extent keeps the next
/// cards warm for the same reason.
class LargeScreenShelf extends StatelessWidget {
  const LargeScreenShelf({
    super.key,
    required this.title,
    this.subtitle,
    required this.height,
    required this.itemCount,
    required this.itemBuilder,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final double height;
  final int itemCount;
  final NullableIndexedWidgetBuilder itemBuilder;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final double inset = LargeScreenMetrics.pageInset(
      MediaQuery.sizeOf(context).width,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.symmetric(horizontal: inset),
          child: LargeScreenSectionHeader(
            title: title,
            subtitle: subtitle,
            trailing: trailing,
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: height,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: inset),
            itemCount: itemCount,
            scrollCacheExtent: const ScrollCacheExtent.pixels(1400),
            itemBuilder: (BuildContext context, int index) => Padding(
              padding: EdgeInsets.only(
                right: index == itemCount - 1 ? 0 : LargeScreenMetrics.cardGap,
              ),
              child: itemBuilder(context, index),
            ),
          ),
        ),
      ],
    );
  }
}

/// A track line sized for a television: 64 dp tall, 44 dp cover, 19 dp title.
class LargeScreenTrackRow extends StatefulWidget {
  const LargeScreenTrackRow({
    super.key,
    required this.index,
    required this.title,
    required this.artist,
    this.imageUrl,
    this.duration,
    this.current = false,
    this.playing = false,
    this.onTap,
    this.trailing,
    this.leading,
  });

  final int index;
  final String title;
  final String artist;
  final String? imageUrl;
  final Duration? duration;
  final bool current;
  final bool playing;
  final VoidCallback? onTap;
  final Widget? trailing;
  final Widget? leading;

  @override
  State<LargeScreenTrackRow> createState() => _LargeScreenTrackRowState();
}

class _LargeScreenTrackRowState extends State<LargeScreenTrackRow> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return LargeScreenTapTarget(
      onTap: feedbackAction(context, widget.onTap),
      onFocusChange: (bool value) => setState(() => _focused = value),
      borderRadius: BorderRadius.circular(12),
      focusScale: 1.008,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 130),
        width: double.infinity,
        height: 64,
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: widget.current
              ? apple.accentSoft
              : _focused
              ? apple.fill
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 38,
              child: widget.current
                  ? Icon(
                      widget.playing
                          ? Icons.graphic_eq_rounded
                          : Icons.pause_rounded,
                      size: 18,
                      color: apple.accent,
                    )
                  : Text(
                      '${widget.index + 1}',
                      textAlign: TextAlign.center,
                      style: LargeScreenType.rowMeta(context).copyWith(
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                        color: _focused
                            ? apple.secondaryLabel
                            : apple.tertiaryLabel,
                      ),
                    ),
            ),
            ?widget.leading,
            LargeScreenArtwork(
              url: widget.imageUrl,
              size: 44,
              radius: 9,
              iconScale: .34,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  CopyableSongTitle(
                    title: widget.title,
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: LargeScreenType.rowTitle(context).copyWith(
                        color: widget.current ? apple.accent : apple.label,
                        fontWeight: widget.current || _focused
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    widget.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: LargeScreenType.rowMeta(context),
                  ),
                ],
              ),
            ),
            if (widget.trailing != null) ...<Widget>[
              const SizedBox(width: 12),
              widget.trailing!,
            ],
            if (widget.duration != null)
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Text(
                  legacyDuration(widget.duration!),
                  style: LargeScreenType.rowMeta(context).copyWith(
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The primary action of a hero: a white pill with a glyph.
class LargeScreenPrimaryButton extends StatelessWidget {
  const LargeScreenPrimaryButton({
    super.key,
    required this.label,
    required this.icon,
    this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return LargeScreenTapTarget(
      onTap: feedbackAction(context, onTap),
      borderRadius: BorderRadius.circular(24),
      focusScale: 1.04,
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 21, color: Colors.black),
            const SizedBox(width: 8),
            Text(
              context.tr(label),
              style: LargeScreenType.button(
                context,
              ).copyWith(color: Colors.black),
            ),
          ],
        ),
      ),
    );
  }
}

/// The secondary action of a hero: a translucent pill.
class LargeScreenSecondaryButton extends StatelessWidget {
  const LargeScreenSecondaryButton({
    super.key,
    required this.label,
    required this.icon,
    this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return LargeScreenTapTarget(
      onTap: feedbackAction(context, onTap),
      borderRadius: BorderRadius.circular(24),
      focusScale: 1.04,
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        decoration: BoxDecoration(
          color: apple.fill,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: apple.separator, width: .5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 20, color: apple.label),
            const SizedBox(width: 8),
            Text(
              context.tr(label),
              style: LargeScreenType.button(
                context,
              ).copyWith(color: apple.label),
            ),
          ],
        ),
      ),
    );
  }
}

/// A capsule choice used for the search tabs and other small filters.
class LargeScreenChoiceChip extends StatelessWidget {
  const LargeScreenChoiceChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return LargeScreenTapTarget(
      onTap: feedbackAction(context, onTap),
      borderRadius: BorderRadius.circular(21),
      focusScale: 1.05,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        decoration: BoxDecoration(
          color: selected ? apple.label : apple.fill,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Center(
          child: Text(
            context.tr(label),
            style: LargeScreenType.button(context).copyWith(
              fontSize: 17.5,
              color: selected ? apple.background : apple.label,
            ),
          ),
        ),
      ),
    );
  }
}

/// Loading, empty and error states inside the large-screen composition.
class LargeScreenNotice extends StatelessWidget {
  const LargeScreenNotice({
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
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 64),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 86,
              height: 86,
              decoration: BoxDecoration(
                color: apple.fill,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 38, color: apple.secondaryLabel),
            ),
            const SizedBox(height: 20),
            Text(
              context.tr(message),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontSize: 19,
                height: 1.35,
                color: apple.secondaryLabel,
              ),
            ),
            if (action != null) ...<Widget>[
              const SizedBox(height: 22),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// A page header in the ten-foot ramp: one big title and one quiet line.
class LargeScreenPageTitle extends StatelessWidget {
  const LargeScreenPageTitle({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
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
                  style: LargeScreenType.display(context),
                ),
              ),
              if ((subtitle ?? '').isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  context.tr(subtitle!),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: LargeScreenType.cardMeta(
                    context,
                  ).copyWith(fontSize: 17),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...<Widget>[const SizedBox(width: 18), trailing!],
      ],
    );
  }
}
