import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../data/audio_quality.dart';
import '../data/models.dart';
import '../downloads/download_dialog.dart';
import 'player_backdrop.dart';
import '../l10n/app_localizations.dart';
import '../navigation/pull_down_to_close.dart';
import '../state/app_state.dart';
import '../state/song_comments_controller.dart';
import '../state/ui_preferences.dart';
import '../theme/app_palette.dart';
import '../theme/app_theme.dart';
import '../theme/design_tokens.dart';
import '../theme/paper_widgets.dart';
import '../tv/tv_mode.dart';
import '../utils/cover_save.dart';
import '../widgets/accessible_controls.dart';
import '../widgets/animated_notice.dart';
import '../widgets/animated_track_cover.dart';
import '../widgets/catalog_links.dart';
import '../widgets/copyable_song_title.dart';
import '../widgets/interaction_feedback.dart';
import '../widgets/listen_together_dialog.dart';
import '../widgets/lyric_viewport.dart';
import '../widgets/playback_queue_view.dart';
import '../widgets/player_seek_bar.dart';
import '../widgets/playlist_picker_dialog.dart';
import '../widgets/song_comments_view.dart';
import 'desktop_now_playing.dart';
import 'artwork_lyrics_layout.dart';
import '../theme/font_preferences.dart';

/// Shared comments entry from the player header.
Future<void> showSongComments(
  BuildContext context, {
  required AppState state,
  required Track track,
  required SongCommentsController controller,
}) async {
  final bool compact = useCompactLayout(
    state.uiMode,
    MediaQuery.sizeOf(context).width,
  );
  Widget content(BuildContext sheetContext) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 10, 2),
        child: Row(
          children: [
            const Expanded(child: InlineLabel('评论')),
            AccessibleIconButton(
              key: const ValueKey('desktop-panel-close'),
              tooltip: '关闭',
              onPressed: () => Navigator.of(sheetContext).pop(),
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      ),
      Expanded(
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: SongCommentsView(
                state: state,
                track: track,
                controller: controller,
              ),
            ),
            // Fade the wall out instead of cutting it off at the panel edge.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 56,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: <Color>[
                        sheetContext.colors.ivoryLight,
                        sheetContext.colors.ivoryLight.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ],
  );
  if (compact) {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.colors.ivoryLight,
      showDragHandle: true,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .76,
        child: content(sheetContext),
      ),
    );
    return;
  }
  await showDialog<void>(
    context: context,
    barrierColor: context.colors.slateDark.withValues(alpha: .2),
    builder: (dialogContext) => Dialog(
      insetPadding: const EdgeInsets.all(32),
      child: SizedBox(
        width: 620,
        height: MediaQuery.sizeOf(context).height * .76,
        child: content(dialogContext),
      ),
    ),
  );
}

/// Shared queue entry from the player header and desktop transport.
Future<void> showPlaybackQueue(BuildContext context, AppState state) async {
  if (!useCompactLayout(state.uiMode, MediaQuery.sizeOf(context).width)) {
    await showDialog<void>(
      context: context,
      barrierColor: context.colors.slateDark.withValues(alpha: .2),
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(32),
        child: SizedBox(
          width: 580,
          height: MediaQuery.sizeOf(context).height * .76,
          child: PlaybackQueueView(
            state: state,
            onClose: () => Navigator.pop(context),
          ),
        ),
      ),
    );
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.colors.ivoryLight,
    showDragHandle: true,
    builder: (context) => SizedBox(
      height: MediaQuery.sizeOf(context).height * .76,
      child: PlaybackQueueView(
        state: state,
        onClose: () => Navigator.pop(context),
      ),
    ),
  );
}

/// Responsive cover/lyric spread with the same transport order on every size.
class NowPlayingPage extends StatefulWidget {
  const NowPlayingPage({
    super.key,
    required this.state,
    this.onClose,
    this.entranceSettled,
    this.pullDown,
  });

  final AppState state;
  final VoidCallback? onClose;

  /// Flips once the entrance transition has finished. The album flow stays
  /// still until then, and it follows the notifier directly so the whole page
  /// does not rebuild on the frame the entrance lands.
  final ValueListenable<bool>? entranceSettled;

  /// Host of the pull-down dismissal. Only the compact presentation arms the
  /// gesture: it drags the whole page away from the top half of the screen and
  /// needs a host that owns the transition.
  final PlayerPullDown? pullDown;

  @override
  State<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends State<NowPlayingPage> {
  bool _lyricsMode = false;
  bool _controlsVisible = true;
  // Defaults to the non-destructive branch: a semantics-driven tap never
  // passes through onPointerDown, so it must not fold the lyrics away.
  bool _controlsHiddenAtTouchDown = true;
  bool _saving = false;
  bool _selectionOpen = false;
  bool _commentsOpen = false;
  bool _queueOpen = false;
  bool _moreOpen = false;
  bool? _desktopLayout;
  DesktopNowPlayingPane _desktopPane = DesktopNowPlayingPane.lyrics;
  final GlobalKey _backdropKey = GlobalKey();
  late SongCommentsController _commentsController;
  Timer? _hideTimer;
  final Set<int> _activeControlPointers = {};

  void _beginControlPointer(int pointer) {
    _activeControlPointers.add(pointer);
    _hideTimer?.cancel();
  }

  void _endControlPointer(int pointer) {
    _activeControlPointers.remove(pointer);
    _armHide();
  }

  Color? _themeSeed;
  FontPreferences? _themeFonts;
  ThemeData? _cachedPlayerTheme;
  (Color, FontPreferences)? _cachedPlayerThemeKey;

  ThemeData _playerTheme(BuildContext context) {
    final Color accent =
        widget.state.legacyAccentSeed ?? Theme.of(context).colorScheme.primary;
    final key = (accent, widget.state.fontPreferences);
    if (_cachedPlayerThemeKey != key) {
      _cachedPlayerThemeKey = key;
      _cachedPlayerTheme = buildAppTheme(
        brightness: Brightness.dark,
        accent: accent,
        fonts: widget.state.fontPreferences,
      );
    }
    return _cachedPlayerTheme!;
  }

  @override
  void initState() {
    super.initState();
    widget.state.playerPresentationChanged(true);
    _commentsController = SongCommentsController(widget.state.gateway);
    widget.state.addListener(_preferencesChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.state.ensureCurrentLyrics());
    });
  }

  bool get _canAutoHide =>
      _activeControlPointers.isEmpty &&
      !_selectionOpen &&
      !_commentsOpen &&
      !_queueOpen &&
      !_moreOpen &&
      (_desktopLayout == true
          ? _desktopPane == DesktopNowPlayingPane.lyrics
          : _lyricsMode) &&
      !widget.state.lyricsLoading &&
      widget.state.lyrics.isNotEmpty;

  void _preferencesChanged() {
    if (_themeSeed != widget.state.legacyAccentSeed ||
        _themeFonts != widget.state.fontPreferences) {
      _themeSeed = widget.state.legacyAccentSeed;
      _themeFonts = widget.state.fontPreferences;
      if (mounted) setState(() {});
    }
    if (!_canAutoHide && !_controlsVisible) _wakeControls();
    _armHide();
  }

  void _armHide() {
    _hideTimer?.cancel();
    if (!_canAutoHide) return;
    _hideTimer = Timer(
      Duration(
        milliseconds: (widget.state.lyricControlsSeconds * 1000).round(),
      ),
      _hideControls,
    );
  }

  void _selectionChanged(bool active) {
    _selectionOpen = active;
    if (active) {
      _hideTimer?.cancel();
    } else {
      _armHide();
    }
  }

  void _hideControls() {
    if (!mounted) return;
    if (!_canAutoHide) {
      _wakeControls();
      return;
    }
    // Retire floating tooltip nodes before their anchors become invisible.
    // Wait for real animation completion, including on a delayed frame.
    if (Tooltip.dismissAllToolTips()) {
      _hideTimer = Timer(const Duration(milliseconds: 16), _hideControls);
      return;
    }
    setState(() => _controlsVisible = false);
  }

  void _wakeControls() {
    _hideTimer?.cancel();
    if (!_controlsVisible && mounted) setState(() => _controlsVisible = true);
  }

  void _controlsActivity() {
    _wakeControls();
    _armHide();
  }

  // Record the starting mode without waking the controls for lyric or drag
  // gestures. Only a completed background tap changes the presentation.
  void _onTouchDown() {
    _controlsHiddenAtTouchDown = !_controlsVisible;
  }

  /// Return one step only after a completed tap outside the lyric text.
  void _stepBackFromLyrics() {
    if (!_lyricsMode || _selectionOpen) return;
    if (_controlsHiddenAtTouchDown) {
      _wakeControls();
      _armHide();
    } else {
      _toggleLyrics();
    }
  }

  @override
  void dispose() {
    widget.state.playerPresentationChanged(false);
    _hideTimer?.cancel();
    widget.state.removeListener(_preferencesChanged);
    _commentsController.dispose();
    super.dispose();
  }

  void _toggleLyrics() {
    setState(() {
      _lyricsMode = !_lyricsMode;
      if (!_lyricsMode) _selectionOpen = false;
      _controlsVisible = true;
    });
    _armHide();
  }

  Future<void> _queue() async {
    _queueOpen = true;
    _hideTimer?.cancel();
    await showPlaybackQueue(context, widget.state);
    if (!mounted) return;
    _queueOpen = false;
    _wakeControls();
    _armHide();
  }

  void _closePage() {
    final VoidCallback? onClose = widget.onClose;
    if (onClose != null) {
      onClose();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _toggleFullscreen() async {
    try {
      if (await windowManager.isFullScreen()) {
        await windowManager.setFullScreen(false);
      } else {
        await windowManager.setFullScreen(true);
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: TrText('无法切换全屏状态。')));
    }
  }

  Future<void> _openComments() async {
    final track = widget.state.current;
    if (track == null || _commentsOpen) return;
    _commentsOpen = true;
    _hideTimer?.cancel();
    await showSongComments(
      context,
      state: widget.state,
      track: track,
      controller: _commentsController,
    );
    if (!mounted) return;
    _commentsOpen = false;
    _wakeControls();
    _armHide();
  }

  void _selectDesktopPane(DesktopNowPlayingPane pane) {
    if (_desktopPane == pane) {
      _controlsActivity();
      return;
    }
    _hideTimer?.cancel();
    setState(() {
      _desktopPane = pane;
      _selectionOpen = false;
      _controlsVisible = true;
    });
    _armHide();
  }

  @override
  void didUpdateWidget(covariant NowPlayingPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_preferencesChanged);
      widget.state.addListener(_preferencesChanged);
      _commentsController.dispose();
      _commentsController = SongCommentsController(widget.state.gateway);
    }
  }

  /// 移动端整屏歌词：标题固定，正文占满剩余高度。
  Widget _mobileLyrics({bool withArtwork = false}) => LayoutBuilder(
    builder: (context, box) => Padding(
      padding: EdgeInsets.symmetric(
        horizontal: 4,
        vertical: !withArtwork
            ? 16
            : box.maxHeight < 240
            ? 4
            : 12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!withArtwork || box.maxHeight >= 240) ...[
            const InlineLabel('歌词'),
            SizedBox(height: withArtwork ? 12 : AppSpacing.md),
          ],
          Expanded(
            child: _settledGate(
              LyricViewport(
                state: widget.state,
                backdropKey: _backdropKey,
                onSelectionChanged: _selectionChanged,
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Future<void> _saveArtwork(Track track) async {
    if (_saving) return;
    _hideTimer?.cancel();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const TrText('保存封面图片？'),
        content: TrText('将「${track.title}」的封面保存在设备中。'),
        actions: [
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: context.colors.slateDark,
            ),
            onPressed: () => Navigator.pop(context, false),
            child: const TrText('取消'),
          ),
          FilledButton(
            onPressed: track.coverUrl == null
                ? null
                : () => Navigator.pop(context, true),
            child: const TrText('保存'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (confirmed != true) {
      _armHide();
      return;
    }
    setState(() => _saving = true);
    try {
      final saved = await saveCover(track.coverUrl!, track.title);
      if (mounted && saved) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: TrText('封面已保存')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: TrText('保存失败，请检查相册权限或稍后重试。')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
      _armHide();
    }
  }

  /// Holds the lyric engine still until the entrance has landed.
  ///
  /// The lyric canvas is the most expensive painter in the player — one
  /// blurred layer per visible row, all of them re-blurred whenever the words
  /// move — and the entrance slide re-rasterises the whole page on every
  /// frame. Muting its ticker for those 500 ms removes the two costs from the
  /// same frame budget; the rows are already laid out, so nothing jumps when
  /// it resumes. The gate owns the viewport as a plain child, so unmuting
  /// rebuilds one `TickerMode` node instead of the page.
  Widget _settledGate(Widget child) {
    final ValueListenable<bool>? settled = widget.entranceSettled;
    if (settled == null) return child;
    return _EntranceTickerGate(settled: settled, child: child);
  }

  Widget _cover(Track track) => Semantics(
    label: context.tr('歌曲封面，长按保存'),
    child: GestureDetector(
      onTap: () {
        if (useCompactLayout(
          widget.state.uiMode,
          MediaQuery.sizeOf(context).width,
        )) {
          unawaited(widget.state.feedback());
          _toggleLyrics();
        }
      },
      onLongPress: () => unawaited(_saveArtwork(track)),
      child: AspectRatio(
        aspectRatio: 1,
        child: AnimatedContainer(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            boxShadow:
                widget.state.showArtworkWithLyrics &&
                    _lyricsMode &&
                    useCompactLayout(
                      widget.state.uiMode,
                      MediaQuery.sizeOf(context).width,
                    )
                ? const []
                : const [
                    BoxShadow(
                      color: Color(0x66000000),
                      blurRadius: 24,
                      spreadRadius: 1,
                      offset: Offset(0, 8),
                    ),
                  ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: KeyedSubtree(
              key: const ValueKey('legacy-now-playing-cover'),
              child: AnimatedTrackCover(
                track: track,
                direction: widget.state.trackChangeDirection,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  /// The phone header: one row, one action.
  ///
  /// Everything the player can do with the song sits behind [更多] now. Five
  /// icons used to crowd this row and cover the cover with chrome; the back
  /// arrow stays, because leaving the page is not something done to the song.
  Widget _header(bool compact) => IgnorePointer(
    ignoring: compact && !_controlsVisible,
    child: AnimatedOpacity(
      opacity: compact && !_controlsVisible ? 0 : 1,
      curve: Curves.easeOutCubic,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 360),
      child: _headerControls(),
    ),
  );

  Widget _headerControls() => Padding(
    padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
    child: Row(
      children: <Widget>[
        AccessibleIconButton(
          tooltip: '返回',
          onPressed: _closePage,
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
        ),
        const Spacer(),
        if (_saving)
          const Padding(
            padding: EdgeInsets.only(right: 12),
            child: SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        AccessibleIconButton(
          key: const ValueKey('now-playing-more'),
          tooltip: '更多',
          onPressed: () => unawaited(_showMore()),
          icon: const Icon(Icons.more_horiz_rounded),
        ),
      ],
    ),
  );

  /// Opens the song sheet: what the player knows about the track, and every
  /// action the header used to spell out with its own icon.
  Future<void> _showMore() async {
    if (widget.state.current == null || _moreOpen) return;
    _moreOpen = true;
    _hideTimer?.cancel();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.colors.ivoryLight,
      showDragHandle: true,
      builder: (BuildContext sheetContext) => AnimatedBuilder(
        animation: widget.state,
        builder: (BuildContext context, Widget? child) {
          final Track? track = widget.state.current;
          if (track == null) {
            return SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                child: Row(
                  children: <Widget>[
                    const Expanded(child: TrText('没有正在播放的曲目')),
                    AccessibleIconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
            );
          }
          return _NowPlayingMoreSheet(
            state: widget.state,
            track: track,
            lyricsOpen: _lyricsMode,
            onLyrics: () {
              Navigator.of(sheetContext).pop();
              _toggleLyrics();
            },
            onSaveArtwork: () {
              Navigator.of(sheetContext).pop();
              unawaited(_saveArtwork(track));
            },
            onAddToPlaylist: () {
              Navigator.of(sheetContext).pop();
              unawaited(
                showAddToPlaylistDialog(
                  this.context,
                  widget.state,
                  track: track,
                ),
              );
            },
            onDownload: () {
              Navigator.of(sheetContext).pop();
              unawaited(
                downloadTracks(this.context, widget.state, <Track>[track]),
              );
            },
            onComments: () {
              Navigator.of(sheetContext).pop();
              unawaited(_openComments());
            },
            onQueue: () {
              Navigator.of(sheetContext).pop();
              unawaited(_queue());
            },
          );
        },
      ),
    );
    if (!mounted) return;
    _moreOpen = false;
    _wakeControls();
    _armHide();
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: _playerTheme(context),
    child: Scaffold(
      backgroundColor: Colors.black,
      body: AnimatedBuilder(
        animation: widget.state,
        builder: (context, _) {
          final Track? track = widget.state.current;
          return Stack(
            fit: StackFit.expand,
            children: [
              _EntranceGatedBackdrop(
                settled: widget.entranceSettled,
                builder: (bool settled) => AlbumBlurFlow(
                  boundaryKey: _backdropKey,
                  track: track,
                  // The immersive player owns its canvas: browse-page backdrop
                  // settings (including "不使用" or a custom picture) must not
                  // strip the song's album-colour flow from here.
                  mode: widget.state.playerBackground,
                  frameRate: widget.state.playerBackgroundFps == 0
                      ? null
                      : widget.state.playerBackgroundFps,
                  solidColor: widget.state.playerBackgroundColor,
                  imagePath: widget.state.playerBackgroundImagePath,
                  pageColor: Colors.black,
                  animationsEnabled: settled && widget.state.playing,
                  // Reads the live preference: the shell rebuilds this page on
                  // every state report, so dragging the slider is reflected on
                  // the next frame instead of on the next opening.
                  quality: widget.state.playerBackgroundQuality,
                  // The slide re-executes the whole page display list once per
                  // frame; a single gradient instead of the warped mesh keeps
                  // those frames affordable.
                  preview: !settled,
                ),
              ),
              if (track == null)
                _EmptyNowPlaying(onBack: _closePage)
              else
                LayoutBuilder(
                  builder: (context, box) {
                    final bool compact = useCompactLayout(
                      widget.state.uiMode,
                      box.maxWidth,
                    );
                    if (_desktopLayout != !compact) {
                      _desktopLayout = !compact;
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) {
                          _wakeControls();
                          _armHide();
                        }
                      });
                    }
                    if (!compact) {
                      return Stack(
                        fit: StackFit.expand,
                        children: <Widget>[
                          SafeArea(
                            child: DesktopNowPlaying(
                              key: const ValueKey('desktop-now-playing'),
                              state: widget.state,
                              track: track,
                              artwork: _cover(track),
                              lyrics: _settledGate(
                                LyricViewport(
                                  state: widget.state,
                                  backdropKey: _backdropKey,
                                  onSelectionChanged: _selectionChanged,
                                ),
                              ),
                              comments: SongCommentsView(
                                state: widget.state,
                                track: track,
                                controller: _commentsController,
                              ),
                              queue: PlaybackQueueView(
                                state: widget.state,
                                showHeader: false,
                              ),
                              pane: _desktopPane,
                              onPaneChanged: _selectDesktopPane,
                              onBack: _closePage,
                              onSaveArtwork: () =>
                                  unawaited(_saveArtwork(track)),
                              onFullscreen: () =>
                                  unawaited(_toggleFullscreen()),
                              controlsVisible: _controlsVisible,
                              onActivity: _controlsActivity,
                              onPointerStart: _beginControlPointer,
                              onPointerEnd: _endControlPointer,
                            ),
                          ),
                          ?_pullDownLayer(box),
                        ],
                      );
                    }
                    return Listener(
                      behavior: HitTestBehavior.translucent,
                      onPointerDown: (event) {
                        _onTouchDown();
                        _beginControlPointer(event.pointer);
                      },
                      onPointerUp: (event) => _endControlPointer(event.pointer),
                      onPointerCancel: (event) =>
                          _endControlPointer(event.pointer),
                      child: Stack(
                        fit: StackFit.expand,
                        children: <Widget>[
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            excludeFromSemantics: true,
                            onTap: compact && _lyricsMode
                                ? _stepBackFromLyrics
                                : null,
                            child: SafeArea(
                              child: widget.state.showArtworkWithLyrics
                                  ? _mobile(track)
                                  : Column(
                                      children: [
                                        _header(compact),
                                        Expanded(child: _mobile(track)),
                                      ],
                                    ),
                            ),
                          ),
                          ?_pullDownLayer(box),
                        ],
                      ),
                    );
                  },
                ),
            ],
          );
        },
      ),
    ),
  );

  /// A downward drag from anywhere in the upper half pulls the player away.
  ///
  /// Desktop and phone share it: the strip sits above the page content, so its
  /// recognizer answers the gesture arena before the content's own drag
  /// handlers and an upward drag is still left to them, while taps fall
  /// through to the controls behind it.
  Widget? _pullDownLayer(BoxConstraints box) {
    final PlayerPullDown? pullDown = widget.pullDown;
    if (pullDown == null) return null;
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      height: box.maxHeight * .5,
      child: PlayerPullDownRegion(
        pullDown: pullDown,
        travel: box.maxHeight,
        enabled: !_selectionOpen && !_commentsOpen && !_queueOpen && !_moreOpen,
      ),
    );
  }

  Widget _readingPane(Track track) => RepaintBoundary(
    child: AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1).animate(animation),
          child: RepaintBoundary(child: child),
        ),
      ),
      layoutBuilder: (current, previous) => Stack(
        fit: StackFit.expand,
        children: [
          for (final old in previous)
            ExcludeSemantics(child: IgnorePointer(child: old)),
          ?current,
        ],
      ),
      child: _lyricsMode
          ? KeyedSubtree(
              key: const ValueKey('mobile-lyrics'),
              child: _mobileLyrics(),
            )
          : LayoutBuilder(
              key: const ValueKey('mobile-cover'),
              builder: (context, box) => Center(
                child: SizedBox.square(
                  dimension: (box.maxHeight - 16).clamp(
                    0,
                    box.maxWidth.clamp(0, 380),
                  ),
                  child: _cover(track),
                ),
              ),
            ),
    ),
  );

  Widget _mobile(Track track) {
    final size = MediaQuery.sizeOf(context);
    final visible = !_lyricsMode || _controlsVisible;
    if (widget.state.showArtworkWithLyrics) {
      return ArtworkLyricsLayout(
        lyricsVisible: _lyricsMode,
        controlsVisible: visible,
        header: _headerControls(),
        summary: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
          child: PlayerTrackSummary(
            key: const ValueKey('compact-player-summary'),
            track: track,
            onTap: _controlsActivity,
          ),
        ),
        artwork: _cover(track),
        lyrics: _mobileLyrics(withArtwork: true),
        details: SingleChildScrollView(
          child: _ArtworkTrackDetails(track: track, state: widget.state),
        ),
        transport: SingleChildScrollView(
          child: _PlaybackTransport(
            track: track,
            state: widget.state,
            edgeToEdge: true,
          ),
        ),
      );
    }
    if (size.height < 500 && size.width > size.height) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: LayoutBuilder(
          builder: (context, box) => Row(
            children: [
              Expanded(child: _readingPane(track)),
              IgnorePointer(
                ignoring: !visible,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 360),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) => SizeTransition(
                    axis: Axis.horizontal,
                    sizeFactor: animation,
                    child: FadeTransition(opacity: animation, child: child),
                  ),
                  child: !visible
                      ? const SizedBox.shrink(key: ValueKey('hidden'))
                      : SizedBox(
                          key: const ValueKey('controls'),
                          width: (box.maxWidth * 0.6).clamp(280, 400),
                          child: Padding(
                            padding: const EdgeInsets.only(left: 20),
                            child: Column(
                              children: [
                                Expanded(
                                  child: SingleChildScrollView(
                                    child: _TrackDetails(
                                      track: track,
                                      state: widget.state,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                _PlaybackTransport(
                                  track: track,
                                  state: widget.state,
                                ),
                              ],
                            ),
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
      child: Column(
        children: [
          Expanded(child: _readingPane(track)),
          IgnorePointer(
            ignoring: !visible,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 360),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) => SizeTransition(
                sizeFactor: animation,
                child: FadeTransition(opacity: animation, child: child),
              ),
              child: visible
                  ? Padding(
                      key: const ValueKey('controls'),
                      padding: const EdgeInsets.only(top: 16),
                      child: _TrackInfo(track: track, state: widget.state),
                    )
                  : const SizedBox.shrink(key: ValueKey('hidden')),
            ),
          ),
        ],
      ),
    );
  }
}

/// A compact metadata row leaves the whole text column aligned with the cover.
/// Secondary actions stay in More rather than squeezing the song title.
class _ArtworkTrackDetails extends StatelessWidget {
  const _ArtworkTrackDetails({required this.track, required this.state});
  final Track track;
  final AppState state;

  @override
  Widget build(BuildContext context) => Row(
    key: const ValueKey('artwork-track-details'),
    children: [
      Expanded(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CopyableSongTitle(
              title: track.title,
              child: Text(
                track.title,
                key: const ValueKey('artwork-track-title'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.fonts.apply(
                  FontCategory.playerTitle,
                  const TextStyle(
                    fontFamily: AppFonts.sans,
                    fontSize: 21,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 5),
            ArtistNameLink(
              key: const ValueKey('artwork-track-artist'),
              state: state,
              artists: track.artists,
              fallback: track.artist,
              style: context.fonts.apply(
                FontCategory.playerArtist,
                const TextStyle(
                  fontFamily: AppFonts.sans,
                  fontSize: 16,
                  height: 1.2,
                  color: Color(0xCCFFFFFF),
                ),
              ),
            ),
            if (state.likeError != null)
              TrText(
                state.likeError!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.type.caption.copyWith(
                  color: context.colors.clayDeep,
                ),
              ),
          ],
        ),
      ),
      const SizedBox(width: 4),
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
  );
}

class _TrackInfo extends StatelessWidget {
  const _TrackInfo({required this.track, required this.state});
  final Track track;
  final AppState state;
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _TrackDetails(track: track, state: state),
      const SizedBox(height: 16),
      _PlaybackTransport(track: track, state: state),
    ],
  );
}

class _TrackDetails extends StatelessWidget {
  const _TrackDetails({required this.track, required this.state});
  final Track track;
  final AppState state;
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            child: CopyableSongTitle(
              title: track.title,
              child: Text(
                track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.fonts.apply(
                  FontCategory.playerTitle,
                  const TextStyle(
                    fontFamily: AppFonts.sans,
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
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
      if (track.translatedTitle?.isNotEmpty ?? false) ...[
        const SizedBox(height: 4),
        Text(
          track.translatedTitle!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.type.bodySm.copyWith(
            fontSize: 15,
            color: context.colors.cloudDark,
          ),
        ),
      ],
      const SizedBox(height: 4),
      DefaultTextStyle(
        style: context.fonts.apply(
          FontCategory.playerArtist,
          TextStyle(
            fontFamily: AppFonts.sans,
            fontSize: 17,
            color: context.colors.cloudDark,
          ),
        ),
        child: Row(
          children: [
            Flexible(
              child: ArtistNameLink(
                state: state,
                artists: track.artists,
                fallback: track.artist,
              ),
            ),
            if (track.album.isNotEmpty) ...[
              const Text(' · '),
              Flexible(
                child: AlbumNameLink(state: state, track: track),
              ),
            ],
          ],
        ),
      ),
      if (state.likeError != null) ...[
        const SizedBox(height: AppSpacing.sm),
        TrText(
          state.likeError!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.type.caption.copyWith(color: context.colors.clayDeep),
        ),
      ],
    ],
  );
}

class _PlaybackTransport extends StatelessWidget {
  const _PlaybackTransport({
    required this.track,
    required this.state,
    this.edgeToEdge = false,
  });
  final Track track;
  final AppState state;
  final bool edgeToEdge;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(16),
    child: DecoratedBox(
      decoration: const BoxDecoration(color: Colors.transparent),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: edgeToEdge ? 0 : 12,
          vertical: edgeToEdge ? 4 : 12,
        ),
        child: Column(
          key: const ValueKey('now-playing-transport'),
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedNotice(
              message: state.playbackError,
              onDismiss: state.clearPlaybackError,
            ),
            PlayerSeekBar(state: state),
            SizedBox(height: edgeToEdge ? 0 : AppSpacing.sm),
            // Time labels ride the tick lane so position updates never rebuild
            // the whole page.
            AnimatedBuilder(
              animation: state.all,
              builder: (BuildContext context, _) => Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(fmt(state.precisePosition), style: context.type.monoSm),
                  Text(fmt(track.duration), style: context.type.monoSm),
                ],
              ),
            ),
            SizedBox(height: edgeToEdge ? 8 : 12),
            // Fill the rail width so the last control has no trailing empty slab.
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _ControlIcon(
                  icon: state.shuffle
                      ? Icons.shuffle_on_rounded
                      : Icons.shuffle_rounded,
                  active: state.shuffle,
                  tooltip: '随机播放',
                  onTap: state.toggleShuffle,
                ),
                _ControlIcon(
                  icon: Icons.skip_previous_rounded,
                  size: 34,
                  tooltip: '上一首',
                  onTap: state.previous,
                ),
                _BigPlayPause(playing: state.playing, onTap: state.togglePlay),
                _ControlIcon(
                  icon: Icons.skip_next_rounded,
                  size: 34,
                  tooltip: '下一首',
                  onTap: state.next,
                ),
                _ControlIcon(
                  icon: state.repeat == LoopMode.one
                      ? Icons.repeat_one_on_rounded
                      : Icons.repeat_rounded,
                  active: state.repeat != LoopMode.off,
                  tooltip: '循环播放',
                  onTap: state.cycleRepeat,
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _ControlIcon extends StatefulWidget {
  const _ControlIcon({
    required this.icon,
    required this.onTap,
    this.active = false,
    this.tooltip,
    this.size = 26,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final bool active;
  final String? tooltip;
  final double size;

  @override
  State<_ControlIcon> createState() => _ControlIconState();
}

class _ControlIconState extends State<_ControlIcon> {
  bool _hovering = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.onTap != null;
    final bool highlighted = _hovering || _focused;
    final Color color = !enabled
        ? context.colors.cloudMedium
        : widget.active || highlighted
        ? context.colors.slateDark
        : context.colors.cloudDark;
    final Widget btn = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: TvTapTarget(
        onTap: widget.onTap,
        enabled: enabled,
        onFocusChange: (bool value) => setState(() => _focused = value),
        borderRadius: BorderRadius.circular(24),
        focusScale: 1.1,
        child: GestureDetector(
          onTap: feedbackAction(context, widget.onTap),
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: Icon(widget.icon, size: widget.size, color: color),
            ),
          ),
        ),
      ),
    );
    return widget.tooltip == null
        ? btn
        : AccessibleTooltip(message: widget.tooltip!, child: btn);
  }
}

class _BigPlayPause extends StatelessWidget {
  const _BigPlayPause({required this.playing, required this.onTap});

  final bool playing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => AccessibleIconButton(
    key: const ValueKey('now-playing-play'),
    tooltip: playing ? '暂停' : '播放',
    onPressed: onTap,
    iconSize: 38,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints.tightFor(width: 68, height: 68),
    color: context.colors.onPlayer,
    style: IconButton.styleFrom(
      backgroundColor: Colors.transparent,
      foregroundColor: context.colors.onPlayer,
      hoverColor: Colors.transparent,
      highlightColor: Colors.transparent,
      minimumSize: const Size(68, 68),
      shape: const CircleBorder(),
    ),
    icon: AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: Icon(
        playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
        key: ValueKey(playing),
        size: 38,
      ),
    ),
  );
}

/// What sits behind [更多]: the song's details on top, every action the phone
/// header used to spell out with its own icon underneath.
///
/// The sheet is the one place that can grow without stealing room from the
/// artwork, so it is also where the player finally says what it knows about
/// the track — album, length, the tier it is streaming at, and whether it is
/// reading a file or the service.
class _NowPlayingMoreSheet extends StatelessWidget {
  const _NowPlayingMoreSheet({
    required this.state,
    required this.track,
    required this.lyricsOpen,
    required this.onLyrics,
    required this.onSaveArtwork,
    required this.onAddToPlaylist,
    required this.onDownload,
    required this.onComments,
    required this.onQueue,
  });

  final AppState state;
  final Track track;
  final bool lyricsOpen;
  final VoidCallback onLyrics;
  final VoidCallback onSaveArtwork;
  final VoidCallback onAddToPlaylist;
  final VoidCallback onDownload;
  final VoidCallback onComments;
  final VoidCallback onQueue;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Expanded(child: InlineLabel('歌曲详情')),
                  AccessibleIconButton(
                    key: const ValueKey('now-playing-more-close'),
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox.square(
                      dimension: 64,
                      child: AnimatedTrackCover(
                        track: track,
                        direction: state.trackChangeDirection,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          track.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: context.type.subheading,
                        ),
                        if (track.translatedTitle?.isNotEmpty ?? false) ...[
                          const SizedBox(height: 2),
                          Text(
                            track.translatedTitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.type.bodySm.copyWith(
                              color: context.colors.cloudDark,
                            ),
                          ),
                        ],
                        const SizedBox(height: 4),
                        Text(
                          track.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.type.bodySm.copyWith(
                            color: context.colors.cloudDark,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              _DetailLine(
                label: context.tr('专辑'),
                value: track.album.isEmpty ? '—' : track.album,
              ),
              _DetailLine(label: context.tr('时长'), value: fmt(track.duration)),
              _DetailLine(
                label: context.tr('音质'),
                value: context.tr(state.playbackQuality.label),
              ),
              _DetailLine(
                label: context.tr('来源'),
                value: track.localPath == null
                    ? context.tr('在线播放')
                    : context.tr('本地文件'),
              ),
              const SizedBox(height: 10),
              Divider(height: 1, color: context.colors.stone),
              const SizedBox(height: 2),
              _MoreAction(
                icon: Icons.lyrics_outlined,
                label: context.tr('歌词'),
                selected: lyricsOpen,
                onTap: onLyrics,
              ),
              if (state.showArtworkWithLyrics)
                _MoreAction(
                  icon: Icons.group_rounded,
                  label: context.tr('一起听'),
                  onTap: () =>
                      unawaited(showListenTogetherDialog(context, state)),
                ),
              _MoreAction(
                icon: Icons.save_alt_rounded,
                label: context.tr('保存封面'),
                onTap: onSaveArtwork,
              ),
              _MoreAction(
                icon: Icons.playlist_add_rounded,
                label: context.tr('添加到歌单'),
                onTap: onAddToPlaylist,
              ),
              _MoreAction(
                icon: Icons.download_rounded,
                label: context.tr('下载歌曲'),
                onTap: onDownload,
              ),
              _MoreAction(
                icon: Icons.chat_bubble_outline_rounded,
                label: context.tr('查看评论'),
                onTap: onComments,
              ),
              _MoreAction(
                icon: Icons.queue_music_rounded,
                label: context.tr('播放队列'),
                onTap: onQueue,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// One labelled fact about the track: a quiet caption and its value.
class _DetailLine extends StatelessWidget {
  const _DetailLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 68,
          child: Text(
            label,
            style: context.type.bodySm.copyWith(
              color: context.colors.cloudMedium,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: context.type.bodySm,
          ),
        ),
      ],
    ),
  );
}

/// A row of the sheet's action list; the selected one carries a check so the
/// lyrics toggle reads as a state, not as a one-shot command.
class _MoreAction extends StatelessWidget {
  const _MoreAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final Color color = onTap == null
        ? context.colors.cloudMedium
        : selected
        ? context.colors.clayDeep
        : context.colors.slateDark;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 13),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 22, color: color),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: context.type.body.copyWith(color: color),
              ),
            ),
            if (selected)
              Icon(
                Icons.check_rounded,
                size: 18,
                color: context.colors.clayDeep,
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyNowPlaying extends StatelessWidget {
  const _EmptyNowPlaying({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TrText('没有正在播放的曲目', style: context.type.subheading),
          const SizedBox(height: AppSpacing.sm),
          TrText(
            '回到曲库，翻开一页吧。',
            style: context.type.bodyMuted.copyWith(fontSize: 16),
          ),
          const SizedBox(height: AppSpacing.lg),
          IvoryButton(label: '返回', onPressed: onBack),
        ],
      ),
    );
  }
}

/// Mutes its subtree's tickers until [settled] reports true.
///
/// Same shape as [_EntranceGatedBackdrop]: the child is built once and handed
/// in, so flipping the flag rebuilds this node and nothing below it.
class _EntranceTickerGate extends StatelessWidget {
  const _EntranceTickerGate({required this.settled, required this.child});

  final ValueListenable<bool> settled;
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: settled,
    builder: (BuildContext context, bool value, Widget? child) =>
        TickerMode(enabled: value, child: child!),
    child: child,
  );
}

/// Rebuilds only the backdrop when the entrance settles.
///
/// Handing the page a plain bool would rebuild the whole player — header,
/// artwork, lyrics, transport — on the frame the entrance lands, which is a
/// visible hitch right at the end of the open animation.
class _EntranceGatedBackdrop extends StatelessWidget {
  const _EntranceGatedBackdrop({required this.settled, required this.builder});

  final ValueListenable<bool>? settled;
  final Widget Function(bool settled) builder;

  @override
  Widget build(BuildContext context) {
    final ValueListenable<bool>? listenable = settled;
    if (listenable == null) return builder(true);
    return ValueListenableBuilder<bool>(
      valueListenable: listenable,
      builder: (BuildContext context, bool value, Widget? _) => builder(value),
    );
  }
}
