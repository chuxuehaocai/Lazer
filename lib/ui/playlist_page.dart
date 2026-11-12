import '../state/build_safe_notifier.dart';
import '../widgets/build_safe_state.dart';
import '../animation/apple_spring.dart';
import '../widgets/spring_buttons.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../animation/apple_modal.dart';

import '../data/models.dart';
import '../downloads/download_dialog.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../theme/apple_design.dart';
import '../tv/tv_mode.dart';
import '../widgets/catalog_links.dart';
import '../widgets/accessible_controls.dart';
import '../widgets/cover_transition.dart';
import '../widgets/track_batch_bar.dart';
import 'login.dart';
import 'widgets.dart';

/// The liked-songs library entry.
class AppLikesPage extends StatelessWidget {
  const AppLikesPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    if (!state.hasNetworkProvider) {
      return AppNotice(
        message: '切换到音乐平台后查看喜欢的音乐。',
        icon: Icons.favorite_border_rounded,
        action: SpringFilledButton(
          onPressed: () => unawaited(showAppLoginDialog(context, state)),
          child: const TrText('音乐平台'),
        ),
      );
    }
    if (state.isGuest) {
      return AppNotice(
        message: '登录后查看喜欢的音乐。',
        icon: Icons.favorite_border_rounded,
        action: SpringFilledButton(
          onPressed: () => unawaited(showAppLoginDialog(context, state)),
          child: const TrText('登录'),
        ),
      );
    }
    final Playlist? liked = state.collections.liked;
    if (liked == null) {
      final String? error = state.collectionsError;
      if (error != null) {
        return AppNotice(
          message: error,
          icon: Icons.wifi_off_rounded,
          action: SpringFilledButton(
            onPressed: () => unawaited(state.refreshCollections(force: true)),
            child: const TrText('重试'),
          ),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }
    return AppPlaylistPage(state: state, playlist: liked, embedded: true);
  }
}

/// One playlist with the Apple Music large album header and track list.
class AppPlaylistPage extends StatefulWidget {
  const AppPlaylistPage({
    super.key,
    required this.state,
    required this.playlist,
    this.embedded = false,
    this.album,
  });

  final AppState state;
  final Playlist playlist;
  final bool embedded;

  /// When set, the page loads album tracks instead of playlist tracks. The
  /// album still travels through [playlist] for the header and title, so both
  /// details share one implementation.
  final Album? album;

  @override
  State<AppPlaylistPage> createState() => _AppPlaylistPageState();
}

class _AppPlaylistPageState extends State<AppPlaylistPage>
    with BuildSafeState<AppPlaylistPage>, WidgetsBindingObserver {
  final ScrollController _scroll = ScrollController();
  final GlobalKey _headerKey = GlobalKey();
  final ValueNotifier<bool> _showLocate = BuildSafeValueNotifier<bool>(false);
  bool _refreshScheduled = false;
  List<Track>? _tracks;
  String? _note;
  String? _error;
  List<double>? _rowTops;
  List<double>? _rowHeights;
  bool _metricsDirty = true;
  // The locator asks for the playing row on every scroll frame; remembering
  // the answer keeps a long playlist from scanning its tracks each frame.
  String? _rowIndexTrackId;
  int _rowIndexCache = -1;
  int _requestSerial = 0;
  bool _refreshOnResume = false;
  bool _selecting = false;
  final Set<String> _selected = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_scheduleLocateRefresh);
    widget.state.addListener(_scheduleLocateRefresh);
    unawaited(_load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _metricsDirty = true;
    _scheduleLocateRefresh();
  }

  @override
  void didUpdateWidget(covariant AppPlaylistPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_scheduleLocateRefresh);
      widget.state.addListener(_scheduleLocateRefresh);
    }
    if (oldWidget.state != widget.state ||
        oldWidget.playlist.id != widget.playlist.id ||
        oldWidget.album?.id != widget.album?.id) {
      _tracks = null;
      _selecting = false;
      _selected.clear();
      _note = null;
      _rowTops = null;
      _rowHeights = null;
      _metricsDirty = true;
      _rowIndexTrackId = null;
      _rowIndexCache = -1;
      _showLocate.value = false;
      unawaited(_load());
      final int serial = _requestSerial;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && serial == _requestSerial && _scroll.hasClients) {
          _scroll.jumpTo(0);
        }
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scroll.removeListener(_scheduleLocateRefresh);
    widget.state.removeListener(_scheduleLocateRefresh);
    _showLocate.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _refreshOnResume = true;
      return;
    }
    if (!_refreshOnResume || !mounted) return;
    _refreshOnResume = false;
    // A request that was in flight while the app was backgrounded can be left
    // behind by the platform/network stack. Start a new generation on resume;
    // _load's serial makes any late page from the old request harmless.
    unawaited(_load(force: true));
  }

  Future<void> _load({bool force = false}) async {
    final int serial = ++_requestSerial;
    final catalog = widget.state.catalog;
    final String playlistId = widget.playlist.id;
    setState(() => _error = null);
    final Album? album = widget.album;
    try {
      if (album == null && _tracks == null) {
        // Last session's track list paints immediately; the live request below
        // replaces it as soon as the gateway answers.
        final List<Track>? stored = await catalog.cachedPlaylistTracks(
          playlistId,
        );
        if (!mounted || serial != _requestSerial) return;
        if (stored != null && _tracks == null) {
          setState(() {
            _tracks = stored;
            _metricsDirty = true;
            _rowIndexTrackId = null;
            _rowIndexCache = -1;
          });
          _scheduleLocateRefresh();
        }
      }
      if (album != null) {
        // The list row only carries a stub Album; the full description lives
        // on the album detail endpoint.
        final details = await catalog.albumDetailsFor(album.id, force: force);
        if (!mounted || serial != _requestSerial) return;
        setState(() {
          _tracks = details.tracks;
          _note = details.description;
          _metricsDirty = true;
          _rowIndexTrackId = null;
          _rowIndexCache = -1;
        });
        _scheduleLocateRefresh();
        return;
      }

      // Replace the stale snapshot with the first live page, then append each
      // following 100-song page as soon as it arrives. AppCover starts its own
      // image request, so a slow cover CDN cannot delay the song rows.
      final fresh = <Track>[];
      await for (final page in catalog.playlistTrackPages(playlistId)) {
        if (!mounted || serial != _requestSerial) return;
        fresh.addAll(page);
        setState(() {
          _tracks = List<Track>.unmodifiable(fresh);
          _metricsDirty = true;
          _rowIndexTrackId = null;
          _rowIndexCache = -1;
        });
        _scheduleLocateRefresh();
      }
    } catch (_) {
      if (!mounted || serial != _requestSerial) return;
      setState(() => _error = '歌单读取失败，请重试。'); // i18n:key
    }
  }

  /// Natural height of one [AppTrackRow]: 44 px cover, up to three
  /// single-line text rows and the row's vertical padding/margin.
  ///
  /// Every text line is single-line with ellipsis, so its height depends on
  /// the theme style alone — not on the words. Measuring the two styles once
  /// keeps a 1,000-song playlist from laying out 3,000 text painters on the
  /// frame the locator first needs its offsets.
  static double _lineHeight(TextStyle? style, TextScaler scaler) {
    final TextPainter painter = TextPainter(
      text: TextSpan(text: '国', style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final double height = painter.height;
    painter.dispose();
    return height;
  }

  void _ensureRowMetrics() {
    final List<Track>? tracks = _tracks;
    if (tracks == null) {
      _rowTops = null;
      _rowHeights = null;
      return;
    }
    if (!_metricsDirty &&
        _rowTops?.length == tracks.length &&
        _rowHeights?.length == tracks.length) {
      return;
    }
    final ThemeData theme = Theme.of(context);
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    // Only two possible row heights exist (with/without a translated title);
    // sampling them once turns the per-track work into one addition.
    final double title = _lineHeight(theme.textTheme.bodyMedium, scaler);
    final double detail = _lineHeight(theme.textTheme.bodySmall, scaler);
    final double plain = math.max(44.0, title + detail) + 16.0;
    final double translated = math.max(44.0, title + detail * 2) + 16.0;
    final List<double> tops = <double>[];
    final List<double> heights = <double>[];
    var offset = 0.0;
    for (final Track track in tracks) {
      final String? subtitle = track.translatedTitle?.trim();
      final double extent = subtitle == null || subtitle.isEmpty
          ? plain
          : translated;
      tops.add(offset);
      heights.add(extent);
      offset += extent;
    }
    _rowTops = tops;
    _rowHeights = heights;
    _metricsDirty = false;
  }

  int _currentIndex(List<Track> tracks) {
    final Track? current = widget.state.current;
    if (current == null) {
      _rowIndexTrackId = null;
      _rowIndexCache = -1;
      return -1;
    }
    if (_rowIndexTrackId == current.id) return _rowIndexCache;
    final int index = tracks.indexWhere(
      (Track track) => track.id == current.id,
    );
    _rowIndexTrackId = current.id;
    _rowIndexCache = index;
    return index;
  }

  void _scheduleLocateRefresh() {
    if (_refreshScheduled) return;
    _refreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshScheduled = false;
      _refreshLocate();
    });
  }

  void _refreshLocate() {
    if (!mounted) return;
    final bool show = _shouldShowLocate();
    if (_showLocate.value != show) _showLocate.value = show;
  }

  /// Show the locator only when the playing track belongs to this playlist
  /// and its row is currently outside the visible scroll range.
  bool _shouldShowLocate() {
    final List<Track>? tracks = _tracks;
    if (tracks == null || tracks.isEmpty || !_scroll.hasClients) return false;
    final int index = _currentIndex(tracks);
    if (index < 0) return false;
    _ensureRowMetrics();
    final List<double>? tops = _rowTops;
    final List<double>? heights = _rowHeights;
    final double? header = _headerKey.currentContext?.size?.height;
    if (tops == null || heights == null || header == null) return false;
    final double top = 12 + header + tops[index];
    final double bottom = top + heights[index];
    final double viewTop = _scroll.offset;
    final double viewBottom =
        viewTop +
        _scroll.position.viewportDimension -
        MediaQuery.paddingOf(context).bottom;
    return bottom <= viewTop || top >= viewBottom;
  }

  Future<void> _locateCurrent() async {
    final List<Track>? tracks = _tracks;
    if (tracks == null || tracks.isEmpty || !_scroll.hasClients) return;
    final int index = _currentIndex(tracks);
    if (index < 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.tr('当前歌曲不在这个歌单中'))));
      return;
    }
    _ensureRowMetrics();
    final List<double>? tops = _rowTops;
    final List<double>? heights = _rowHeights;
    if (tops == null || heights == null) return;
    final double header = _headerKey.currentContext?.size?.height ?? 0;
    final double top = 12 + header + tops[index];
    final double extent = heights[index];
    final double viewport =
        _scroll.position.viewportDimension -
        MediaQuery.paddingOf(context).bottom;
    final double target = (top - (viewport - extent) / 2).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    await _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 360),
      curve: const AppleSpringCurve(),
    );
  }

  void _selectTrack(Track track, {bool enter = false}) {
    setState(() {
      _selecting = true;
      if (enter || !_selected.contains(track.id)) {
        _selected.add(track.id);
      } else {
        _selected.remove(track.id);
      }
    });
  }

  void _closeSelection() => setState(() {
    _selecting = false;
    _selected.clear();
  });

  void _selectAll(List<Track> tracks) => setState(() {
    if (_selected.length == tracks.map((track) => track.id).toSet().length) {
      _selected.clear();
    } else {
      _selected.addAll(tracks.map((track) => track.id));
    }
  });

  @override
  Widget build(BuildContext context) {
    final List<Track>? tracks = _tracks;
    final double inset = pageInset(context);
    final bool compact = MediaQuery.sizeOf(context).width < 680;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            CustomScrollView(
              controller: _scroll,
              slivers: <Widget>[
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(inset, 12, inset, 0),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      key: _headerKey,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        AppPlaylistHeader(
                          playlist: widget.playlist,
                          compact: compact,
                          artist: widget.album?.artist,
                          artistWidget: widget.album == null
                              ? null
                              : ArtistNameLink(
                                  state: widget.state,
                                  artists: widget.album!.artists,
                                  fallback: widget.album!.artist,
                                ),
                          note: _note ?? widget.album?.note,
                          noteIsData: _note != null,
                          onPlay: tracks == null || tracks.isEmpty
                              ? null
                              : () => widget.state.playQueue(tracks),
                          onShuffle: tracks == null || tracks.isEmpty
                              ? null
                              : () => widget.state.playQueue(
                                  List<Track>.of(tracks)..shuffle(),
                                ),
                          onDownload: tracks == null || tracks.isEmpty
                              ? null
                              : () => downloadTracks(
                                  context,
                                  widget.state,
                                  tracks,
                                  folderName: widget.playlist.name,
                                ),
                        ),
                        const SizedBox(height: 22),
                        if (_error != null)
                          AppNotice(
                            message: _error!,
                            action: SpringFilledButton(
                              onPressed: () => unawaited(_load(force: true)),
                              child: const TrText('重试'),
                            ),
                          )
                        else if (tracks == null)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 52),
                            child: Center(child: CircularProgressIndicator()),
                          )
                        else if (tracks.isEmpty)
                          const AppNotice(message: '这个歌单还没有可播放的曲目。')
                        else
                          AppSectionHeader(
                            title: '歌曲',
                            subtitle: '${tracks.length} 首',
                          ),
                        const SizedBox(height: 6),
                      ],
                    ),
                  ),
                ),
                if (tracks != null && tracks.isNotEmpty)
                  SliverPadding(
                    padding: EdgeInsets.symmetric(horizontal: inset),
                    sliver: SliverList.builder(
                      itemCount: tracks.length,
                      itemBuilder: (BuildContext context, int i) => AppTrackRow(
                        key: ValueKey<String>('playlist-row-$i'),
                        track: tracks[i],
                        index: i,
                        current: widget.state.current?.id == tracks[i].id,
                        playing: widget.state.playing,
                        selectionMode: _selecting,
                        selected: _selected.contains(tracks[i].id),
                        onLongPress: () => _selectTrack(tracks[i], enter: true),
                        onTap: () => _selecting
                            ? _selectTrack(tracks[i])
                            : widget.state.playQueue(tracks, startIndex: i),
                        onMenuRequested: (Offset position) => showTrackActions(
                          context,
                          widget.state,
                          tracks[i],
                          position,
                        ),
                      ),
                    ),
                  ),
                // Leave room for the floating locate button so the last row
                // can scroll clear of it.
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 88 + MediaQuery.paddingOf(context).bottom,
                  ),
                ),
              ],
            ),
            if (_selecting && tracks != null)
              Positioned(
                left: 12,
                right: 12,
                bottom: 18 + MediaQuery.paddingOf(context).bottom,
                child: TrackBatchBar(
                  selectedCount: _selected.length,
                  totalCount: tracks.map((track) => track.id).toSet().length,
                  onSelectAll: () => _selectAll(tracks),
                  onDownload:
                      tracks.any(
                        (track) =>
                            _selected.contains(track.id) &&
                            track.isServiceTrack,
                      )
                      ? () => unawaited(
                          downloadTracks(
                            context,
                            widget.state,
                            tracks
                                .where((track) => _selected.contains(track.id))
                                .toList(),
                            folderName: widget.playlist.name,
                          ),
                        )
                      : null,
                  onClose: _closeSelection,
                ),
              ),
            Positioned(
              right: 18,
              bottom: 18 + MediaQuery.paddingOf(context).bottom,
              child: ValueListenableBuilder<bool>(
                valueListenable: _showLocate,
                builder: (BuildContext context, bool show, Widget? _) {
                  if (!show || _selecting) return const SizedBox.shrink();
                  return FloatingActionButton.small(
                    key: const ValueKey<String>('playlist-locate'),
                    heroTag: null,
                    tooltip: context.tr('定位正在播放'),
                    backgroundColor: AppleSemanticColors.of(context).accent,
                    foregroundColor: Colors.white,
                    onPressed: () => unawaited(_locateCurrent()),
                    child: const Icon(Icons.my_location_rounded, size: 20),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AppPlaylistHeader extends StatelessWidget {
  const AppPlaylistHeader({
    super.key,
    required this.playlist,
    required this.compact,
    required this.onPlay,
    this.onDownload,
    this.onShuffle,
    this.artist,
    this.artistWidget,
    this.note,
    this.noteIsData = false,
    this.metadata,
    this.cover,
    this.transitionIdentity,
    this.showShuffle = true,
  });

  final Playlist playlist;
  final bool compact;
  final VoidCallback? onPlay;
  final VoidCallback? onDownload;

  /// Starts the same list in a shuffled order. A chart header hides it because
  /// a chart's order is its meaning.
  final VoidCallback? onShuffle;
  final Widget? metadata;
  final Widget? cover;
  final String? transitionIdentity;
  final bool showShuffle;

  /// Album-only extras. A playlist leaves both null and renders as before.
  final String? artist;

  /// Replaces the plain artist line when the caller can make it a link.
  final Widget? artistWidget;

  /// Either the catalogue's album description or the generated track count.
  final String? note;

  /// True when [note] came from the catalogue and must stay untranslated.
  final bool noteIsData;

  static Future<void> _showNote(
    BuildContext context,
    String note, {
    required bool isData,
  }) => showAppleDialog<void>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: const TrText('专辑简介'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(child: isData ? Text(note) : TrText(note)),
      ),
      actions: <Widget>[
        SpringTextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const TrText('关闭'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final double coverSize = compact ? 168 : 190;
    final Widget stillCover =
        cover ??
        AppCover(
          url: playlist.coverUrl,
          size: coverSize,
          radius: 14,
          fadeIn: true,
        );
    final Widget artwork = CoverTransitionTarget(
      identity: transitionIdentity ?? 'playlist:${playlist.id}',
      size: coverSize,
      child: RepaintBoundary(child: stillCover),
    );
    final Widget? summary = note == null || note!.trim().isEmpty
        ? null
        : TvTapTarget(
            onTap: () => _showNote(context, note!, isData: noteIsData),
            borderRadius: BorderRadius.circular(6),
            child: GestureDetector(
              onTap: () => _showNote(context, note!, isData: noteIsData),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Text(
                  noteIsData ? note! : context.tr(note!),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: compact ? TextAlign.center : TextAlign.start,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: apple.tertiaryLabel,
                    height: 1.5,
                  ),
                ),
              ),
            ),
          );
    final Widget info = Column(
      crossAxisAlignment: compact
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
      children: <Widget>[
        // Desktop stacks the title block against the transport row, so the
        // row sits on the cover's bottom edge and the leftover height opens
        // above the title. Compact layouts have no bounded height to spend.
        if (!compact) const Spacer(),
        CoverTransitionText.target(
          identity: transitionIdentity ?? 'playlist:${playlist.id}',
          role: CoverTextRole.title,
          child: Text(
            playlist.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: compact ? TextAlign.center : TextAlign.start,
            style: theme.textTheme.headlineLarge?.copyWith(
              color: apple.label,
              fontWeight: FontWeight.w700,
              letterSpacing: -.6,
            ),
          ),
        ),
        if (artistWidget != null) ...[
          const SizedBox(height: 4),
          artistWidget!,
        ] else if (artist != null) ...[
          const SizedBox(height: 4),
          Text(
            artist!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: compact ? TextAlign.center : TextAlign.start,
            style: theme.textTheme.titleMedium?.copyWith(
              color: apple.secondaryLabel,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
        // Albums drop the count line: it only forced a blank row between the
        // artist and the summary.
        if (metadata != null) ...[
          const SizedBox(height: 7),
          metadata!,
        ] else if (artist == null) ...[
          const SizedBox(height: 7),
          CoverTransitionText.target(
            identity: transitionIdentity ?? 'playlist:${playlist.id}',
            role: CoverTextRole.detail,
            child: Text(
              <String>[
                if (playlist.trackCount > 0)
                  context.tr('${playlist.trackCount} 首歌曲'),
                if (playlist.description.isNotEmpty) playlist.description,
              ].join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: compact ? TextAlign.center : TextAlign.start,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: apple.secondaryLabel,
              ),
            ),
          ),
        ],
        // The summary rides just above the transport row; compact layouts
        // keep a plain three-line block with no leftover height to spend.
        if (summary != null)
          Padding(padding: const EdgeInsets.only(top: 8), child: summary),
        // The metadata block needs air before the transport row: the pill is
        // a solid shape, and butting it against the count line reads as one
        // smudged block. The desktop column anchors the row to the cover's
        // bottom edge either way, so this only opens space above it.
        const SizedBox(height: 16),
        Wrap(
          alignment: compact ? WrapAlignment.center : WrapAlignment.start,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 10,
          runSpacing: 8,
          children: <Widget>[
            SpringFilledButton.icon(
              onPressed: onPlay,
              icon: const Icon(Icons.play_arrow_rounded, size: 20),
              label: const TrText('播放全部'),
            ),
            if (onDownload != null) ...<Widget>[
              SpringOutlinedButton.icon(
                key: const ValueKey<String>('download-all'),
                onPressed: onDownload,
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const TrText('下载'),
              ),
            ],
            if (showShuffle)
              AccessibleIconButton(
                tooltip: '随机播放',
                onPressed: onShuffle,
                icon: const Icon(Icons.shuffle_rounded, size: 19),
                iconSize: 19,
                color: onShuffle == null ? apple.tertiaryLabel : apple.accent,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 40,
                  height: 40,
                ),
                style: IconButton.styleFrom(
                  backgroundColor: apple.fill,
                  shape: const CircleBorder(),
                ),
              ),
          ],
        ),
      ],
    );
    if (compact) {
      return Column(
        children: <Widget>[artwork, const SizedBox(height: 18), info],
      );
    }
    // The desktop column keeps its transport row on the cover's bottom edge
    // when the metadata fits. A very long playlist name grows the title to two
    // lines and can make the column taller than the artwork; the old fixed
    // `SizedBox(height: coverSize)` then overflowed at the bottom. Intrinsic
    // height lets the row take the taller of the cover and the text block while
    // `Spacer` still pins short metadata to the cover's bottom edge.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Align(alignment: Alignment.topLeft, child: artwork),
          const SizedBox(width: 24),
          Expanded(child: info),
        ],
      ),
    );
  }
}
