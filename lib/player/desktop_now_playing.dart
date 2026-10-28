import 'dart:async';
import '../widgets/catalog_links.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../downloads/download_dialog.dart';
import '../downloads/download_manager.dart';
import '../downloads/download_queue_sheet.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../theme/app_palette.dart';
import '../tv/tv_mode.dart';
import '../widgets/accessible_controls.dart';
import '../widgets/animated_notice.dart';
import '../widgets/copyable_song_title.dart';
import '../widgets/player_seek_bar.dart';
import '../widgets/interaction_feedback.dart';
import '../widgets/listen_together_dialog.dart';
import '../widgets/playlist_picker_dialog.dart';
import '../widgets/volume_control.dart';

enum DesktopNowPlayingPane { lyrics, comments, queue }

/// Desktop listening workspace with an unscrolled, collapsible transport dock.
class DesktopNowPlaying extends StatelessWidget {
  const DesktopNowPlaying({
    super.key,
    required this.state,
    required this.track,
    required this.artwork,
    required this.lyrics,
    required this.comments,
    required this.queue,
    required this.pane,
    required this.onPaneChanged,
    required this.onBack,
    required this.onSaveArtwork,
    required this.onFullscreen,
    required this.controlsVisible,
    required this.onActivity,
  });
  final AppState state;
  final Track track;
  final Widget artwork, lyrics, comments, queue;
  final DesktopNowPlayingPane pane;
  final ValueChanged<DesktopNowPlayingPane> onPaneChanged;
  final VoidCallback onBack, onSaveArtwork, onFullscreen;
  final bool controlsVisible;
  final VoidCallback onActivity;

  @override
  Widget build(BuildContext context) {
    final bool tv = TvScope.isActive(context);
    return Focus(
      // A remote needs the first focusable control, not an empty root node;
      // the shell's TvFocusRegion claims focus on a television.
      autofocus: !tv,
      canRequestFocus: !tv,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent || event is KeyRepeatEvent) onActivity();
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        onEnter: (_) => onActivity(),
        onHover: (_) => onActivity(),
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => onActivity(),
          onPointerUp: (_) => onActivity(),
          onPointerCancel: (_) => onActivity(),
          onPointerSignal: (_) => onActivity(),
          child: SafeArea(
            minimum: tvSafeInsets(context),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 20, 8),
                  child: Row(
                    children: [
                      AccessibleIconButton(
                        key: const ValueKey('desktop-close'),
                        tooltip: '返回',
                        onPressed: onBack,
                        icon: const Icon(Icons.keyboard_arrow_down_rounded),
                      ),
                      const Spacer(),
                      _AddToPlaylistButton(state: state, track: track),
                      const SizedBox(width: 2),
                      _DownloadButton(state: state, track: track),
                    ],
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, box) {
                      final double sidePadding = (box.maxWidth * .04).clamp(
                        24.0,
                        64.0,
                      );
                      return Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: sidePadding,
                          vertical: 24,
                        ),
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1280),
                            child: LayoutBuilder(
                              builder: (context, content) {
                                // Both panes share the available width equally
                                // at every window size. Bound the artwork group
                                // inside its pane without changing the split.
                                final double paneGap = (content.maxWidth * .06)
                                    .clamp(16.0, 80.0);
                                return Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Expanded(
                                      child: Align(
                                        alignment: Alignment.center,
                                        child: ConstrainedBox(
                                          constraints: const BoxConstraints(
                                            maxWidth: 440,
                                          ),
                                          child: _Presentation(
                                            track: track,
                                            state: state,
                                            artwork: artwork,
                                            onSaveArtwork: onSaveArtwork,
                                          ),
                                        ),
                                      ),
                                    ),
                                    SizedBox(width: paneGap),
                                    Expanded(
                                      child: RepaintBoundary(
                                        child: AnimatedSwitcher(
                                          duration:
                                              MediaQuery.disableAnimationsOf(
                                                context,
                                              )
                                              ? Duration.zero
                                              : const Duration(
                                                  milliseconds: 240,
                                                ),
                                          switchInCurve: Curves.easeOutCubic,
                                          switchOutCurve: Curves.easeInCubic,
                                          transitionBuilder:
                                              (child, animation) =>
                                                  FadeTransition(
                                                    opacity: animation,
                                                    child: SlideTransition(
                                                      position: Tween(
                                                        begin: const Offset(
                                                          .025,
                                                          0,
                                                        ),
                                                        end: Offset.zero,
                                                      ).animate(animation),
                                                      child: RepaintBoundary(
                                                        child: child,
                                                      ),
                                                    ),
                                                  ),
                                          layoutBuilder: (current, previous) =>
                                              Stack(
                                                fit: StackFit.expand,
                                                children: [
                                                  for (final old in previous)
                                                    ExcludeSemantics(
                                                      child: IgnorePointer(
                                                        child: old,
                                                      ),
                                                    ),
                                                  ?current,
                                                ],
                                              ),
                                          child: KeyedSubtree(
                                            key: ValueKey(pane),
                                            child: switch (pane) {
                                              DesktopNowPlayingPane.lyrics =>
                                                lyrics,
                                              DesktopNowPlayingPane.comments =>
                                                comments,
                                              DesktopNowPlayingPane.queue =>
                                                queue,
                                            },
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                _DesktopDock(
                  state: state,
                  visible: controlsVisible,
                  pane: pane,
                  onPaneChanged: onPaneChanged,
                  onFullscreen: onFullscreen,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Adds the current song to one of the account's cloud playlists, or creates
/// a playlist and adds it in one step (the official 收藏到歌单 flow).
class _AddToPlaylistButton extends StatelessWidget {
  const _AddToPlaylistButton({required this.state, required this.track});
  final AppState state;
  final Track track;

  @override
  Widget build(BuildContext context) {
    final bool cloud =
        int.tryParse(track.id) != null && track.localPath == null;
    return AccessibleIconButton(
      key: const ValueKey('desktop-add-to-playlist'),
      tooltip: cloud ? '添加到歌单' : '本地歌曲无法添加到云端歌单',
      onPressed: cloud
          ? () =>
                unawaited(showAddToPlaylistDialog(context, state, track: track))
          : null,
      color: context.colors.onPlayer,
      icon: const Icon(Icons.playlist_add_rounded),
    );
  }
}

/// Top-bar action for the current track. Tapping it opens the same quality /
/// destination dialog every other download entry point uses; once the track is
/// queued or finished, the same button opens the download queue instead of
/// enqueueing a duplicate.
class _DownloadButton extends StatelessWidget {
  const _DownloadButton({required this.state, required this.track});
  final AppState state;
  final Track track;

  @override
  Widget build(BuildContext context) {
    // Local files (imports, scans and downloads played back from the library)
    // have no service id to resolve.
    if (int.tryParse(track.id) == null || track.localPath != null) {
      return AccessibleIconButton(
        key: const ValueKey('desktop-download'),
        tooltip: '本地歌曲无需下载',
        onPressed: null,
        color: context.colors.cloudDark,
        icon: const Icon(Icons.download_rounded),
      );
    }
    return AnimatedBuilder(
      animation: state.downloadManager,
      builder: (context, _) {
        DownloadTask? task;
        for (final DownloadTask candidate in state.downloadManager.tasks) {
          if (candidate.track.id != track.id) continue;
          // A running task describes the button better than an older finished
          // one for the same song at a different quality.
          if (task == null || candidate.isActive) task = candidate;
        }
        final bool active = task?.isActive ?? false;
        final bool done = task?.isDone ?? false;
        final bool queued = active || done;
        return AccessibleIconButton(
          key: const ValueKey('desktop-download'),
          tooltip: queued ? '下载任务' : '下载歌曲',
          onPressed: () => unawaited(
            queued
                ? showDownloadQueueSheet(context, state)
                : downloadTracks(context, state, <Track>[track]),
          ),
          color: queued ? context.colors.clayDeep : context.colors.onPlayer,
          icon: active
              ? SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(
                    value: task?.progress,
                    strokeWidth: 2.4,
                    color: context.colors.clayDeep,
                  ),
                )
              : Icon(
                  done ? Icons.download_done_rounded : Icons.download_rounded,
                ),
        );
      },
    );
  }
}

class _PaneTab extends StatelessWidget {
  const _PaneTab({
    super.key,
    required this.label,
    required this.icon,
    required this.active,
    required this.onPressed,
  });
  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) {
    final Color activeColor = context.colors.onPlayer;
    final Color mutedColor = context.colors.cloudDark;
    return Semantics(
      button: true,
      selected: active,
      label: context.tr(label),
      child: Tooltip(
        message: context.tr(label),
        child: TvTapTarget(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(11),
          focusScale: 1.08,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: feedbackAction(context, onPressed),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  // The selected pane keeps a soft chip around its glyph, the
                  // way the mobile player marks the active tab.
                  color: active
                      ? Colors.white.withValues(alpha: 0.16)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(
                  icon,
                  size: 21,
                  color: active ? activeColor : mutedColor,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Presentation extends StatelessWidget {
  const _Presentation({
    required this.track,
    required this.state,
    required this.artwork,
    required this.onSaveArtwork,
  });
  final Track track;
  final AppState state;
  final Widget artwork;
  final VoidCallback onSaveArtwork;

  /// The cover is the download affordance now: right-clicking it offers the
  /// save action instead of a toolbar button.
  Widget _cover(BuildContext context) => GestureDetector(
    onSecondaryTapDown: (TapDownDetails details) =>
        unawaited(_showCoverMenu(context, details.globalPosition)),
    child: artwork,
  );

  Future<void> _showCoverMenu(BuildContext context, Offset position) async {
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final String? choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        overlay.size.width - position.dx,
        overlay.size.height - position.dy,
      ),
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(value: 'save', child: TrText('保存封面')),
        if (int.tryParse(track.id) != null)
          PopupMenuItem<String>(value: 'download', child: TrText('下载歌曲')),
      ],
    );
    if (choice == 'save') onSaveArtwork();
    if (choice == 'download' && context.mounted) {
      await downloadTracks(context, state, <Track>[track]);
    }
  }

  Widget _metadata(BuildContext context, {bool compact = false}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: CopyableSongTitle(
              title: track.title,
              child: Text(
                track.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.type.heading.copyWith(
                  fontSize: compact ? 22 : 30,
                  height: 1.2,
                ),
              ),
            ),
          ),
          AccessibleIconButton(
            tooltip: '一起听',
            onPressed: () =>
                unawaited(showListenTogetherDialog(context, state)),
            icon: const Icon(Icons.group_rounded),
          ),
          AccessibleIconButton(
            tooltip: state.signedIn ? '收藏歌曲' : '登录后收藏',
            onPressed: state.signedIn
                ? () => unawaited(state.toggleLikeCurrent())
                : null,
            icon: Icon(
              state.currentLiked
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,
              color: state.currentLiked
                  ? context.colors.clayDeep
                  : context.colors.cloudDark,
            ),
          ),
        ],
      ),
      if (track.translatedTitle?.isNotEmpty ?? false)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            track.translatedTitle!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.type.bodySmMuted.copyWith(
              fontSize: compact ? 12 : 15,
            ),
          ),
        ),
      SizedBox(height: compact ? 8 : 12),
      ArtistNameLink(
        state: state,
        artists: track.artists,
        fallback: track.artist,
        maxLines: 2,
        style: context.type.body.copyWith(fontSize: compact ? 14 : 18),
      ),
      SizedBox(height: compact ? 4 : 6),
      AlbumNameLink(
        state: state,
        track: track,
        style: context.type.bodySmMuted.copyWith(fontSize: compact ? 12 : 15),
      ),
      AnimatedNotice(message: state.likeError),
    ],
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      if (box.maxHeight < 320 * MediaQuery.textScalerOf(context).scale(1)) {
        return SingleChildScrollView(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox.square(
                dimension: 72,
                child: RepaintBoundary(child: _cover(context)),
              ),
              const SizedBox(width: 16),
              Expanded(child: _metadata(context, compact: true)),
            ],
          ),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: AspectRatio(
              aspectRatio: 1,
              child: RepaintBoundary(child: _cover(context)),
            ),
          ),
          const SizedBox(height: 24),
          _metadata(context),
        ],
      );
    },
  );
}

class _DesktopDock extends StatelessWidget {
  const _DesktopDock({
    required this.state,
    required this.visible,
    required this.pane,
    required this.onPaneChanged,
    required this.onFullscreen,
  });
  final AppState state;
  final bool visible;
  final DesktopNowPlayingPane pane;
  final ValueChanged<DesktopNowPlayingPane> onPaneChanged;
  final VoidCallback onFullscreen;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state,
    builder: (context, _) => AnimatedSwitcher(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 360),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => SizeTransition(
        axis: Axis.vertical,
        sizeFactor: animation,
        alignment: Alignment.bottomCenter,
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: !visible
          ? const SizedBox.shrink(key: ValueKey('hidden-desktop-dock'))
          : Padding(
              key: const ValueKey('visible-desktop-dock'),
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: DecoratedBox(
                  decoration: const BoxDecoration(color: Colors.transparent),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                    child: Column(
                      key: const ValueKey('now-playing-transport'),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          transitionBuilder: (child, animation) =>
                              SizeTransition(
                                sizeFactor: animation,
                                child: FadeTransition(
                                  opacity: animation,
                                  child: child,
                                ),
                              ),
                          child: state.playbackError == null
                              ? const SizedBox.shrink(
                                  key: ValueKey('no-playback-error'),
                                )
                              : Row(
                                  key: ValueKey(state.playbackError),
                                  children: [
                                    Icon(
                                      Icons.info_outline_rounded,
                                      size: 16,
                                      color: context.colors.clayDeep,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: TrText(
                                        state.playbackError!,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: context.type.caption.copyWith(
                                          color: context.colors.clayDeep,
                                        ),
                                      ),
                                    ),
                                    AccessibleIconButton(
                                      tooltip: '关闭提示',
                                      onPressed: state.clearPlaybackError,
                                      constraints:
                                          const BoxConstraints.tightFor(
                                            width: 32,
                                            height: 32,
                                          ),
                                      style: IconButton.styleFrom(
                                        minimumSize: const Size(32, 32),
                                        padding: const EdgeInsets.all(4),
                                        tapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                      ),
                                      icon: const Icon(
                                        Icons.close_rounded,
                                        size: 18,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                        Row(
                          children: [
                            _Clock(state: state),
                            const SizedBox(width: 12),
                            Expanded(
                              child: PlayerSeekBar(
                                key: const ValueKey('desktop-seek-bar'),
                                state: state,
                                trackHeight: 3,
                                thumbRadius: 5,
                              ),
                            ),
                            const SizedBox(width: 12),
                            _Clock(state: state, end: true),
                          ],
                        ),
                        Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: Row(
                                children: [
                                  _PaneTab(
                                    key: const ValueKey('desktop-lyrics'),
                                    label: '歌词',
                                    icon: Icons.lyrics_outlined,
                                    active:
                                        pane == DesktopNowPlayingPane.lyrics,
                                    onPressed: () => onPaneChanged(
                                      DesktopNowPlayingPane.lyrics,
                                    ),
                                  ),
                                  _PaneTab(
                                    key: const ValueKey('desktop-comments'),
                                    label: '评论',
                                    icon: Icons.chat_bubble_outline_rounded,
                                    active:
                                        pane == DesktopNowPlayingPane.comments,
                                    onPressed: () => onPaneChanged(
                                      DesktopNowPlayingPane.comments,
                                    ),
                                  ),
                                  _PaneTab(
                                    key: const ValueKey('desktop-queue'),
                                    label: '播放队列 (Q)',
                                    icon: Icons.queue_music_rounded,
                                    active: pane == DesktopNowPlayingPane.queue,
                                    onPressed: () => onPaneChanged(
                                      DesktopNowPlayingPane.queue,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Expanded(
                              flex: 3,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Row(
                                  children: [
                                    AccessibleIconButton(
                                      tooltip: '随机播放',
                                      onPressed: state.toggleShuffle,
                                      color: state.shuffle
                                          ? context.colors.clayDeep
                                          : context.colors.cloudDark,
                                      icon: Icon(
                                        state.shuffle
                                            ? Icons.shuffle_on_rounded
                                            : Icons.shuffle_rounded,
                                        size: 23,
                                      ),
                                    ),
                                    AccessibleIconButton(
                                      tooltip: '上一首',
                                      onPressed: state.previous,
                                      icon: const Icon(
                                        Icons.skip_previous_rounded,
                                        size: 28,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    AccessibleIconButton(
                                      key: const ValueKey('desktop-play-pause'),
                                      tooltip: state.playing ? '暂停' : '播放',
                                      color: context.colors.onPlayer,
                                      onPressed: state.togglePlay,
                                      icon: AnimatedSwitcher(
                                        duration: const Duration(
                                          milliseconds: 180,
                                        ),
                                        child: Icon(
                                          state.playing
                                              ? Icons.pause_rounded
                                              : Icons.play_arrow_rounded,
                                          key: ValueKey(state.playing),
                                          size: 28,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    AccessibleIconButton(
                                      tooltip: '下一首',
                                      onPressed: state.next,
                                      icon: const Icon(
                                        Icons.skip_next_rounded,
                                        size: 28,
                                      ),
                                    ),
                                    AccessibleIconButton(
                                      tooltip: '循环播放',
                                      onPressed: state.cycleRepeat,
                                      color: state.repeat != LoopMode.off
                                          ? context.colors.clayDeep
                                          : context.colors.cloudDark,
                                      icon: Icon(
                                        state.repeat == LoopMode.one
                                            ? Icons.repeat_one_rounded
                                            : Icons.repeat_rounded,
                                        size: 23,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 2,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  Flexible(child: VolumeControl(state: state)),
                                  const SizedBox(width: 2),
                                  AccessibleIconButton(
                                    key: const ValueKey('desktop-fullscreen'),
                                    tooltip: '全屏 (F)',
                                    color: context.colors.slateDark,
                                    iconSize: 22,
                                    constraints: const BoxConstraints(
                                      minWidth: 40,
                                      minHeight: 48,
                                    ),
                                    padding: const EdgeInsets.all(8),
                                    onPressed: onFullscreen,
                                    icon: const Icon(Icons.fullscreen_rounded),
                                  ),
                                ],
                              ),
                            ),
                          ],
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

class _Clock extends StatelessWidget {
  const _Clock({required this.state, this.end = false});
  final AppState state;
  final bool end;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 54 * MediaQuery.textScalerOf(context).scale(1),
    child: AnimatedBuilder(
      animation: state.all,
      builder: (context, _) => Text(
        fmt(
          end
              ? state.current?.duration ?? Duration.zero
              : state.precisePosition,
        ),
        textAlign: end ? TextAlign.right : TextAlign.left,
        style: context.type.monoSm,
      ),
    ),
  );
}
