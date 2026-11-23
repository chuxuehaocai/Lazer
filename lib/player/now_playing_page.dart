import '../gateway/music_models.dart';
import '../widgets/build_safe_state.dart';
import '../animation/apple_spring.dart';
import '../widgets/spring_buttons.dart';
import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../animation/apple_modal.dart';
import 'package:window_manager/window_manager.dart';

import '../data/models.dart';
import '../downloads/download_dialog.dart';
import '../plugins/plugin_extensions.dart';
import 'player_backdrop.dart';
import '../l10n/app_localizations.dart';
import '../navigation/pull_down_to_close.dart';
import '../state/app_state.dart';
import '../state/media_shortcuts.dart';
import '../state/song_comments_controller.dart';
import '../state/ui_preferences.dart';
import '../theme/app_palette.dart';
import '../theme/apple_design.dart';
import '../theme/design_tokens.dart';
import '../theme/paper_widgets.dart';
import '../tv/tv_mode.dart';
import '../utils/cover_save.dart';
import '../widgets/accessible_controls.dart';
import '../widgets/animated_notice.dart';
import '../widgets/animated_track_cover.dart';
import '../widgets/catalog_links.dart';
import '../widgets/windows_backdrop.dart';
import '../widgets/copyable_song_title.dart';
import '../widgets/interaction_feedback.dart';
import '../widgets/listen_together_dialog.dart';
import '../widgets/lyric_viewport.dart';
import '../widgets/playback_queue_view.dart';
import '../widgets/player_seek_bar.dart';
import '../widgets/playlist_picker_dialog.dart';
import '../widgets/song_comments_view.dart';
import '../widgets/window_chrome.dart';
import 'desktop_now_playing.dart';
import 'artwork_lyrics_layout.dart';
import '../theme/font_preferences.dart';
import 'osu_search.dart';

typedef _PlayerSheetAction = FutureOr<void> Function();

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
    layoutStyle: state.layoutStyle,
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
    await showAppleModalBottomSheet<void>(
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
  await showAppleDialog<void>(
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
  if (!useCompactLayout(
    state.uiMode,
    MediaQuery.sizeOf(context).width,
    layoutStyle: state.layoutStyle,
  )) {
    await showAppleDialog<void>(
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
  await showAppleModalBottomSheet<void>(
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
    this.presentationActive,
    this.pullDown,
  });

  final AppState state;
  final VoidCallback? onClose;

  /// Flips once the entrance transition has finished. The album flow stays
  /// still until then, and it follows the notifier directly so the whole page
  /// does not rebuild on the frame the entrance lands.
  final ValueListenable<bool>? entranceSettled;

  /// The host marks a committed dismissal before the page leaves the tree.
  /// Drag previews keep this active so cancellation preserves the chrome.
  final ValueListenable<bool>? presentationActive;

  /// Host of the pull-down dismissal. Only the compact presentation arms the
  /// gesture: it drags the whole page away from the top half of the screen and
  /// needs a host that owns the transition.
  final PlayerPullDown? pullDown;

  @override
  State<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends State<NowPlayingPage>
    with WidgetsBindingObserver, BuildSafeState<NowPlayingPage> {
  bool _lyricsMode = false;
  final ValueNotifier<bool> _controlsVisibility = ValueNotifier(true);
  final ValueNotifier<bool> _mobileLyricSeeking = ValueNotifier(false);
  bool _mobileControlsHidden = false;
  bool get _controlsVisible => _controlsVisibility.value;
  WindowChromeController? _windowChrome;
  // Defaults to the non-destructive branch: a semantics-driven tap never
  // passes through onPointerDown, so it must not fold the lyrics away.
  bool _controlsHiddenAtTouchDown = true;
  bool _saving = false;
  bool _artworkActionOpen = false;
  bool _selectionOpen = false;
  String? _selectionTrackId;
  bool _foreground = true;
  bool _commentsOpen = false;
  bool _queueOpen = false;
  bool _moreOpen = false;
  bool? _desktopLayout;
  DesktopNowPlayingPane _desktopPane = DesktopNowPlayingPane.lyrics;
  final GlobalKey _backdropKey = GlobalKey();
  final FocusNode _playPauseFocus = FocusNode(debugLabel: 'player-play-pause');
  late SongCommentsController _commentsController;
  Timer? _hideTimer;
  final Set<int> _activeControlPointers = {};

  /// The desktop canvas children, kept across playback reports.
  ///
  /// The page listens to [AppState], so every structural report — play state,
  /// queue, lyric loads, artwork, downloads, account updates — rebuilds the
  /// whole desktop canvas. Handing the reading pane, the comments wall, the
  /// queue and the artwork to that rebuild as fresh widget instances made each
  /// of those reports re-enter their layout, and the lyric sheet in particular
  /// is the heaviest child on the page. All four already follow [AppState]
  /// through their own listeners, so a report only has to hand the same
  /// instances back; only a new song, new artwork or another state object
  /// builds them again. Opening the player produces exactly that burst (a lyric
  /// sheet landing, the artwork provider changing), on the frames the entrance
  /// spring is trying to move.
  Object? _desktopPaneKey;
  Widget? _desktopLyrics;
  Widget? _desktopComments;
  Widget? _desktopQueue;
  Widget? _desktopArtwork;

  /// Rebuilds the desktop canvas children when anything they are built from
  /// changed, and leaves them alone for every other report.
  void _buildDesktopPane(Track track) {
    final Object key = (
      track.id,
      track.coverUrl,
      widget.state.currentArtwork.providerFor(track),
      widget.state.trackChangeDirection,
      _commentsController,
    );
    if (_desktopPaneKey == key) return;
    _desktopPaneKey = key;
    _desktopLyrics = _settledGate(
      LyricViewport(
        key: ValueKey<String>('desktop-lyrics-${track.id}'),
        state: widget.state,
        backdropKey: _backdropKey,
        onSelectionChanged: (active) => _selectionChanged(track.id, active),
      ),
    );
    _desktopComments = SongCommentsView(
      state: widget.state,
      track: track,
      controller: _commentsController,
    );
    _desktopQueue = PlaybackQueueView(state: widget.state, showHeader: false);
    _desktopArtwork = _cover(track);
  }

  /// Whether the idle countdown is currently waiting to hide the controls.
  ///
  /// Read from the live timer instead of a remembered flag: the flag used to
  /// disagree with the timer whenever a pending hide was consumed while hiding
  /// was not allowed, and nothing re-armed the countdown afterwards.
  bool get _hidePending => _hideTimer?.isActive ?? false;

  void _beginControlPointer(int pointer) {
    _activeControlPointers.add(pointer);
    _hideTimer?.cancel();
  }

  void _endControlPointer(int pointer) {
    if (!_activeControlPointers.remove(pointer)) return;
    _armHide();
  }

  /// Retires holds whose pointer-up was consumed outside this view.
  ///
  /// An OS window drag ends inside the platform's move loop, so a press that
  /// started one never reports its release here. Clearing the hold lets the
  /// countdown start again instead of keeping the dock awake indefinitely.
  void _releaseControlPointers() {
    _activeControlPointers.clear();
    if (_controlsVisible) _armHide();
  }

  Color? _themeSeed;
  FontPreferences? _themeFonts;
  ThemeData? _cachedPlayerTheme;
  (Color, FontPreferences, bool)? _cachedPlayerThemeKey;

  ThemeData _playerTheme(BuildContext context) {
    final Color accent =
        widget.state.accentSeed ?? Theme.of(context).colorScheme.primary;
    final bool compact =
        !largeScreenModeOf(context) &&
        useCompactLayout(
          widget.state.uiMode,
          MediaQuery.sizeOf(context).width,
          layoutStyle: widget.state.layoutStyle,
        );
    final key = (accent, widget.state.fontPreferences, compact);
    if (_cachedPlayerThemeKey != key) {
      _cachedPlayerThemeKey = key;
      _cachedPlayerTheme = buildAppleTheme(
        brightness: Brightness.dark,
        seedAccent: accent,
        fonts: widget.state.fontPreferences,
        compact: compact,
      );
    }
    return _cachedPlayerTheme!;
  }

  @override
  void initState() {
    super.initState();
    _controlsVisibility.addListener(_syncMobileLyricSeeking);
    WidgetsBinding.instance.addObserver(this);
    widget.state.playerPresentationChanged(true);
    _commentsController = SongCommentsController(
      widget.state.catalog.connections,
    );
    widget.state.addListener(_preferencesChanged);
    widget.presentationActive?.addListener(_syncWindowChromePresentation);
    _armLyricsRequest();
  }

  /// A last resort for [NowPlayingPage.entranceSettled] never flipping.
  ///
  /// The gate below only exists to keep the fetch off the entrance frames. A
  /// page whose host never reports settling must still end up with its sheet,
  /// so the wait has a ceiling instead of becoming a permanent condition.
  static const Duration _lyricsGateFallback = Duration(milliseconds: 1200);
  Timer? _lyricsGate;

  /// Loads the current sheet once the entrance has landed.
  ///
  /// The reply resolves on this isolate: the sheet is parsed, kept, and then
  /// reported through [AppState.notifyListeners], which rebuilds this page and
  /// lays the lyric rows out once more. Asking for it from the first post-frame
  /// callback put that burst in the middle of the entrance spring, on the same
  /// frames that were already moving the whole page. Waiting for the settled
  /// notifier costs nothing in the normal case, because the request starts when
  /// a track is selected and this call is then a no-op.
  void _armLyricsRequest() {
    final ValueListenable<bool>? settled = widget.entranceSettled;
    if (settled == null || settled.value) {
      _requestLyrics();
      return;
    }
    settled.addListener(_lyricsWhenSettled);
    _lyricsGate = Timer(_lyricsGateFallback, _releaseLyricsGate);
  }

  void _lyricsWhenSettled() {
    if (widget.entranceSettled?.value != true) return;
    _releaseLyricsGate();
  }

  void _releaseLyricsGate() {
    _lyricsGate?.cancel();
    _lyricsGate = null;
    widget.entranceSettled?.removeListener(_lyricsWhenSettled);
    _requestLyrics();
  }

  void _requestLyrics() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.state.ensureCurrentLyrics());
    });
  }

  /// Whether the idle countdown may hide the transport right now.
  ///
  /// A paused desktop player is still an idle one: the dock leaves the canvas
  /// and a click on the canvas restores it, exactly as it does during playback.
  /// The compact presentation keeps its transport while paused, because a
  /// touch player has no free "click anywhere" wake — the small summary is its
  /// only way back, and losing the transport there reads as a dead screen. A
  /// playback error is the exception on both: retry and output selection live
  /// in the transport, so it stays reachable until the error clears.
  bool get _idleAllowsHide => _desktopLayout == true || widget.state.playing;

  bool get _canAutoHide =>
      _foreground &&
      (widget.presentationActive?.value ?? true) &&
      !TvScope.isActive(context) &&
      _idleAllowsHide &&
      widget.state.playbackError == null &&
      _activeControlPointers.isEmpty &&
      !_selectionOpen &&
      !_commentsOpen &&
      !_queueOpen &&
      !_moreOpen &&
      !_artworkActionOpen &&
      (_desktopLayout == true
          ? _desktopPane == DesktopNowPlayingPane.lyrics
          : _lyricsMode) &&
      !widget.state.lyricsLoading &&
      widget.state.lyrics.isNotEmpty;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final WindowChromeController? chrome = WindowChromeScope.maybeOf(context);
    if (chrome == _windowChrome) return;
    _windowChrome?.detach(_controlsVisibility);
    _windowChrome = chrome;
    _syncWindowChromePresentation();
  }

  void _syncWindowChromePresentation() {
    if (!(widget.presentationActive?.value ?? true)) {
      _windowChrome?.detach(_controlsVisibility);
      return;
    }
    _windowChrome?.attach(
      _controlsVisibility,
      onActivity: _controlsActivity,
      onPointerStart: _beginControlPointer,
      onPointerEnd: _endControlPointer,
      onPointerRelease: _releaseControlPointers,
    );
    // Re-attaching follows a presentation that was briefly inactive. The
    // countdown that ran while it was inactive may already be gone, and
    // nothing else would start another one.
    _armHideIfIdle();
  }

  void _preferencesChanged() {
    // A new song replaces the keyed viewport. Its disposed selection must
    // never keep the new song's background taps and pull-down locked.
    if (_selectionOpen && _selectionTrackId != widget.state.current?.id) {
      setState(() {
        _selectionOpen = false;
        _selectionTrackId = null;
      });
    }
    if (_themeSeed != widget.state.accentSeed ||
        _themeFonts != widget.state.fontPreferences) {
      _themeSeed = widget.state.accentSeed;
      _themeFonts = widget.state.fontPreferences;
      if (mounted) setState(() {});
    }
    // The app state notifies on every playback tick. Re-arming the hide timer
    // from here used to cancel and allocate a Timer for each of those
    // notifications — tens per second for as long as the player was open — and
    // it also restarted the countdown, so the controls never hid during
    // playback. Touching the timer only when its state is actually wrong keeps
    // that cost away and still recovers every countdown that was consumed.
    _reconcileCountdown();
  }

  /// Keeps the idle countdown consistent with the page's current state.
  ///
  /// The previous version only reacted to the "may hide" transition, so a
  /// countdown that expired while hiding was not allowed — a lyric reload, an
  /// open sheet, a pointer the platform still owned after a window drag, or a
  /// briefly inactive presentation — was simply gone and never started again,
  /// which left the dock on screen until the next gesture re-armed it. Reading
  /// the live timer makes each of those paths heal on the next notification.
  void _reconcileCountdown() {
    if (!_canAutoHide) {
      if (_hidePending) {
        _hideTimer!.cancel();
        _hideTimer = null;
      }
      if (!_controlsVisible) _wakeControls();
      return;
    }
    _armHideIfIdle();
  }

  /// Starts the countdown when the controls are visible and nothing is
  /// counting down. Allocation-free while the timer is already pending, so the
  /// playback ticks stay cheap.
  void _armHideIfIdle() {
    if (!_controlsVisible || _hidePending) return;
    _armHide();
  }

  void _armHide() {
    _hideTimer?.cancel();
    _hideTimer = null;
    if (!_canAutoHide) return;
    _hideTimer = Timer(
      Duration(
        milliseconds: (widget.state.lyricControlsSeconds * 1000).round(),
      ),
      _hideControls,
    );
  }

  void _selectionChanged(String? trackId, bool active) {
    if (!mounted || trackId != widget.state.current?.id) return;
    if (_selectionOpen == active) return;
    setState(() {
      _selectionOpen = active;
      _selectionTrackId = active ? trackId : null;
    });
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
    setState(() => _controlsVisibility.value = false);
  }

  void _syncMobileLyricSeeking() {
    _mobileLyricSeeking.value = !_controlsVisible && _mobileControlsHidden;
  }

  void _mobileControlsHiddenChanged(bool hidden) {
    _mobileControlsHidden = hidden;
    _syncMobileLyricSeeking();
  }

  void _wakeControls() {
    _hideTimer?.cancel();
    if (!_controlsVisible && mounted) {
      setState(() => _controlsVisibility.value = true);
    }
  }

  void _controlsActivity() {
    _wakeControls();
    _armHide();
  }

  // Record the starting mode without waking the controls for lyric or drag
  // gestures. Only a completed background tap changes the presentation.
  void _onTouchDown() {
    if (_activeControlPointers.isEmpty) {
      _controlsHiddenAtTouchDown = !_controlsVisible;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    // An interrupted touch is not guaranteed to deliver its final pointer
    // event. Retire those holds so the next interaction can hide normally.
    _activeControlPointers.clear();
    _controlsHiddenAtTouchDown = true;
    _wakeControls();
    _armHide();
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
    WidgetsBinding.instance.removeObserver(this);
    _lyricsGate?.cancel();
    _lyricsGate = null;
    widget.entranceSettled?.removeListener(_lyricsWhenSettled);
    widget.presentationActive?.removeListener(_syncWindowChromePresentation);
    _windowChrome?.detach(_controlsVisibility);
    _controlsVisibility.dispose();
    _mobileLyricSeeking.dispose();
    _playPauseFocus.dispose();
    widget.state.playerPresentationChanged(false);
    _hideTimer?.cancel();
    widget.state.removeListener(_preferencesChanged);
    _commentsController.dispose();
    super.dispose();
  }

  void _toggleLyrics() {
    setState(() {
      _lyricsMode = !_lyricsMode;
      if (!_lyricsMode) {
        _selectionOpen = false;
        _selectionTrackId = null;
      }
      _controlsVisibility.value = true;
    });
    _armHide();
  }

  Future<void> _queue() async {
    if (_queueOpen) return;
    _queueOpen = true;
    _hideTimer?.cancel();
    try {
      await showPlaybackQueue(context, widget.state);
    } finally {
      _queueOpen = false;
      if (mounted) _controlsActivity();
    }
  }

  Future<void> _showSleepTimer() async {
    _hideTimer?.cancel();
    final Duration? duration = await showAppleModalBottomSheet<Duration>(
      context: context,
      backgroundColor: context.colors.ivoryLight,
      showDragHandle: true,
      builder: (BuildContext sheetContext) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const InlineLabel('睡眠定时'),
              const SizedBox(height: 8),
              const TrText('结束后暂停播放并释放音频焦点，移除播放器前台通知。'),
              const SizedBox(height: 8),
              for (final Duration value in const <Duration>[
                Duration(minutes: 15),
                Duration(minutes: 30),
                Duration(hours: 1),
                Duration(hours: 2),
              ])
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.schedule_rounded),
                  title: Text(_sleepTimerLabel(value)),
                  onTap: () => Navigator.of(sheetContext).pop(value),
                ),
              if (widget.state.sleepTimerActive)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.close_rounded),
                  title: const TrText('取消睡眠定时'),
                  onTap: () => Navigator.of(sheetContext).pop(Duration.zero),
                ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || duration == null) return;
    if (duration == Duration.zero) {
      widget.state.cancelSleepTimer();
    } else {
      widget.state.startSleepTimer(duration);
    }
  }

  void _closePage() {
    _windowChrome?.detach(_controlsVisibility);
    _wakeControls();
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
    if (track == null ||
        !widget.state.supportsCurrentMusic(MusicCapability.comments) ||
        _commentsOpen) {
      return;
    }
    _commentsOpen = true;
    _hideTimer?.cancel();
    try {
      await showSongComments(
        context,
        state: widget.state,
        track: track,
        controller: _commentsController,
      );
    } finally {
      _commentsOpen = false;
      if (mounted) _controlsActivity();
    }
  }

  void _selectDesktopPane(DesktopNowPlayingPane pane) {
    final bool unavailable =
        pane == DesktopNowPlayingPane.comments &&
        !widget.state.supportsCurrentMusic(MusicCapability.comments);
    if (unavailable) pane = DesktopNowPlayingPane.lyrics;
    // The reading pane's own tab folds it away: the artwork takes the middle of
    // the canvas, and the same tab (or L) brings the lyrics back. Nothing else
    // in the dock needs a second control for it, and a platform without comments
    // must not fold the lyrics just because it fell back to them.
    if (!unavailable &&
        pane == DesktopNowPlayingPane.lyrics &&
        _desktopPane == DesktopNowPlayingPane.lyrics) {
      pane = DesktopNowPlayingPane.none;
    }
    if (_desktopPane == pane) {
      _controlsActivity();
      return;
    }
    _hideTimer?.cancel();
    setState(() {
      _desktopPane = pane;
      _selectionOpen = false;
      _controlsVisibility.value = true;
    });
    _armHide();
  }

  @override
  void didUpdateWidget(covariant NowPlayingPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.presentationActive != widget.presentationActive) {
      oldWidget.presentationActive?.removeListener(
        _syncWindowChromePresentation,
      );
      widget.presentationActive?.addListener(_syncWindowChromePresentation);
      _syncWindowChromePresentation();
    }
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_preferencesChanged);
      widget.state.addListener(_preferencesChanged);
      _commentsController.dispose();
      _commentsController = SongCommentsController(
        widget.state.catalog.connections,
      );
    }
    // Every cached canvas child belongs to the previous state object or to the
    // previous entrance host; rebuilding them on the next build is cheaper than
    // deciding which of them may survive the swap.
    _desktopPaneKey = null;
    if (oldWidget.entranceSettled != widget.entranceSettled) {
      oldWidget.entranceSettled?.removeListener(_lyricsWhenSettled);
      _lyricsGate?.cancel();
      _lyricsGate = null;
      _armLyricsRequest();
    }
  }

  /// 移动端整屏歌词：标题固定，正文占满剩余高度。
  Widget _mobileLyrics() {
    final trackId = widget.state.current?.id;
    return LayoutBuilder(
      key: const ValueKey('mobile-lyrics'),
      builder: (context, box) => Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 4,
          vertical: box.maxHeight < 240 ? 4 : 12,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (box.maxHeight >= 240) ...[
              const InlineLabel('歌词'),
              const SizedBox(height: 12),
            ],
            Expanded(
              child: _settledGate(
                LyricViewport(
                  key: ValueKey<String>('mobile-lyrics-${trackId ?? ''}'),
                  state: widget.state,
                  seekEnabled: _mobileLyricSeeking,
                  backdropKey: _backdropKey,
                  onSelectionChanged: (active) =>
                      _selectionChanged(trackId, active),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveArtwork(Track track) async {
    if (_artworkActionOpen) return;
    _artworkActionOpen = true;
    _hideTimer?.cancel();
    try {
      final confirmed = await showAppleDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const TrText('保存封面图片？'),
          content: TrText('将「${track.title}」的封面保存在设备中。'),
          actions: [
            SpringTextButton(
              style: TextButton.styleFrom(
                foregroundColor: context.colors.slateDark,
              ),
              onPressed: () => Navigator.pop(context, false),
              child: const TrText('取消'),
            ),
            SpringFilledButton(
              onPressed: track.coverUrl == null
                  ? null
                  : () => Navigator.pop(context, true),
              child: const TrText('保存'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
      setState(() => _saving = true);
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
      _artworkActionOpen = false;
      if (mounted) {
        setState(() => _saving = false);
        _controlsActivity();
      }
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

  Widget _cover(Track track, {bool compact = false}) {
    return Semantics(
      label: context.tr('歌曲封面，长按保存'),
      child: GestureDetector(
        onTap: () {
          if (compact) {
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
            curve: const AppleSpringCurve(),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: _lyricsMode && compact
                  ? const []
                  : [
                      BoxShadow(
                        color: const Color(0x66000000),
                        blurRadius: 24,
                        spreadRadius: 1,
                        offset: compact ? Offset.zero : const Offset(0, 8),
                      ),
                    ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: KeyedSubtree(
                key: const ValueKey('now-playing-cover'),
                child: AnimatedTrackCover(
                  track: track,
                  image: widget.state.currentArtwork.providerFor(track),
                  direction: widget.state.trackChangeDirection,
                  spring: compact ? AppleSpring.responsive : AppleSpring.smooth,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The phone header: one row, one action.
  ///
  /// Everything the player can do with the song sits behind [更多] now. Five
  /// icons used to crowd this row and cover the cover with chrome; the back
  /// arrow stays, because leaving the page is not something done to the song.
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

  Future<void> _invokePlayerMenu(LuaPlayerMenuItem item, Track track) async {
    try {
      await widget.state.pluginManager.invokePlayerMenu(item, track.toJson());
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  /// Opens the song sheet: what the player knows about the track, and every
  /// action the header used to spell out with its own icon.
  Future<void> _showMore() async {
    if (widget.state.current == null || _moreOpen) return;
    _moreOpen = true;
    _hideTimer?.cancel();
    bool sheetClosed = false;
    try {
      final action = await showAppleModalBottomSheet<_PlayerSheetAction>(
        context: context,
        isScrollControlled: true,
        backgroundColor: context.colors.ivoryLight,
        showDragHandle: true,
        builder: (BuildContext sheetContext) => AnimatedBuilder(
          animation: Listenable.merge([
            widget.state,
            widget.state.listenTogether,
          ]),
          builder: (BuildContext context, Widget? child) {
            void selectAction([_PlayerSheetAction? action]) {
              if (sheetClosed ||
                  !sheetContext.mounted ||
                  ModalRoute.of(sheetContext)?.isCurrent != true) {
                return;
              }
              sheetClosed = true;
              Navigator.of(sheetContext).pop(action);
            }

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
                        onPressed: selectAction,
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
              pluginMenuItems: widget.state.pluginManager.playerMenuItems,
              lyricsOpen: _lyricsMode,
              onClose: selectAction,
              onLyrics: () => selectAction(_toggleLyrics),
              onTogether: () => selectAction(
                () => showListenTogetherDialog(this.context, widget.state),
              ),
              onSaveArtwork: () => selectAction(() => _saveArtwork(track)),
              onSearchOsu: () => selectAction(
                () => searchInOsu(this.context, widget.state.current),
              ),
              onAddToPlaylist: () => selectAction(
                () => showAddToPlaylistDialog(
                  this.context,
                  widget.state,
                  track: track,
                ),
              ),
              onDownload: () => selectAction(
                () =>
                    downloadTracks(this.context, widget.state, <Track>[track]),
              ),
              onComments: () => selectAction(_openComments),
              onQueue: () => selectAction(_queue),
              onSleepTimer: () => selectAction(_showSleepTimer),
              onPluginMenu: (item) =>
                  selectAction(() => _invokePlayerMenu(item, track)),
            );
          },
        ),
      );
      // Keep the idle timer suspended while the selected action owns a child
      // sheet or an asynchronous plugin operation. Closing More is only the
      // handoff; every action (including cancellation) shares this cleanup.
      if (mounted && action != null) await action();
    } finally {
      _moreOpen = false;
      if (mounted) _controlsActivity();
    }
  }

  @override
  Widget build(BuildContext context) => TvTraversalScope(
    child: TvFocusRegion(
      initialFocus: _playPauseFocus,
      child: Focus(
        autofocus: !TvScope.isActive(context),
        canRequestFocus: !TvScope.isActive(context),
        onKeyEvent: _onShortcutKey,
        child: Theme(
          data: _playerTheme(context),
          child: Scaffold(
            backgroundColor: Colors.transparent,
            // The ambient canvas is a sibling of the state-driven content, not
            // part of it: it rebuilds on its own signature (artwork and
            // background preferences) instead of once per playback report.
            body: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                _PlayerBackdropHost(
                  state: widget.state,
                  settled: widget.entranceSettled,
                  boundaryKey: _backdropKey,
                ),
                AnimatedBuilder(
                  animation: widget.state,
                  builder: (context, _) {
                    final Track? track = widget.state.current;
                    if (track == null) {
                      return _EmptyNowPlaying(onBack: _closePage);
                    }
                    return Opacity(
                      key: const ValueKey('player-content-opacity'),
                      opacity: widget.state.uiAlpha,
                      child: LayoutBuilder(
                        builder: (context, box) {
                          final bool compact =
                              !largeScreenModeOf(context) &&
                              useCompactLayout(
                                widget.state.uiMode,
                                box.maxWidth,
                                layoutStyle: widget.state.layoutStyle,
                              );
                          if (_desktopLayout != !compact) {
                            if (compact) _lyricsMode = false;
                            _desktopLayout = !compact;
                            _selectionOpen = false;
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) {
                                _wakeControls();
                                _armHide();
                              }
                            });
                          }
                          if (!compact) {
                            _buildDesktopPane(track);
                            return Stack(
                              fit: StackFit.expand,
                              children: <Widget>[
                                SafeArea(
                                  top:
                                      WindowChromeScope.maybeLayoutOf(
                                        context,
                                      )?.inline !=
                                      true,
                                  child: DesktopNowPlaying(
                                    key: const ValueKey('desktop-now-playing'),
                                    state: widget.state,
                                    track: track,
                                    artwork: _desktopArtwork!,
                                    lyrics: _desktopLyrics!,
                                    comments: _desktopComments!,
                                    queue: _desktopQueue!,
                                    pane: _desktopPane,
                                    onPaneChanged: _selectDesktopPane,
                                    onBack: _closePage,
                                    onSaveArtwork: () =>
                                        unawaited(_saveArtwork(track)),
                                    onFullscreen: () =>
                                        unawaited(_toggleFullscreen()),
                                    controlsVisible: _controlsVisible,
                                    playPauseFocus: _playPauseFocus,
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
                            onPointerUp: (event) =>
                                _endControlPointer(event.pointer),
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
                                  child: SafeArea(child: _mobile(track)),
                                ),
                                ?_pullDownLayer(box),
                              ],
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  /// The desktop player's one-key actions.
  ///
  /// The docs and the transport tooltips have always advertised Q/F/L/C/M/Esc;
  /// nothing was listening for them. The handler skips text fields and the
  /// shortcut recorder so typing a search query never toggles the player.
  KeyEventResult _onShortcutKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (MediaShortcutRecorder.active || _isEditingText() || _selectionOpen) {
      return KeyEventResult.ignored;
    }
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed ||
        keyboard.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.keyQ:
        if (_desktopLayout == true) {
          _selectDesktopPane(DesktopNowPlayingPane.queue);
        } else {
          unawaited(_queue());
        }
      case LogicalKeyboardKey.keyF:
        unawaited(_toggleFullscreen());
      case LogicalKeyboardKey.keyL:
        if (_desktopLayout == true) {
          _selectDesktopPane(DesktopNowPlayingPane.lyrics);
        } else {
          _toggleLyrics();
        }
      case LogicalKeyboardKey.keyC:
        if (_desktopLayout == true) {
          _selectDesktopPane(DesktopNowPlayingPane.comments);
        } else {
          unawaited(_openComments());
        }
      case LogicalKeyboardKey.keyM:
        unawaited(widget.state.toggleMute());
      case LogicalKeyboardKey.escape:
        _closePage();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  bool _isEditingText() {
    final BuildContext? context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    if (context.widget is EditableText) return true;
    return context.findAncestorStateOfType<EditableTextState>() != null;
  }

  /// A downward drag from anywhere in the upper half pulls the player away.
  ///
  /// Desktop and phone share it: the strip sits above the page content, so its
  /// recognizer answers the gesture arena before the content's own drag
  /// handlers and an upward drag is still left to them, while taps fall
  /// through to the controls behind it.
  Widget? _pullDownLayer(BoxConstraints box) {
    final PlayerPullDown? pullDown = widget.pullDown;
    if (pullDown == null) return null;
    // On the desktop layout the top band belongs to the window: pressing there
    // moves the window, as it does on every browse page, so pull-down starts
    // underneath it. A phone or tablet keeps the whole upper half for the
    // gesture — nothing there answers to a floating capsule.
    final bool floating =
        _desktopLayout == true &&
        WindowChromeScope.maybeLayoutOf(context)?.inline == true;
    final double band = floating ? kInlineChromeInset : 0;
    final double height = box.maxHeight * .5 - band;
    if (height <= 0) return null;
    return Positioned(
      left: 0,
      right: 0,
      top: band,
      height: height,
      child: PlayerPullDownRegion(
        pullDown: pullDown,
        travel: box.maxHeight,
        enabled: !_selectionOpen && !_commentsOpen && !_queueOpen && !_moreOpen,
      ),
    );
  }

  Widget _mobile(Track track) => ArtworkLyricsLayout(
    lyricsVisible: _lyricsMode,
    controlsVisible: !_lyricsMode || _controlsVisible,
    onControlsHiddenChanged: _mobileControlsHiddenChanged,
    header: _headerControls(),
    summary: Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 6),
      child: PlayerTrackSummary(
        key: const ValueKey('compact-player-summary'),
        track: track,
        onTap: _controlsActivity,
      ),
    ),
    artwork: _cover(track, compact: true),
    lyrics: _mobileLyrics(),
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

class _ControlIconState extends State<_ControlIcon>
    with BuildSafeState<_ControlIcon> {
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
      switchInCurve: const AppleSpringCurve(),
      switchOutCurve: const AppleSpringCurve(),
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : AppleSpring.responsive.duration,
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
    required this.pluginMenuItems,
    required this.lyricsOpen,
    required this.onClose,
    required this.onLyrics,
    required this.onTogether,
    required this.onSaveArtwork,
    required this.onSearchOsu,
    required this.onAddToPlaylist,
    required this.onDownload,
    required this.onComments,
    required this.onQueue,
    required this.onSleepTimer,
    required this.onPluginMenu,
  });

  final AppState state;
  final Track track;
  final List<LuaPlayerMenuItem> pluginMenuItems;
  final bool lyricsOpen;
  final VoidCallback onClose;
  final VoidCallback onLyrics;
  final VoidCallback onTogether;
  final VoidCallback onSaveArtwork;
  final VoidCallback onSearchOsu;
  final VoidCallback onAddToPlaylist;
  final VoidCallback onDownload;
  final VoidCallback onComments;
  final VoidCallback onQueue;
  final VoidCallback onSleepTimer;
  final ValueChanged<LuaPlayerMenuItem> onPluginMenu;

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
                    onPressed: onClose,
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
                value: context.tr(
                  state.audioQualityLabel(state.playbackQuality),
                ),
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
              if (state.supportsCurrentMusic(MusicCapability.listenTogether))
                _MoreAction(
                  icon: Icons.group_rounded,
                  label: context.tr(
                    state.listenTogether.ready ? '查看一起听房间状态' : '创建一起听',
                  ),
                  onTap: onTogether,
                ),
              _MoreAction(
                icon: Icons.save_alt_rounded,
                label: context.tr('保存封面'),
                onTap: onSaveArtwork,
              ),
              _MoreAction(
                icon: Icons.search_rounded,
                label: context.tr('在 osu! 中搜索'),
                onTap: osuBeatmapSearchUri(track) == null ? null : onSearchOsu,
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
              if (state.supportsCurrentMusic(MusicCapability.comments))
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
              _MoreAction(
                icon: Icons.bedtime_outlined,
                label: state.sleepTimerActive
                    ? context.tr('睡眠定时（已设置）')
                    : context.tr('睡眠定时'),
                selected: state.sleepTimerActive,
                onTap: onSleepTimer,
              ),
              if (pluginMenuItems.isNotEmpty) ...<Widget>[
                const SizedBox(height: 4),
                Divider(height: 1, color: context.colors.stone),
                for (final item in pluginMenuItems)
                  _MoreAction(
                    icon: luaPluginIcon(item.icon),
                    label: item.pluginName.isEmpty
                        ? item.label
                        : '${item.label}（${item.pluginName}）',
                    onTap: item.enabled ? () => onPluginMenu(item) : null,
                  ),
              ],
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

String _sleepTimerLabel(Duration duration) {
  if (duration.inMinutes < 60) return '${duration.inMinutes} 分钟后';
  return '${duration.inHours} 小时后';
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
            '去曲库选一首歌。',
            style: context.type.bodyMuted.copyWith(fontSize: 16),
          ),
          const SizedBox(height: AppSpacing.lg),
          IvoryButton(label: '返回', onPressed: onBack),
        ],
      ),
    );
  }
}

/// Mutes its subtree's tickers without rebuilding the lyric page on landing.
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

/// The immersive player canvas, kept outside the page's per-tick rebuild.
///
/// The page listens to [AppState] and therefore rebuilds on every playback
/// report — ten times a second while audio plays. The ambient canvas is the
/// most expensive subtree on that page (a warped album-colour mesh plus the
/// full-screen vignette stack), and reconfiguring it on every report competed
/// directly with the entrance spring: opening the player stuttered for as long
/// as the page was still sliding in. This widget watches the same state but
/// rebuilds only when something the canvas actually paints changed.
class _PlayerBackdropHost extends StatefulWidget {
  const _PlayerBackdropHost({
    required this.state,
    required this.settled,
    required this.boundaryKey,
  });

  final AppState state;
  final ValueListenable<bool>? settled;
  final GlobalKey boundaryKey;

  @override
  State<_PlayerBackdropHost> createState() => _PlayerBackdropHostState();
}

class _PlayerBackdropHostState extends State<_PlayerBackdropHost> {
  late _BackdropSignature _signature = _signatureOf(widget.state);

  /// Every input the canvas paints from, in one comparable tuple.
  static _BackdropSignature _signatureOf(AppState state) => (
    state.current?.id,
    state.current?.coverUrl,
    state.playerBackground,
    state.playerBackgroundFps,
    state.playerBackgroundColor,
    state.playerBackgroundImagePath,
    state.playerBackgroundImageAlignmentX,
    state.playerBackgroundImageAlignmentY,
    state.playerBackgroundImageScale,
    state.playerBackgroundBlurEnabled,
    state.playerBackgroundBlur,
    state.backgroundDarkEdgeEnabled,
    state.playerBackgroundQuality,
    state.playerBackgroundOpacity,
  );

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_stateChanged);
  }

  @override
  void didUpdateWidget(covariant _PlayerBackdropHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_stateChanged);
      widget.state.addListener(_stateChanged);
      _signature = _signatureOf(widget.state);
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_stateChanged);
    super.dispose();
  }

  void _stateChanged() {
    if (!mounted) return;
    final _BackdropSignature next = _signatureOf(widget.state);
    if (next == _signature) return;
    setState(() => _signature = next);
  }

  @override
  Widget build(BuildContext context) {
    final AppState state = widget.state;
    if (state.playerBackground == AppBackgroundMode.windowsMica) {
      return RepaintBoundary(
        key: widget.boundaryKey,
        child: MicaSurface(opacity: state.playerBackgroundOpacity),
      );
    }
    return ColoredBox(
      color: Colors.black,
      child: Opacity(
        key: const ValueKey('player-background-opacity'),
        opacity: state.playerBackgroundOpacity,
        child: _buildCanvas(state),
      ),
    );
  }

  Widget _buildCanvas(AppState state) {
    return _EntranceGatedBackdrop(
      settled: widget.settled,
      builder: (bool settled) => AlbumBlurFlow(
        boundaryKey: widget.boundaryKey,
        track: state.current,
        // The immersive player owns its canvas: browse-page backdrop settings
        // (including "不使用" or a custom picture) must not strip the song's
        // album-colour flow from here.
        mode: state.playerBackground,
        frameRate: state.playerBackgroundFps == 0
            ? null
            : state.playerBackgroundFps,
        solidColor: state.playerBackgroundColor,
        imagePath: state.playerBackgroundImagePath,
        imageAlignmentX: state.playerBackgroundImageAlignmentX,
        imageAlignmentY: state.playerBackgroundImageAlignmentY,
        imageScale: state.playerBackgroundImageScale,
        blurSigma: state.playerBackgroundBlurEnabled
            ? state.playerBackgroundBlur
            : 0,
        darkEdge: state.backgroundDarkEdgeEnabled,
        pageColor: Colors.black,
        // The ambient canvas belongs to the song, not to the transport. Pausing
        // used to freeze it, which read as the whole page stopping; it now keeps
        // flowing at the configured cadence and only the entrance gate holds it.
        animationsEnabled: settled,
        quality: state.playerBackgroundQuality,
        // The background belongs to the visible player at every point in its
        // spring. Replacing it with the entrance-only placeholder made the
        // selected canvas disappear whenever the outer status was interrupted
        // or not delivered.
        preview: false,
      ),
    );
  }
}

/// The canvas inputs, compared by value.
typedef _BackdropSignature = (
  Object?, // track id
  Object?, // cover url
  Object?, // background mode
  Object?, // frame rate cap
  Object?, // solid colour
  Object?, // picture path
  Object?, // picture alignment x
  Object?, // picture alignment y
  Object?, // picture scale
  Object?, // picture blur enabled
  Object?, // picture blur sigma
  Object?, // dark edge
  Object?, // render quality
  Object?, // background opacity
);
