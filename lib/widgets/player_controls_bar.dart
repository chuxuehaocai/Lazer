import 'build_safe_state.dart';
import '../animation/apple_spring.dart';
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import '../theme/app_palette.dart';
import '../theme/design_tokens.dart';
import 'interaction_feedback.dart';
import 'plate_art.dart';
import '../ui/player_bar.dart';
import '../theme/shape_scale.dart';

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
  Widget build(BuildContext context) => SafeArea(
    top: false,
    bottom: includeBottomSafeArea,
    child: AppPlayerBar(state: state, onOpen: onExpand),
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

class _TrackRowState extends State<TrackRow> with BuildSafeState<TrackRow> {
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
                    borderRadius: BorderRadius.circular(6 * AppleShape.scaleOf(context)),
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
