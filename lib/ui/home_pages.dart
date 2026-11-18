import '../gateway/music_models.dart';
import '../widgets/build_safe_state.dart';
import '../animation/apple_spring.dart';
import '../widgets/spring_buttons.dart';
import 'dart:async';

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/catalog.dart';
import '../data/models.dart';
import '../downloads/download_dialog.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../state/ui_preferences.dart';
import '../theme/apple_design.dart';
import '../widgets/app_scroll_behavior.dart';
import '../widgets/catalog_links.dart';
import '../widgets/cover_transition.dart';
import '../widgets/interaction_feedback.dart';
import '../tv/tv_mode.dart';
import '../tv/large_screen_widgets.dart';
import '../widgets/ui_scaling.dart';
import '../widgets/window_chrome.dart';
import 'widgets.dart';

import 'page_utils.dart';
import 'login.dart';

double _phoneCoverCardHeight(BuildContext context, double minimum) => math.max(
  minimum,
  // The legacy title is larger than a track caption. Reserve its measured
  // scaled lines plus the icon row and insets when accessibility text grows.
  mediaCardCaptionHeight(
        context,
        titleStyle: Theme.of(context).textTheme.titleMedium,
      ) +
      61,
);

/// Daily recommendations use the same independent detail page as playlists.
Playlist dailyRecommendationsPlaylist(
  HomeFeed feed, {
  bool serverLibrary = false,
}) {
  final tracks = feed.daily.isEmpty ? feed.quick : feed.daily;
  return Playlist(
    id: dailyRecommendationsPlaylistId,
    name: serverLibrary ? '随机发现' : '每日推荐',
    trackIds: tracks.map((track) => track.id).toList(),
    coverSeed: tracks.firstOrNull?.coverSeed ?? 0,
    coverUrl: tracks.firstOrNull?.coverUrl,
    trackCount: tracks.length,
    description: serverLibrary ? '探索服务器里的音乐' : '今日限定好歌',
  );
}

/// Artwork shortcuts, recent listening and discovery shelves.
class AppHomePage extends StatefulWidget {
  const AppHomePage({
    super.key,
    required this.state,
    required this.onOpenPlaylist,
    required this.onPlayTrack,
    required this.onOpenChart,
    this.topInset = 0,
  });

  final AppState state;
  final ValueChanged<Playlist> onOpenPlaylist;
  final void Function(List<Track> tracks, int index) onPlayTrack;
  final ValueChanged<MusicChart> onOpenChart;
  final double topInset;

  @override
  State<AppHomePage> createState() => _AppHomePageState();
}

class _AppHomePageState extends State<AppHomePage>
    with BuildSafeState<AppHomePage> {
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
    if (widget.state.isLocalPlayback) {
      return LocalRecentHome(
        state: widget.state,
        onPlayTrack: widget.onPlayTrack,
        topInset: widget.topInset,
      );
    }
    final HomeFeed? feed = widget.state.home;
    if (feed == null) {
      return AppNotice(
        topInset: widget.topInset,
        message: widget.state.homeError ?? '正在加载曲库…',
        action:
            widget.state.hasNetworkProvider && !widget.state.activeMusicSignedIn
            ? SpringFilledButton(
                onPressed: () =>
                    unawaited(showAppLoginDialog(context, widget.state)),
                child: const TrText('登录'),
              )
            : widget.state.homeError == null
            ? null
            : SpringFilledButton(
                onPressed: () =>
                    unawaited(widget.state.refreshHome(force: true)),
                child: const TrText('重试'),
              ),
      );
    }
    final bool supportsHomeFeed = widget.state.supportsMusic(
      MusicCapability.homeFeed,
    );
    final bool supportsRecommendations = widget.state.supportsMusic(
      MusicCapability.recommendations,
    );
    final bool supportsRadio = widget.state.supportsMusic(
      MusicCapability.radio,
    );
    final bool supportsCharts = widget.state.supportsMusic(
      MusicCapability.charts,
    );
    final bool hasFeedShelves =
        feed.quick.isNotEmpty ||
        feed.daily.isNotEmpty ||
        feed.recommended.isNotEmpty ||
        feed.playlists.isNotEmpty ||
        feed.albums.isNotEmpty ||
        feed.editorialPlaylists.isNotEmpty;
    final bool showPluginHome =
        supportsHomeFeed ||
        supportsRecommendations ||
        supportsRadio ||
        hasFeedShelves;
    final List<Playlist> recommendations = uniquePlaylists(feed.recommended);
    final List<Track> recent = widget.state.recentTracks;
    final ArtistRef? stationArtist = recent
        .expand((track) => track.artists)
        .where((artist) => artist.hasIdentity)
        .firstOrNull;
    final double inset = pageInset(context);
    final bool phone = compactBrowsePresentation(context);
    final bool compact =
        phone || MediaQuery.sizeOf(context).width < kTabletBreakpoint;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: adaptiveContentMaxWidth(context, 1180),
        ),
        child: CustomScrollView(
          key: const PageStorageKey<String>('discovery-scroll'),
          slivers: <Widget>[
            SliverPadding(
              // Keep a real scroll tail beneath the floating mobile bar. A
              // short home feed otherwise leaves the retained route with no
              // scroll extent at all; an interrupted cover return then cannot
              // hand the gesture back to the page and the lower half appears
              // frozen behind the navigation capsule.
              padding: EdgeInsets.fromLTRB(
                inset,
                8 + widget.topInset,
                inset,
                compact ? MediaQuery.sizeOf(context).height * .45 : 32,
              ),
              sliver: SliverList(
                delegate: SliverChildListDelegate(<Widget>[
                  // The discovery feed has no page title, so this thin band is
                  // the window's grab handle in Inline chrome mode.
                  const WindowDragBand(),
                  if (showPluginHome) ...<Widget>[
                    HomeActionShelf(
                      compact: phone,
                      serverLibrary: !supportsRecommendations,
                      busy: _startingStation,
                      covers: <String?>[
                        ...recent.map((track) => track.coverUrl),
                        ...feed.quick.map((track) => track.coverUrl),
                        ...feed.albums.map((album) => album.coverUrl),
                      ],
                      onDaily:
                          (supportsHomeFeed ||
                                  supportsRecommendations ||
                                  feed.quick.isNotEmpty ||
                                  feed.daily.isNotEmpty) &&
                              (feed.quick.isNotEmpty || feed.daily.isNotEmpty)
                          ? () {
                              if (!widget.state.signedIn) {
                                unawaited(
                                  showAppLoginDialog(context, widget.state),
                                );
                                return;
                              }
                              widget.onOpenPlaylist(
                                dailyRecommendationsPlaylist(
                                  feed,
                                  serverLibrary: !supportsRecommendations,
                                ),
                              );
                            }
                          : null,
                      onFm: supportsRadio && widget.state.signedIn
                          ? () => _playStation(
                              widget.state.catalog.personalFmTracks,
                            )
                          : null,
                      onHeart:
                          supportsRadio &&
                              widget.state.collections.liked != null
                          ? () => unawaited(_startHeartMode())
                          : null,
                      onReplay: recent.isEmpty
                          ? null
                          : () => widget.state.playQueue(recent),
                    ),
                    SizedBox(height: phone ? 34 : (compact ? 28 : 30)),
                  ],
                  AppSectionHeader(title: '最近播放'),
                  SizedBox(height: phone ? 10 : 12),
                  if (recent.isNotEmpty)
                    HomeRecentTrackShelf(
                      compact: phone,
                      currentTrackId: widget.state.current?.id,
                      tracks: recent,
                      onPlay: widget.onPlayTrack,
                      onMenuRequested: (track, position) => showTrackActions(
                        context,
                        widget.state,
                        track,
                        position,
                      ),
                    )
                  else
                    const AppNotice(message: '还没有最近播放记录'),
                  if (feed.albums.isNotEmpty) ...<Widget>[
                    SizedBox(height: phone ? 36 : 30),
                    const AppSectionHeader(title: '为你推荐的新发行'),
                    const SizedBox(height: 14),
                    _HomeReleaseShelf(
                      state: widget.state,
                      albums: feed.albums,
                      compact: compact,
                    ),
                  ],
                  if (feed.editorialPlaylists.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 38),
                    const AppSectionHeader(title: '编辑精选'),
                    const SizedBox(height: 14),
                    _EditorialPlaylistShelf(
                      playlists: feed.editorialPlaylists,
                      onOpen: widget.onOpenPlaylist,
                      compact: compact,
                    ),
                  ],
                  if (widget.state.enableExternalCharts ||
                      supportsCharts ||
                      widget.state.discoveryCharts.isNotEmpty) ...[
                    const SizedBox(height: 38),
                    const AppSectionHeader(title: '排行榜'),
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
                  ],
                  if (recommendations.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 38),
                    const AppSectionHeader(title: '猜你喜欢'),
                    const SizedBox(height: 14),
                    _RecommendationShelf(
                      playlists: recommendations,
                      onOpen: widget.onOpenPlaylist,
                      compact: compact,
                    ),
                  ],
                  if (supportsRadio) ...<Widget>[
                    const SizedBox(height: 38),
                    AppSectionHeader(title: '为你创建的电台'),
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
                  ],
                ]),
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 28 + MediaQuery.paddingOf(context).bottom,
              ),
            ),
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
    this.serverLibrary = false,
    this.dailyOpensPlaylist = true,
    this.compact,
  });

  final bool busy;
  final List<String?> covers;
  final VoidCallback? onDaily;
  final VoidCallback? onFm;
  final VoidCallback? onHeart;
  final VoidCallback? onReplay;

  /// Ten-foot layout: four larger cards across the browse width.
  final bool large;
  final bool serverLibrary;

  /// Guests on TV open sign-in instead of navigating to a collection.
  final bool dailyOpensPlaylist;
  final bool? compact;

  @override
  Widget build(BuildContext context) {
    final bool phone =
        !large && (compact ?? compactBrowsePresentation(context));
    final items =
        <({String title, String subtitle, IconData icon, VoidCallback? tap})>[
          (
            title: serverLibrary ? '随机发现' : '每日推荐', // i18n:key
            subtitle: serverLibrary ? '探索服务器里的音乐' : '今日限定好歌', // i18n:key
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
            subtitle: serverLibrary ? '随机播放喜欢的音乐' : '红心与相似推荐', // i18n:key
            icon: Icons.favorite_rounded,
            tap: onHeart,
          ),
          (
            title: '反复聆听', // i18n:key
            subtitle: '回到你爱的歌', // i18n:key
            icon: Icons.replay_rounded,
            tap: onReplay,
          ),
        ].where((item) => item.tap != null).toList();
    if (items.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double gap = large ? 18 : 14;
        // Four cards fill a desktop row, including at 1280px window width.
        // Phone widths retain a swipeable shelf instead of tiny captions.
        final bool fitRow =
            !phone && constraints.maxWidth >= (large ? 960 : 740);
        final double cardWidth = fitRow
            ? (constraints.maxWidth - (items.length - 1) * gap) /
                  math.max(1, items.length)
            : large
            ? 300
            : 228;
        final double tileHeight = large
            ? 216
            : phone
            ? _phoneCoverCardHeight(context, 154)
            : fitRow
            ? (cardWidth * .66).clamp(148.0, 184.0)
            : 154;
        return _PagedHorizontalShelf(
          key: const ValueKey<String>('home-actions'),
          height: tileHeight,
          showArrows: !TvScope.isActive(context),
          gap: gap,
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            final bool daily = item.icon == Icons.calendar_today_rounded;
            return StableCoverKey(
              key: ValueKey<String>('home-action:${item.title}'),
              builder: (GlobalKey coverKey) => CoverTransitionSource(
                key: coverKey,
                identity: daily && dailyOpensPlaylist
                    ? 'playlist:$dailyRecommendationsPlaylistId'
                    : null,
                morphArtwork: daily,
                radius: large ? 18 : 16,
                child: FilledCoverCard(
                  width: cardWidth,
                  height: tileHeight,
                  large: large,
                  compact: phone,
                  title: item.title,
                  detail: item.subtitle,
                  icon: item.icon,
                  covers: covers.isEmpty
                      ? const <String?>[]
                      : <String?>[
                          for (var offset = 0; offset < covers.length; offset++)
                            covers[(index * 2 + offset) % covers.length],
                        ],
                  onTap: busy || item.tap == null
                      ? null
                      : () {
                          if (daily && dailyOpensPlaylist) {
                            rememberCoverTransition(
                              'playlist:$dailyRecommendationsPlaylistId',
                              coverKey,
                            );
                          }
                          item.tap!();
                        },
                ),
              ),
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
    this.pageByViewport = false,
  });

  final double height;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final double gap;

  /// Hides the paging chevrons where the remote already pages by focus.
  final bool showArrows;
  final bool pageByViewport;

  @override
  State<_PagedHorizontalShelf> createState() => _PagedHorizontalShelfState();
}

class _PagedHorizontalShelfState extends State<_PagedHorizontalShelf>
    with BuildSafeState<_PagedHorizontalShelf> {
  final ScrollController _controller = ScrollController(
    keepScrollOffset: false,
  );
  bool _layoutRefreshPending = false;

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
    if (_layoutRefreshPending) return;
    _layoutRefreshPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _layoutRefreshPending = false;
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
    final double distance = widget.pageByViewport
        ? position.viewportDimension + widget.gap
        : position.viewportDimension * .86;
    final target = (position.pixels + distance * direction).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    _controller.animateTo(
      target,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 340),
      curve: const AppleSpringCurve(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool desktop = MediaQuery.sizeOf(context).width >= kTabletBreakpoint;
    return SizedBox(
      height: widget.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          ScrollConfiguration(
            behavior: shelfScrollBehavior(context),
            child: NotificationListener<ScrollMetricsNotification>(
              onNotification: (_) {
                _refreshAfterLayout();
                return false;
              },
              child: ListView.separated(
                controller: _controller,
                scrollDirection: Axis.horizontal,
                // Off-page artwork must stay inside the content lane rather
                // than painting through the sidebar or the next shelf.
                clipBehavior: Clip.hardEdge,
                physics: const BouncingScrollPhysics(),
                itemCount: widget.itemCount,
                separatorBuilder: (_, _) => SizedBox(width: widget.gap),
                itemBuilder: widget.itemBuilder,
              ),
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
                          label: MaterialLocalizations.of(
                            context,
                          ).previousPageTooltip,
                          visible: attached && pixels > 1,
                          onTap: () => _page(-1),
                        ),
                        _ShelfArrow(
                          icon: Icons.chevron_right_rounded,
                          label: MaterialLocalizations.of(
                            context,
                          ).nextPageTooltip,
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
    required this.label,
    required this.visible,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final bool visible;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !visible,
    child: ExcludeFocus(
      excluding: !visible,
      child: ExcludeSemantics(
        excluding: !visible,
        child: AnimatedOpacity(
          curve: const AppleSpringCurve(),
          opacity: visible ? 1 : 0,
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : AppleSpring.responsive.duration,
          child: Material(
            color: AppleSemanticColors.of(
              context,
            ).tertiaryBackground.withValues(alpha: .94),
            elevation: 8,
            shadowColor: Colors.black26,
            shape: const CircleBorder(),
            child: Tooltip(
              message: label,
              excludeFromSemantics: true,
              child: Semantics(
                button: true,
                label: label,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: visible ? onTap : null,
                  child: SizedBox.square(
                    dimension: 38,
                    child: Icon(icon, size: 24),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// A stable six-cover collage. Artwork only changes with the feed, so the
/// landing page never runs a timer just to slide repeated covers under labels.
class _CoverMosaic extends StatelessWidget {
  const _CoverMosaic({required this.covers, this.rows = 2});
  final List<String?> covers;
  final int rows;
  static const int columns = 3;

  @override
  Widget build(BuildContext context) {
    final artwork = covers
        .whereType<String>()
        .where((url) => url.isNotEmpty)
        .toSet()
        .take(rows * columns)
        .toList(growable: false);
    if (artwork.isEmpty) return const SizedBox.expand();
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, box) => Column(
          children: [
            for (var row = 0; row < rows; row++)
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var column = 0; column < columns; column++)
                      Expanded(
                        child: AppCover(
                          url:
                              artwork[(row * columns + column) %
                                  artwork.length],
                          size: math.max(
                            box.maxWidth / columns,
                            box.maxHeight / rows,
                          ),
                          radius: 0,
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
}

/// The phone keeps the original square artwork tiles without continuously
/// repainting a repeated off-screen strip. Only tiles covering the card exist.
class _PhoneCoverMosaic extends StatelessWidget {
  const _PhoneCoverMosaic({required this.covers, this.tile = 76});

  final List<String?> covers;
  final double tile;

  @override
  Widget build(BuildContext context) {
    final artwork = covers
        .whereType<String>()
        .where((url) => url.isNotEmpty)
        .take(8)
        .toList(growable: false);
    if (artwork.isEmpty) return const SizedBox.expand();
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, box) {
          final rows = (box.maxHeight / tile).ceil();
          final columns = (box.maxWidth / tile).ceil();
          return ClipRect(
            child: Stack(
              children: [
                for (var column = 0; column < columns; column++)
                  for (var row = 0; row < rows; row++)
                    Positioned(
                      left: column * tile,
                      top: row * tile,
                      child: AppCover(
                        url: artwork[(column * rows + row) % artwork.length],
                        size: tile,
                        radius: 0,
                      ),
                    ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class LocalRecentHome extends StatelessWidget {
  const LocalRecentHome({
    super.key,
    required this.state,
    required this.onPlayTrack,
    this.topInset = 0,
  });
  final AppState state;
  final void Function(List<Track>, int) onPlayTrack;
  final double topInset;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([state, state.localLibrary]),
    builder: (context, _) {
      final recent = state.recentTracks;
      final inset = pageInset(context);
      return Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: adaptiveContentMaxWidth(context, 1180),
          ),
          child: ListView(
            key: const PageStorageKey('local-recent-scroll'),
            padding: EdgeInsets.fromLTRB(
              inset,
              20 + topInset,
              inset,
              28 + MediaQuery.paddingOf(context).bottom,
            ),
            children: [
              const AppSectionHeader(title: '最近播放'),
              const SizedBox(height: 14),
              if (recent.isEmpty)
                const AppNotice(message: '还没有最近播放记录')
              else
                HomeRecentTrackShelf(
                  compact: compactBrowsePresentation(context),
                  currentTrackId: state.current?.id,
                  tracks: recent,
                  onPlay: onPlayTrack,
                  onMenuRequested: (track, position) =>
                      showTrackActions(context, state, track, position),
                ),
            ],
          ),
        ),
      );
    },
  );
}

/// Recent listening is laid out in reading order. Sparse history takes only
/// the rows it needs; a full desktop page holds three rows of three tracks.
class HomeRecentTrackShelf extends StatelessWidget {
  const HomeRecentTrackShelf({
    super.key,
    required this.tracks,
    required this.onPlay,
    this.currentTrackId,
    this.onMenuRequested,
    this.compact,
  });
  final String? currentTrackId;
  final List<Track> tracks;
  final void Function(List<Track>, int) onPlay;
  final void Function(Track, Offset)? onMenuRequested;
  final bool? compact;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      if (tracks.isEmpty) return const SizedBox.shrink();
      final bool phone = compact ?? compactBrowsePresentation(context);
      if (phone) {
        return _phoneShelf(context, box.maxWidth);
      }
      const double gap = 10;
      final double rowHeight = mediaTrackCardHeight(context);
      final int columns = ((box.maxWidth + gap) / 270).floor().clamp(1, 3);
      final int pageSize = columns * 3;
      final int rows = (math.min(tracks.length, pageSize) / columns).ceil();
      final int pages = (tracks.length / pageSize).ceil();
      final double width = (box.maxWidth - (columns - 1) * gap) / columns;
      return _PagedHorizontalShelf(
        key: const ValueKey<String>('recent-tracks'),
        height: rows * rowHeight + (rows - 1) * gap,
        gap: gap,
        pageByViewport: true,
        itemCount: pages,
        itemBuilder: (context, page) => SizedBox(
          width: box.maxWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var row = 0; row < rows; row++) ...[
                if (row > 0) const SizedBox(height: gap),
                Row(
                  children: [
                    for (var column = 0; column < columns; column++) ...[
                      if (column > 0) const SizedBox(width: gap),
                      if (page * pageSize + row * columns + column <
                          tracks.length)
                        SizedBox(
                          width: width,
                          height: rowHeight,
                          child: _track(
                            page * pageSize + row * columns + column,
                          ),
                        )
                      else
                        SizedBox(width: width),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      );
    },
  );

  Widget _phoneShelf(BuildContext context, double availableWidth) {
    const rows = 3;
    const columnGap = 10.0;
    const rowGap = 8.0;
    final visibleColumns = availableWidth >= 920
        ? 3
        : availableWidth >= 560
        ? 2
        : 1;
    final width =
        (availableWidth - (visibleColumns - 1) * columnGap) / visibleColumns;
    final rowHeight = mediaTrackCardHeight(context, compact: true);
    return _PagedHorizontalShelf(
      key: const ValueKey<String>('recent-tracks'),
      height: rows * rowHeight + (rows - 1) * rowGap,
      gap: columnGap,
      itemCount: (tracks.length / rows).ceil(),
      itemBuilder: (context, column) => SizedBox(
        width: width,
        child: Column(
          children: [
            for (var row = 0; row < rows; row++) ...[
              if (row > 0) const SizedBox(height: rowGap),
              if (column * rows + row < tracks.length)
                _track(column * rows + row, compact: true),
            ],
          ],
        ),
      ),
    );
  }

  Widget _track(int index, {bool compact = false}) => AppArtistTrackCard(
    key: ValueKey('recent-track:${tracks[index].id}'),
    track: tracks[index],
    current: currentTrackId == tracks[index].id,
    compact: compact,
    onTap: () => onPlay(tracks, index),
    onMenuRequested: onMenuRequested == null
        ? null
        : (position) => onMenuRequested!(tracks[index], position),
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
    height:
        (compact ? 146 : 168) + math.max(58, mediaCardCaptionHeight(context)),
    itemCount: albums.length,
    gap: 16,
    itemBuilder: (context, index) {
      final album = albums[index];
      final double size = compact ? 146 : 168;
      return StableCoverKey(
        key: ValueKey<String>('album:${album.id}'),
        builder: (GlobalKey coverKey) => SizedBox(
          width: size,
          child: InkWell(
            borderRadius: BorderRadius.circular(11),
            onTap: feedbackAction(context, () {
              rememberCoverTransition('playlist:${album.id}', coverKey);
              unawaited(openAlbumDetails(context, state, album));
            }),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                CoverTransitionSource(
                  key: coverKey,
                  identity: 'playlist:${album.id}',
                  child: AppCover(url: album.coverUrl, size: size, radius: 11),
                ),
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
      return StableCoverKey(
        key: ValueKey<String>('playlist:${playlist.id}'),
        builder: (GlobalKey coverKey) => SizedBox(
          width: compact ? 270 : 330,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: feedbackAction(context, () {
              rememberCoverTransition('playlist:${playlist.id}', coverKey);
              onOpen(playlist);
            }),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  CoverTransitionSource(
                    key: coverKey,
                    identity: 'playlist:${playlist.id}',
                    child: AppCover(
                      url: playlist.coverUrl,
                      size: compact ? 270 : 330,
                      radius: 0,
                    ),
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
                          context.tr('编辑精选'),
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
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
  Widget build(BuildContext context) {
    final phone = !large && compactBrowsePresentation(context);
    final small = compact || phone;
    return _PagedHorizontalShelf(
      key: const ValueKey<String>('charts'),
      height: large ? 344 : (small ? 274 : 294),
      itemCount: charts.length,
      gap: large ? 22 : 16,
      showArrows: !large,
      itemBuilder: (context, index) {
        final chart = charts[index];
        return StableCoverKey(
          key: ValueKey<String>('chart:${chart.id}'),
          builder: (GlobalKey coverKey) {
            void open() {
              rememberCoverTransition('chart:${chart.id}', coverKey);
              onOpen(chart);
            }

            final Widget card = SizedBox(
              width: large ? 336 : (small ? 246 : 278),
              child: Material(
                color: Colors.black,
                borderRadius: BorderRadius.circular(18),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: feedbackAction(context, open),
                  child: CoverTransitionSource(
                    key: coverKey,
                    identity: 'chart:${chart.id}',
                    morphArtwork: true,
                    radius: 18,
                    child: ColoredBox(
                      color: Colors.black,
                      child: Stack(
                        fit: StackFit.expand,
                        children: <Widget>[
                          Transform.scale(
                            scale: 1.32,
                            child: phone
                                ? Transform.rotate(
                                    angle: -.11,
                                    child: _PhoneCoverMosaic(
                                      covers: chart.entries
                                          .map(chartEntryCover)
                                          .toList(growable: false),
                                      tile: 82,
                                    ),
                                  )
                                : _CoverMosaic(
                                    covers: chart.entries
                                        .map(chartEntryCover)
                                        .toList(growable: false),
                                    rows: 3,
                                  ),
                          ),
                          ColoredBox(
                            color: Colors.black.withValues(alpha: .68),
                          ),
                          const DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: <Color>[
                                  Color(0x12000000),
                                  Color(0xF2000000),
                                ],
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
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineSmall
                                      ?.copyWith(
                                        fontSize: large ? 27 : null,
                                        color: Colors.white,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: -.6,
                                      ),
                                ),
                                TrText(
                                  chart.issueLabel,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        fontSize: large ? 16 : null,
                                        color: Colors.white70,
                                      ),
                                ),
                                SizedBox(height: large ? 12 : 9),
                                for (final entry in chart.entries.take(3))
                                  Padding(
                                    padding: EdgeInsets.only(
                                      top: large ? 7 : 5,
                                    ),
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
                ),
              ),
            );
            // Chart cards used InkWell only, so a TV remote could pass over them
            // without a focus stop or visible selection. Give the large layout
            // the same focus ring and spring lift as every other TV card.
            return large
                ? LargeScreenTapTarget(
                    onTap: feedbackAction(context, open),
                    borderRadius: BorderRadius.circular(18),
                    focusScale: 1.035,
                    child: card,
                  )
                : card;
          },
        );
      },
    );
  }
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
    height:
        (compact ? 144 : 168) + math.max(58, mediaCardCaptionHeight(context)),
    itemCount: playlists.length,
    gap: 16,
    itemBuilder: (context, index) => AppPlaylistCard(
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
    final height = compactBrowsePresentation(context)
        ? _phoneCoverCardHeight(context, 154)
        : 154.0;
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
      height: height,
      itemCount: stations.length,
      itemBuilder: (context, index) {
        final station = stations[index];
        return FilledCoverCard(
          width: 272,
          height: height,
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
/// every platform: a stable cover mosaic under a dark gradient, the category
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
    this.compact,
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
  final bool? compact;

  @override
  Widget build(BuildContext context) {
    final bool phone =
        !large && (compact ?? compactBrowsePresentation(context));
    final VoidCallback? tap = onTap == null
        ? null
        : feedbackAction(context, onTap!);
    final BorderRadius radius = BorderRadius.circular(large ? 18 : 16);
    return SizedBox(
      width: width,
      height: phone ? _phoneCoverCardHeight(context, height) : height,
      child: MouseRegion(
        cursor: tap == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        child: TvTapTarget(
          onTap: tap,
          borderRadius: radius,
          focusScale: 1.02,
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
                    opacity: tap == null
                        ? (phone ? .18 : .2)
                        : (phone ? .58 : .82),
                    child: phone
                        ? _PhoneCoverMosaic(covers: covers)
                        : _CoverMosaic(covers: covers),
                  ),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: phone
                          ? const <Color>[Color(0x22000000), Color(0xE0000000)]
                          : const <Color>[
                              Color(0x22000000),
                              Color(0x44000000),
                              Color(0xE8000000),
                            ],
                      stops: phone ? null : const <double>[0, .4, 1],
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
                            size: large ? 35 : (phone ? 29 : 30),
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
                              fontSize: large ? 21 : (phone ? null : 18),
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                            ),
                      ),
                      Text(
                        context.tr(detail),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontSize: large ? 15.5 : (phone ? null : 13),
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: tap,
                    canRequestFocus: !TvScope.isActive(context),
                    borderRadius: radius,
                    hoverColor: Colors.white.withValues(alpha: .08),
                    focusColor: Colors.white.withValues(alpha: .15),
                    child: Ink(
                      decoration: BoxDecoration(
                        borderRadius: radius,
                        border: phone
                            ? null
                            : Border.all(
                                color: Colors.white.withValues(alpha: .12),
                              ),
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
            SpringTextButton(
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
