import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../downloads/download_dialog.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../theme/apple_design.dart';
import '../tv/tv_mode.dart';
import '../widgets/catalog_links.dart';
import 'legacy_login.dart';
import 'legacy_widgets.dart';

/// The liked-songs library entry.
class LegacyLikesPage extends StatelessWidget {
  const LegacyLikesPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    if (state.isGuest) {
      return LegacyNotice(
        message: '登录后查看喜欢的音乐。',
        icon: Icons.favorite_border_rounded,
        action: FilledButton(
          onPressed: () => unawaited(showLegacyLoginDialog(context, state)),
          child: const TrText('登录'),
        ),
      );
    }
    final Playlist? liked = state.collections.liked;
    if (liked == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return LegacyPlaylistPage(state: state, playlist: liked, embedded: true);
  }
}

/// One playlist with the Apple Music large album header and track list.
class LegacyPlaylistPage extends StatefulWidget {
  const LegacyPlaylistPage({
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
  State<LegacyPlaylistPage> createState() => _LegacyPlaylistPageState();
}

class _LegacyPlaylistPageState extends State<LegacyPlaylistPage> {
  final ScrollController _scroll = ScrollController();
  final GlobalKey _headerKey = GlobalKey();
  final ValueNotifier<bool> _showLocate = ValueNotifier<bool>(false);
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

  @override
  void initState() {
    super.initState();
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
  void didUpdateWidget(covariant LegacyPlaylistPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_scheduleLocateRefresh);
      widget.state.addListener(_scheduleLocateRefresh);
    }
    if (oldWidget.state != widget.state ||
        oldWidget.playlist.id != widget.playlist.id ||
        oldWidget.album?.id != widget.album?.id) {
      _tracks = null;
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
    _scroll.removeListener(_scheduleLocateRefresh);
    widget.state.removeListener(_scheduleLocateRefresh);
    _showLocate.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
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
      final List<Track> tracks;
      String? note;
      if (album != null) {
        // The list row only carries a stub Album; the full description lives
        // on the album detail endpoint.
        final details = await catalog.albumDetailsFor(album.id);
        tracks = details.tracks;
        note = details.description;
      } else {
        tracks = await catalog.playlistTracks(playlistId);
      }
      if (!mounted || serial != _requestSerial) return;
      setState(() {
        _tracks = tracks;
        _note = note;
        _metricsDirty = true;
        _rowIndexTrackId = null;
        _rowIndexCache = -1;
      });
      _scheduleLocateRefresh();
    } catch (_) {
      if (!mounted || serial != _requestSerial) return;
      setState(() => _error = '歌单读取失败，请重试。'); // i18n:key
    }
  }

  /// Natural height of one [LegacyTrackRow]: 44 px cover, up to three
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
    final double viewBottom = viewTop + _scroll.position.viewportDimension;
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
    final double viewport = _scroll.position.viewportDimension;
    final double target = (top - (viewport - extent) / 2).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    await _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<Track>? tracks = _tracks;
    final double inset = legacyPageInset(context);
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
                        _PlaylistHeader(
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
                          LegacyNotice(
                            message: _error!,
                            action: FilledButton(
                              onPressed: () => unawaited(_load()),
                              child: const TrText('重试'),
                            ),
                          )
                        else if (tracks == null)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 52),
                            child: Center(child: CircularProgressIndicator()),
                          )
                        else if (tracks.isEmpty)
                          const LegacyNotice(message: '这个歌单还没有可播放的曲目。')
                        else
                          LegacySectionHeader(
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
                      itemBuilder: (BuildContext context, int i) =>
                          LegacyTrackRow(
                            key: ValueKey<String>('playlist-row-$i'),
                            track: tracks[i],
                            index: i,
                            current: widget.state.current?.id == tracks[i].id,
                            playing: widget.state.playing,
                            onTap: () =>
                                widget.state.playQueue(tracks, startIndex: i),
                            onMenuRequested: (Offset position) =>
                                showTrackActions(
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
                const SliverToBoxAdapter(child: SizedBox(height: 88)),
              ],
            ),
            Positioned(
              right: 18,
              bottom: 18,
              child: ValueListenableBuilder<bool>(
                valueListenable: _showLocate,
                builder: (BuildContext context, bool show, Widget? _) {
                  if (!show) return const SizedBox.shrink();
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

class _PlaylistHeader extends StatelessWidget {
  const _PlaylistHeader({
    required this.playlist,
    required this.compact,
    required this.onPlay,
    this.onDownload,
    this.artist,
    this.artistWidget,
    this.note,
    this.noteIsData = false,
  });

  final Playlist playlist;
  final bool compact;
  final VoidCallback? onPlay;
  final VoidCallback? onDownload;

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
  }) => showDialog<void>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: const TrText('专辑简介'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(child: isData ? Text(note) : TrText(note)),
      ),
      actions: <Widget>[
        TextButton(
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
    final Widget stillCover = LegacyCover(
      url: playlist.coverUrl,
      size: coverSize,
      radius: 14,
    );
    final Widget cover = RepaintBoundary(child: stillCover);
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
        Text(
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
        if (artist == null) ...[
          const SizedBox(height: 7),
          Text(
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
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FilledButton.icon(
              onPressed: onPlay,
              icon: const Icon(Icons.play_arrow_rounded, size: 20),
              label: const TrText('播放全部'),
            ),
            if (onDownload != null) ...<Widget>[
              const SizedBox(width: 10),
              OutlinedButton.icon(
                key: const ValueKey<String>('download-all'),
                onPressed: onDownload,
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const TrText('下载'),
              ),
            ],
            const SizedBox(width: 10),
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: apple.fill,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.shuffle_rounded,
                size: 19,
                color: onPlay == null ? apple.tertiaryLabel : apple.accent,
              ),
            ),
          ],
        ),
      ],
    );
    if (compact) {
      return Column(
        children: <Widget>[cover, const SizedBox(height: 18), info],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        cover,
        const SizedBox(width: 24),
        Expanded(
          child: SizedBox(height: coverSize, child: info),
        ),
      ],
    );
  }
}
