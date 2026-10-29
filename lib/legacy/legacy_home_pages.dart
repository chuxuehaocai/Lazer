import 'dart:async';

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/catalog.dart';
import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../theme/apple_design.dart';
import '../widgets/app_scroll_behavior.dart';
import '../widgets/catalog_links.dart';
import '../widgets/interaction_feedback.dart';
import '../tv/tv_mode.dart';
import '../widgets/ui_scaling.dart';
import 'legacy_widgets.dart';

import 'legacy_page_utils.dart';

/// Apple-style browse page: a large title, one featured card, a horizontal
/// recommendation shelf and the quick-pick track list.
class LegacyHomePage extends StatefulWidget {
  const LegacyHomePage({
    super.key,
    required this.state,
    required this.onOpenPlaylist,
    required this.onPlayTrack,
    required this.onOpenChart,
  });

  final AppState state;
  final ValueChanged<Playlist> onOpenPlaylist;
  final void Function(List<Track> tracks, int index) onPlayTrack;
  final ValueChanged<MusicChart> onOpenChart;

  @override
  State<LegacyHomePage> createState() => _LegacyHomePageState();
}

class _LegacyHomePageState extends State<LegacyHomePage> {
  bool _startingStation = false;

  Future<void> _playStation(Future<List<Track>> Function() load) async {
    if (_startingStation) return;
    setState(() => _startingStation = true);
    try {
      final tracks = await load();
      if (!mounted) return;
      if (tracks.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.tr('暂时没有可播放的歌曲'))));
      } else {
        widget.state.playStationQueue(tracks, loadMore: load);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.tr('播放队列加载失败，请稍后重试'))));
      }
    } finally {
      if (mounted) setState(() => _startingStation = false);
    }
  }

  Future<void> _startHeartMode() async {
    if (_startingStation) return;
    setState(() => _startingStation = true);
    try {
      final bool started = await widget.state.startHeartMode();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.tr(started ? '已切换至心动模式' : '暂时没有可播放的歌曲')),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.tr('播放队列加载失败，请稍后重试'))));
      }
    } finally {
      if (mounted) setState(() => _startingStation = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final HomeFeed? feed = widget.state.home;
    if (feed == null) {
      return LegacyNotice(
        message: widget.state.homeError ?? '正在加载曲库…',
        action: widget.state.homeError == null
            ? null
            : FilledButton(
                onPressed: () =>
                    unawaited(widget.state.refreshHome(force: true)),
                child: const TrText('重试'),
              ),
      );
    }
    final List<Playlist> recommendations = uniquePlaylists(feed.recommended);
    final List<Track> recent = widget.state.recentTracks;
    final ArtistRef? stationArtist = recent
        .expand((track) => track.artists)
        .where((artist) => artist.id > 0)
        .firstOrNull;
    final double inset = legacyPageInset(context);
    final bool compact = MediaQuery.sizeOf(context).width < 720;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: adaptiveContentMaxWidth(context, 1180),
        ),
        child: CustomScrollView(
          key: const PageStorageKey<String>('discovery-scroll'),
          slivers: <Widget>[
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, 8, inset, 0),
              sliver: SliverList(
                delegate: SliverChildListDelegate(<Widget>[
                  HomeActionShelf(
                    busy: _startingStation,
                    covers: <String?>[
                      ...recent.map((track) => track.coverUrl),
                      ...feed.quick.map((track) => track.coverUrl),
                      ...feed.albums.map((album) => album.coverUrl),
                    ],
                    onDaily: !widget.state.signedIn || feed.quick.isEmpty
                        ? null
                        : () => widget.state.playQueue(feed.quick),
                    onFm: widget.state.signedIn
                        ? () => _playStation(
                            widget.state.catalog.personalFmTracks,
                          )
                        : null,
                    onHeart: widget.state.collections.liked == null
                        ? null
                        : () => unawaited(_startHeartMode()),
                    onReplay: recent.isEmpty
                        ? null
                        : () => widget.state.playQueue(recent),
                  ),
                  const SizedBox(height: 34),
                  LegacySectionHeader(title: '最近播放'),
                  const SizedBox(height: 10),
                  if (recent.isNotEmpty)
                    _HomeTrackGrid(
                      state: widget.state,
                      tracks: recent,
                      onPlay: widget.onPlayTrack,
                    )
                  else
                    const LegacyNotice(message: '还没有最近播放记录'),
                  if (feed.albums.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 36),
                    const LegacySectionHeader(title: '为你推荐的新发行'),
                    const SizedBox(height: 14),
                    _HomeReleaseShelf(
                      state: widget.state,
                      albums: feed.albums,
                      compact: compact,
                    ),
                  ],
                  if (feed.editorialPlaylists.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 38),
                    const LegacySectionHeader(title: '网易云编辑精选'),
                    const SizedBox(height: 14),
                    _EditorialPlaylistShelf(
                      playlists: feed.editorialPlaylists,
                      onOpen: widget.onOpenPlaylist,
                      compact: compact,
                    ),
                  ],
                  const SizedBox(height: 38),
                  const LegacySectionHeader(title: '排行榜'),
                  const SizedBox(height: 14),
                  if (widget.state.discoveryCharts.isNotEmpty)
                    ChartShelf(
                      charts: widget.state.discoveryCharts,
                      onOpen: widget.onOpenChart,
                      compact: compact,
                    )
                  else
                    ChartLoadCard(
                      loading: widget.state.discoveryChartsLoading,
                      message: widget.state.discoveryChartsError,
                      onRetry: () => unawaited(
                        widget.state.refreshDiscoveryCharts(force: true),
                      ),
                    ),
                  if (recommendations.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 38),
                    const LegacySectionHeader(title: '猜你喜欢'),
                    const SizedBox(height: 14),
                    _RecommendationShelf(
                      playlists: recommendations,
                      onOpen: widget.onOpenPlaylist,
                      compact: compact,
                    ),
                  ],
                  const SizedBox(height: 38),
                  LegacySectionHeader(title: '为你创建的电台'),
                  const SizedBox(height: 14),
                  _StationStrip(
                    enabled: widget.state.signedIn,
                    covers: <String?>[
                      ...recent.map((track) => track.coverUrl),
                      ...feed.quick.map((track) => track.coverUrl),
                      ...feed.albums.map((album) => album.coverUrl),
                    ],
                    onFm: () =>
                        _playStation(widget.state.catalog.personalFmTracks),
                    onLiked: widget.state.collections.liked == null
                        ? null
                        : () => _playStation(() async {
                            final tracks = await widget.state.catalog
                                .playlistTracks(
                                  widget.state.collections.liked!.id,
                                );
                            return List<Track>.of(tracks)..shuffle();
                          }),
                    onHeart: widget.state.collections.liked == null
                        ? null
                        : () => unawaited(_startHeartMode()),
                    artistName: stationArtist?.name,
                    onArtist: stationArtist == null
                        ? null
                        : () => _playStation(
                            () => widget.state.catalog.artistStationTracks(
                              stationArtist,
                            ),
                          ),
                  ),
                ]),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 28)),
          ],
        ),
      ),
    );
  }
}

/// The 为你打造 shortcuts on the browse page.
///
/// Shared by the desktop/phone home and the large-screen home. Every platform
/// renders the same filled card as the 电台 strip: the cover mosaic, gradient
/// and two caption lines cover the whole tile, so the four shortcuts read as
/// artwork rather than as a second navigation bar.
class HomeActionShelf extends StatelessWidget {
  const HomeActionShelf({
    super.key,
    required this.busy,
    required this.covers,
    this.onDaily,
    this.onFm,
    this.onHeart,
    this.onReplay,
    this.large = false,
  });

  final bool busy;
  final List<String?> covers;
  final VoidCallback? onDaily;
  final VoidCallback? onFm;
  final VoidCallback? onHeart;
  final VoidCallback? onReplay;

  /// Ten-foot layout: four larger cards across the browse width.
  final bool large;

  @override
  Widget build(BuildContext context) {
    final items =
        <({String title, String subtitle, IconData icon, VoidCallback? tap})>[
          (
            title: '每日推荐', // i18n:key
            subtitle: '今日限定好歌', // i18n:key
            icon: Icons.calendar_today_rounded,
            tap: onDaily,
          ),
          (
            title: '私人漫游', // i18n:key
            subtitle: '发现没听过的音乐', // i18n:key
            icon: Icons.waves_rounded,
            tap: onFm,
          ),
          (
            title: '心动模式', // i18n:key
            subtitle: '红心与相似推荐', // i18n:key
            icon: Icons.favorite_rounded,
            tap: onHeart,
          ),
          (
            title: '反复聆听', // i18n:key
            subtitle: '回到你爱的歌', // i18n:key
            icon: Icons.replay_rounded,
            tap: onReplay,
          ),
        ];
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // The four shortcuts share the browse width on a television instead of
        // huddling at the left. The large-screen home asks for bigger tiles so
        // the artwork reads from the sofa.
        final double gap = large ? 18 : 14;
        final double cardWidth =
            TvScope.isActive(context) && constraints.maxWidth.isFinite
            ? ((constraints.maxWidth - 3 * gap) / 4).clamp(
                large ? 300.0 : 228.0,
                large ? 480.0 : 372.0,
              )
            : 228.0;
        final double tileHeight = large ? 216 : 154;
        return _PagedHorizontalShelf(
          key: const ValueKey<String>('home-actions'),
          height: tileHeight,
          showArrows: !TvScope.isActive(context),
          gap: gap,
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return FilledCoverCard(
              width: cardWidth,
              height: tileHeight,
              large: large,
              title: item.title,
              detail: item.subtitle,
              icon: item.icon,
              covers: covers.isEmpty
                  ? const <String?>[]
                  : <String?>[
                      for (var offset = 0; offset < covers.length; offset++)
                        covers[(index * 2 + offset) % covers.length],
                    ],
              onTap: busy ? null : item.tap,
            );
          },
        );
      },
    );
  }
}

class _PagedHorizontalShelf extends StatefulWidget {
  const _PagedHorizontalShelf({
    super.key,
    required this.height,
    required this.itemCount,
    required this.itemBuilder,
    this.gap = 14,
    this.showArrows = true,
  });

  final double height;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final double gap;

  /// Hides the paging chevrons where the remote already pages by focus.
  final bool showArrows;

  @override
  State<_PagedHorizontalShelf> createState() => _PagedHorizontalShelfState();
}

class _PagedHorizontalShelfState extends State<_PagedHorizontalShelf> {
  final ScrollController _controller = ScrollController(
    keepScrollOffset: false,
  );

  @override
  void initState() {
    super.initState();
    _refreshAfterLayout();
  }

  @override
  void didUpdateWidget(covariant _PagedHorizontalShelf oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.itemCount != widget.itemCount ||
        oldWidget.height != widget.height) {
      _refreshAfterLayout();
    }
  }

  void _refreshAfterLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _page(double direction) {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    if (!position.hasContentDimensions) return;
    final target =
        (position.pixels + position.viewportDimension * .86 * direction).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
    _controller.animateTo(
      target,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 340),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool desktop = MediaQuery.sizeOf(context).width >= 720;
    return SizedBox(
      height: widget.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          ScrollConfiguration(
            behavior: shelfScrollBehavior(context),
            child: ListView.separated(
              controller: _controller,
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              physics: const BouncingScrollPhysics(),
              itemCount: widget.itemCount,
              separatorBuilder: (_, _) => SizedBox(width: widget.gap),
              itemBuilder: widget.itemBuilder,
            ),
          ),
          if (desktop && widget.showArrows)
            Positioned.fill(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  final bool attached =
                      _controller.hasClients &&
                      _controller.position.hasContentDimensions;
                  final double pixels = attached
                      ? _controller.position.pixels
                      : 0;
                  final double max = attached
                      ? _controller.position.maxScrollExtent
                      : 0;
                  return IgnorePointer(
                    ignoring: !attached || max <= 0,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: <Widget>[
                        _ShelfArrow(
                          icon: Icons.chevron_left_rounded,
                          visible: attached && pixels > 1,
                          onTap: () => _page(-1),
                        ),
                        _ShelfArrow(
                          icon: Icons.chevron_right_rounded,
                          visible: attached && pixels < max - 1,
                          onTap: () => _page(1),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _ShelfArrow extends StatelessWidget {
  const _ShelfArrow({
    required this.icon,
    required this.visible,
    required this.onTap,
  });
  final IconData icon;
  final bool visible;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    opacity: visible ? 1 : 0,
    duration: const Duration(milliseconds: 140),
    child: Material(
      color: AppleSemanticColors.of(
        context,
      ).tertiaryBackground.withValues(alpha: .94),
      elevation: 8,
      shadowColor: Colors.black26,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: visible ? onTap : null,
        child: SizedBox.square(dimension: 38, child: Icon(icon, size: 24)),
      ),
    ),
  );
}

class _MovingCoverMosaic extends StatefulWidget {
  const _MovingCoverMosaic({
    required this.covers,
    this.angle = 0,
    this.reverse = false,
    this.rows = 2,
    this.tile = 76,
    this.diagonal = 0,
  });
  final List<String?> covers;
  final double angle;
  final bool reverse;
  final int rows;
  final double tile;
  final double diagonal;

  @override
  State<_MovingCoverMosaic> createState() => _MovingCoverMosaicState();
}

class _MovingCoverMosaicState extends State<_MovingCoverMosaic>
    with WidgetsBindingObserver {
  static const Duration _driftDuration = Duration(seconds: 18);
  static const Duration _frameInterval = Duration(milliseconds: 33);

  // This is intentionally a 30 fps timer, not an AnimationController. A
  // controller still wakes the UI isolate on every display vsync (165+ times
  // a second on high-refresh screens) even if its listener only publishes a
  // value every 33 ms.
  final ValueNotifier<double> _phase = ValueNotifier<double>(0);
  final Stopwatch _clock = Stopwatch();
  Timer? _timer;
  Duration _lastAdvance = Duration.zero;
  double _phaseValue = 0;
  bool _reduceMotion = false;
  bool _tickerAllowed = true;
  bool _appActive = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncPlayback();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bool active = state == AppLifecycleState.resumed;
    if (active == _appActive) return;
    _appActive = active;
    _syncPlayback();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool reduce = MediaQuery.disableAnimationsOf(context);
    final bool allowed = TickerMode.valuesOf(context).enabled;
    if (reduce != _reduceMotion || allowed != _tickerAllowed) {
      _reduceMotion = reduce;
      _tickerAllowed = allowed;
      _syncPlayback();
    }
  }

  @override
  void didUpdateWidget(covariant _MovingCoverMosaic oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPlayback();
  }

  bool get _hasCovers => widget.covers.any((url) => url?.isNotEmpty ?? false);

  bool get _runs =>
      _hasCovers && !_reduceMotion && _tickerAllowed && _appActive;

  void _syncPlayback() {
    if (_runs) {
      if (_timer != null) return;
      _clock
        ..reset()
        ..start();
      _lastAdvance = Duration.zero;
      _timer = Timer.periodic(_frameInterval, (_) => _advance());
    } else {
      _timer?.cancel();
      _timer = null;
      _clock.stop();
      _lastAdvance = Duration.zero;
    }
  }

  void _advance() {
    if (!mounted) return;
    final Duration elapsed = _clock.elapsed;
    final double delta =
        (elapsed - _lastAdvance).inMicroseconds / _driftDuration.inMicroseconds;
    _lastAdvance = elapsed;
    if (delta <= 0) return;
    _phaseValue = (_phaseValue + delta) % 1;
    _phase.value = _phaseValue;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _clock.stop();
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final covers = widget.covers
        .where((url) => url?.isNotEmpty ?? false)
        .take(8)
        .toList();
    if (covers.isEmpty) return const SizedBox.expand();
    final repeated = List<String?>.generate(
      math.max(24, widget.rows * 12),
      (index) => covers[index % covers.length],
    );
    final travel = widget.tile * covers.length;
    return AnimatedBuilder(
      animation: _phase,
      builder: (context, child) => Transform.rotate(
        angle: widget.angle,
        child: Transform.translate(
          offset: Offset(
            widget.reverse
                ? -travel + _phase.value * travel
                : -_phase.value * travel,
            (_phase.value - .5) * widget.tile * widget.diagonal,
          ),
          child: child,
        ),
      ),
      child: RepaintBoundary(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: 0,
          maxWidth: double.infinity,
          child: SizedBox(
            width: repeated.length * widget.tile / widget.rows,
            height: widget.tile * widget.rows,
            child: Wrap(
              direction: Axis.vertical,
              children: <Widget>[
                for (final url in repeated)
                  LegacyCover(url: url, size: widget.tile, radius: 0),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeTrackGrid extends StatelessWidget {
  const _HomeTrackGrid({
    required this.state,
    required this.tracks,
    required this.onPlay,
  });
  final AppState state;
  final List<Track> tracks;
  final void Function(List<Track>, int) onPlay;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      const int rows = 3;
      final int visibleColumns = box.maxWidth >= 920
          ? 3
          : box.maxWidth >= 560
          ? 2
          : 1;
      final List<Track> shown = tracks;
      final int columns = (shown.length / rows).ceil();
      final double width =
          (box.maxWidth - (visibleColumns - 1) * 10) / visibleColumns;
      return _PagedHorizontalShelf(
        key: const ValueKey<String>('recent-tracks'),
        height: rows * 66 + (rows - 1) * 8,
        gap: 10,
        itemCount: columns,
        itemBuilder: (context, column) => SizedBox(
          width: width,
          child: Column(
            children: <Widget>[
              for (var row = 0; row < rows; row++) ...<Widget>[
                if (row > 0) const SizedBox(height: 8),
                if (column * rows + row < shown.length)
                  LegacyArtistTrackCard(
                    track: shown[column * rows + row],
                    current: state.current?.id == shown[column * rows + row].id,
                    onTap: () => onPlay(shown, column * rows + row),
                  ),
              ],
            ],
          ),
        ),
      );
    },
  );
}

class _HomeReleaseShelf extends StatelessWidget {
  const _HomeReleaseShelf({
    required this.state,
    required this.albums,
    required this.compact,
  });
  final AppState state;
  final List<Album> albums;
  final bool compact;

  @override
  Widget build(BuildContext context) => _PagedHorizontalShelf(
    key: const ValueKey<String>('new-releases'),
    height: compact ? 204 : 226,
    itemCount: albums.length,
    gap: 16,
    itemBuilder: (context, index) {
      final album = albums[index];
      final double size = compact ? 146 : 168;
      return SizedBox(
        width: size,
        child: InkWell(
          borderRadius: BorderRadius.circular(11),
          onTap: feedbackAction(
            context,
            () => unawaited(openAlbumDetails(context, state, album)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              LegacyCover(url: album.coverUrl, size: size, radius: 11),
              const SizedBox(height: 8),
              Text(
                album.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              Text(
                album.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppleSemanticColors.of(context).secondaryLabel,
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _EditorialPlaylistShelf extends StatelessWidget {
  const _EditorialPlaylistShelf({
    required this.playlists,
    required this.onOpen,
    required this.compact,
  });
  final List<Playlist> playlists;
  final ValueChanged<Playlist> onOpen;
  final bool compact;

  @override
  Widget build(BuildContext context) => _PagedHorizontalShelf(
    key: const ValueKey<String>('editorial-playlists'),
    height: compact ? 190 : 214,
    itemCount: playlists.length,
    gap: 16,
    itemBuilder: (context, index) {
      final playlist = playlists[index];
      return SizedBox(
        width: compact ? 270 : 330,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: feedbackAction(context, () => onOpen(playlist)),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                LegacyCover(
                  url: playlist.coverUrl,
                  size: compact ? 270 : 330,
                  radius: 0,
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[Color(0x11000000), Color(0xD9000000)],
                      stops: <double>[.25, 1],
                    ),
                  ),
                ),
                Positioned(
                  left: 18,
                  right: 18,
                  bottom: 16,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        context.tr('网易云编辑精选'),
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Colors.white70,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        playlist.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              height: 1.15,
                            ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// The chart shelf on the browse page.
///
/// Shared with the large-screen home; [large] enlarges the card, its logo and
/// its top-three list without changing the mosaic or the paging logic.
class ChartShelf extends StatelessWidget {
  const ChartShelf({
    super.key,
    required this.charts,
    required this.onOpen,
    this.compact = false,
    this.large = false,
  });
  final List<MusicChart> charts;
  final ValueChanged<MusicChart> onOpen;
  final bool compact;
  final bool large;

  @override
  Widget build(BuildContext context) => _PagedHorizontalShelf(
    key: const ValueKey<String>('charts'),
    height: large ? 344 : (compact ? 274 : 294),
    itemCount: charts.length,
    gap: large ? 22 : 16,
    showArrows: !large,
    itemBuilder: (context, index) {
      final chart = charts[index];
      return SizedBox(
        width: large ? 336 : (compact ? 246 : 278),
        child: Material(
          color: Colors.black,
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: feedbackAction(context, () => onOpen(chart)),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                Transform.scale(
                  scale: 1.32,
                  child: _MovingCoverMosaic(
                    covers: chart.entries
                        .map(chartEntryCover)
                        .toList(growable: false),
                    angle: -.11,
                    reverse: true,
                    rows: 4,
                    tile: 82,
                    diagonal: -.55,
                  ),
                ),
                ColoredBox(color: Colors.black.withValues(alpha: .68)),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[Color(0x12000000), Color(0xF2000000)],
                      stops: <double>[.22, 1],
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    large ? 22 : 18,
                    large ? 22 : 18,
                    large ? 22 : 18,
                    large ? 20 : 16,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      ChartLogo(chart: chart, large: large),
                      const Spacer(),
                      Text(
                        chart.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              fontSize: large ? 27 : null,
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -.6,
                            ),
                      ),
                      TrText(
                        chart.issueLabel,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontSize: large ? 16 : null,
                          color: Colors.white70,
                        ),
                      ),
                      SizedBox(height: large ? 12 : 9),
                      for (final entry in chart.entries.take(3))
                        Padding(
                          padding: EdgeInsets.only(top: large ? 7 : 5),
                          child: Row(
                            children: <Widget>[
                              SizedBox(
                                width: large ? 32 : 24,
                                child: Text(
                                  '${entry.rank}',
                                  style: TextStyle(
                                    fontSize: large ? 17 : null,
                                    color: Colors.white60,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  entry.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: large ? 17 : null,
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

String? chartEntryCover(ChartEntry entry) =>
    entry.track?.coverUrl ?? entry.coverUrl;

String _chartBrand(MusicChart chart) {
  final title = chart.title.toLowerCase();
  if (title.contains('billboard')) return 'billboard';
  if ((chart.providerKey ?? '').startsWith('biliboard:')) return 'BILIBOARD';
  if (title.contains('uk')) return 'OFFICIAL CHARTS';
  if (title.contains('beatport')) return 'BEATPORT';
  if (title.contains('oricon')) return 'ORICON';
  if (title.contains('nrj')) return 'NRJ';
  return 'CHARTS';
}

String? _chartLogoAsset(MusicChart chart) {
  final title = chart.title.toLowerCase();
  if (title.contains('billboard')) {
    return 'assets/chart_logos/billboard.png';
  }
  if ((chart.providerKey ?? '').startsWith('biliboard:')) {
    return 'assets/chart_logos/biliboard.png';
  }
  if (title.contains('uk')) {
    return 'assets/chart_logos/official_charts.png';
  }
  if (title.contains('beatport')) {
    return 'assets/chart_logos/beatport.png';
  }
  if (title.contains('oricon')) return 'assets/chart_logos/oricon.png';
  if (title.contains('nrj')) return 'assets/chart_logos/nrj.png';
  return null;
}

class ChartLogo extends StatelessWidget {
  const ChartLogo({super.key, required this.chart, this.large = false});
  final MusicChart chart;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final asset = _chartLogoAsset(chart);
    final biliboard = (chart.providerKey ?? '').startsWith('biliboard:');
    if (asset == null) {
      return Text(
        _chartBrand(chart),
        style: TextStyle(
          color: Colors.white,
          fontSize: large ? 21 : 16,
          height: 1,
          fontWeight: FontWeight.w900,
          letterSpacing: .5,
        ),
      );
    }
    return SizedBox(
      height: large ? 52 : 38,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Image.asset(
            asset,
            width: large ? (biliboard ? 58 : 190) : (biliboard ? 42 : 144),
            height: large ? 52 : 38,
            alignment: Alignment.centerLeft,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.high,
          ),
          if (biliboard) ...<Widget>[
            SizedBox(width: large ? 10 : 7),
            Text(
              'BiliBoard',
              style: TextStyle(
                color: Colors.white,
                fontSize: large ? 25 : 18,
                height: 1,
                fontWeight: FontWeight.w900,
                letterSpacing: -.6,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _RecommendationShelf extends StatelessWidget {
  const _RecommendationShelf({
    required this.playlists,
    required this.onOpen,
    required this.compact,
  });
  final List<Playlist> playlists;
  final ValueChanged<Playlist> onOpen;
  final bool compact;

  @override
  Widget build(BuildContext context) => _PagedHorizontalShelf(
    key: const ValueKey<String>('recommendations'),
    height: compact ? 202 : 224,
    itemCount: playlists.length,
    gap: 16,
    itemBuilder: (context, index) => LegacyPlaylistCard(
      playlist: playlists[index],
      width: compact ? 144 : 168,
      onTap: () => onOpen(playlists[index]),
    ),
  );
}

class _StationStrip extends StatelessWidget {
  const _StationStrip({
    required this.enabled,
    required this.onFm,
    required this.covers,
    this.onLiked,
    this.onHeart,
    this.artistName,
    this.onArtist,
  });
  final bool enabled;
  final VoidCallback onFm;
  final List<String?> covers;
  final VoidCallback? onLiked;
  final VoidCallback? onHeart;
  final String? artistName;
  final VoidCallback? onArtist;

  @override
  Widget build(BuildContext context) {
    final stations =
        <({String title, String detail, IconData icon, VoidCallback? tap})>[
          (
            title: '私人漫游', // i18n:key
            detail: '算法探索', // i18n:key
            icon: Icons.radar_rounded,
            tap: enabled ? onFm : null,
          ),
          (
            title: '红心随机', // i18n:key
            detail: '只播放收藏', // i18n:key
            icon: Icons.shuffle_rounded,
            tap: onLiked,
          ),
          (
            title: '心动模式', // i18n:key
            detail: '熟悉与新鲜', // i18n:key
            icon: Icons.favorite_rounded,
            tap: onHeart,
          ),
          if (artistName != null)
            (
              title: '$artistName 电台', // i18n:key
              detail: '相似歌手与曲风', // i18n:key
              icon: Icons.graphic_eq_rounded,
              tap: onArtist,
            ),
        ];
    return _PagedHorizontalShelf(
      key: const ValueKey<String>('stations'),
      height: 154,
      itemCount: stations.length,
      itemBuilder: (context, index) {
        final station = stations[index];
        return FilledCoverCard(
          width: 272,
          height: 154,
          title: station.title,
          detail: station.detail,
          icon: station.icon,
          covers: covers.isEmpty
              ? const <String?>[]
              : <String?>[
                  for (var offset = 0; offset < covers.length; offset++)
                    covers[(index * 3 + offset) % covers.length],
                ],
          onTap: station.tap,
        );
      },
    );
  }
}

/// A card filled edge to edge with artwork.
///
/// This is the 电台 strip's card, and the same renderer now draws 为你打造 on
/// every platform: a moving cover mosaic under a dark gradient, the category
/// glyph and a play mark on the top row, and the title/detail pair on two
/// caption lines. A television gets the usual focus ring through
/// [TvTapTarget]; a pointer gets the same tap target without a second widget.
class FilledCoverCard extends StatelessWidget {
  const FilledCoverCard({
    super.key,
    required this.width,
    required this.height,
    required this.title,
    required this.detail,
    required this.icon,
    required this.covers,
    this.onTap,
    this.large = false,
  });

  final double width;
  final double height;
  final String title;
  final String detail;
  final IconData icon;
  final List<String?> covers;
  final VoidCallback? onTap;

  /// Ten-foot sizing: a wider card, a larger caption and a two-row mosaic of
  /// bigger covers, used by the large-screen shortcuts.
  final bool large;

  @override
  Widget build(BuildContext context) {
    final VoidCallback? tap = onTap == null
        ? null
        : feedbackAction(context, onTap!);
    final BorderRadius radius = BorderRadius.circular(large ? 18 : 16);
    return SizedBox(
      width: width,
      height: height,
      child: MouseRegion(
        cursor: tap == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        child: TvTapTarget(
          onTap: tap,
          borderRadius: radius,
          focusScale: 1.02,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: tap,
            child: ClipRRect(
              borderRadius: radius,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  ColoredBox(
                    color: AppleSemanticColors.of(
                      context,
                    ).secondaryGroupedBackground,
                    child: Opacity(
                      opacity: tap == null ? .18 : .58,
                      child: _MovingCoverMosaic(
                        covers: covers,
                        tile: large ? 104 : 76,
                      ),
                    ),
                  ),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: <Color>[Color(0x22000000), Color(0xE0000000)],
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.all(large ? 20 : 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: <Widget>[
                            Icon(
                              icon,
                              color: Colors.white,
                              size: large ? 27 : 22,
                            ),
                            Icon(
                              Icons.play_circle_fill_rounded,
                              color: Colors.white,
                              size: large ? 35 : 29,
                            ),
                          ],
                        ),
                        const Spacer(),
                        Text(
                          context.tr(title),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                fontSize: large ? 21 : null,
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                              ),
                        ),
                        Text(
                          context.tr(detail),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                fontSize: large ? 15.5 : null,
                                color: Colors.white70,
                              ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The placeholder shown while the charts are loading or after a failure.
class ChartLoadCard extends StatelessWidget {
  const ChartLoadCard({
    super.key,
    required this.loading,
    required this.message,
    required this.onRetry,
    this.large = false,
  });
  final bool loading;
  final String? message;
  final VoidCallback onRetry;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final TextStyle? label = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(fontSize: large ? 18 : null);
    return Container(
      height: large ? 140 : 112,
      padding: EdgeInsets.symmetric(horizontal: large ? 24 : 18),
      decoration: BoxDecoration(
        color: AppleSemanticColors.of(context).secondaryGroupedBackground,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: <Widget>[
          if (loading)
            SizedBox.square(
              dimension: large ? 26 : 22,
              child: const CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(Icons.leaderboard_rounded, size: large ? 28 : 24),
          SizedBox(width: large ? 16 : 13),
          Expanded(
            child: Text(
              context.tr(loading ? '正在载入排行榜…' : message ?? '暂无榜单数据'),
              style: label,
            ),
          ),
          if (!loading)
            TextButton(
              onPressed: onRetry,
              child: Text(
                context.tr('重试'),
                style: large ? const TextStyle(fontSize: 17) : null,
              ),
            ),
        ],
      ),
    );
  }
}
