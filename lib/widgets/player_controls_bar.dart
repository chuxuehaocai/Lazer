import '../animation/apple_spring.dart';
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../theme/app_palette.dart';
import '../theme/design_tokens.dart';
import 'accessible_controls.dart';
import 'interaction_feedback.dart';
import 'player_seek_bar.dart';
import 'plate_art.dart';
import 'volume_control.dart';

class PlayerControlsBar extends StatelessWidget {
  const PlayerControlsBar({
    super.key,
    required this.state,
    required this.onExpand,
    this.includeBottomSafeArea = false,
  });

  final AppState state;
  final VoidCallback onExpand;
  final bool includeBottomSafeArea;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    // Structural lane only: the rail below owns the 100 ms position updates,
    // so ticking playback does not rebuild the artwork and title rows.
    animation: state,
    builder: (context, _) {
      final Track? track = state.current;
      return DecoratedBox(
        decoration: BoxDecoration(
          color: context.colors.playerSurface,
          border: Border(top: context.borders.onDark),
        ),
        child: SafeArea(
          top: false,
          bottom: includeBottomSafeArea,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                PlayerSeekBar(state: state, trackHeight: 3, thumbRadius: 5),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: track == null
                          ? const TrText(
                              '未选择曲目',
                              style: TextStyle(color: Colors.white70),
                            )
                          : InkWell(
                              onTap: feedbackAction(context, onExpand),
                              child: Row(
                                children: [
                                  SizedBox.square(
                                    dimension: 44,
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(6),
                                      child: PlateArt(
                                        seed: track.coverSeed,
                                        coverUrl: track.coverUrl,
                                        accent: track.accent,
                                        radius: BorderRadius.zero,
                                        size: 44,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: AppSpacing.sm),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          track.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: context.type.bodySm.copyWith(
                                            color: context.colors.onPlayer,
                                          ),
                                        ),
                                        Text(
                                          track.artist,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: context.type.caption.copyWith(
                                            color: context.colors.onDarkMuted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                    ),
                    Expanded(
                      flex: 3,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          AccessibleIconButton(
                            tooltip: '上一首',
                            color: context.colors.onPlayer,
                            onPressed: state.previous,
                            icon: const Icon(Icons.skip_previous_rounded),
                          ),
                          AccessibleIconButton(
                            tooltip: state.playing ? '暂停' : '播放',
                            color: context.colors.onPlayer,
                            onPressed: state.togglePlay,
                            icon: Icon(
                              state.playing
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                            ),
                          ),
                          AccessibleIconButton(
                            tooltip: '下一首',
                            color: context.colors.onPlayer,
                            onPressed: state.next,
                            icon: const Icon(Icons.skip_next_rounded),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: VolumeControl(state: state, onDark: true),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class TrackRow extends StatefulWidget {
  const TrackRow({
    super.key,
    this.state,
    required this.track,
    required this.index,
    required this.isCurrent,
    required this.onPlay,
  });

  final AppState? state;
  final Track track;
  final int index;
  final bool isCurrent;
  final VoidCallback onPlay;

  @override
  State<TrackRow> createState() => _TrackRowState();
}

class _TrackRowState extends State<TrackRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final Track track = widget.track;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: feedbackAction(context, widget.onPlay),
          child: AnimatedContainer(
            curve: const AppleSpringCurve(),
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : AppleSpring.responsive.duration,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.sm,
            ),
            color: widget.isCurrent || _hovered
                ? context.colors.oatWarm.withValues(alpha: .42)
                : Colors.transparent,
            child: Row(
              children: [
                SizedBox(
                  width: 32,
                  child: Text(
                    '${widget.index}'.padLeft(2, '0'),
                    style: context.type.monoSm,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                SizedBox.square(
                  dimension: 40,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: PlateArt(
                      seed: track.coverSeed,
                      coverUrl: track.coverUrl,
                      accent: track.accent,
                      radius: BorderRadius.zero,
                      size: 40,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.type.bodySm.copyWith(
                          fontWeight: widget.isCurrent
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                      Text(
                        track.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.type.captionMuted,
                      ),
                    ],
                  ),
                ),
                if (MediaQuery.sizeOf(context).width > 680)
                  Expanded(
                    flex: 2,
                    child: Text(
                      track.album,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.type.captionMuted,
                    ),
                  ),
                Text(fmt(track.duration), style: context.type.monoSm),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
