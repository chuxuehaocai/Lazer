import 'package:flutter/material.dart';

import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../theme/apple_design.dart';
import '../theme/tokens.dart';
import '../tv/tv_mode.dart';
import 'accessible_controls.dart';
import 'copyable_song_title.dart';
import 'interaction_feedback.dart';
import 'plate_art.dart';

/// The same queue content fills the desktop side panel, the floating player
/// card and the compact bottom sheet.
class PlaybackQueueView extends StatefulWidget {
  const PlaybackQueueView({
    super.key,
    required this.state,
    this.onClose,
    this.showHeader = true,
  });

  final AppState state;
  final VoidCallback? onClose;

  /// `false` when the host panel already draws the title and close button.
  final bool showHeader;

  @override
  State<PlaybackQueueView> createState() => _PlaybackQueueViewState();
}

class _PlaybackQueueViewState extends State<PlaybackQueueView> {
  ScrollController? _scroll;

  double get _rowExtent =>
      (MediaQuery.textScalerOf(context).scale(16) * 1.4 +
              MediaQuery.textScalerOf(context).scale(12) * 1.4 +
              22)
          .clamp(72, double.infinity);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scroll ??= ScrollController(
      initialScrollOffset:
          (widget.state.queueIndex - 2).clamp(0, widget.state.queueLength) *
          _rowExtent,
    );
  }

  @override
  void dispose() {
    _scroll?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return AnimatedBuilder(
      animation: widget.state,
      builder: (BuildContext context, _) {
        final AppState state = widget.state;
        // The getter returns an immutable snapshot; take it once per rebuild,
        // rather than copying the entire queue for every visible row.
        final List<Track> queue = state.queue;
        final String? currentId = state.current?.id;
        return SafeArea(
          top: false,
          child: Column(
            children: <Widget>[
              if (widget.showHeader)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 10, 8),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        Icons.queue_music_rounded,
                        size: 20,
                        color: apple.secondaryLabel,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TrText(
                          '播放队列',
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      TrText(
                        '${queue.length} 首',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: apple.secondaryLabel,
                        ),
                      ),
                      if (widget.onClose != null) ...<Widget>[
                        const SizedBox(width: 4),
                        AccessibleIconButton(
                          tooltip: '关闭',
                          icon: const Icon(Icons.close_rounded, size: 20),
                          onPressed: widget.onClose,
                        ),
                      ],
                    ],
                  ),
                ),
              Expanded(
                child: ListView.builder(
                  key: const PageStorageKey<String>('playback-queue'),
                  controller: _scroll,
                  itemExtent: _rowExtent,
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                  itemCount: queue.length,
                  itemBuilder: (BuildContext context, int i) => _QueueRow(
                    track: queue[i],
                    index: i,
                    state: state,
                    isCurrent: currentId == queue[i].id,
                    playing: state.playing && currentId == queue[i].id,
                    onTap: () => state.playTrackAt(i),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _QueueRow extends StatefulWidget {
  const _QueueRow({
    required this.track,
    required this.index,
    required this.state,
    required this.isCurrent,
    required this.playing,
    required this.onTap,
  });

  final Track track;
  final int index;
  final AppState state;
  final bool isCurrent;
  final bool playing;
  final VoidCallback onTap;

  @override
  State<_QueueRow> createState() => _QueueRowState();
}

class _QueueRowState extends State<_QueueRow> {
  bool _hovering = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final bool current = widget.isCurrent;
    final bool highlighted = _hovering || _focused;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Material(
          color: current
              ? apple.accentSoft
              : highlighted
              ? apple.fill
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: feedbackAction(context, widget.onTap),
            onFocusChange: (bool value) => setState(() => _focused = value),
            child: Stack(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 10,
                  ),
                  child: Row(
                    children: <Widget>[
                      SizedBox(
                        width: 24,
                        child: current && widget.playing
                            ? _PlayingBars(state: widget.state)
                            : Text(
                                '${widget.index + 1}'.padLeft(2, '0'),
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: current
                                      ? apple.accent
                                      : apple.secondaryLabel,
                                  fontFeatures: const <FontFeature>[
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                      ),
                      const SizedBox(width: 8),
                      ClipRRect(
                        borderRadius: AppShape.smRadius,
                        child: SizedBox.square(
                          dimension: 44,
                          child: PlateArt(
                            seed: widget.track.coverSeed,
                            coverUrl: widget.track.coverUrl,
                            size: 44,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: <Widget>[
                            CopyableSongTitle(
                              title: widget.track.title,
                              child: Text(
                                widget.track.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: current ? apple.accent : apple.label,
                                  fontWeight: current
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              widget.track.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: apple.secondaryLabel,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        fmt(widget.track.duration),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: apple.secondaryLabel,
                          fontFeatures: const <FontFeature>[
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (_focused && TvScope.isActive(context))
                  Positioned.fill(
                    child: IgnorePointer(
                      child: TvFocusOutline(
                        borderRadius: BorderRadius.circular(8),
                        width: 2,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Three tiny animated bars marking the active track.
///
/// Driven by the discrete 100 ms tick lane instead of a repeating
/// AnimationController: a perpetual 60 fps ticker would keep the UI isolate
/// busy for a decorative indicator. Implicit 220 ms steps keep the living feel
/// without a busy loop.
class _PlayingBars extends StatefulWidget {
  const _PlayingBars({required this.state});

  final AppState state;

  @override
  State<_PlayingBars> createState() => _PlayingBarsState();
}

class _PlayingBarsState extends State<_PlayingBars> {
  int _step = 0;

  @override
  void initState() {
    super.initState();
    widget.state.ticks.addListener(_advance);
  }

  @override
  void didUpdateWidget(covariant _PlayingBars oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.ticks.removeListener(_advance);
      widget.state.ticks.addListener(_advance);
    }
  }

  void _advance() {
    if (mounted) setState(() => _step = (_step + 1) % 4);
  }

  @override
  void dispose() {
    widget.state.ticks.removeListener(_advance);
    super.dispose();
  }

  static const List<List<double>> _pattern = <List<double>>[
    <double>[5, 11, 8],
    <double>[9, 6, 12],
    <double>[12, 10, 5],
    <double>[7, 12, 9],
  ];

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final List<double> heights = _pattern[_step];
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            for (int i = 0; i < 3; i++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                width: 2.5,
                height: heights[i],
                margin: const EdgeInsets.only(right: 2.5),
                decoration: BoxDecoration(
                  color: apple.accent,
                  borderRadius: const BorderRadius.all(Radius.circular(2)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
