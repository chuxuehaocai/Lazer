import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../local/local_music_page.dart';
import '../state/app_state.dart';
import '../state/build_safe_notifier.dart';
import '../state/song_comments_controller.dart';
import '../state/detail_requests.dart';
import '../state/ui_preferences.dart';
import '../theme/apple_design.dart';
import '../animation/motion_snapshot.dart';
import '../animation/apple_spring.dart';
import '../gateway/music_models.dart';
import '../widgets/music_provider_badge.dart';
import '../widgets/shared_browse_background.dart';
import '../tv/large_screen_chrome.dart';
import '../tv/large_screen_pages.dart';
import '../tv/large_screen_widgets.dart';
import '../tv/tv_mode.dart';
import '../updates/update_checker.dart';
import '../updates/update_dialog.dart';
import '../utils/artwork.dart';
import '../widgets/apple_ui.dart';
import '../widgets/artwork_image.dart';
import '../widgets/cover_transition.dart';
import '../widgets/interaction_feedback.dart';
import '../widgets/retained_content_switcher.dart';
import '../widgets/song_comments_view.dart';
import 'background.dart';
import 'login.dart';
import '../navigation/pull_down_to_close.dart';
import '../navigation/system_back_gesture.dart';
import '../player/now_playing_page.dart';
import '../player/player_page_motion.dart';
import 'pages.dart';
import 'player_bar.dart';
import 'widgets.dart';

/// The app shell, rebuilt around Apple's adaptive navigation model.
///
/// Desktop gets a translucent source-list sidebar, a content toolbar and the
/// full transport, while phones get an inline navigation bar, the iOS tab bar
/// and a floating mini-player. Both compositions share one content tree, one
/// search page and one set of playback controls, so switching layouts never
/// loses context.
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.state,
    this.autoCheckUpdates = false,
  });

  final AppState state;

  /// Whether to look for a newer release shortly after startup.
  ///
  /// Only production enables this: widget tests pump the shell directly and
  /// must not spawn network work or a pending timer.
  final bool autoCheckUpdates;

  @override
  State<AppShell> createState() => _AppShellState();
}

enum _AppSection { home, search, library, likes, settings }

class _BrowseLocation {
  const _BrowseLocation({
    required this.key,
    required this.section,
    this.playlist,
    this.album,
    this.artist,
    this.chart,
    this.artistSongs = false,
    this.artistReleases,
    this.comments = false,
    this.localMusic = false,
  });

  final String key;
  final _AppSection section;
  final Playlist? playlist;
  final Album? album;
  final ArtistRef? artist;
  final MusicChart? chart;
  final bool artistSongs;
  final AlbumReleaseGroup? artistReleases;
  final bool comments;
  final bool localMusic;
}

class _AppShellState extends State<AppShell> with TickerProviderStateMixin {
  _AppSection _section = _AppSection.home;
  final List<_BrowseLocation> _browseHistory = <_BrowseLocation>[];
  final ValueNotifier<double?> _backProgress = ValueNotifier(null);
  String? _backTarget;
  String? _backSource;
  bool _backPlayer = false;
  bool _backCommitted = false;
  Object? _railCollectionsSource;
  List<Playlist> _railPlaylistCache = const <Playlist>[];
  Playlist? _playlist;

  /// Set when the open detail is an album; the playlist pipeline renders it.
  Album? _album;
  ArtistRef? _artist;
  MusicChart? _chart;
  bool _localMusic = false;
  bool _artistSongs = false;
  AlbumReleaseGroup? _artistReleases;
  bool _comments = false;
  SongCommentsController? _commentsController;
  late final AnimationController _nowPlayingMotion;
  late final Animation<Offset> _nowPlayingSlide;
  bool _nowPlayingOpen = false;

  /// Whether the player's entrance has finished. A notifier rather than a field
  /// so the album flow can follow it on its own: flipping a plain field would
  /// rebuild the whole player on the frame the entrance lands.
  final ValueNotifier<bool> _playerSettled = ValueNotifier<bool>(true);
  bool get _nowPlayingSettled => _playerSettled.value;

  /// The player page widget, built once per opening and handed to the tree
  /// unchanged. Rebuilding the shell — a playback report, the entrance
  /// settling — must not rebuild the player's subtree: it is the most
  /// expensive tree in the app and it already follows [state] through its own
  /// listeners, so a new widget instance here is pure cost on the frame the
  /// open animation is trying to run.
  Widget? _playerPage;

  /// Hosts the player's pull-down gesture on the same motion that opens it, so
  /// the page follows the finger and settles from wherever it was left.
  late final PlayerPullDown _playerPull = _PlayerPull(this);

  /// Drives the shell's own rebuilds. Playback reports ten times a second;
  /// rebuilding the whole page for every tick while a switch is animating is
  /// what turns a 420 ms cross-fade into a stutter, so [state] is filtered
  /// through [_onAppStateChanged] instead of listened to directly.
  final _ShellRepaint _repaint = _ShellRepaint();
  bool _stateReportScheduled = false;

  /// The switcher's actual spring lifetime controls ambient work, including
  /// its settling tail and any changes of direction.
  bool _contentSwitching = false;
  String? _shownContentKey;

  /// The browse tree is fully covered while the player is up. Caching it
  /// keeps playback notifications (track changes, lyric loads, download
  /// progress) from rebuilding the shelf/mosaic page underneath during the
  /// player's own animations. The cache is refreshed as soon as the player
  /// starts closing so the revealed page is current.
  ///
  /// Everything that decides the tree's shape is stored alongside it. A
  /// window resize while the player is open keeps the same widget instance
  /// but lays it out at the new width, so a cached desktop tree would overflow
  /// a phone-sized window; comparing these flags rebuilds it in time.
  Widget? _coveredShell;
  bool _coveredShellStale = false;
  Brightness? _coveredShellBrightness;
  Color? _coveredShellAccent;
  bool? _coveredShellCompact;
  bool? _coveredShellCompactBar;
  bool? _coveredShellBackdrop;
  bool? _coveredShellLargeScreen;

  AppState get state => widget.state;
  late String _connectionKey = state.activeConnectionKey;

  @override
  void initState() {
    super.initState();
    _nowPlayingMotion = AnimationController.unbounded(
      vsync: this,
      duration: PlayerPageMotion.spring.duration,
      reverseDuration: PlayerPageMotion.spring.duration,
      animationBehavior: AnimationBehavior.preserve,
    )..addStatusListener(_onNowPlayingStatus);
    // An unbounded controller has no implicit closed endpoint. Keep the idle
    // browse page live until the player actually starts moving.
    _nowPlayingMotion.animateBack(0, duration: Duration.zero);
    state.addListener(_onAppStateChanged);
    _backProgress.addListener(_onBackProgress);
    // The first frame is not a switch: only a change from here on is one.
    _shownContentKey = _contentKey;
    // Linear on purpose: the pull writes straight into the controller value,
    // so the page must track the finger one to one. The easing of the open and
    // close transitions belongs to those animations instead.
    _nowPlayingSlide = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(_nowPlayingMotion);
    albumDetailRequest.addListener(_onAlbumRequest);
    artistDetailRequest.addListener(_onArtistRequest);
    TvOverlayStack.instance.addListener(_onTvOverlayChanged);
    if (widget.autoCheckUpdates) {
      _updateTimer = Timer(
        const Duration(seconds: 4),
        () => unawaited(_checkForUpdates()),
      );
    }
  }

  Timer? _updateTimer;
  AppRelease? _pendingUpdate;

  void _scheduleUpdateCheck(Duration delay) {
    _updateTimer?.cancel();
    if (!mounted || !widget.autoCheckUpdates) return;
    _updateTimer = Timer(delay, () => unawaited(_checkForUpdates()));
  }

  /// Gives the catalogue time to land before talking to GitHub. A failure is
  /// already silent inside [AppState]; a found release opens the same prompt
  /// the settings button uses.
  Future<void> _checkForUpdates() async {
    final AppRelease? release = _pendingUpdate ?? await state.checkForUpdates();
    if (!mounted) return;
    if (release == null) {
      // Startup is often the least reliable moment to reach GitHub. Retry a
      // failure in this session; a successful check keeps the daily cadence.
      _scheduleUpdateCheck(
        state.updateError == null
            ? const Duration(hours: 1)
            : const Duration(minutes: 5),
      );
      return;
    }
    // A manual check can skip this release while an automatic prompt is
    // waiting behind another route. Apply that decision to the retained result.
    if (state.skippedUpdateVersion == release.version.normalized) {
      _pendingUpdate = null;
      _scheduleUpdateCheck(const Duration(hours: 1));
      return;
    }
    _pendingUpdate = release;
    // Retain the result while another dialog is visible. Previously this
    // marked the day as checked and silently dropped the update prompt.
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (route != null && !route.isCurrent ||
        lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      _scheduleUpdateCheck(const Duration(seconds: 5));
      return;
    }
    _pendingUpdate = null;
    await showUpdateDialog(context, state, release);
    _scheduleUpdateCheck(const Duration(hours: 1));
  }

  bool _overlayRefreshScheduled = false;

  /// The queue and volume cards live in the overlay rather than in this route,
  /// so Back must consult their registry before its own navigation.
  void _onTvOverlayChanged() {
    if (!mounted || _overlayRefreshScheduled) return;
    _overlayRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _overlayRefreshScheduled = false;
      if (mounted) setState(() {});
    });
  }

  /// Playback, downloads and lyrics all report through [state]. Only the
  /// chrome is rebuilt per report; while a page switch is animating the report
  /// is held back and folded into the rebuild that ends the switch.
  void _onAppStateChanged() {
    if (!mounted) return;
    if (_connectionKey != state.activeConnectionKey) {
      _browseHistory.clear();
      cancelCoverTransitions();
      _connectionKey = state.activeConnectionKey;
      _playlist = null;
      _album = null;
      _artist = null;
      _chart = null;
      _comments = false;
      _artistSongs = false;
      _artistReleases = null;
      _coveredShell = null;
    }
    if (_contentSwitching && !_nowPlayingOpen) return;
    // Progress ticks use AppState.ticks; structural reports must all reach the
    // page, including changes whose list lengths or track IDs stay the same.
    // A page can report from its own initState, i.e. while the tree is being
    // built; marking the shell dirty there throws. Take that report on the
    // frame that is already running instead.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_stateReportScheduled) return;
      _stateReportScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _stateReportScheduled = false;
        if (mounted) _repaint.ping();
      });
      return;
    }
    _repaint.ping();
  }

  void _onContentTransitionChanged(bool switching) {
    if (!mounted) return;
    state.browseTransitionChanged(switching);
    if (_contentSwitching == switching) return;
    _contentSwitching = switching;
    // The switcher reports a retarget from didUpdateWidget as well as its
    // completion from the ticker. Read the latest state after either event.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _repaint.ping();
      });
    } else {
      _repaint.ping();
    }
  }

  void _onNowPlayingStatus(AnimationStatus status) {
    if (!mounted) return;
    if (status == AnimationStatus.completed && !_nowPlayingSettled) {
      _playerSettled.value = true;
    } else if (status == AnimationStatus.dismissed && _nowPlayingOpen) {
      // The next opening builds a fresh page with fresh state.
      setState(() {
        _nowPlayingOpen = false;
        _playerPage = null;
      });
    }
  }

  /// The player's overlay wrappers, rebuilt when the entrance lands. The page
  /// arrives as a prebuilt child so it is not part of that rebuild.
  Widget _playerOverlay(BuildContext context, bool settled, Widget? page) =>
      Semantics(
        key: const ValueKey<String>('now-playing-semantics'),
        container: true,
        child: ExcludeSemantics(
          excluding: !settled,
          child: MotionSnapshot(
            animation: _nowPlayingMotion,
            // Focus starts on the first control of the player so a remote can
            // operate it at once.
            child: TvFocusRegion(focusToken: settled, child: page!),
          ),
        ),
      );

  /// One page instance per opening, reused across shell rebuilds.
  Widget _playerPageWidget() => _playerPage ??= NowPlayingPage(
    state: state,
    onClose: _closeNowPlaying,
    entranceSettled: _playerSettled,
    pullDown: _playerPull,
  );

  @override
  void didUpdateWidget(covariant AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      _browseHistory.clear();
      cancelCoverTransitions();
      oldWidget.state.removeListener(_onAppStateChanged);
      widget.state.addListener(_onAppStateChanged);
      _playerPage = null;
    }
  }

  @override
  void dispose() {
    cancelCoverTransitions();
    _updateTimer?.cancel();
    state.removeListener(_onAppStateChanged);
    _playerSettled.dispose();
    _backProgress.dispose();
    _repaint.dispose();
    _nowPlayingMotion
      ..removeStatusListener(_onNowPlayingStatus)
      ..dispose();
    _commentsController?.dispose();
    albumDetailRequest.removeListener(_onAlbumRequest);
    artistDetailRequest.removeListener(_onArtistRequest);
    TvOverlayStack.instance.removeListener(_onTvOverlayChanged);
    super.dispose();
  }

  void _select(_AppSection section) {
    _browseHistory.clear();
    cancelCoverTransitions();
    setState(() {
      _section = section;
      _playlist = null;
      _album = null;
      _artist = null;
      _chart = null;
      _artistSongs = false;
      _artistReleases = null;
      _comments = false;
      _localMusic = false;
    });
  }

  void _openPlaylist(Playlist playlist) {
    if (_playlist?.id == playlist.id && _album == null && !_comments) return;
    _rememberBrowseLocation();
    setState(() {
      _playlist = playlist;
      _album = null;
      _artist = null;
      _chart = null;
      _artistSongs = false;
      _artistReleases = null;
      _comments = false;
      _localMusic = false;
    });
  }

  /// 音乐库 → 本地音乐. It keeps the library section selected so the rail still
  /// reads as the current place, while the content pane swaps to the page.
  void _openLocalMusic() {
    _rememberBrowseLocation();
    cancelCoverTransitions();
    setState(() {
      _section = _AppSection.library;
      _localMusic = true;
      _playlist = null;
      _album = null;
      _artist = null;
      _chart = null;
      _artistSongs = false;
      _artistReleases = null;
      _comments = false;
    });
  }

  /// An album row anywhere in the app asks for the right-hand slot. The album
  /// rides the playlist pipeline, so there is one list implementation.
  void _onAlbumRequest() {
    final Album? album = albumDetailRequest.value;
    if (album == null) return;
    albumDetailRequest.value = null;
    if (!mounted) return;
    _openAlbum(album);
  }

  /// Opens [album] in the content pane.
  ///
  /// The playlist pipeline renders albums as well (they share a cover, title
  /// and track list), so an album is a playlist with its own metadata rather
  /// than a second page type.
  void _openAlbum(Album album) {
    if (_album?.id == album.id && !_comments) return;
    _rememberBrowseLocation();
    _closeNowPlaying();
    setState(() {
      _album = album;
      _artist = null;
      _chart = null;
      _artistSongs = false;
      _artistReleases = null;
      _localMusic = false;
      _playlist = Playlist(
        id: album.id,
        name: album.title,
        trackIds: const <String>[],
        coverSeed: album.coverSeed,
        coverUrl: album.coverUrl,
        trackCount: album.trackCount ?? 0,
      );
      _comments = false;
    });
  }

  void _onArtistRequest() {
    final ArtistRef? artist = artistDetailRequest.value;
    if (artist == null) return;
    artistDetailRequest.value = null;
    if (!mounted) return;
    _closeNowPlaying();
    _rememberBrowseLocation();
    setState(() {
      _artist = artist;
      _chart = null;
      _artistSongs = false;
      _artistReleases = null;
      _playlist = null;
      _album = null;
      _comments = false;
      _localMusic = false;
    });
  }

  void _openArtistSongs() {
    _rememberBrowseLocation();
    setState(() => _artistSongs = true);
  }

  void _openChart(MusicChart chart) {
    if (_chart?.id == chart.id && !_comments) return;
    _rememberBrowseLocation();
    setState(() {
      _chart = chart;
      _playlist = null;
      _album = null;
      _artist = null;
      _artistSongs = false;
      _artistReleases = null;
      _comments = false;
      _localMusic = false;
    });
  }

  void _openArtistReleases(AlbumReleaseGroup group) {
    _rememberBrowseLocation();
    setState(() => _artistReleases = group);
  }

  void _rememberBrowseLocation() {
    // Keep the actual return chain, never every page that has been visited.
    // A bound also prevents artist/album links forming an unlimited cycle.
    _browseHistory.add(
      _BrowseLocation(
        key: _contentKey,
        section: _section,
        playlist: _playlist,
        album: _album,
        artist: _artist,
        chart: _chart,
        artistSongs: _artistSongs,
        artistReleases: _artistReleases,
        comments: _comments,
        localMusic: _localMusic,
      ),
    );
    if (_browseHistory.length > 8) _browseHistory.removeAt(1);
  }

  void _backToRoot() {
    if (_browseHistory.isNotEmpty) {
      final identity = _chart != null
          ? 'chart:${_chart!.id}'
          : _playlist != null
          ? 'playlist:${_playlist!.id}'
          : null;
      if (identity != null) returnCoverTransition(identity);
      final previous = _browseHistory.removeLast();
      setState(() {
        _section = previous.section;
        _playlist = previous.playlist;
        _album = previous.album;
        _artist = previous.artist;
        _chart = previous.chart;
        _artistSongs = previous.artistSongs;
        _artistReleases = previous.artistReleases;
        _comments = previous.comments;
        _localMusic = previous.localMusic;
      });
      return;
    }
    setState(() {
      if (_artistSongs || _artistReleases != null) {
        _artistSongs = false;
        _artistReleases = null;
        return;
      }
      _playlist = null;
      _album = null;
      _artist = null;
      _chart = null;
      _comments = false;
      _localMusic = false;
    });
  }

  void _toggleComments() {
    if (!state.supportsMusic(MusicCapability.comments)) return;
    if (_comments) {
      _backToRoot();
      return;
    }
    _rememberBrowseLocation();
    setState(() {
      _comments = !_comments;
      if (_comments) {
        _commentsController ??= SongCommentsController(state.gateway);
      }
    });
  }

  void _openNowPlaying() {
    if (_nowPlayingOpen &&
        _nowPlayingMotion.status != AnimationStatus.reverse) {
      return;
    }
    setState(() {
      _nowPlayingOpen = true;
      _playerSettled.value = false;
    });
    PlayerPageMotion.animate(
      _nowPlayingMotion,
      1,
      compact: useCompactLayout(state.uiMode, MediaQuery.sizeOf(context).width),
      reduceMotion: MediaQuery.disableAnimationsOf(context),
    );
  }

  void _closeNowPlaying() {
    if (!_nowPlayingOpen) return;
    setState(() {
      _playerSettled.value = false;
      _coveredShellStale = true;
    });
    PlayerPageMotion.animate(
      _nowPlayingMotion,
      0,
      compact: useCompactLayout(state.uiMode, MediaQuery.sizeOf(context).width),
      reduceMotion: MediaQuery.disableAnimationsOf(context),
    );
  }

  /// Settles a finger-driven pull. The player closes when it has been dragged
  /// far enough, or flung downward; otherwise it returns to the open position.
  void _settlePlayerPull(double velocity, {bool cancel = false}) {
    if (!_nowPlayingOpen) return;
    final double open = _nowPlayingMotion.value.clamp(0.0, 1.0);
    final double pulled = 1 - open;
    final bool dismiss = cancel
        ? false
        : velocity < -900
        ? false
        : (velocity > 900 && pulled > .02) || pulled >= .22;
    final normalizedVelocity = -velocity / MediaQuery.sizeOf(context).height;
    if (!dismiss) {
      PlayerPageMotion.animate(
        _nowPlayingMotion,
        1,
        compact: useCompactLayout(
          state.uiMode,
          MediaQuery.sizeOf(context).width,
        ),
        velocity: normalizedVelocity,
        releasedPull: true,
        reduceMotion: MediaQuery.disableAnimationsOf(context),
      );
      return;
    }
    unawaited(state.feedback());
    setState(() {
      _playerSettled.value = false;
      // Rebuild the browse tree once so the uncovered page is current.
      _coveredShellStale = true;
    });
    PlayerPageMotion.animate(
      _nowPlayingMotion,
      0,
      compact: useCompactLayout(state.uiMode, MediaQuery.sizeOf(context).width),
      velocity: normalizedVelocity,
      releasedPull: true,
      reduceMotion: MediaQuery.disableAnimationsOf(context),
    );
  }

  bool get _hasOpenDetail =>
      _playlist != null ||
      _album != null ||
      _artist != null ||
      _chart != null ||
      _comments ||
      _localMusic;

  /// A remote's Back button is the only navigation affordance a television
  /// has. It closes the player, then detail pages, then returns to 发现; only
  /// at the browse root does it leave the app.
  void _handleBack() {
    if (TvOverlayStack.instance.closeTop()) return;
    if (_nowPlayingOpen) {
      _closeNowPlaying();
      return;
    }
    if (_hasOpenDetail) {
      _backToRoot();
      return;
    }
    if (_section != _AppSection.home) _select(_AppSection.home);
  }

  bool _canStartSystemBack() =>
      mounted &&
      (ModalRoute.of(context)?.isCurrent ?? false) &&
      !TvOverlayStack.instance.hasOpen &&
      !largeScreenModeOf(context) &&
      (_nowPlayingOpen
          ? _nowPlayingSettled && _playerPull.canStart
          : !_contentSwitching &&
                (_hasOpenDetail || _section != _AppSection.home));

  void _startSystemBack() {
    _backSource = _contentKey;
    _backPlayer = _nowPlayingOpen;
    _backCommitted = false;
    if (_backPlayer) {
      _nowPlayingMotion.stop();
      _playerSettled.value = false;
      _coveredShellStale = true;
    }
    setState(() {
      _backTarget = _backPlayer
          ? null
          : _browseHistory.isNotEmpty
          ? _browseHistory.last.key
          : '$activePlatformContentKey:section:home';
    });
    state.browseTransitionChanged(true);
  }

  void _onBackProgress() {
    final progress = _backProgress.value;
    if (_backPlayer &&
        progress != null &&
        !MediaQuery.disableAnimationsOf(context)) {
      _nowPlayingMotion.value = (1 - progress).clamp(.001, 1.0);
    }
    if (progress == null) {
      if (_backPlayer && !_backCommitted && _nowPlayingOpen) {
        _nowPlayingMotion.value = 1;
        _playerSettled.value = true;
      }
      // Keep the target until the committed content update has been built.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _backTarget = null);
      });
      state.browseTransitionChanged(false);
    }
  }

  void _commitSystemBack() {
    if (!(ModalRoute.of(context)?.isCurrent ?? false) ||
        TvOverlayStack.instance.hasOpen ||
        _contentKey != _backSource ||
        _nowPlayingOpen != _backPlayer) {
      _backCommitted = false;
      return;
    }
    _backCommitted = true;
    if (_backPlayer) {
      // The gesture already moved the player completely offscreen. Retire it
      // at that endpoint instead of starting another close spring at .001.
      _nowPlayingMotion.animateBack(0, duration: Duration.zero);
    } else {
      _handleBack();
    }
  }

  // -- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final bool sharedBackground = BrowseBackgroundScope.contains(context);
    final Brightness brightness = Theme.of(context).brightness;
    final Color accent = state.accentSeed ?? AppleColors.musicRed;
    return Theme(
      data:
          buildAppleTheme(
            brightness: brightness,
            seedAccent: accent,
            fonts: state.fontPreferences,
          ).copyWith(
            scaffoldBackgroundColor: sharedBackground
                ? Colors.transparent
                : null,
          ),
      child: AnimatedBuilder(
        animation: _repaint,
        builder: (BuildContext context, _) {
          // Stop ambient work in the first changed build; the switcher then
          // reports when its actual spring has finished settling.
          final String contentKey = _contentKey;
          if (_shownContentKey != contentKey) {
            _shownContentKey = contentKey;
            if (!(MediaQuery.maybeOf(context)?.disableAnimations ?? false)) {
              _contentSwitching = true;
            }
          }
          final AppleSemanticColors apple = AppleSemanticColors.of(context);
          final Size window = MediaQuery.sizeOf(context);
          final bool largeScreen = largeScreenModeOf(context);
          final bool compact = useCompactLayout(state.uiMode, window.width);
          final bool compactBar = window.width < 1_000;
          final bool paintedBackdrop =
              state.backgroundMode != AppBackgroundMode.off;
          // The "follow the song" palette still needs the artwork seed when
          // the backdrop is off, so the widget stays mounted to extract it.
          final bool needsSeed = state.paletteMode == AppPaletteMode.nowPlaying;
          // With no artwork behind it, pure black reads as a hole in the
          // window; the dark theme lifts that empty canvas to a deep warm
          // grey instead.
          final Color canvas = brightness == Brightness.dark && !paintedBackdrop
              ? AppleColors.darkCanvas
              : apple.background;
          final bool backdrop = paintedBackdrop || needsSeed;
          // Everything that decides the browse tree's shape, so a cached copy
          // is only reused where it would have been rebuilt identically.
          final bool shellShapeMatches =
              _coveredShellBrightness == brightness &&
              _coveredShellAccent == accent &&
              _coveredShellCompact == compact &&
              _coveredShellCompactBar == compactBar &&
              _coveredShellBackdrop == backdrop &&
              _coveredShellLargeScreen == largeScreen;
          final Widget? cachedShell = _coveredShell;
          // Reuse the cached tree while the player covers it. Opening the
          // player is the expensive frame: rebuilding a page the player is
          // about to hide would double the work of the transition's first
          // frame, and the warm copy from the previous frame is the same tree.
          final bool reuseShell =
              _nowPlayingOpen &&
              cachedShell != null &&
              shellShapeMatches &&
              !_coveredShellStale;
          final Widget shell = reuseShell
              ? cachedShell
              : Scaffold(
                  backgroundColor: sharedBackground
                      ? Colors.transparent
                      : canvas,
                  body: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      if (!sharedBackground && (paintedBackdrop || needsSeed))
                        // The mesh drifts on a ten second time base: freezing
                        // it for the length of a page switch is invisible and
                        // hands the frame budget to the transition.
                        TickerMode(
                          enabled: !_contentSwitching,
                          child: AppAlbumBackdrop(
                            track: state.current,
                            mode: state.backgroundMode,
                            imagePath: state.backgroundImagePath,
                            uiAlpha: state.uiAlpha,
                            quality: state.dynamicBackgroundQuality,
                            frameRate: state.browseBackgroundFps,
                            solidColor: state.browseBackgroundColor,
                          ),
                        ),
                      // Content sits on a semantic system background from
                      // which the album tint is allowed to breathe through.
                      // Keeping this veil opaque enough is what makes Apple's
                      // high-contrast labels remain readable over arbitrary
                      // artwork.
                      if (!sharedBackground)
                        Positioned.fill(
                          child: ColoredBox(
                            color: paintedBackdrop
                                ? apple.background.withValues(
                                    alpha: (state.uiAlpha * .9).clamp(.56, .92),
                                  )
                                : canvas,
                          ),
                        ),
                      SafeArea(
                        bottom: false,
                        // Televisions overscan: keep the chrome inside the
                        // panel's visible box even though Android reports no
                        // safe insets.
                        minimum: tvSafeInsets(context),
                        child: largeScreen
                            ? _largeScreenLayout(apple)
                            : compact
                            ? _compactLayout(apple, compactBar: compactBar)
                            : _desktopLayout(apple, compactBar: compactBar),
                      ),
                    ],
                  ),
                );
          if (!reuseShell) {
            _coveredShell = shell;
            _coveredShellStale = false;
            _coveredShellBrightness = brightness;
            _coveredShellAccent = accent;
            _coveredShellCompact = compact;
            _coveredShellCompactBar = compactBar;
            _coveredShellBackdrop = backdrop;
            _coveredShellLargeScreen = largeScreen;
          }
          // The traversal policy belongs here, inside the route: MaterialApp's
          // navigator installs its own FocusTraversalGroup around every page,
          // so a group above the MaterialApp would never be consulted. Under
          // the shell it covers the browse tree and the player overlay, which
          // is exactly the region a remote has to cross.
          return TvTraversalScope(
            child: SystemBackGesture(
              canStart: _canStartSystemBack,
              progress: _backProgress,
              onStart: _startSystemBack,
              onCommit: _commitSystemBack,
              child: PopScope<void>(
                // Back is handled in-app while a page or the player is open; at
                // the browse root it keeps the platform's default (leave the app).
                canPop:
                    !TvOverlayStack.instance.hasOpen &&
                    !_nowPlayingOpen &&
                    !_hasOpenDetail &&
                    _section == _AppSection.home,
                onPopInvokedWithResult: (bool didPop, void _) {
                  if (!didPop) _handleBack();
                },
                child: Semantics(
                  key: const ValueKey<String>('app-semantics-root'),
                  container: true,
                  label: 'Lazer',
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      ExcludeSemantics(
                        excluding: _nowPlayingOpen,
                        child: ExcludeFocus(
                          excluding: _nowPlayingOpen,
                          child: TickerMode(
                            enabled: !_nowPlayingOpen,
                            child: MotionSnapshot(
                              animation: _nowPlayingMotion,
                              child: shell,
                            ),
                          ),
                        ),
                      ),
                      if (_nowPlayingOpen)
                        Positioned.fill(
                          child: AnimatedBuilder(
                            animation: _nowPlayingMotion,
                            builder: (context, child) => Stack(
                              fit: StackFit.expand,
                              children: [
                                // Keep the browse page hidden under an upward
                                // overshoot without painting a black layer over
                                // the player's own album canvas.
                                if (_nowPlayingMotion.value > 1)
                                  const ColoredBox(color: Colors.black),
                                child!,
                              ],
                            ),
                            child: SlideTransition(
                              position: _nowPlayingSlide,
                              // The settle flag only shapes the wrappers below, and
                              // they take the page as a prebuilt child: flipping it
                              // rebuilds a handful of widgets instead of the whole
                              // player on the frame the entrance lands.
                              child: ValueListenableBuilder<bool>(
                                valueListenable: _playerSettled,
                                builder: _playerOverlay,
                                child: _playerPageWidget(),
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
        },
      ),
    );
  }

  Widget _desktopLayout(AppleSemanticColors apple, {required bool compactBar}) {
    return Column(
      children: <Widget>[
        Expanded(
          child: Row(
            children: <Widget>[
              _sidebar(apple),
              Container(width: .5, color: apple.separator),
              Expanded(
                child: Column(
                  children: <Widget>[
                    _desktopToolbar(apple),
                    Container(height: .5, color: apple.separator),
                    Expanded(child: RepaintBoundary(child: _content())),
                  ],
                ),
              ),
            ],
          ),
        ),
        RepaintBoundary(
          child: AppPlayerBar(
            state: state,
            compact: compactBar,
            comments: _comments,
            onComments: _toggleComments,
            onOpen: _openNowPlaying,
          ),
        ),
      ],
    );
  }

  // -- large screen (ten-foot) ---------------------------------------------

  /// The 大屏幕模式 composition: destinations at the top, shelves in the middle,
  /// the transport at the bottom. The desktop rail is not drawn here at all —
  /// a remote cannot use a 236 dp source list, and the navigation capsule is
  /// what Apple Music itself uses on a television.
  Widget _largeScreenLayout(AppleSemanticColors apple) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // The shell already sits inside the overscan safe area, so the width
        // the pages may use is the width they were handed, not the panel's.
        // Without this the four-across shelf is measured from the panel and
        // the fifth card sneaks in past the overscan gutter.
        final MediaQueryData media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(size: constraints.biggest),
          child: Column(
            children: <Widget>[
              LargeScreenNavBar(
                selected: _largeScreenTab,
                searchActive: _section == _AppSection.search && !_hasOpenDetail,
                canGoBack: _hasOpenDetail,
                onBack: _backToRoot,
                onTab: (LargeScreenTab tab) => _select(switch (tab) {
                  LargeScreenTab.home => _AppSection.home,
                  LargeScreenTab.library => _AppSection.library,
                  LargeScreenTab.likes => _AppSection.likes,
                  LargeScreenTab.settings => _AppSection.settings,
                }),
                onSearch: () => _select(_AppSection.search),
                onNowPlaying: _openNowPlaying,
                account: _accountButton(apple, radius: 22),
                playing: state.playing,
              ),
              // The page owns the whole area under the capsule; the transport
              // strip is painted over it, with no panel of its own. Pages end
              // their scroll content with `floatingBarInset` so the last row
              // can still be brought above the strip.
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    RepaintBoundary(child: _content()),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 10,
                      child: RepaintBoundary(
                        child: LargeScreenTransport(
                          state: state,
                          onOpen: _openNowPlaying,
                        ),
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

  LargeScreenTab get _largeScreenTab => switch (_section) {
    _AppSection.home || _AppSection.search => LargeScreenTab.home,
    _AppSection.library => LargeScreenTab.library,
    _AppSection.likes => LargeScreenTab.likes,
    _AppSection.settings => LargeScreenTab.settings,
  };

  /// Builds the current large-screen page.
  ///
  /// The page selection mirrors [_contentPage], but the pages themselves are
  /// the shelf-and-rail composition instead of the desktop lists. Details that
  /// are not worth a second implementation on a television (settings, local
  /// music, comments) are reused at a larger reading measure.
  Widget _largeScreenPage() {
    final LargeScreenActions actions = LargeScreenActions(
      onOpenPlaylist: _openPlaylist,
      onOpenAlbum: _openAlbum,
      onOpenArtist: (ArtistRef artist) => artistDetailRequest.value = artist,
      onOpenChart: _openChart,
      onOpenLikes: () => _select(_AppSection.likes),
      onOpenLocalMusic: _openLocalMusic,
      onPlayTracks: (List<Track> tracks, int index) =>
          state.playQueue(tracks, startIndex: index),
    );
    if (_comments) {
      final Track? track = state.current;
      final SongCommentsController? controller = _commentsController;
      if (track == null || controller == null) {
        return const LargeScreenNotice(message: '还没有播放中的歌曲。');
      }
      return LargeScreenCommentsPage(
        state: state,
        track: track,
        controller: controller,
      );
    }
    if (_localMusic) return LargeScreenLocalMusicPage(state: state);
    final MusicChart? chart = _chart;
    if (chart != null) return LargeScreenChartPage(state: state, chart: chart);
    final ArtistRef? artist = _artist;
    if (artist != null) {
      return LargeScreenArtistPage(state: state, artist: artist);
    }
    final Playlist? playlist = _playlist;
    if (playlist != null) {
      return LargeScreenCollectionPage(
        state: state,
        playlist: playlist,
        album: _album,
      );
    }
    return switch (_section) {
      _AppSection.home => LargeScreenHomePage(state: state, actions: actions),
      _AppSection.search => LargeScreenSearchPage(
        state: state,
        actions: actions,
      ),
      _AppSection.library => LargeScreenLibraryPage(
        state: state,
        actions: actions,
      ),
      _AppSection.likes => LargeScreenLikesPage(state: state),
      _AppSection.settings => LargeScreenSettingsPage(
        state: state,
        onOpenLocalMusic: _openLocalMusic,
      ),
    };
  }

  Widget _compactLayout(AppleSemanticColors apple, {required bool compactBar}) {
    return Column(
      children: <Widget>[
        _mobileToolbar(apple),
        Expanded(child: RepaintBoundary(child: _content())),
        if (state.current != null)
          RepaintBoundary(
            child: AppPlayerBar(
              state: state,
              compact: true,
              comments: _comments,
              onComments: _toggleComments,
              onOpen: _openNowPlaying,
            ),
          ),
        AppleGlass(
          borderRadius: BorderRadius.zero,
          blurSigma: 16,
          color: apple.glass,
          border: Border(top: BorderSide(color: apple.separator, width: .5)),
          child: NavigationBar(
            selectedIndex: _section.index,
            onDestinationSelected: (int index) =>
                _select(_AppSection.values[index]),
            destinations: <NavigationDestination>[
              NavigationDestination(
                icon: const Icon(Icons.home_outlined),
                selectedIcon: const Icon(Icons.home_rounded),
                label: context.tr('主页'),
              ),
              NavigationDestination(
                icon: const Icon(Icons.search_outlined),
                selectedIcon: const Icon(Icons.search_rounded),
                label: context.tr('搜索'),
              ),
              NavigationDestination(
                icon: const Icon(Icons.library_music_outlined),
                selectedIcon: const Icon(Icons.library_music_rounded),
                label: context.tr('音乐库'),
              ),
              NavigationDestination(
                icon: const Icon(Icons.favorite_border_rounded),
                selectedIcon: const Icon(Icons.favorite_rounded),
                label: context.tr('我喜欢'),
              ),
              NavigationDestination(
                icon: const Icon(Icons.settings_outlined),
                selectedIcon: const Icon(Icons.settings_rounded),
                label: context.tr('设置'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // -- sidebar and toolbars -------------------------------------------------

  Widget _sidebar(AppleSemanticColors apple) {
    return AppleGlass(
      borderRadius: BorderRadius.zero,
      blurSigma: 16,
      color: apple.glass.withValues(alpha: .92),
      child: SizedBox(
        width: 236,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 14, 14),
              child: Text(
                'Lazer',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: apple.label,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.5,
                ),
              ),
            ),
            Expanded(
              child: CustomScrollView(
                slivers: <Widget>[
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 0),
                    sliver: SliverList.list(
                      children: <Widget>[
                        _sidebarLabel(apple, '浏览'), // i18n:key
                        AppRailItem(
                          icon: Icons.search_rounded,
                          label: '搜索',
                          selected:
                              _section == _AppSection.search &&
                              _playlist == null &&
                              _artist == null &&
                              _chart == null &&
                              !_comments,
                          onTap: () => _select(_AppSection.search),
                        ),
                        const SizedBox(height: 2),
                        AppRailItem(
                          icon: Icons.home_rounded,
                          label: '主页',
                          selected:
                              _section == _AppSection.home &&
                              _playlist == null &&
                              _artist == null &&
                              _chart == null &&
                              !_comments,
                          onTap: () => _select(_AppSection.home),
                        ),
                        const SizedBox(height: 2),
                        AppRailItem(
                          icon: Icons.library_music_rounded,
                          label: '音乐库',
                          selected:
                              _section == _AppSection.library &&
                              _playlist == null &&
                              _artist == null &&
                              _chart == null &&
                              !_comments,
                          onTap: () => _select(_AppSection.library),
                        ),
                        const SizedBox(height: 2),
                        AppRailItem(
                          icon: Icons.favorite_rounded,
                          label: '我喜欢',
                          selected:
                              _section == _AppSection.likes &&
                              _playlist == null &&
                              _artist == null &&
                              _chart == null &&
                              !_comments,
                          onTap: () => _select(_AppSection.likes),
                        ),
                        const SizedBox(height: 22),
                        SizedBox(
                          height: 33,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 9),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: <Widget>[
                                Text(
                                  context.tr('资料库'),
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(
                                        color: apple.secondaryLabel,
                                        fontWeight: FontWeight.w600,
                                      ),
                                ),
                                if (state.signedIn) ...<Widget>[
                                  const SizedBox(width: 9),
                                  Transform.translate(
                                    offset: const Offset(0, 1),
                                    child: _LibraryRefreshButton(
                                      onRefresh: () =>
                                          state.refreshCollections(force: true),
                                    ),
                                  ),
                                ],
                                const Spacer(),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 5),
                      ],
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                    sliver: _railPlaylists(apple),
                  ),
                ],
              ),
            ),
            Container(height: .5, color: apple.separator),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 8, 10),
              child: Row(
                children: <Widget>[
                  Expanded(child: _accountRow(apple)),
                  const SizedBox(width: 6),
                  _themeToggleButton(),
                ],
              ),
            ),
            // A direct way into settings, right under the account block; the
            // account menu keeps its own entry for touch-sized screens.
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 8, 10),
              child: AppRailItem(
                icon: Icons.settings_rounded,
                label: '设置',
                selected: _section == _AppSection.settings,
                onTap: () => _select(_AppSection.settings),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sidebarLabel(AppleSemanticColors apple, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(9, 12, 9, 5),
      child: Text(
        context.tr(label),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: apple.secondaryLabel,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _desktopToolbar(AppleSemanticColors apple) {
    final bool canGoBack =
        _playlist != null ||
        _artist != null ||
        _chart != null ||
        _comments ||
        _localMusic;
    return SizedBox(
      height: 64,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Row(
          children: <Widget>[
            if (canGoBack) ...<Widget>[
              _ToolbarButton(
                tooltip: '返回',
                icon: Icons.chevron_left_rounded,
                onPressed: _backToRoot,
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                context.tr(_pageTitle),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: apple.label,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mobileToolbar(AppleSemanticColors apple) {
    final bool canGoBack =
        _playlist != null ||
        _artist != null ||
        _chart != null ||
        _comments ||
        _localMusic;
    return SizedBox(
      height: 50,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: <Widget>[
            if (canGoBack) ...<Widget>[
              _ToolbarButton(
                tooltip: '返回',
                icon: Icons.chevron_left_rounded,
                onPressed: _backToRoot,
              ),
              const SizedBox(width: 10),
            ] else
              const SizedBox(width: 8),
            Expanded(
              child: Text(
                context.tr(_pageTitle),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: apple.label,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            _ToolbarButton(
              tooltip: Theme.of(context).brightness == Brightness.dark
                  ? '浅色外观'
                  : '深色外观',
              icon: Theme.of(context).brightness == Brightness.dark
                  ? Icons.light_mode_rounded
                  : Icons.dark_mode_rounded,
              onPressed: () => unawaited(
                state.setThemeMode(
                  Theme.of(context).brightness == Brightness.dark
                      ? ThemeMode.light
                      : ThemeMode.dark,
                ),
              ),
            ),
            const SizedBox(width: 2),
            _accountButton(apple, radius: 15),
          ],
        ),
      ),
    );
  }

  String get _pageTitle {
    if (_comments) return '评论'; // i18n:key
    if (_localMusic) return '本地音乐'; // i18n:key
    if (_chart != null) return _chart!.title;
    if (_playlist != null) return _playlist!.name;
    if (_artist != null) {
      if (_artistSongs) return '全部歌曲'; // i18n:key
      if (_artistReleases == AlbumReleaseGroup.album) return '全部专辑'; // i18n:key
      if (_artistReleases == AlbumReleaseGroup.singleEp) {
        return '全部单曲 / EP'; // i18n:key
      }
      return _artist!.name;
    }
    return switch (_section) {
      _AppSection.home => '发现', // i18n:key
      _AppSection.search => '搜索', // i18n:key
      _AppSection.library => '资料库', // i18n:key
      _AppSection.likes => '我喜欢的音乐', // i18n:key
      _AppSection.settings => '设置', // i18n:key
    };
  }

  Widget _railPlaylists(AppleSemanticColors apple) {
    final collections = state.collections;
    if (!identical(_railCollectionsSource, collections)) {
      _railCollectionsSource = collections;
      _railPlaylistCache = <Playlist>[
        if (collections.liked != null) collections.liked!,
        ...collections.created,
        ...collections.subscribed,
      ];
    }
    final List<Playlist> playlists = _railPlaylistCache;
    if (playlists.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(9, 5, 9, 8),
          child: Text(
            context.tr(state.isGuest ? '登录后同步你的歌单' : '暂无歌单'),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: apple.tertiaryLabel),
          ),
        ),
      );
    }
    // Only the rows on screen are mounted: an account can hold a thousand
    // playlists, and every shell rebuild used to rebuild all of them.
    return SliverList.builder(
      itemCount: playlists.length,
      itemBuilder: (BuildContext context, int index) {
        final Playlist playlist = playlists[index];
        return _RailPlaylist(
          playlist: playlist,
          selected: _playlist?.id == playlist.id,
          onTap: () => _openPlaylist(playlist),
        );
      },
    );
  }

  String get _accountInitial {
    if (state.isGuest) return '访'; // i18n:key
    final String name = state.user.name.trim();
    if (name.isEmpty) return '你'; // i18n:key
    return name.characters.first;
  }

  void _onAccountSelected(String value) {
    if (value == 'login' || value == 'platform') {
      unawaited(showAppLoginDialog(context, state));
    } else if (value == 'logout') {
      state.signOut();
    } else if (value == 'settings') {
      _select(_AppSection.settings);
    }
  }

  List<PopupMenuEntry<String>> _accountMenuItems(
    BuildContext context,
    AppleSemanticColors apple,
  ) => <PopupMenuEntry<String>>[
    PopupMenuItem<String>(
      value: 'header',
      enabled: false,
      child: Text(
        state.isGuest
            ? context.tr('游客模式')
            : '${state.user.name} · ${context.tr(state.user.vipLabel ?? '普通用户')}',
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: apple.secondaryLabel),
      ),
    ),
    if (state.isGuest)
      PopupMenuItem<String>(value: 'login', child: TrText('登录'))
    else
      PopupMenuItem<String>(value: 'logout', child: TrText('退出登录')),
    PopupMenuItem<String>(value: 'settings', child: TrText('设置')),
    PopupMenuItem<String>(
      value: 'platform',
      child: Row(
        children: [
          const Expanded(child: TrText('音乐平台')),
          if (state.musicProvider.experimental) const ExperimentalMusicBadge(),
        ],
      ),
    ),
  ];

  /// avatar + name on the left, the theme toggle on its right. Tapping the
  /// avatar opens the account menu; a guest gets the login flow instead.
  Widget _accountRow(AppleSemanticColors apple) {
    final String name = state.isGuest ? context.tr('游客') : state.user.name;
    final String detail = state.isNavidrome
        ? 'Navidrome · ${context.tr('实验性')}'
        : state.isGuest
        ? context.tr('登录以同步资料库')
        : context.tr(state.user.vipLabel ?? '普通用户');
    return PopupMenuButton<String>(
      key: const ValueKey('rail-account'),
      tooltip: context.tr(state.isGuest ? '登录' : state.user.name),
      offset: const Offset(0, -6),
      color: apple.tertiaryBackground,
      surfaceTintColor: Colors.transparent,
      elevation: 18,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      onSelected: _onAccountSelected,
      itemBuilder: (BuildContext context) => _accountMenuItems(context, apple),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        child: Row(
          children: <Widget>[
            _Avatar(
              apple: apple,
              radius: 14,
              label: _accountInitial,
              avatarUrl: state.isGuest ? null : state.user.avatarUrl,
              signedIn: !state.isGuest,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: apple.label,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: apple.secondaryLabel,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _themeToggleButton() {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return _ToolbarButton(
      tooltip: dark ? '浅色外观' : '深色外观',
      icon: dark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
      onPressed: () => unawaited(
        state.setThemeMode(dark ? ThemeMode.light : ThemeMode.dark),
      ),
    );
  }

  Widget _accountButton(AppleSemanticColors apple, {double radius = 15}) {
    return PopupMenuButton<String>(
      tooltip: context.tr(state.isGuest ? '登录' : state.user.name),
      offset: const Offset(0, 42),
      color: apple.tertiaryBackground,
      surfaceTintColor: Colors.transparent,
      elevation: 18,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      onSelected: _onAccountSelected,
      itemBuilder: (BuildContext context) => _accountMenuItems(context, apple),
      child: _Avatar(
        apple: apple,
        radius: radius,
        label: _accountInitial,
        avatarUrl: state.isGuest ? null : state.user.avatarUrl,
        signedIn: !state.isGuest,
      ),
    );
  }

  // -- content --------------------------------------------------------------

  Widget _content() {
    final bool motion = !MediaQuery.disableAnimationsOf(context);
    final bool largeScreen = largeScreenModeOf(context);
    return RetainedContentSwitcher(
      currentKey: _contentKey,
      retainKeys: {
        ..._browseHistory.map((location) => location.key),
        if (!largeScreen) '$activePlatformContentKey:section:home',
      },
      backProgress: _backProgress,
      backTargetKey: _backTarget,
      backCommitted: _backCommitted,
      duration: motion ? const Duration(milliseconds: 420) : Duration.zero,
      onTransitionChanged: _onContentTransitionChanged,
      slideFraction: largeScreen ? .012 : .04,
      page: TvFocusRegion(focusToken: _nowPlayingOpen, child: _contentPage()),
    );
  }

  String get _contentKey => '$activePlatformContentKey:$_pageContentKey';
  String get activePlatformContentKey => state.activeConnectionKey;
  String get _pageContentKey {
    if (_comments) return 'comments';
    if (_localMusic) return 'local-music';
    if (_chart != null) return 'chart:${_chart!.id}';
    if (_artist != null) {
      final String view = _artistSongs
          ? 'songs'
          : _artistReleases == null
          ? 'overview'
          : 'releases:${_artistReleases!.name}';
      return 'artist:${_artist!.key}:$view';
    }
    final Playlist? playlist = _playlist;
    if (playlist != null) return 'playlist:${playlist.id}';
    return 'section:${_section.name}';
  }

  Widget _contentPage() {
    // A television gets the ten-foot composition: same state, same catalogue,
    // same playback — a different page tree.
    if (largeScreenModeOf(context)) return _largeScreenPage();
    if (_comments) {
      final Track? track = state.current;
      final SongCommentsController? controller = _commentsController;
      if (track == null || controller == null) {
        return const AppNotice(message: '还没有播放中的歌曲。');
      }
      return Column(
        children: <Widget>[
          ApplePageTitle(
            title: '评论',
            subtitle: track.title,
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 6),
          ),
          Expanded(
            child: SongCommentsView(
              state: state,
              track: track,
              controller: controller,
            ),
          ),
        ],
      );
    }
    final MusicChart? chart = _chart;
    if (chart != null) {
      return AppChartPage(state: state, chart: chart);
    }
    if (_localMusic) {
      return LocalMusicPage(state: state);
    }
    final ArtistRef? artist = _artist;
    if (artist != null) {
      if (_artistSongs) {
        return AppArtistSongsPage(state: state, artist: artist);
      }
      final AlbumReleaseGroup? releaseGroup = _artistReleases;
      if (releaseGroup != null) {
        return AppArtistReleasesPage(
          state: state,
          artist: artist,
          group: releaseGroup,
        );
      }
      return AppArtistPage(
        state: state,
        artist: artist,
        onOpenAllSongs: _openArtistSongs,
        onOpenAlbums: () => _openArtistReleases(AlbumReleaseGroup.album),
        onOpenSingles: () => _openArtistReleases(AlbumReleaseGroup.singleEp),
      );
    }
    final Playlist? playlist = _playlist;
    if (playlist != null) {
      return AppPlaylistPage(state: state, playlist: playlist, album: _album);
    }
    return switch (_section) {
      _AppSection.home => AppHomePage(
        state: state,
        onOpenPlaylist: _openPlaylist,
        onOpenChart: _openChart,
        onPlayTrack: (List<Track> tracks, int index) =>
            state.playQueue(tracks, startIndex: index),
      ),
      _AppSection.search => AppSearchPage(
        state: state,
        onOpenPlaylist: _openPlaylist,
      ),
      _AppSection.library => AppLibraryPage(
        state: state,
        onOpenPlaylist: _openPlaylist,
        onOpenLocalMusic: _openLocalMusic,
      ),
      _AppSection.likes => AppLikesPage(state: state),
      _AppSection.settings => AppSettingsPage(
        state: state,
        onOpenLocalMusic: _openLocalMusic,
      ),
    };
  }
}

class _ToolbarButton extends StatefulWidget {
  const _ToolbarButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  State<_ToolbarButton> createState() => _ToolbarButtonState();
}

class _ToolbarButtonState extends State<_ToolbarButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Tooltip(
        message: context.tr(widget.tooltip),
        child: TvTapTarget(
          onTap: feedbackAction(context, widget.onPressed),
          borderRadius: BorderRadius.circular(17),
          focusScale: 1.08,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: feedbackAction(context, widget.onPressed),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: _hovering ? apple.tertiaryFill : Colors.transparent,
                shape: BoxShape.circle,
              ),
              child: Icon(widget.icon, size: 20, color: apple.secondaryLabel),
            ),
          ),
        ),
      ),
    );
  }
}

class _LibraryRefreshButton extends StatefulWidget {
  const _LibraryRefreshButton({required this.onRefresh});
  final Future<void> Function() onRefresh;

  @override
  State<_LibraryRefreshButton> createState() => _LibraryRefreshButtonState();
}

class _LibraryRefreshButtonState extends State<_LibraryRefreshButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _rotation;
  }

  @override
  void dispose() {
    _rotation.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    if (!MediaQuery.disableAnimationsOf(context)) _rotation.forward(from: 0);
    try {
      await widget.onRefresh();
    } finally {
      if (mounted) _refreshing = false;
    }
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: context.tr('同步歌单'),
    button: true,
    child: TvTapTarget(
      onTap: () => unawaited(_refresh()),
      borderRadius: BorderRadius.circular(9),
      focusScale: 1.15,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => unawaited(_refresh()),
        child: SizedBox.square(
          dimension: 16,
          child: RotationTransition(
            turns: _rotation.drive(CurveTween(curve: const AppleSpringCurve())),
            child: Icon(
              Icons.sync_rounded,
              size: 12,
              color: AppleSemanticColors.of(context).secondaryLabel,
            ),
          ),
        ),
      ),
    ),
  );
}

class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.apple,
    required this.radius,
    required this.label,
    this.avatarUrl,
    this.signedIn = false,
  });

  final AppleSemanticColors apple;
  final double radius;
  final String label;
  final String? avatarUrl;
  final bool signedIn;

  @override
  Widget build(BuildContext context) {
    final String? url = enlargedArtworkUrl(avatarUrl, sizePx: 96);
    final Widget fallback = Center(
      child: signedIn
          ? Icon(Icons.person_rounded, size: radius * 1.15, color: Colors.white)
          : Text(
              context.tr(label),
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
    );
    return Container(
      width: radius * 2,
      height: radius * 2,
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            Color.lerp(apple.accent, Colors.white, .18)!,
            apple.accent,
          ],
        ),
        shape: BoxShape.circle,
      ),
      child: url == null
          ? fallback
          : Image(
              image: ArtworkImage(url),
              fit: BoxFit.cover,
              width: radius * 2,
              height: radius * 2,
              gaplessPlayback: true,
              frameBuilder:
                  (
                    BuildContext context,
                    Widget child,
                    int? frame,
                    bool wasSynchronouslyLoaded,
                  ) => wasSynchronouslyLoaded || frame != null
                  ? child
                  : fallback,
              errorBuilder:
                  (
                    BuildContext context,
                    Object error,
                    StackTrace? stackTrace,
                  ) => fallback,
            ),
    );
  }
}

class _RailPlaylist extends StatefulWidget {
  const _RailPlaylist({
    required this.playlist,
    required this.selected,
    required this.onTap,
  });

  final Playlist playlist;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_RailPlaylist> createState() => _RailPlaylistState();
}

class _RailPlaylistState extends State<_RailPlaylist> {
  bool _hovering = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      cursor: SystemMouseCursors.click,
      child: TvTapTarget(
        onTap: feedbackAction(context, widget.onTap),
        onFocusChange: (bool value) => setState(() => _focused = value),
        borderRadius: BorderRadius.circular(7),
        focusScale: 1.01,
        child: GestureDetector(
          onTap: feedbackAction(context, widget.onTap),
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: 34,
            margin: const EdgeInsets.only(bottom: 1),
            padding: const EdgeInsets.symmetric(horizontal: 7),
            decoration: BoxDecoration(
              color: widget.selected
                  ? apple.fill
                  : _hovering || _focused
                  ? apple.tertiaryFill
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Row(
              children: <Widget>[
                AppCover(
                  url: widget.playlist.coverUrl,
                  size: 24,
                  radius: 5,
                  iconSize: 12,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    widget.playlist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: widget.selected || _focused
                          ? apple.label
                          : apple.secondaryLabel,
                      fontWeight: widget.selected
                          ? FontWeight.w600
                          : FontWeight.w400,
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

/// The shell's side of the player's pull-down: it drives the very motion that
/// opens the player, so a drag is continuous with the open and close
/// transitions instead of a separate animation.
class _PlayerPull implements PlayerPullDown {
  _PlayerPull(this._shell);

  final _AppShellState _shell;
  double _initialOpen = 1;
  bool _dragging = false;

  @override
  bool get canStart =>
      _shell._nowPlayingOpen &&
      !_dragging &&
      _shell._nowPlayingMotion.value > .001;

  @override
  void startPull() {
    _dragging = true;
    _initialOpen = _shell._nowPlayingMotion.value;
    _shell._nowPlayingMotion.stop();
    _shell._playerSettled.value = false;
  }

  @override
  void updatePull(double progress) {
    // Stay off the lower bound: the controller reports a dismissal as soon as
    // it reaches zero, and the pull is not committed until the finger lifts.
    _shell._nowPlayingMotion.value = (_initialOpen - progress).clamp(
      .001,
      _initialOpen > 1 ? _initialOpen : 1.0,
    );
  }

  @override
  void endPull(double velocity) {
    _dragging = false;
    _shell._settlePlayerPull(velocity);
  }

  @override
  void cancelPull() {
    _dragging = false;
    _shell._settlePlayerPull(0, cancel: true);
  }
}

/// A [ChangeNotifier] the shell pings when it wants a rebuild, so playback
/// reports can be filtered instead of rebuilding the page ten times a second.
class _ShellRepaint extends ChangeNotifier with BuildSafeNotifier {
  void ping() => notifyListeners();
}
