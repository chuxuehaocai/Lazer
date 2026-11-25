import 'build_safe_state.dart';
import '../animation/apple_spring.dart';
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../state/build_safe_notifier.dart';
import '../theme/apple_design.dart';
import '../theme/tokens.dart';
import '../tv/tv_mode.dart';
import 'accessible_controls.dart';
import 'apple_ui.dart';
import 'copyable_song_title.dart';
import 'interaction_feedback.dart';
import 'plate_art.dart';
import '../theme/shape_scale.dart';

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
  final _showLocate = BuildSafeValueNotifier(false);
  bool _locateScheduled = false;

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
    )..addListener(_updateLocate);
    _scheduleLocate();
  }

  void _scheduleLocate() {
    if (_locateScheduled) return;
    _locateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _locateScheduled = false;
      if (mounted) _updateLocate();
    });
  }

  void _updateLocate() {
    final scroll = _scroll;
    final index = widget.state.queueIndex;
    if (scroll == null ||
        scroll.positions.length != 1 ||
        index < 0 ||
        index >= widget.state.queueLength) {
      _showLocate.value = false;
      return;
    }
    final top = index * _rowExtent;
    _showLocate.value =
        top < scroll.offset ||
        top + _rowExtent > scroll.offset + scroll.position.viewportDimension;
  }

  Future<void> _locateCurrent() async {
    final scroll = _scroll;
    if (scroll == null || scroll.positions.length != 1) return;
    final target =
        (widget.state.queueIndex * _rowExtent -
                (scroll.position.viewportDimension - _rowExtent) / 2)
            .clamp(0.0, scroll.position.maxScrollExtent);
    if (MediaQuery.disableAnimationsOf(context)) {
      scroll.jumpTo(target);
    } else {
      await scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 320),
        curve: const AppleSpringCurve(),
      );
    }
  }

  @override
  void dispose() {
    _scroll?.dispose();
    _showLocate.dispose();
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
        final int currentIndex = state.queueIndex;
        _scheduleLocate();
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
                child: queue.isEmpty
                    ? LayoutBuilder(
                        builder: (context, box) => SingleChildScrollView(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              minHeight: box.maxHeight,
                            ),
                            child: const AppleEmptyState(
                              message: '播放队列为空。',
                              icon: Icons.queue_music_rounded,
                            ),
                          ),
                        ),
                      )
                    : Stack(
                        children: [
                          ListView.builder(
                            key: const PageStorageKey<String>('playback-queue'),
                            controller: _scroll,
                            itemExtent: _rowExtent,
                            padding: const EdgeInsets.fromLTRB(10, 0, 10, 72),
                            itemCount: queue.length,
                            itemBuilder: (BuildContext context, int i) => _QueueRow(
                              track: queue[i],
                              index: i,
                              state: state,
                              // The queue may contain the same song twice; only the slot
                              // the transport is actually at is the current one.
                              isCurrent: i == currentIndex,
                              playing: state.playing && i == currentIndex,
                              onTap: () => state.playTrackAt(i),
                            ),
                          ),
                          Positioned(
                            right: 16,
                            bottom: 16,
                            child: ValueListenableBuilder<bool>(
                              valueListenable: _showLocate,
                              builder: (context, show, _) => show
                                  ? FloatingActionButton.small(
                                      key: const ValueKey(
                                        'queue-locate-current',
                                      ),
                                      heroTag: null,
                                      tooltip: context.tr('定位正在播放'),
                                      onPressed: _locateCurrent,
                                      child: const Icon(
                                        Icons.my_location_rounded,
                                        size: 20,
                                      ),
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          ),
                        ],
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

class _QueueRowState extends State<_QueueRow> with BuildSafeState<_QueueRow> {
  bool _hovering = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final bool current = widget.isCurrent;
    final bool highlighted = _hovering || _focused;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Preserve room for the title when a side panel is narrow or text grows.
        final showDuration =
            constraints.maxWidth >=
            200 + MediaQuery.textScalerOf(context).scale(12) * 5;
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
              borderRadius: BorderRadius.circular(8 * AppleShape.scaleOf(context)),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: feedbackAction(context, widget.onTap),
                onSecondaryTapDown: (TapDownDetails details) =>
                    _openMenu(details.globalPosition),
                onLongPress: _openMenuAtRow,
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
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
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
                                      color: current
                                          ? apple.accent
                                          : apple.label,
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
                          if (showDuration) ...[
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
                        ],
                      ),
                    ),
                    if (_focused && TvScope.isActive(context))
                      Positioned.fill(
                        child: IgnorePointer(
                          child: TvFocusOutline(
                            borderRadius: BorderRadius.circular(8 * AppleShape.scaleOf(context)),
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
      },
    );
  }

  /// Opens the row menu at the pointer (right-click).
  Future<void> _openMenu(Offset globalPosition) async {
    final AppState state = widget.state;
    final bool current = widget.isCurrent;
    final String? choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(1, 1),
        Offset.zero & MediaQuery.sizeOf(context),
      ),
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'play',
          height: 36,
          child: const SizedBox(width: 148, child: TrText('立即播放')),
        ),
        PopupMenuItem<String>(
          value: 'next',
          height: 36,
          enabled: !current,
          child: const SizedBox(width: 148, child: TrText('下一首播放')),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'remove',
          height: 36,
          enabled: !current,
          child: const SizedBox(width: 148, child: TrText('从队列移除')),
        ),
      ],
    );
    if (choice == null || !mounted) return;
    final VoidCallback? run = switch (choice) {
      'play' => () => state.playTrackAt(widget.index),
      'next' => () => state.queueNext(widget.track),
      'remove' => () => state.removeQueuedAt(widget.index),
      _ => null,
    };
    feedbackAction(context, run)?.call();
  }

  /// Opens the row menu at the row itself (long-press, which carries no point).
  void _openMenuAtRow() {
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    _openMenu(box.localToGlobal(box.size.center(Offset.zero)));
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

class _PlayingBarsState extends State<_PlayingBars>
    with BuildSafeState<_PlayingBars> {
  int _step = 0;
  bool _listening = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final enabled =
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context);
    if (enabled == _listening) return;
    _listening = enabled;
    if (enabled) {
      widget.state.ticks.addListener(_advance);
    } else {
      widget.state.ticks.removeListener(_advance);
    }
  }

  @override
  void didUpdateWidget(covariant _PlayingBars oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_listening && oldWidget.state != widget.state) {
      oldWidget.state.ticks.removeListener(_advance);
      widget.state.ticks.addListener(_advance);
    }
  }

  void _advance() {
    if (mounted) setState(() => _step = (_step + 1) % 4);
  }

  @override
  void dispose() {
    if (_listening) widget.state.ticks.removeListener(_advance);
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
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : AppleSpring.responsive.duration,
                curve: const AppleSpringCurve(),
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
