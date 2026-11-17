import '../gateway/music_models.dart';
import '../animation/apple_spring.dart';
import '../animation/view_transitions.dart';
import 'dart:async';
import 'dart:math' as math;
import '../widgets/catalog_links.dart';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
import '../widgets/window_chrome.dart';
import 'osu_search.dart';
import '../theme/font_preferences.dart';

enum DesktopNowPlayingPane { lyrics, comments, queue }

bool _usesWindowCapsule(BuildContext context) =>
    WindowChromeScope.maybeLayoutOf(context)?.inline == true &&
    !TvScope.isActive(context);

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
    this.onPointerStart,
    this.onPointerEnd,
    this.playPauseFocus,
  });
  final AppState state;
  final Track track;
  final Widget artwork, lyrics, comments, queue;
  final DesktopNowPlayingPane pane;
  final ValueChanged<DesktopNowPlayingPane> onPaneChanged;
  final VoidCallback onBack, onSaveArtwork, onFullscreen;
  final bool controlsVisible;
  final VoidCallback onActivity;
  final ValueChanged<int>? onPointerStart, onPointerEnd;
  final FocusNode? playPauseFocus;

  @override
  Widget build(BuildContext context) {
    final bool tv = TvScope.isActive(context);
    final bool inlineChrome = _usesWindowCapsule(context);
    final bool inlineFrame =
        WindowChromeScope.maybeLayoutOf(context)?.inline == true;
    final double headerInset = inlineFrame
        ? MediaQuery.paddingOf(context).top
        : 0;
    // Lyrics can extend behind the floating header. Lists and their controls
    // need to begin below it; this must not shift the artwork's center.
    final double paneTopInset = headerInset + (inlineChrome ? 0 : 64);
    return Focus(
      // A remote needs the first focusable control, not an empty root node;
      // the shell's TvFocusRegion claims focus on a television.
      autofocus: !tv,
      canRequestFocus: !tv,
      onKeyEvent: (node, event) {
        if (tv && (event is KeyDownEvent || event is KeyRepeatEvent)) {
          onActivity();
        }
        return KeyEventResult.ignored;
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (event) {
          onPointerStart?.call(event.pointer);
          onActivity();
        },
        onPointerUp: (event) => onPointerEnd?.call(event.pointer),
        onPointerCancel: (event) => onPointerEnd?.call(event.pointer),
        child: SafeArea(
          top: WindowChromeScope.maybeLayoutOf(context)?.inline != true,
          minimum: tvSafeInsets(context),
          child: Stack(
            children: [
              // The floating header must not shift the artwork and metadata
              // below the center of the listening canvas.
              Positioned.fill(
                child: Column(
                  children: [
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, box) {
                          final double sidePadding = (box.maxWidth * .04).clamp(
                            28.0,
                            80.0,
                          );
                          return Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: sidePadding,
                              vertical: 8,
                            ),
                            child: Center(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 1480,
                                ),
                                child: LayoutBuilder(
                                  builder: (context, content) {
                                    // Give the cover a stable left column and lyrics
                                    // the wider reading lane used by the desktop
                                    // design, without wasting scarce vertical space.
                                    final double paneGap =
                                        (content.maxWidth * .075).clamp(
                                          24.0,
                                          110.0,
                                        );
                                    return Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        Expanded(
                                          flex: 42,
                                          child: Align(
                                            alignment: Alignment.center,
                                            child: ConstrainedBox(
                                              constraints: BoxConstraints(
                                                maxWidth: (box.maxWidth * .35)
                                                    .clamp(280.0, 520.0),
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
                                          flex: 58,
                                          child: Padding(
                                            padding: EdgeInsets.only(
                                              top:
                                                  pane ==
                                                      DesktopNowPlayingPane
                                                          .lyrics
                                                  ? 0
                                                  : paneTopInset,
                                            ),
                                            child: RepaintBoundary(
                                              // Share page transitions so transparent
                                              // panes never overlap and outgoing TV
                                              // controls leave traversal immediately.
                                              child: ViewTransitionSwitcher(
                                                child: KeyedSubtree(
                                                  key: ValueKey(pane),
                                                  child: switch (pane) {
                                                    DesktopNowPlayingPane
                                                        .lyrics =>
                                                      lyrics,
                                                    DesktopNowPlayingPane
                                                        .comments =>
                                                      comments,
                                                    DesktopNowPlayingPane
                                                        .queue =>
                                                      queue,
                                                  },
                                                ),
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
                      playPauseFocus: playPauseFocus,
                      visible: controlsVisible,
                      pane: pane,
                      onPaneChanged: onPaneChanged,
                      onFullscreen: onFullscreen,
                    ),
                  ],
                ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: WindowChromeHeader(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 20, 4),
                    child: Row(
                      children: [
                        WindowChromeCollapse(
                          child: AccessibleIconButton(
                            key: const ValueKey('desktop-close'),
                            tooltip: '返回',
                            onPressed: onBack,
                            icon: const Icon(Icons.keyboard_arrow_down_rounded),
                          ),
                        ),
                        const Spacer(),
                        WindowChromeActions(
                          children: [
                            AccessibleIconButton(
                              key: const ValueKey('desktop-search-osu'),
                              tooltip: '在 osu! 中搜索',
                              onPressed: osuBeatmapSearchUri(track) == null
                                  ? null
                                  : () =>
                                        unawaited(searchInOsu(context, track)),
                              color: inlineChrome
                                  ? null
                                  : context.colors.onPlayer,
                              icon: const Icon(Icons.search_rounded),
                            ),
                            _AddToPlaylistButton(state: state, track: track),
                            _DownloadButton(state: state, track: track),
                          ],
                        ),
                      ],
                    ),
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

/// Adds the current song to one of the account's cloud playlists, or creates
/// a playlist and adds it in one step (the official 收藏到歌单 flow).
class _AddToPlaylistButton extends StatelessWidget {
  const _AddToPlaylistButton({required this.state, required this.track});
  final AppState state;
  final Track track;

  @override
  Widget build(BuildContext context) {
    final bool cloud = track.isServiceTrack && track.localPath == null;
    return AccessibleIconButton(
      key: const ValueKey('desktop-add-to-playlist'),
      tooltip: cloud ? '添加到歌单' : '本地歌曲无法添加到云端歌单',
      onPressed: cloud
          ? () =>
                unawaited(showAddToPlaylistDialog(context, state, track: track))
          : null,
      color: _usesWindowCapsule(context) ? null : context.colors.onPlayer,
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
    final bool inlineChrome = _usesWindowCapsule(context);
    // Local files (imports, scans and downloads played back from the library)
    // have no service id to resolve.
    if (!track.isServiceTrack || track.localPath != null) {
      return AccessibleIconButton(
        key: const ValueKey('desktop-download'),
        tooltip: '本地歌曲无需下载',
        onPressed: null,
        color: inlineChrome ? null : context.colors.cloudDark,
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
          color: inlineChrome
              ? null
              : queued
              ? context.colors.clayDeep
              : context.colors.onPlayer,
          icon: active
              ? SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(
                    value: task?.progress,
                    strokeWidth: 2.4,
                    color: inlineChrome
                        ? Theme.of(context).colorScheme.onSurfaceVariant
                        : context.colors.clayDeep,
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
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: feedbackAction(context, onPressed),
              canRequestFocus: !TvScope.isActive(context),
              borderRadius: BorderRadius.circular(11),
              child: AnimatedContainer(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : AppleSpring.responsive.duration,
                curve: const AppleSpringCurve(),
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
        if (track.isServiceTrack)
          PopupMenuItem<String>(value: 'download', child: TrText('下载歌曲')),
      ],
    );
    if (choice == 'save') onSaveArtwork();
    if (choice == 'download' && context.mounted) {
      await downloadTracks(context, state, <Track>[track]);
    }
  }

  Widget _metadata(
    BuildContext context, {
    bool compact = false,
    bool tight = false,
  }) => Column(
    key: const ValueKey('desktop-player-metadata'),
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
                textWidthBasis: TextWidthBasis.longestLine,
                style: context.fonts.apply(
                  FontCategory.playerTitle,
                  TextStyle(
                    fontSize: compact ? 22 : (tight ? 26 : 32),
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                    color: context.colors.slateDark,
                  ),
                ),
              ),
            ),
          ),
          if (state.supportsMusic(MusicCapability.listenTogether))
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
              fontSize: compact ? 12 : (tight ? 14 : 15),
            ),
          ),
        ),
      SizedBox(height: compact || tight ? 8 : 12),
      ArtistNameLink(
        state: state,
        artists: track.artists,
        fallback: track.artist,
        maxLines: 1,
        style: context.fonts.apply(
          FontCategory.playerArtist,
          TextStyle(
            fontSize: compact ? 14 : (tight ? 17 : 19),
            color: context.colors.slateDark,
          ),
        ),
      ),
      SizedBox(height: compact || tight ? 4 : 6),
      AlbumNameLink(
        state: state,
        track: track,
        style: context.fonts.apply(
          FontCategory.playerArtist,
          TextStyle(
            fontSize: compact ? 12 : (tight ? 14 : 15),
            color: context.colors.cloudDark,
          ),
        ),
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
      return _ArtworkAndMetadata(
        artwork: RepaintBoundary(child: _cover(context)),
        metadata: _metadata(context, tight: box.maxHeight < 560),
      );
    },
  );
}

/// Keeps the metadata as wide as the height-constrained square artwork.
class _ArtworkAndMetadata extends MultiChildRenderObjectWidget {
  _ArtworkAndMetadata({required Widget artwork, required Widget metadata})
    : super(children: [artwork, metadata]);

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderArtworkAndMetadata();
}

class _ArtworkAndMetadataParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderArtworkAndMetadata extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _ArtworkAndMetadataParentData>,
        RenderBoxContainerDefaultsMixin<
          RenderBox,
          _ArtworkAndMetadataParentData
        > {
  static const double _gap = 16;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _ArtworkAndMetadataParentData) {
      child.parentData = _ArtworkAndMetadataParentData();
    }
  }

  @override
  void performLayout() {
    size = constraints.biggest;
    final RenderBox artwork = firstChild!;
    final RenderBox metadata = childAfter(artwork)!;

    // First measure the metadata at full width, then match it to the artwork.
    // Narrower text may wrap, so recompute the available artwork size once.
    metadata.layout(BoxConstraints(maxWidth: size.width), parentUsesSize: true);
    double artworkSize = math.min(
      size.width,
      math.max(0, size.height - _gap - metadata.size.height),
    );
    if (artworkSize < size.width && artworkSize >= 96) {
      metadata.layout(
        BoxConstraints.tightFor(width: artworkSize),
        parentUsesSize: true,
      );
      final double available = math.max(
        0,
        size.height - _gap - metadata.size.height,
      );
      if (artworkSize > available) {
        artworkSize = available;
        metadata.layout(
          BoxConstraints.tightFor(width: artworkSize),
          parentUsesSize: true,
        );
      }
    }

    artwork.layout(
      BoxConstraints.tightForFinite(width: artworkSize, height: artworkSize),
    );
    final double top = math.max(
      0,
      (size.height - artworkSize - _gap - metadata.size.height) / 2,
    );
    final double left = (size.width - artworkSize) / 2;
    (artwork.parentData! as _ArtworkAndMetadataParentData).offset = Offset(
      left,
      top,
    );
    (metadata.parentData! as _ArtworkAndMetadataParentData).offset = Offset(
      left,
      top + artworkSize + _gap,
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

class _DesktopDockTransition extends StatefulWidget {
  const _DesktopDockTransition({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  State<_DesktopDockTransition> createState() => _DesktopDockTransitionState();
}

class _DesktopDockTransitionState extends State<_DesktopDockTransition>
    with TickerProviderStateMixin {
  static const _revealSpring = AppleSpring(
    duration: Duration(milliseconds: 600),
    bounce: .15,
  );
  // A disappearing dock has no visible resting surface to bounce against.
  static const _hideSpring = AppleSpring(duration: Duration(milliseconds: 600));
  late final _extent = AnimationController.unbounded(
    vsync: this,
    value: widget.visible ? 1 : 0,
  );
  late final _opacity = AnimationController(
    vsync: this,
    value: widget.visible ? 1 : 0,
    duration: const Duration(milliseconds: 220),
  );

  void _snap() {
    _extent.value = widget.visible ? 1 : 0;
    _opacity.value = widget.visible ? 1 : 0;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) _snap();
  }

  @override
  void didUpdateWidget(covariant _DesktopDockTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible == oldWidget.visible) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _snap();
      return;
    }
    // The cover follows this layout extent directly. Retarget its presented
    // position and velocity instead of creating another outgoing dock.
    _extent.springTo(
      widget.visible ? 1 : 0,
      spring: widget.visible ? _revealSpring : _hideSpring,
    );
    _opacity.animateTo(widget.visible ? 1 : 0, curve: Curves.easeInOutCubic);
  }

  @override
  void dispose() {
    _extent.dispose();
    _opacity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeFocus(
    excluding: !widget.visible,
    child: ExcludeSemantics(
      excluding: !widget.visible,
      child: IgnorePointer(
        ignoring: !widget.visible,
        child: TickerMode(
          enabled: widget.visible,
          child: SizeTransition(
            key: const ValueKey('desktop-dock-size'),
            sizeFactor: _extent,
            alignment: Alignment.bottomCenter,
            child: FadeTransition(
              key: const ValueKey('desktop-dock-fade'),
              opacity: _opacity,
              child: widget.child,
            ),
          ),
        ),
      ),
    ),
  );
}

class _DesktopDock extends StatelessWidget {
  const _DesktopDock({
    required this.state,
    required this.visible,
    required this.pane,
    required this.onPaneChanged,
    required this.onFullscreen,
    this.playPauseFocus,
  });
  final AppState state;
  final bool visible;
  final DesktopNowPlayingPane pane;
  final ValueChanged<DesktopNowPlayingPane> onPaneChanged;
  final VoidCallback onFullscreen;
  final FocusNode? playPauseFocus;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state,
    builder: (context, _) => _DesktopDockTransition(
      visible: visible,
      child: Padding(
        key: const ValueKey('desktop-dock-content'),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: DecoratedBox(
            decoration: const BoxDecoration(color: Colors.transparent),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
              child: Column(
                key: const ValueKey('now-playing-transport'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedSwitcher(
                    switchInCurve: const AppleSpringCurve(),
                    switchOutCurve: const AppleSpringCurve(),
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : AppleSpring.responsive.duration,
                    transitionBuilder: (child, animation) => SizeTransition(
                      sizeFactor: animation,
                      child: FadeTransition(opacity: animation, child: child),
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
                                constraints: const BoxConstraints.tightFor(
                                  width: 32,
                                  height: 32,
                                ),
                                style: IconButton.styleFrom(
                                  minimumSize: const Size(32, 32),
                                  padding: const EdgeInsets.all(4),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                                icon: const Icon(Icons.close_rounded, size: 18),
                              ),
                            ],
                          ),
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
                              active: pane == DesktopNowPlayingPane.lyrics,
                              onPressed: () =>
                                  onPaneChanged(DesktopNowPlayingPane.lyrics),
                            ),
                            if (state.supportsCurrentMusic(
                              MusicCapability.comments,
                            ))
                              _PaneTab(
                                key: const ValueKey('desktop-comments'),
                                label: '评论',
                                icon: Icons.chat_bubble_outline_rounded,
                                active: pane == DesktopNowPlayingPane.comments,
                                onPressed: () => onPaneChanged(
                                  DesktopNowPlayingPane.comments,
                                ),
                              ),
                            _PaneTab(
                              key: const ValueKey('desktop-queue'),
                              label: '播放队列 (Q)',
                              icon: Icons.queue_music_rounded,
                              active: pane == DesktopNowPlayingPane.queue,
                              onPressed: () =>
                                  onPaneChanged(DesktopNowPlayingPane.queue),
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
                              _DesktopPlayPauseButton(
                                key: const ValueKey('desktop-play-pause'),
                                state: state,
                                focusNode: playPauseFocus,
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
                      Expanded(
                        flex: 2,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (!largeScreenModeOf(context)) ...[
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
                          ],
                        ),
                      ),
                    ],
                  ),
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1000),
                      child: Row(
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

class _DesktopPlayPauseButton extends StatelessWidget {
  const _DesktopPlayPauseButton({
    super.key,
    required this.state,
    this.focusNode,
  });

  final AppState state;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final bool remote = TvScope.isActive(context);
    final Color fill = Color.lerp(
      Theme.of(context).colorScheme.primary,
      Colors.white,
      .32,
    )!;
    return TvTapTarget(
      onTap: feedbackAction(context, state.togglePlay),
      autofocus: remote,
      focusNode: remote ? focusNode : null,
      borderRadius: BorderRadius.circular(24),
      focusScale: 1.06,
      child: ExcludeFocus(
        excluding: remote,
        child: IconButton(
          focusNode: remote ? null : focusNode,
          tooltip: context.tr(state.playing ? '暂停' : '播放'),
          onPressed: feedbackAction(context, state.togglePlay),
          style: IconButton.styleFrom(
            backgroundColor: fill,
            foregroundColor: const Color(0xff202124),
            shape: const CircleBorder(),
            minimumSize: const Size.square(48),
            fixedSize: const Size.square(48),
            padding: EdgeInsets.zero,
          ),
          icon: AnimatedSwitcher(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 180),
            child: Icon(
              state.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              key: ValueKey(state.playing),
              size: 28,
            ),
          ),
        ),
      ),
    );
  }
}

class _Clock extends StatelessWidget {
  const _Clock({required this.state, this.end = false});
  final AppState state;
  final bool end;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 54 * MediaQuery.textScalerOf(context).scale(1),
    child: AnimatedBuilder(
      animation: TickerMode.valuesOf(context).enabled ? state.all : state,
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
