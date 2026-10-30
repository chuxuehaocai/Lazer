import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../theme/apple_design.dart';
import '../tv/tv_mode.dart';
import '../widgets/apple_ui.dart';
import '../widgets/copyable_song_title.dart';
import '../widgets/interaction_feedback.dart';
import '../widgets/playback_queue_view.dart';
import 'legacy_widgets.dart';

/// The legacy transport bar, ported from `PlayerBar` in
/// `DesktopPlayerApp.kt`:
///
/// ```
/// Surface(height = 84, surface @ 0.96 × uiAlpha, 1 dp outlineVariant border)
///   Row(padding 20)
///     Row(width 250)        now-playing tile (cover 50, title, translation, artist)
///     Column(weight 1)      transport row + thin seek row
///     Row(width 168, end)   volume, queue, now playing
/// ```
class LegacyPlayerBar extends StatefulWidget {
  const LegacyPlayerBar({
    super.key,
    required this.state,
    this.compact = false,
    this.comments = false,
    required this.onOpen,
    this.onComments,
  });

  final AppState state;

  /// Phone presentation: cover, title and three buttons, 64 dp tall.
  final bool compact;

  /// Whether the comments pane is open in the shell.
  final bool comments;

  final VoidCallback onOpen;
  final VoidCallback? onComments;

  @override
  State<LegacyPlayerBar> createState() => _LegacyPlayerBarState();
}

typedef _PlayerBarSignature = (Track?, bool, bool, bool, LoopMode, double);

class _LegacyPlayerBarState extends State<LegacyPlayerBar> {
  late _PlayerBarSignature _signature;
  Widget? _bar;
  AppState get state => widget.state;

  _PlayerBarSignature get _currentSignature => (
    state.current,
    state.playing,
    state.currentLiked,
    state.shuffle,
    state.repeat,
    state.volume,
  );

  @override
  void initState() {
    super.initState();
    _signature = _currentSignature;
    state.addListener(_onStateChanged);
  }

  void _onStateChanged() {
    final next = _currentSignature;
    if (next == _signature) return;
    _signature = next;
    setState(() => _bar = null);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bar = null;
  }

  @override
  void didUpdateWidget(covariant LegacyPlayerBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_onStateChanged);
      state.addListener(_onStateChanged);
    }
    final next = _currentSignature;
    if (next != _signature) {
      _signature = next;
      _bar = null;
    }
    if (oldWidget.state != widget.state ||
        oldWidget.compact != widget.compact ||
        oldWidget.comments != widget.comments ||
        oldWidget.onOpen != widget.onOpen ||
        oldWidget.onComments != widget.onComments) {
      _bar = null;
    }
  }

  @override
  void dispose() {
    state.removeListener(_onStateChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _bar ??= _buildBar(context);

  Widget _buildBar(BuildContext context) {
    final Track? track = state.current;
    if (widget.compact) {
      final AppleSemanticColors apple = AppleSemanticColors.of(context);
      return AppleGlass(
        borderRadius: BorderRadius.zero,
        blurSigma: 16,
        color: apple.glassStrong,
        border: Border(top: BorderSide(color: apple.separator, width: .5)),
        child: SizedBox(
          height: 60,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                Expanded(
                  child: _NowPlayingTile(
                    track: track,
                    onTap: track == null ? null : widget.onOpen,
                    artworkSize: 42,
                  ),
                ),
                _CompactIcon(
                  icon: state.playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  tooltip: state.playing ? '暂停' : '播放',
                  iconSize: 27,
                  onPressed: track == null ? null : state.togglePlay,
                ),
                const SizedBox(width: 2),
                _CompactIcon(
                  icon: Icons.skip_next_rounded,
                  tooltip: '下一首',
                  iconSize: 25,
                  onPressed: track == null ? null : state.next,
                ),
              ],
            ),
          ),
        ),
      );
    }
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return AppleGlass(
      borderRadius: BorderRadius.zero,
      blurSigma: 16,
      color: apple.glassStrong,
      border: Border(top: BorderSide(color: apple.separator, width: .5)),
      child: SizedBox(
        height: 84,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              SizedBox(
                width: 250,
                child: _NowPlayingTile(
                  track: track,
                  onTap: track == null ? null : widget.onOpen,
                  artworkSize: 50,
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _CompactIcon(
                            icon: state.currentLiked
                                ? Icons.favorite_rounded
                                : Icons.favorite_border_rounded,
                            tooltip: state.currentLiked ? '取消喜欢' : '喜欢',
                            selected: state.currentLiked,
                            onPressed: track == null
                                ? null
                                : () => unawaited(state.toggleLikeCurrent()),
                          ),
                          const SizedBox(width: 3),
                          _CompactIcon(
                            icon: Icons.skip_previous_rounded,
                            tooltip: '上一首',
                            onPressed: track == null ? null : state.previous,
                          ),
                          const SizedBox(width: 3),
                          _PlayButton(state: state),
                          const SizedBox(width: 3),
                          _CompactIcon(
                            icon: Icons.skip_next_rounded,
                            tooltip: '下一首',
                            onPressed: track == null ? null : state.next,
                          ),
                          const SizedBox(width: 3),
                          _CompactIcon(
                            icon: _playModeIcon(state),
                            tooltip: _playModeLabel(context, state),
                            selected:
                                state.shuffle || state.repeat != LoopMode.off,
                            onPressed: state.cyclePlayMode,
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      _SeekRow(state: state),
                    ],
                  ),
                ),
              ),
              SizedBox(
                width: 168,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _VolumeButton(state: state),
                    const SizedBox(width: 2),
                    LegacyQueueButton(state: state),
                    const SizedBox(width: 2),
                    if (widget.onComments != null && !state.isNavidrome) ...[
                      _CompactIcon(
                        icon: Icons.mode_comment_outlined,
                        tooltip: '评论',
                        selected: widget.comments,
                        onPressed: widget.onComments,
                      ),
                      const SizedBox(width: 2),
                    ],
                    _CompactIcon(
                      icon: Icons.lyrics_outlined,
                      tooltip: '歌词',
                      onPressed: widget.onOpen,
                    ),
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

IconData _playModeIcon(AppState state) {
  if (state.shuffle) return Icons.shuffle_rounded;
  return switch (state.repeat) {
    LoopMode.off => Icons.repeat_rounded,
    LoopMode.all => Icons.repeat_on_rounded,
    LoopMode.one => Icons.repeat_one_on_rounded,
  };
}

String _playModeLabel(BuildContext context, AppState state) {
  if (state.shuffle) return context.tr('随机播放');
  return switch (state.repeat) {
    LoopMode.off => context.tr('顺序播放'),
    LoopMode.all => context.tr('列表循环'),
    LoopMode.one => context.tr('单曲循环'),
  };
}

/// The clickable now-playing tile: hover washes the surface, click opens the
/// lyrics page.
class _NowPlayingTile extends StatefulWidget {
  const _NowPlayingTile({
    required this.track,
    this.onTap,
    required this.artworkSize,
  });

  final Track? track;

  /// Null when nothing is loaded: the empty tile is not a control, so a
  /// remote should skip it instead of parking focus on a dead target.
  final VoidCallback? onTap;
  final double artworkSize;

  @override
  State<_NowPlayingTile> createState() => _NowPlayingTileState();
}

class _NowPlayingTileState extends State<_NowPlayingTile> {
  bool _hovering = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Track? track = widget.track;
    final bool highlighted = _hovering || _focused;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      cursor: widget.onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: TvTapTarget(
        onTap: widget.onTap,
        onFocusChange: (bool value) => setState(() => _focused = value),
        borderRadius: BorderRadius.circular(14),
        focusScale: 1.004,
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: ColoredBox(
              color: highlighted
                  ? scheme.surfaceContainerHighest.withValues(alpha: 0.55)
                  : Colors.transparent,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Row(
                  children: [
                    LegacyCover(
                      url: track?.coverUrl,
                      size: widget.artworkSize,
                      radius: 12,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          track == null
                              ? Text(
                                  context.tr('未选择曲目'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleSmall,
                                )
                              : CopyableSongTitle(
                                  title: track.title,
                                  child: Text(
                                    track.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleSmall,
                                  ),
                                ),
                          if (track?.translatedTitle?.trim().isNotEmpty ??
                              false)
                            Text(
                              track!.translatedTitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          Text(
                            track?.artist ?? 'Lazer',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
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

/// `CompactIconButton`: a 30 dp hit target with an 18 dp icon.
class _CompactIcon extends StatelessWidget {
  const _CompactIcon({
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.selected = false,
    this.iconSize = 18,
    this.focusNode,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;
  final double iconSize;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: 30,
      child: IconButton(
        focusNode: focusNode,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 30, height: 30),
        iconSize: iconSize,
        visualDensity: VisualDensity.compact,
        tooltip: context.tr(tooltip),
        onPressed: feedbackAction(context, onPressed),
        style: IconButton.styleFrom(
          foregroundColor: selected ? scheme.primary : scheme.onSurfaceVariant,
          disabledForegroundColor: scheme.onSurfaceVariant.withValues(
            alpha: 0.4,
          ),
        ),
        icon: Icon(icon, size: iconSize),
      ),
    );
  }
}

/// The 38 dp primary play/pause circle with its 21 dp glyph.
class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: 38,
      child: IconButton(
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 38, height: 38),
        iconSize: 21,
        visualDensity: VisualDensity.compact,
        tooltip: context.tr(state.playing ? '暂停' : '播放'),
        onPressed: state.current == null ? null : state.togglePlay,
        style: IconButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          disabledBackgroundColor: scheme.primary.withValues(alpha: 0.4),
          disabledForegroundColor: scheme.onPrimary.withValues(alpha: 0.6),
        ),
        icon: Icon(
          state.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          size: 21,
        ),
      ),
    );
  }
}

/// Elapsed time, thin seek bar, total time — the second row of the centre.
class _SeekRow extends StatefulWidget {
  const _SeekRow({required this.state});

  final AppState state;

  @override
  State<_SeekRow> createState() => _SeekRowState();
}

class _SeekRowState extends State<_SeekRow> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      // TickerMode does not mute ChangeNotifier notifications. The shell
      // disables it while the full player covers this bar, so stop listening
      // to position ticks until the bar is visible again.
      animation: TickerMode.valuesOf(context).enabled
          ? widget.state.all
          : widget.state,
      builder: (BuildContext context, _) {
        final ThemeData theme = Theme.of(context);
        final ColorScheme scheme = theme.colorScheme;
        final TextStyle? label = theme.textTheme.labelSmall?.copyWith(
          color: scheme.onSurfaceVariant,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        );
        final Track? track = widget.state.current;
        final double duration = (track?.duration.inMilliseconds ?? 0)
            .toDouble();
        final double position = widget.state.precisePosition.inMilliseconds
            .toDouble();
        final double fraction =
            _drag ??
            (duration > 0 ? (position / duration).clamp(0.0, 1.0) : 0.0);
        final Duration elapsed = Duration(
          milliseconds: (fraction * duration).round(),
        );
        return Row(
          children: [
            Text(legacyDuration(elapsed), style: label),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: LegacyThinSeekBar(
                  progress: fraction,
                  bufferedProgress: widget.state.bufferedFraction,
                  seekLimit: widget.state.seekLimitFraction,
                  semanticLabel: '播放进度',
                  onSeek: duration <= 0
                      ? null
                      : (double value) {
                          final double target = widget.state.clampSeekFraction(
                            value,
                          );
                          setState(() => _drag = target);
                          widget.state.seek(target);
                        },
                  onSeekFinished: duration <= 0
                      ? null
                      : () => setState(() => _drag = null),
                ),
              ),
            ),
            Text(
              legacyDuration(track?.duration ?? Duration.zero),
              style: label,
            ),
          ],
        );
      },
    );
  }
}

/// `ThinSeekBar`: a 3 dp rounded track with a 10 dp thumb over a hit strip.
///
/// The bar measures 14 dp in the transport bar. The mobile now-playing page
/// passes [height] 48, matching the legacy rail's generous drag target.
///
/// [onSeek] reports every preview position while a gesture is in flight.
/// When [onSeekCommit] is supplied the gesture is treated like the mobile
/// player: dragging only moves the rail and the label, and the seek lands on
/// release. Without it the caller keeps the bar's historical continuous-seek
/// behaviour.
class LegacyThinSeekBar extends StatefulWidget {
  const LegacyThinSeekBar({
    super.key,
    required this.progress,
    this.bufferedProgress,
    this.seekLimit,
    this.onSeek,
    this.onSeekFinished,
    this.onSeekCommit,
    this.height = 14,
    this.semanticLabel,
  });

  final double progress;

  /// Muted lead-in painted behind the played fraction, as on the mobile rail.
  final double? bufferedProgress;

  /// Furthest fraction the current stream can seek to.
  final double? seekLimit;
  final ValueChanged<double>? onSeek;
  final VoidCallback? onSeekFinished;
  final ValueChanged<double>? onSeekCommit;

  /// Height of the transparent hit strip around the 3 dp track.
  final double height;

  /// Spoken purpose of this rail; null leaves only the percentage value.
  final String? semanticLabel;

  @override
  State<LegacyThinSeekBar> createState() => _LegacyThinSeekBarState();
}

class _LegacyThinSeekBarState extends State<LegacyThinSeekBar> {
  double? _drag;
  bool _focused = false;
  Timer? _nudgeTimer;

  double _limit(double fraction) =>
      fraction.clamp(0.0, (widget.seekLimit ?? 1.0).clamp(0.0, 1.0)).toDouble();

  void _seekTo(double dx, double width) {
    if (widget.onSeek == null || width <= 0) return;
    final double fraction = _limit(dx / width);
    setState(() => _drag = fraction);
    widget.onSeek!(fraction);
  }

  void _finish() {
    final double? fraction = _drag;
    if (fraction == null) return;
    widget.onSeekCommit?.call(fraction);
    widget.onSeekFinished?.call();
    if (mounted) setState(() => _drag = null);
  }

  /// A D-pad step: move the playhead without a pointer and treat the new
  /// position as committed. The preview fraction stays pinned briefly so the
  /// rail does not snap back while the engine finishes the seek.
  void _nudge(double delta) {
    if (widget.onSeek == null) return;
    final double base = _drag ?? widget.progress;
    final double next = _limit(base + delta);
    setState(() => _drag = next);
    widget.onSeek!(next);
    widget.onSeekCommit?.call(next);
    widget.onSeekFinished?.call();
    _nudgeTimer?.cancel();
    _nudgeTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _drag = null);
    });
  }

  @override
  void dispose() {
    _nudgeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double height = widget.height;
    final double fraction = (_drag ?? widget.progress).clamp(0.0, 1.0);
    final double buffered = math.max(
      fraction,
      (widget.bufferedProgress ?? fraction).clamp(0.0, 1.0),
    );
    return FocusableActionDetector(
      enabled: TvScope.isActive(context) && widget.onSeek != null,
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.arrowLeft): _SeekNudgeIntent(-0.02),
        SingleActivator(LogicalKeyboardKey.arrowRight): _SeekNudgeIntent(0.02),
        SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(
          TraversalDirection.up,
        ),
        SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(
          TraversalDirection.down,
        ),
      },
      actions: <Type, Action<Intent>>{
        _SeekNudgeIntent: CallbackAction<_SeekNudgeIntent>(
          onInvoke: (_SeekNudgeIntent intent) {
            _nudge(intent.delta);
            return null;
          },
        ),
      },
      onFocusChange: (bool value) => setState(() => _focused = value),
      child: SizedBox(
        height: height,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final double width = constraints.maxWidth;
            final double thumbTravel = math.max(0.0, width - 10);
            final Color track = scheme.surfaceContainerHighest.withValues(
              alpha: 0.95,
            );
            return Semantics(
              label: widget.semanticLabel == null
                  ? null
                  : context.tr(widget.semanticLabel!),
              value: '${(fraction * 100).round()}%',
              child: MouseRegion(
                cursor: widget.onSeek == null
                    ? SystemMouseCursors.basic
                    : SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: widget.onSeek == null
                      ? null
                      : (TapDownDetails details) =>
                            _seekTo(details.localPosition.dx, width),
                  onTapUp: widget.onSeek == null
                      ? null
                      : (TapUpDetails details) => _finish(),
                  onTapCancel: widget.onSeek == null
                      ? null
                      : () {
                          widget.onSeekFinished?.call();
                          setState(() => _drag = null);
                        },
                  onHorizontalDragStart: widget.onSeek == null
                      ? null
                      : (DragStartDetails details) =>
                            _seekTo(details.localPosition.dx, width),
                  onHorizontalDragUpdate: widget.onSeek == null
                      ? null
                      : (DragUpdateDetails details) =>
                            _seekTo(details.localPosition.dx, width),
                  onHorizontalDragEnd: widget.onSeek == null
                      ? null
                      : (DragEndDetails details) => _finish(),
                  onHorizontalDragCancel: widget.onSeek == null
                      ? null
                      : _finish,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned(
                        left: 0,
                        right: 0,
                        top: (height - 3) / 2,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: track,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: const SizedBox(height: 3),
                        ),
                      ),
                      Positioned(
                        left: 0,
                        top: (height - 3) / 2,
                        width: width * buffered,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: scheme.onSurfaceVariant.withValues(
                              alpha: 0.34,
                            ),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: const SizedBox(height: 3),
                        ),
                      ),
                      Positioned(
                        left: 0,
                        top: (height - 3) / 2,
                        width: width * fraction,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: scheme.primary,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: const SizedBox(height: 3),
                        ),
                      ),
                      Positioned(
                        left: thumbTravel * fraction,
                        top: (height - 10) / 2,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: scheme.primary,
                            shape: BoxShape.circle,
                          ),
                          child: const SizedBox.square(dimension: 10),
                        ),
                      ),
                      if (_focused)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: TvFocusOutline(
                              borderRadius: BorderRadius.circular(5),
                              width: 2,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Vertical twin of [LegacyThinSeekBar] used by the volume popover.
///
/// Same 3 dp track and 10 dp thumb as the horizontal rail, filled from the
/// bottom up. Keeping the slider vertical is what lets the popover stay a
/// narrow column above the speaker instead of reserving a wide strip for a
/// horizontal bar.
class _VerticalVolumeBar extends StatefulWidget {
  const _VerticalVolumeBar({
    required this.value,
    required this.semanticLabel,
    this.onChanged,
    this.onFinished,
  });

  final double value;
  final String semanticLabel;
  final ValueChanged<double>? onChanged;
  final VoidCallback? onFinished;

  @override
  State<_VerticalVolumeBar> createState() => _VerticalVolumeBarState();
}

class _VerticalVolumeBarState extends State<_VerticalVolumeBar> {
  double? _drag;
  bool _focused = false;

  void _seekTo(double dy, double height) {
    if (height <= 0 || widget.onChanged == null) return;
    final double value = (1 - dy / height).clamp(0.0, 1.0);
    setState(() => _drag = value);
    widget.onChanged!(value);
  }

  void _finish() {
    setState(() => _drag = null);
    widget.onFinished?.call();
  }

  /// Up/down D-pad step. The gesture path owns persistence, so a step only
  /// previews; [VolumeButton] commits when the panel closes.
  void _nudge(double delta) {
    if (widget.onChanged == null) return;
    final double next = ((_drag ?? widget.value) + delta).clamp(0.0, 1.0);
    setState(() => _drag = next);
    widget.onChanged!(next);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final double value = (_drag ?? widget.value).clamp(0.0, 1.0);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final double height = box.maxHeight;
        final double width = box.maxWidth;
        return FocusableActionDetector(
          enabled: TvScope.isActive(context) && widget.onChanged != null,
          shortcuts: const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.arrowUp): _SeekNudgeIntent(0.05),
            SingleActivator(LogicalKeyboardKey.arrowDown): _SeekNudgeIntent(
              -0.05,
            ),
          },
          actions: <Type, Action<Intent>>{
            _SeekNudgeIntent: CallbackAction<_SeekNudgeIntent>(
              onInvoke: (_SeekNudgeIntent intent) {
                _nudge(intent.delta);
                return null;
              },
            ),
          },
          onFocusChange: (bool value) => setState(() => _focused = value),
          child: Semantics(
            slider: true,
            label: context.tr(widget.semanticLabel),
            value: '${(value * 100).round()}%',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (TapDownDetails details) =>
                  _seekTo(details.localPosition.dy, height),
              onTapUp: (TapUpDetails details) => _finish(),
              onVerticalDragStart: (DragStartDetails details) =>
                  _seekTo(details.localPosition.dy, height),
              onVerticalDragUpdate: (DragUpdateDetails details) =>
                  _seekTo(details.localPosition.dy, height),
              onVerticalDragEnd: (DragEndDetails details) => _finish(),
              onVerticalDragCancel: _finish,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    top: 0,
                    bottom: 0,
                    left: (width - 3) / 2,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.22),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const SizedBox(width: 3),
                    ),
                  ),
                  Positioned(
                    bottom: 0,
                    left: (width - 3) / 2,
                    height: height * value,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const SizedBox(width: 3),
                    ),
                  ),
                  Positioned(
                    left: (width - 10) / 2,
                    bottom: (height - 10) * value,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  if (_focused)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: TvFocusOutline(
                          borderRadius: BorderRadius.circular(6),
                          width: 2,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// `VolumePanelControl`: hovering the speaker opens a narrow vertical column
/// holding the volume bar and its percentage.
class _VolumeButton extends StatefulWidget {
  const _VolumeButton({required this.state});

  final AppState state;

  @override
  State<_VolumeButton> createState() => _VolumeButtonState();
}

class _VolumeButtonState extends State<_VolumeButton> {
  final OverlayPortalController _portal = OverlayPortalController();
  final LayerLink _link = LayerLink();
  final FocusNode _buttonFocus = FocusNode(debugLabel: 'volume-button');
  Timer? _hide;
  bool _iconHovered = false;
  bool _panelHovered = false;
  double? _drag;

  void _open() {
    if (_portal.isShowing) return;
    _portal.show();
    TvOverlayStack.instance.push(_close);
    if (mounted) setState(() {});
  }

  void _close() {
    if (!_portal.isShowing) return;
    final double? pending = _drag;
    if (pending != null) {
      setState(() => _drag = null);
      unawaited(widget.state.setVolume(pending));
    }
    _portal.hide();
    TvOverlayStack.instance.remove(_close);
    if (mounted) setState(() {});
    if (TvScope.isActive(context)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _buttonFocus.requestFocus();
      });
    }
  }

  void _toggle() => _portal.isShowing ? _close() : _open();

  void _sync() {
    _hide?.cancel();
    if (_iconHovered || _panelHovered) {
      _open();
      return;
    }
    _hide = Timer(const Duration(milliseconds: 160), () {
      if (!_iconHovered && !_panelHovered) _close();
    });
  }

  @override
  void dispose() {
    _hide?.cancel();
    _buttonFocus.dispose();
    TvOverlayStack.instance.remove(_close);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final double volume = (_drag ?? widget.state.volume).clamp(0.0, 1.0);
    return OverlayPortal(
      controller: _portal,
      // The overlay hands its entries the window's tight constraints, which
      // would stretch this panel across the whole window. Align passes loose
      // constraints down, so the column keeps its own size while the follower
      // transform still parks it just above the speaker.
      overlayChildBuilder: (BuildContext context) => Align(
        alignment: Alignment.topLeft,
        child: TvFocusRegion(
          focusToken: _portal.isShowing,
          child: CompositedTransformFollower(
            link: _link,
            showWhenUnlinked: false,
            targetAnchor: Alignment.topCenter,
            followerAnchor: Alignment.bottomCenter,
            offset: const Offset(0, -12),
            child: MouseRegion(
              onEnter: (_) {
                _panelHovered = true;
                _sync();
              },
              onExit: (_) {
                _panelHovered = false;
                _sync();
              },
              child: Container(
                width: 60,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: scheme.surface.withValues(alpha: 0.98),
                  borderRadius: BorderRadius.circular(26),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.26),
                      blurRadius: 26,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 32,
                      height: 128,
                      child: _VerticalVolumeBar(
                        value: volume,
                        semanticLabel: '音量',
                        onChanged: (double value) {
                          setState(() => _drag = value);
                          widget.state.previewVolume(value);
                        },
                        onFinished: () {
                          final double? value = _drag;
                          setState(() => _drag = null);
                          if (value != null) {
                            unawaited(widget.state.setVolume(value));
                          }
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${(volume * 100).round()}%',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      child: CompositedTransformTarget(
        link: _link,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) {
            _iconHovered = true;
            _sync();
          },
          onExit: (_) {
            _iconHovered = false;
            _sync();
          },
          child: TvScope.isActive(context)
              ? TvTapTarget(
                  focusNode: _buttonFocus,
                  onTap: _toggle,
                  borderRadius: BorderRadius.circular(15),
                  focusScale: 1.12,
                  child: Semantics(
                    button: true,
                    label: context.tr('音量'),
                    child: SizedBox.square(
                      dimension: 30,
                      child: Icon(
                        volume <= 0.001
                            ? Icons.volume_off_rounded
                            : Icons.volume_up_rounded,
                        size: 30,
                        color: _portal.isShowing
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              : _CompactIcon(
                  icon: volume <= 0.001
                      ? Icons.volume_off_rounded
                      : Icons.volume_up_rounded,
                  tooltip: '音量',
                  selected: _portal.isShowing,
                  onPressed: () => unawaited(widget.state.toggleMute()),
                ),
        ),
      ),
    );
  }
}

/// `PlayerPanelControl` + `PlayQueuePanel`: a floating queue card above the
/// bar. The list itself is the Nextgen [PlaybackQueueView], so queue
/// interaction stays one implementation.
class LegacyQueueButton extends StatefulWidget {
  const LegacyQueueButton({super.key, required this.state});

  final AppState state;

  @override
  State<LegacyQueueButton> createState() => _LegacyQueueButtonState();
}

class _LegacyQueueButtonState extends State<LegacyQueueButton> {
  final OverlayPortalController _portal = OverlayPortalController();
  final LayerLink _link = LayerLink();
  final FocusNode _buttonFocus = FocusNode(debugLabel: 'queue-button');

  void _show() {
    if (_portal.isShowing) return;
    _portal.show();
    TvOverlayStack.instance.push(_hide);
    setState(() {});
  }

  void _hide() {
    if (!_portal.isShowing) return;
    _portal.hide();
    TvOverlayStack.instance.remove(_hide);
    if (mounted) setState(() {});
    if (TvScope.isActive(context)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _buttonFocus.requestFocus();
      });
    }
  }

  void _toggle() => _portal.isShowing ? _hide() : _show();

  @override
  void dispose() {
    _buttonFocus.dispose();
    TvOverlayStack.instance.remove(_hide);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double height = math.min(
      520,
      MediaQuery.sizeOf(context).height * 0.6,
    );
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (BuildContext context) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _hide,
              child: const SizedBox.expand(),
            ),
          ),
          CompositedTransformFollower(
            link: _link,
            showWhenUnlinked: false,
            // Anchor the card's right edge to the button so it never runs off
            // the window edge — the legacy popup opens towards the content.
            targetAnchor: Alignment.topRight,
            followerAnchor: Alignment.bottomRight,
            offset: const Offset(8, -12),
            child: TvFocusRegion(
              focusToken: _portal.isShowing,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  width: 380,
                  height: height,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: scheme.surface.withValues(alpha: 0.98),
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.32),
                        blurRadius: 32,
                        offset: const Offset(0, 12),
                      ),
                    ],
                  ),
                  child: PlaybackQueueView(
                    state: widget.state,
                    onClose: _toggle,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      child: CompositedTransformTarget(
        link: _link,
        child: _CompactIcon(
          focusNode: _buttonFocus,
          icon: Icons.queue_music_rounded,
          tooltip: '播放队列',
          selected: _portal.isShowing,
          onPressed: _toggle,
        ),
      ),
    );
  }
}

/// Left/right D-pad step on the seek rail, in fractional track length.
class _SeekNudgeIntent extends Intent {
  const _SeekNudgeIntent(this.delta);

  final double delta;
}
