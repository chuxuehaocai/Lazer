import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../theme/font_preferences.dart';
import '../widgets/animated_track_cover.dart';

/// The artwork keeps one element while travelling between the reading pane
/// and the transport. Animation ticks only relayout these cached children.
class ArtworkLyricsLayout extends StatefulWidget {
  const ArtworkLyricsLayout({
    super.key,
    required this.lyricsVisible,
    required this.controlsVisible,
    required this.artwork,
    required this.lyrics,
    required this.details,
    required this.transport,
    required this.header,
    required this.summary,
  });

  final bool lyricsVisible, controlsVisible;
  final Widget artwork, lyrics, details, transport;
  final Widget header, summary;

  @override
  State<ArtworkLyricsLayout> createState() => _ArtworkLyricsLayoutState();
}

class _ArtworkLyricsLayoutState extends State<ArtworkLyricsLayout>
    with TickerProviderStateMixin {
  late final AnimationController _mode = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
    value: widget.lyricsVisible ? 1 : 0,
  );
  late final AnimationController _chrome = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 360),
    value: widget.controlsVisible ? 1 : 0,
  );
  late final Animation<double> _summary = ReverseAnimation(_chrome);

  @override
  void didUpdateWidget(covariant ArtworkLyricsLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool reduced = MediaQuery.disableAnimationsOf(context);
    if (oldWidget.lyricsVisible != widget.lyricsVisible) {
      if (reduced) {
        _mode.value = widget.lyricsVisible ? 1 : 0;
      } else {
        // Ease each journey, including reversals, from its current position.
        // Curving the value itself makes the return journey accelerate instead.
        _mode.animateTo(
          widget.lyricsVisible ? 1 : 0,
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
        );
      }
    }
    if (oldWidget.controlsVisible != widget.controlsVisible) {
      if (reduced) {
        _chrome.value = widget.controlsVisible ? 1 : 0;
      } else {
        _chrome.animateTo(
          widget.controlsVisible ? 1 : 0,
          duration: const Duration(milliseconds: 360),
          curve: Curves.easeOutCubic,
        );
      }
    }
  }

  @override
  void dispose() {
    _mode.dispose();
    _chrome.dispose();
    super.dispose();
  }

  Widget _chromeChild(Widget child) => ExcludeFocus(
    excluding: !widget.controlsVisible,
    child: ExcludeSemantics(
      excluding: !widget.controlsVisible,
      child: IgnorePointer(
        ignoring: !widget.controlsVisible,
        child: FadeTransition(
          opacity: _chrome,
          child: RepaintBoundary(child: child),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Stack(
        alignment: Alignment.center,
        children: [
          _chromeChild(widget.header),
          ExcludeFocus(
            excluding: widget.controlsVisible,
            child: ExcludeSemantics(
              excluding: widget.controlsVisible,
              child: IgnorePointer(
                ignoring: widget.controlsVisible,
                child: FadeTransition(
                  key: const ValueKey('compact-player-summary-fade'),
                  opacity: _summary,
                  child: SizeTransition(
                    sizeFactor: _summary,
                    alignment: Alignment.topLeft,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, -.15),
                        end: Offset.zero,
                      ).animate(_summary),
                      child: RepaintBoundary(child: widget.summary),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      Expanded(
        child: LayoutBuilder(
          builder: (context, box) => Padding(
            padding: EdgeInsets.fromLTRB(
              box.maxWidth < 360 ? 20 : 24,
              box.maxHeight < 400 ? 0 : 8,
              box.maxWidth < 360 ? 20 : 24,
              box.maxHeight < 400 ? 8 : 16,
            ),
            child: ClipRect(
              child: CustomMultiChildLayout(
                key: const ValueKey('artwork-lyrics-content'),
                delegate: _ArtworkLyricsDelegate(_mode, _chrome),
                children: [
                  LayoutId(
                    id: 'lyrics',
                    child: ExcludeFocus(
                      excluding: !widget.lyricsVisible,
                      child: ExcludeSemantics(
                        excluding: !widget.lyricsVisible,
                        child: IgnorePointer(
                          ignoring: !widget.lyricsVisible,
                          child: FadeTransition(
                            opacity: _mode,
                            child: TickerMode(
                              enabled: widget.lyricsVisible,
                              child: RepaintBoundary(child: widget.lyrics),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  LayoutId(id: 'details', child: _chromeChild(widget.details)),
                  LayoutId(
                    id: 'transport',
                    child: _chromeChild(widget.transport),
                  ),
                  LayoutId(id: 'artwork', child: _chromeChild(widget.artwork)),
                ],
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

class _ArtworkLyricsDelegate extends MultiChildLayoutDelegate {
  _ArtworkLyricsDelegate(this.mode, this.chrome)
    : super(relayout: Listenable.merge([mode, chrome]));
  final Animation<double> mode, chrome;

  @override
  void performLayout(Size size) {
    if (size.width > size.height * 1.35) {
      _landscape(size);
      return;
    }
    final double w = size.width, h = size.height;
    final double p = mode.value, c = chrome.value;
    final double controlsWidth = math.min(440, w);
    final double left = (w - controlsWidth) / 2;
    final double gap = h < 560 ? 8 : 12;
    final double smallCover = math.min(64, controlsWidth * .24);
    final double metadataInset = (smallCover + 14) * p;
    final Size transport = layoutChild(
      'transport',
      BoxConstraints(
        minWidth: controlsWidth,
        maxWidth: controlsWidth,
        maxHeight: h * .5,
      ),
    );
    final Size details = layoutChild(
      'details',
      BoxConstraints(
        minWidth: math.max(0, controlsWidth - metadataInset),
        maxWidth: math.max(0, controlsWidth - metadataInset),
        maxHeight: math.max(0, h * .3),
      ),
    );
    final double infoHeight = math.max(details.height, smallCover * p);
    final double groupHeight = infoHeight + gap + transport.height;
    final double groupTop = h - groupHeight + 28 * (1 - c);
    positionChild(
      'details',
      Offset(
        left + metadataInset,
        groupTop + (infoHeight - details.height) / 2,
      ),
    );
    positionChild('transport', Offset(left, groupTop + infoHeight + gap));

    final double readingHeight = math.max(0, h - groupHeight - gap);
    final double largeCover = math.max(
      0,
      math.min(380, math.min(controlsWidth, readingHeight - gap * 2)),
    );
    final Rect large = Rect.fromLTWH(
      (w - largeCover) / 2,
      math.max(0, (readingHeight - largeCover) / 2),
      largeCover,
      largeCover,
    );
    final Rect small = Rect.fromLTWH(
      left,
      groupTop + (infoHeight - smallCover) / 2,
      smallCover,
      smallCover,
    );
    final Rect art = Rect.lerp(large, small, p)!;
    layoutChild('artwork', BoxConstraints.tight(art.size));
    positionChild('artwork', art.topLeft);
    final double lyricHeight = math.max(
      0,
      lerpDouble(readingHeight, h - (groupHeight + gap) * c, p)!,
    );
    layoutChild('lyrics', BoxConstraints.tight(Size(w, lyricHeight)));
    positionChild('lyrics', Offset.zero);
  }

  void _landscape(Size size) {
    final double w = size.width, h = size.height;
    final double p = mode.value, c = chrome.value;
    final double columnGap = w < 640 ? 20 : 32;
    final double transportWidth = math.min(400, w * .52);
    final double right = w - transportWidth;
    final double leftWidth = math.max(0, right - columnGap);
    final bool shortScreen = h < 260;
    final double small = math.min(64, h * .3);
    final Size transport = layoutChild(
      'transport',
      BoxConstraints(
        minWidth: transportWidth,
        maxWidth: transportWidth,
        maxHeight: h * .75,
      ),
    );
    final double metadataWidth = lerpDouble(
      shortScreen ? leftWidth : transportWidth,
      math.max(0, leftWidth - small - 14),
      p,
    )!;
    final Size details = layoutChild(
      'details',
      BoxConstraints(
        minWidth: metadataWidth,
        maxWidth: metadataWidth,
        maxHeight: lerpDouble(
          shortScreen ? h * .6 : math.max(0, h - transport.height - 12),
          h * .6,
          p,
        )!,
      ),
    );
    final double groupHeight = math.max(
      transport.height,
      math.max(small, details.height),
    );
    final double groupTop = h - groupHeight + 28 * (1 - c);
    positionChild(
      'details',
      Offset(
        lerpDouble(shortScreen ? 0 : right, small + 14, p)!,
        lerpDouble(
          math.max(
            0,
            h - details.height - (shortScreen ? 0 : transport.height + 12),
          ),
          groupTop + (groupHeight - details.height) / 2,
          p,
        )!,
      ),
    );
    positionChild(
      'transport',
      Offset(right, h - transport.height + 28 * (1 - c)),
    );
    // Short landscape screens put metadata below the artwork instead of
    // clipping large type into the transport's remaining vertical sliver.
    final double artworkHeight = shortScreen
        ? math.max(0, h - details.height - 12)
        : h;
    final double largeSize = math.max(
      0,
      math.min(380, math.min(leftWidth, artworkHeight - 8)),
    );
    final Rect large = Rect.fromLTWH(
      (leftWidth - largeSize) / 2,
      (artworkHeight - largeSize) / 2,
      largeSize,
      largeSize,
    );
    final Rect compact = Rect.fromLTWH(
      0,
      groupTop + (groupHeight - small) / 2,
      small,
      small,
    );
    final Rect art = Rect.lerp(large, compact, p)!;
    layoutChild('artwork', BoxConstraints.tight(art.size));
    positionChild('artwork', art.topLeft);
    layoutChild(
      'lyrics',
      BoxConstraints.tight(Size(w, math.max(0, h - groupHeight * c - 12))),
    );
    positionChild('lyrics', Offset.zero);
  }

  @override
  bool shouldRelayout(covariant _ArtworkLyricsDelegate oldDelegate) =>
      mode != oldDelegate.mode || chrome != oldDelegate.chrome;
}

class PlayerTrackSummary extends StatelessWidget {
  const PlayerTrackSummary({
    super.key,
    required this.track,
    required this.onTap,
  });
  final Track track;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    child: GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Row(
        children: [
          SizedBox.square(
            dimension: 44,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: AnimatedTrackCover(track: track, direction: 0, size: 44),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.fonts.apply(
                    FontCategory.playerTitle,
                    const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ),
                Text(
                  track.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.fonts.apply(
                    FontCategory.playerArtist,
                    const TextStyle(fontSize: 13, color: Color(0xCCFFFFFF)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
