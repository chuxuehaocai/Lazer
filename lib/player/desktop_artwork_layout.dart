import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../animation/apple_spring.dart';

/// The desktop listening canvas: the artwork column on the left and the reading
/// pane (lyrics, comments or queue) on the right.
///
/// Folding the reading pane is not a swap between two layouts. The artwork
/// element itself travels to the middle of the canvas on an Apple spring and
/// grows into the room the pane gives up, so a tap that reverses mid-flight
/// retargets the presented position and keeps its velocity instead of starting
/// over from an endpoint.
class DesktopArtworkLayout extends StatefulWidget {
  const DesktopArtworkLayout({
    super.key,
    required this.paneVisible,
    required this.artwork,
    required this.pane,
    this.paneTopInset = 0,
    this.leftFraction = 0,
    this.leftMin = 0,
    this.leftMax = 0,
    this.columnGap = 0,
    this.dividerGap = 0,
    this.divider,
  });

  /// skin: nowPlayingArtworkFraction / Min / Max。
  /// > 0 时左栏按 `clamp(width * fraction, min, max)` 排版（parchment 的
  /// `clamp(0.34W,240,440)`），0 时沿用内置的等比两栏。
  final double leftFraction;
  final double leftMin;
  final double leftMax;

  /// skin: 左栏与右栏之间的间距（parchment = 32）。
  final double columnGap;

  /// 竖发丝线与右栏之间的间距（parchment = 16）。
  final double dividerGap;

  /// 可选的竖分隔线，占 1px。
  final Widget? divider;

  /// The widest the two-column spread ever gets.
  static const double artworkMaxWidth = 520;

  /// A folded canvas hands the cover the freed width, but past this size the
  /// artwork reads as a poster and only stretches the metadata under it.
  static const double foldedMaxWidth = 720;

  /// Whether the reading pane takes part in the layout. Without it the artwork
  /// owns the canvas and settles in its middle.
  final bool paneVisible;

  /// Artwork and its metadata, laid out at the rect the fold reaches frame by
  /// frame.
  final Widget artwork;

  /// The right-hand reading surface. It keeps its own layout while it fades, so
  /// neither the lyric rows nor their selection boxes reflow on every spring
  /// tick.
  final Widget pane;

  /// Room the reading pane leaves for a floating header. It never shifts the
  /// artwork, which stays centred in the whole canvas.
  final double paneTopInset;

  @override
  State<DesktopArtworkLayout> createState() => _DesktopArtworkLayoutState();
}

class _DesktopArtworkLayoutState extends State<DesktopArtworkLayout>
    with SingleTickerProviderStateMixin {
  /// The compact player's cover spring, at the same response and bounce: the
  /// pane leaves quickly enough to read as one movement, and coming back
  /// settles without wobbling the lyrics the user is about to read.
  static const _foldSpring = AppleSpring(
    duration: Duration(milliseconds: 650),
    bounce: .18,
  );

  // Unbounded so the spring may overshoot; 0 is the two-column spread and 1 is
  // the folded canvas. Every frame reads this controller, which is what makes
  // an interrupted fold continue from where the eye last saw it.
  late final AnimationController _fold = AnimationController.unbounded(
    vsync: this,
    value: widget.paneVisible ? 0 : 1,
  );
  late final Animation<double> _paneOpacity = _fold.drive(const _FoldFade());

  void _snap() => _fold.value = widget.paneVisible ? 0 : 1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) _snap();
  }

  @override
  void didUpdateWidget(covariant DesktopArtworkLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.paneVisible == oldWidget.paneVisible) return;
    _fold.springTo(
      widget.paneVisible ? 0 : 1,
      spring: _foldSpring,
      reduceMotion: MediaQuery.disableAnimationsOf(context),
    );
  }

  @override
  void dispose() {
    _fold.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool folded = !widget.paneVisible;
    // The pane is being removed from the presentation: retire its focus, its
    // semantics, its hit area and its tickers on the frame the fold starts, so
    // a fading reading surface never keeps answering input.
    return CustomMultiChildLayout(
      key: const ValueKey('desktop-artwork-layout'),
      delegate: _DesktopArtworkDelegate(
        _fold,
        paneTopInset: widget.paneTopInset,
        leftFraction: widget.leftFraction,
        leftMin: widget.leftMin,
        leftMax: widget.leftMax,
        columnGap: widget.columnGap,
        dividerGap: widget.dividerGap,
        hasDivider: widget.divider != null,
      ),
      children: [
        LayoutId(
          id: _DesktopArtworkDelegate.pane,
          child: ExcludeFocus(
            excluding: folded,
            child: ExcludeSemantics(
              excluding: folded,
              child: IgnorePointer(
                ignoring: folded,
                child: TickerMode(
                  enabled: !folded,
                  child: FadeTransition(
                    key: const ValueKey('desktop-pane-fade'),
                    opacity: _paneOpacity,
                    child: widget.pane,
                  ),
                ),
              ),
            ),
          ),
        ),
        LayoutId(
          id: _DesktopArtworkDelegate.artwork,
          child: RepaintBoundary(child: widget.artwork),
        ),
        if (widget.divider != null)
          LayoutId(
            id: _DesktopArtworkDelegate.divider,
            // 竖发丝线是「两栏」的一部分：歌词一收起就跟着淡出，而不是留在
            // 空画布上变成一条没有意义的线。淡出和歌词用同一条曲线，所以两者
            // 是同一个动作。
            child: ExcludeSemantics(
              child: FadeTransition(
                key: const ValueKey('desktop-divider-fade'),
                opacity: _paneOpacity,
                child: widget.divider!,
              ),
            ),
          ),
      ],
    );
  }
}

/// The reading pane is gone before the cover has finished growing: text that is
/// already leaving must not keep competing with the artwork for attention.
class _FoldFade extends Animatable<double> {
  const _FoldFade();

  @override
  double transform(double t) => (1 - t * 2.2).clamp(0.0, 1.0);
}

class _DesktopArtworkDelegate extends MultiChildLayoutDelegate {
  _DesktopArtworkDelegate(
    this.fold, {
    required this.paneTopInset,
    this.leftFraction = 0,
    this.leftMin = 0,
    this.leftMax = 0,
    this.columnGap = 0,
    this.dividerGap = 0,
    this.hasDivider = false,
  }) : super(relayout: fold);

  static const int artwork = 1;
  static const int pane = 2;
  static const int divider = 3;

  /// Presented fold progress, including the spring's overshoot.
  final Animation<double> fold;
  final double paneTopInset;

  /// skin: 见 [DesktopArtworkLayout.leftFraction] 等字段。
  final double leftFraction;
  final double leftMin;
  final double leftMax;
  final double columnGap;
  final double dividerGap;
  final bool hasDivider;

  @override
  void performLayout(Size size) {
    // The spring is allowed to cross its endpoint: the artwork arrives in the
    // middle of the canvas with a little bounce instead of stopping dead.
    final double t = fold.value;
    final double w = size.width, h = size.height;
    final bool skinned = leftFraction > 0;
    final double gap = skinned ? columnGap : (w * .075).clamp(24.0, 110.0);
    // A skin pins the artwork column to the reference geometry
    // `clamp(width * fraction, min, max)`; otherwise the built-in even spread.
    final double column = skinned
        ? (w * leftFraction).clamp(
            leftMin > 0 ? leftMin : 0,
            leftMax > 0 ? leftMax : w,
          )
        : math.min(
            DesktopArtworkLayout.artworkMaxWidth,
            math.max(0, (w - gap) / 2),
          );
    final double spread = skinned ? column : column * 2 + gap;
    final double spreadLeft = skinned ? 0 : (w - spread) / 2;
    final Rect columnRect = Rect.fromLTWH(spreadLeft, 0, column, h);
    // A folded canvas hands the artwork the width it can actually use: the
    // freed column, capped by the canvas height (a square can never be taller
    // than the canvas) and by the poster limit above.
    final double foldedWidth = math.min(
      w,
      math.max(column, math.min(DesktopArtworkLayout.foldedMaxWidth, h)),
    );
    final Rect foldedRect = Rect.fromLTWH(
      (w - foldedWidth) / 2,
      0,
      foldedWidth,
      h,
    );
    final Rect lerped = Rect.lerp(columnRect, foldedRect, t)!;
    // Keep the bounce inside the canvas: a window too narrow for the folded
    // width would otherwise paint the artwork over the page's side padding.
    final Rect art = Rect.fromLTRB(
      math.max(0, lerped.left),
      lerped.top,
      math.min(w, lerped.right),
      math.min(h, lerped.bottom),
    );
    layoutChild(artwork, BoxConstraints.tight(art.size));
    positionChild(artwork, art.topLeft);

    // The pane keeps its resting size while it fades: relayouting the lyric
    // canvas on every tick would repaint the whole reading surface to no end.
    final double dividerSpan = hasDivider ? 1 + dividerGap : 0;
    final double paneLeft = spreadLeft + column + gap + dividerSpan;
    final Rect paneRect = Rect.fromLTWH(
      paneLeft,
      paneTopInset,
      skinned ? math.max(0, w - paneLeft) : column,
      math.max(0, h - paneTopInset),
    );
    layoutChild(pane, BoxConstraints.tight(paneRect.size));
    positionChild(pane, paneRect.topLeft);
    if (hasDivider) {
      final double dx = spreadLeft + column + gap;
      layoutChild(
        divider,
        BoxConstraints.tight(Size(1, math.max(0, h - paneTopInset))),
      );
      positionChild(divider, Offset(dx, paneTopInset));
    }
  }

  @override
  bool shouldRelayout(covariant _DesktopArtworkDelegate oldDelegate) =>
      fold != oldDelegate.fold ||
      paneTopInset != oldDelegate.paneTopInset ||
      leftFraction != oldDelegate.leftFraction ||
      leftMin != oldDelegate.leftMin ||
      leftMax != oldDelegate.leftMax ||
      columnGap != oldDelegate.columnGap ||
      dividerGap != oldDelegate.dividerGap ||
      hasDivider != oldDelegate.hasDivider;
}
