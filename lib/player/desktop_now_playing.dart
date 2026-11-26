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
import '../state/ui_preferences.dart';
import '../theme/adaptive_contrast.dart';
import '../theme/app_palette.dart';
import '../theme/apple_design.dart';
import '../theme/lazer_theme.dart';
import '../theme/paper_widgets.dart';
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
import 'desktop_artwork_layout.dart';
import '../theme/font_preferences.dart';
import '../theme/shape_scale.dart';

/// Which surface fills the desktop player's reading column.
///
/// [none] folds that column away: the artwork takes the middle of the canvas
/// instead of sharing it with lyrics, comments or the queue.
enum DesktopNowPlayingPane { lyrics, comments, queue, none }

/// The tone the listening canvas actually resolves to, for chrome that has to sit
/// on it without material of its own.
///
/// Not `AppleSemanticColors.background`: that token describes the card surface the
/// chrome theme is built from, and in the Mio player it is white while the canvas
/// underneath is cover art on black. Reading it gave the back arrow black ink on
/// a dark image — the reason it disappeared.
Color playerBackdropInk(
  BuildContext context,
  AppBackgroundMode mode,
) => switch (mode) {
  // No backdrop at all: the page itself is the canvas.
  AppBackgroundMode.off =>
    Theme.of(context).brightness == Brightness.dark
        ? AppleSemanticColors.dark
        : AppleSemanticColors.light,
  // Every other mode composites over a black edge (`pageColor: Colors.black` in
  // the player backdrop), and the cover-driven flow is dark in practice.
  AppBackgroundMode.solidColor ||
  AppBackgroundMode.customImage ||
  AppBackgroundMode.windowsMica ||
  AppBackgroundMode.nowPlayingStatic ||
  AppBackgroundMode.nowPlayingDynamic => AppleSemanticColors.dark,
}.background;

/// Breathing room below the cover and metadata group on the desktop canvas.
const double kDesktopArtworkBottomInset = 24;

/// The player's own header row: the back control's leading inset on the left, a
/// 4 dp breath under the window edge, and the capsule's end inset on the right,
/// so the page capsule stops exactly where the floating one does.
const EdgeInsets kDesktopPlayerHeaderInset = EdgeInsets.fromLTRB(
  16,
  4,
  kWindowChromeEnd,
  4,
);

/// Height the classic title-bar player reserves above the cover for its own
/// back/actions row, so the artwork never sits under the button.
const double _kClassicHeaderRowHeight = 52;

bool _usesWindowCapsule(BuildContext context) =>
    WindowChromeScope.maybeLayoutOf(context)?.inline == true &&
    !TvScope.isActive(context);

/// Whether the player's action row is painted inside a window capsule.
///
/// Two presentations wear one capsule: the frame's floating capsule in Inline
/// mode, and the capsule the page draws for itself under a classic title bar.
/// The buttons take the capsule's ink in both — [WindowChromeActions] owns that
/// material — and keep the player's own ink only on a television, which retains
/// the in-page toolbar.
bool _usesCapsuleInk(BuildContext context) =>
    WindowChromeScope.maybeLayoutOf(context) != null &&
    !TvScope.isActive(context);

/// Desktop listening workspace with an unscrolled, collapsible transport dock.
class DesktopNowPlaying extends StatelessWidget {
  static const double artworkMaxWidth = DesktopArtworkLayout.artworkMaxWidth;

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
  final VoidCallback onBack, onSaveArtwork;
  final bool controlsVisible;
  final VoidCallback onActivity;
  final ValueChanged<int>? onPointerStart, onPointerEnd;
  final FocusNode? playPauseFocus;

  @override
  Widget build(BuildContext context) {
    final bool tv = TvScope.isActive(context);
    final bool inlineChrome = _usesWindowCapsule(context);
    final bool capsuleInk = _usesCapsuleInk(context);
    final bool inlineFrame =
        WindowChromeScope.maybeLayoutOf(context)?.inline == true;
    // Ink for the one command that has no material of its own.
    //
    // The floating back button sits straight on the listening canvas — the
    // backdrop the player composes over the cover art, not the card surface
    // `AppleSemanticColors.background` describes. Resolving against that token
    // was the bug: it is white in the Mio player's chrome theme, so the arrow
    // came out black on a black-and-cover-art canvas.
    final Color backInk = contrastingLabel(
      playerBackdropInk(context, state.playerBackground),
    );
    // Nothing is painted behind the glyph, so it needs the shadow on every canvas
    // the player has — including the classic title bar, where the button sits on
    // the same cover art.
    final List<Shadow> backShadows = <Shadow>[
      // The glyph can land on any part of the cover art. A glow in the opposite
      // direction is what keeps one ink readable across it: a dark glow behind
      // light ink, a light glow behind dark ink.
      Shadow(
        color: backInk.computeLuminance() > .5
            ? const Color(0x73000000)
            : const Color(0x59FFFFFF),
        blurRadius: 4,
        offset: const Offset(0, 1),
      ),
    ];
    // The listening canvas starts below the floating capsule: the page keeps
    // the same band of space every browse page keeps, instead of the artwork
    // running up against the window's top edge.
    final double chromeInset = inlineFrame ? kInlineChromeInset : 0;
    // Lists and their controls sit inside the canvas, which already carries the
    // band; only the classic strip needs room for its own collapse row.
    // 只有「确实存在经典标题栏」时页面才自己画返回按钮：没有 WindowChromeScope
    // 的宿主（网页版、测试、非桌面）不需要这条带子，否则白扣一块高度。
    final bool pageHeaderRow =
        WindowChromeScope.maybeLayoutOf(context) != null && !inlineFrame && !tv;
    final double headerRowInset = pageHeaderRow ? _kClassicHeaderRowHeight : 0;
    // 经典标题栏时头部那一条已经在外层让出真实高度了，这里扣掉，免得歌词区
    // 被推两次（原来 64 是「浮在封面上的头部」需要的避让量）。
    final double paneTopInset = math.max(
      0,
      (inlineChrome ? 0 : 64) - headerRowInset,
    );
    // The top band behaves like every browse page's header: dragging there
    // moves the window, double-clicking it restores or maximizes. Desktop only —
    // this widget *is* the desktop layout, and the band is inert everywhere
    // else, so a phone or tablet gesture area is untouched.
    return WindowDragArea(
      bandHeight: kInlineChromeInset,
      child: Focus(
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
                  child: Padding(
                    // 经典标题栏下这条返回按钮是页面自己画的，它要占真实空间：
                    // 之前封面顶到窗口左上角，按钮正好压在封面上。让出这条高度后
                    // 可用高度变小，封面连同下面的标题/歌手一起等比缩小 ->
                    // tools/capture 的截图里就是「缩小封面给按钮腾位置」。
                    padding: EdgeInsets.only(top: chromeInset + headerRowInset),
                    child: Column(
                      children: [
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, box) {
                              // skin: nowPlayingSidePadding（0 = 内置 4% clamp 28–80）
                              final LazerThemeTokens skin = LazerThemeTokens.of(
                                context,
                              );
                              final double sidePadding =
                                  skin.nowPlayingSidePadding > 0
                                  ? skin.nowPlayingSidePadding
                                  : (box.maxWidth * .04).clamp(28.0, 80.0);
                              return Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: sidePadding,
                                  vertical: 8,
                                ),
                                child: LayoutBuilder(
                                  builder: (context, content) {
                                    // A folded reading pane keeps the lyrics in
                                    // the tree: the same viewport comes back
                                    // without losing the current line, while the
                                    // artwork owns the canvas in the meantime.
                                    final DesktopNowPlayingPane shown =
                                        pane == DesktopNowPlayingPane.none
                                        ? DesktopNowPlayingPane.lyrics
                                        : pane;
                                    final double scale =
                                        MediaQuery.textScalerOf(
                                          context,
                                        ).scale(1);
                                    // skin: 正在播放的版心几何（parchment = 0.34W /
                                    // 240–440 / gap 32 / 竖线 1px / 再 16）
                                    final bool skinnedCanvas =
                                        skin.nowPlayingArtworkFraction > 0;
                                    return DesktopArtworkLayout(
                                      // 经典标题栏的那条页面头已经在外层让出高度了，
                                      // 这里不再重复扣，避免封面被压两次。
                                      leftFraction:
                                          skin.nowPlayingArtworkFraction,
                                      leftMin: skin.nowPlayingArtworkMin,
                                      leftMax: skin.nowPlayingArtworkMax,
                                      columnGap: skinnedCanvas ? 32 : 0,
                                      dividerGap: skinnedCanvas ? 16 : 0,
                                      divider: skinnedCanvas
                                          ? const Hairline(vertical: true)
                                          : null,
                                      paneVisible:
                                          pane != DesktopNowPlayingPane.none,
                                      paneTopInset:
                                          shown == DesktopNowPlayingPane.lyrics
                                          ? 0
                                          : paneTopInset,
                                      artwork: _Presentation(
                                        track: track,
                                        state: state,
                                        artwork: artwork,
                                        onSaveArtwork: onSaveArtwork,
                                        // Both branches only depend on the
                                        // canvas height, so deciding them here
                                        // keeps the per-frame fold from
                                        // rebuilding the artwork subtree.
                                        compact:
                                            content.maxHeight < 320 * scale,
                                        tight: content.maxHeight < 560,
                                        folded:
                                            pane == DesktopNowPlayingPane.none,
                                      ),
                                      pane: RepaintBoundary(
                                        // Share page transitions so transparent
                                        // panes never overlap and outgoing TV
                                        // controls leave traversal immediately.
                                        child: ViewTransitionSwitcher(
                                          child: KeyedSubtree(
                                            key: ValueKey(shown),
                                            child: switch (shown) {
                                              DesktopNowPlayingPane.lyrics =>
                                                lyrics,
                                              DesktopNowPlayingPane.comments =>
                                                comments,
                                              DesktopNowPlayingPane.queue ||
                                              DesktopNowPlayingPane.none =>
                                                queue,
                                            },
                                          ),
                                        ),
                                      ),
                                    );
                                  },
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
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: WindowChromeHeader(
                    child: Padding(
                      padding: kDesktopPlayerHeaderInset,
                      child: Row(
                        children: [
                          WindowChromeCollapse(
                            // A tooltip inside the capsule would nest a second
                            // overlay under the one that paints these buttons;
                            // the label stays in semantics while the capsule is
                            // in charge.
                            child: AccessibleIconButton(
                              key: const ValueKey('desktop-close'),
                              tooltip: inlineChrome ? null : '返回',
                              semanticLabel: inlineChrome ? '返回' : null,
                              onPressed: onBack,
                              color: backInk,
                              icon: Icon(
                                Icons.keyboard_arrow_down_rounded,
                                shadows: backShadows,
                              ),
                            ),
                          ),
                          const Spacer(),
                          WindowChromeActions(
                            children: [
                              AccessibleIconButton(
                                key: const ValueKey('desktop-search-osu'),
                                tooltip: inlineChrome ? null : '在 osu! 中搜索',
                                semanticLabel: inlineChrome
                                    ? '在 osu! 中搜索'
                                    : null,
                                onPressed: osuBeatmapSearchUri(track) == null
                                    ? null
                                    : () => unawaited(
                                        searchInOsu(context, track),
                                      ),
                                color: capsuleInk
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
    final bool inlineChrome = _usesWindowCapsule(context);
    final bool capsuleInk = _usesCapsuleInk(context);
    return AccessibleIconButton(
      key: const ValueKey('desktop-add-to-playlist'),
      // See the capsule's close button: a tooltip would nest a second overlay
      // under the portal that paints these actions. Each sink spells the label
      // out because the i18n gate reads literals at the call site.
      tooltip: inlineChrome ? null : (cloud ? '添加到歌单' : '本地歌曲无法添加到云端歌单'),
      semanticLabel: inlineChrome ? (cloud ? '添加到歌单' : '本地歌曲无法添加到云端歌单') : null,
      onPressed: cloud
          ? () =>
                unawaited(showAddToPlaylistDialog(context, state, track: track))
          : null,
      color: capsuleInk ? null : context.colors.onPlayer,
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
    final bool capsuleInk = _usesCapsuleInk(context);
    // Local files (imports, scans and downloads played back from the library)
    // have no service id to resolve.
    if (!track.isServiceTrack || track.localPath != null) {
      return AccessibleIconButton(
        key: const ValueKey('desktop-download'),
        tooltip: inlineChrome ? null : '本地歌曲无需下载',
        semanticLabel: inlineChrome ? '本地歌曲无需下载' : null,
        onPressed: null,
        color: capsuleInk ? null : context.colors.cloudDark,
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
          tooltip: inlineChrome ? null : (queued ? '下载任务' : '下载歌曲'),
          semanticLabel: inlineChrome ? (queued ? '下载任务' : '下载歌曲') : null,
          onPressed: () => unawaited(
            queued
                ? showDownloadQueueSheet(context, state)
                : downloadTracks(context, state, <Track>[track]),
          ),
          color: capsuleInk
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
                    color: capsuleInk
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
    // The paper skin can make the reading canvas light while the legacy
    // onPlayer role remains white. Resolve the active glyph against the actual
    // page surface so the selected lower-left tab stays readable.
    final Color pageSurface = AppleSemanticColors.of(context).background;
    final Color activeColor = contrastingLabel(pageSurface);
    final Color mutedColor = context.colors.cloudDark;
    return Semantics(
      button: true,
      selected: active,
      label: context.tr(label),
      child: Tooltip(
        message: context.tr(label),
        child: TvTapTarget(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(11 * AppleShape.scaleOf(context)),
          focusScale: 1.08,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: feedbackAction(context, onPressed),
              canRequestFocus: !TvScope.isActive(context),
              borderRadius: BorderRadius.circular(
                11 * AppleShape.scaleOf(context),
              ),
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
                      ? activeColor.withValues(alpha: 0.14)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(
                    11 * AppleShape.scaleOf(context),
                  ),
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
    required this.compact,
    required this.tight,
    this.folded = false,
  });
  final Track track;
  final AppState state;
  final Widget artwork;
  final VoidCallback onSaveArtwork;

  /// A short canvas puts the cover beside the metadata instead of above it.
  final bool compact;

  /// A short-ish canvas keeps the metadata set at a tighter size.
  final bool tight;

  /// The reading pane is gone, so the artwork owns the canvas and centres
  /// itself in it — including the short canvas, which would otherwise leave the
  /// cover at the left edge of a centred row.
  final bool folded;

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
  }) {
    // skin: nowPlayingTitleSize / SubtitleSize / MetaSize（0 = 内置档位）
    final LazerThemeTokens skin = LazerThemeTokens.of(context);
    final double titleSize = skin.nowPlayingTitleSize > 0
        ? skin.nowPlayingTitleSize
        : (compact ? 22 : (tight ? 26 : 32));
    final double subtitleSize = skin.nowPlayingSubtitleSize > 0
        ? skin.nowPlayingSubtitleSize
        : (compact ? 12 : (tight ? 14 : 15));
    final double metaSize = skin.nowPlayingMetaSize > 0
        ? skin.nowPlayingMetaSize
        : (compact ? 14 : (tight ? 17 : 19));
    return Column(
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
                      fontSize: titleSize,
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
              style: context.type.bodySmMuted.copyWith(fontSize: subtitleSize),
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
            TextStyle(fontSize: metaSize, color: context.colors.slateDark),
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
  }

  @override
  Widget build(BuildContext context) {
    if (compact) {
      // A short canvas keeps the cover beside the metadata while the lyrics are
      // up. Folded, the reading pane is gone, so the cover takes the middle of
      // the canvas on its own and the metadata reads underneath it.
      if (folded) {
        return Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox.square(
                  dimension: 72,
                  child: RepaintBoundary(child: _cover(context)),
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: _metadata(context, compact: true),
                ),
              ],
            ),
          ),
        );
      }
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
      metadata: _metadata(context, tight: tight),
    );
  }
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
  static const double _bottomInset = kDesktopArtworkBottomInset;

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
    // Keep the artwork group clear of the lower window edge. The desktop dock
    // owns the transport below this render box, but the cover should still
    // have a visible breathing space when the dock is hidden.
    final double availableHeight = math.max(0, size.height - _bottomInset);

    // First measure the metadata at full width, then match it to the artwork.
    // Narrower text may wrap, so recompute the available artwork size once.
    metadata.layout(BoxConstraints(maxWidth: size.width), parentUsesSize: true);
    double artworkSize = math.min(
      size.width,
      math.max(0, availableHeight - _gap - metadata.size.height),
    );
    if (artworkSize < size.width && artworkSize >= 96) {
      metadata.layout(
        BoxConstraints.tightFor(width: artworkSize),
        parentUsesSize: true,
      );
      final double available = math.max(
        0,
        availableHeight - _gap - metadata.size.height,
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
      (availableHeight - artworkSize - _gap - metadata.size.height) / 2,
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
              // The transport repaints ten times a second: both clocks and the
              // seek bar follow the position tick. Without a boundary of its own
              // those repaints climb to the player's outermost layer, which also
              // holds the album canvas, the vignette gradients and the whole
              // artwork column, so a clock tick re-rasterises the entire page.
              // That is affordable at rest and plainly visible while the
              // entrance spring is still moving that same page.
              child: RepaintBoundary(child: widget.child),
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
    this.playPauseFocus,
  });
  final AppState state;
  final bool visible;
  final DesktopNowPlayingPane pane;
  final ValueChanged<DesktopNowPlayingPane> onPaneChanged;
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
          borderRadius: BorderRadius.circular(16 * AppleShape.scaleOf(context)),
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
                              // The tab both shows and folds the reading pane,
                              // so its label states what the tap will do.
                              label: pane == DesktopNowPlayingPane.lyrics
                                  ? '收起歌词'
                                  : '显示歌词',
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
                            if (!largeScreenModeOf(context))
                              // The volume slider now closes the row: the player
                              // no longer offers a fullscreen button (F still
                              // toggles it). It keeps its own bounded width, so
                              // it is placed rather than stretched — a Flexible
                              // would hand it the whole slot and then paint the
                              // slider at the slot's leading edge.
                              VolumeControl(state: state),
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
      borderRadius: BorderRadius.circular(24 * AppleShape.scaleOf(context)),
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
