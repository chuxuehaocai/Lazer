// i18n:data — interface strings declared here are translated at their render sites.
/// Pages of the large-screen presentation.
///
/// These are deliberately separate from the desktop pages: a television is
/// read from three metres, so artwork is the navigation and text is a caption
/// under it, not a 15 dp list row. Loading, playback and catalogue access all
/// go through the same [AppState] the rest of the app uses.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../data/catalog.dart';
import '../data/catalog_details.dart';
import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../legacy/legacy_login.dart';
import '../legacy/legacy_pages.dart';
import '../local/local_music_page.dart';
import '../state/app_state.dart';
import '../state/detail_requests.dart';
import '../state/song_comments_controller.dart';
import '../theme/apple_design.dart';
import '../widgets/apple_ui.dart';
import '../widgets/interaction_feedback.dart';
import '../widgets/song_comments_view.dart';
import 'large_screen_widgets.dart';

/// Navigation and playback callbacks the shell hands to a large-screen page.
class LargeScreenActions {
  const LargeScreenActions({
    required this.onOpenPlaylist,
    required this.onOpenAlbum,
    required this.onOpenArtist,
    required this.onOpenChart,
    required this.onOpenLikes,
    required this.onOpenLocalMusic,
    required this.onPlayTracks,
  });

  final ValueChanged<Playlist> onOpenPlaylist;
  final ValueChanged<Album> onOpenAlbum;
  final ValueChanged<ArtistRef> onOpenArtist;
  final ValueChanged<MusicChart> onOpenChart;
  final VoidCallback onOpenLikes;
  final VoidCallback onOpenLocalMusic;
  final void Function(List<Track> tracks, int index) onPlayTracks;
}

List<Playlist> _uniquePlaylists(Iterable<Playlist> playlists) {
  final Set<String> seen = <String>{};
  return <Playlist>[
    for (final Playlist playlist in playlists)
      if (playlist.id.isNotEmpty && seen.add(playlist.id)) playlist,
  ];
}

List<Album> _uniqueAlbums(Iterable<Album> albums) {
  final Set<String> seen = <String>{};
  return <Album>[
    for (final Album album in albums)
      if (album.id.isNotEmpty && seen.add(album.id)) album,
  ];
}

List<ArtistRef> _artistsFrom(List<Track> tracks, List<Album> albums) {
  final Map<String, ArtistRef> byId = <String, ArtistRef>{};
  for (final Track track in tracks) {
    for (final ArtistRef artist in track.artists) {
      if (artist.hasIdentity && artist.name.trim().isNotEmpty) {
        byId.putIfAbsent(artist.key, () => artist);
      }
    }
  }
  for (final Album album in albums) {
    for (final ArtistRef artist in album.artists) {
      if (artist.hasIdentity && artist.name.trim().isNotEmpty) {
        byId.putIfAbsent(
          artist.key,
          () => ArtistRef(
            id: artist.id,
            platformKey: artist.platformKey,
            name: artist.name,
            coverUrl: artist.coverUrl ?? album.coverUrl,
          ),
        );
      }
    }
  }
  return byId.values.toList(growable: false);
}

String _countSongs(BuildContext context, int count) => context.tr('$count 首');

String _countAlbums(BuildContext context, int count) => context.tr('$count 张');

String _countPlaylists(BuildContext context, int count) =>
    context.tr('$count 个歌单');

String _countArtists(BuildContext context, int count) =>
    context.tr('$count 位歌手');

String _countForFilter(
  BuildContext context,
  LargeScreenLibraryFilter filter,
  int count,
) => switch (filter) {
  LargeScreenLibraryFilter.songs => _countSongs(context, count),
  LargeScreenLibraryFilter.playlists => _countPlaylists(context, count),
  LargeScreenLibraryFilter.artists => _countArtists(context, count),
};

// ---------------------------------------------------------------------------
// 现在就听
// ---------------------------------------------------------------------------

/// The shelf page of the large-screen mode.
class LargeScreenHomePage extends StatefulWidget {
  const LargeScreenHomePage({
    super.key,
    required this.state,
    required this.actions,
  });

  final AppState state;
  final LargeScreenActions actions;

  @override
  State<LargeScreenHomePage> createState() => _LargeScreenHomePageState();
}

class _LargeScreenHomePageState extends State<LargeScreenHomePage> {
  bool _startingStation = false;

  AppState get _state => widget.state;

  Future<void> _playStation(Future<List<Track>> Function() load) async {
    if (_startingStation) return;
    setState(() => _startingStation = true);
    try {
      final List<Track> tracks = await load();
      if (!mounted) return;
      if (tracks.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.tr('暂时没有可播放的歌曲'))));
      } else {
        _state.playStationQueue(tracks, loadMore: load);
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
      final bool started = await _state.startHeartMode();
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
    final HomeFeed? feed = _state.home;
    if (feed == null) {
      final String? error = _state.homeError;
      return LargeScreenNotice(
        message: error ?? '正在加载曲库…',
        action: error == null
            ? null
            : LargeScreenPrimaryButton(
                label: '重试',
                icon: Icons.refresh_rounded,
                onTap: () => unawaited(_state.refreshHome(force: true)),
              ),
      );
    }
    final double width = MediaQuery.sizeOf(context).width;
    final double inset = LargeScreenMetrics.pageInset(width);
    final double featureWidth = LargeScreenMetrics.featureCardWidth(width);
    final double artWidth = LargeScreenMetrics.artworkCardWidth(width);
    final List<Track> recent = _state.recentTracks;
    final List<Playlist> recommendations = _uniquePlaylists(feed.recommended);
    final List<MusicChart> charts = _state.discoveryCharts;
    // The mosaic on the 为你打造 cards uses the same cover pool as the desktop
    // home: recent tracks, today's picks and the recommended albums.
    final List<String?> covers = <String?>[
      ...recent.map((Track track) => track.coverUrl),
      ...feed.quick.map((Track track) => track.coverUrl),
      ...feed.albums.map((Album album) => album.coverUrl),
    ];

    final List<_FeatureEntry> features = <_FeatureEntry>[];
    final Set<String> seen = <String>{};
    void addFeature({
      required String key,
      required String title,
      String? subtitle,
      String? imageUrl,
      required VoidCallback onTap,
      IconData icon = Icons.playlist_play_rounded,
    }) {
      if (features.length >= 8 || !seen.add(key)) return;
      features.add(
        _FeatureEntry(
          title: title,
          subtitle: subtitle,
          imageUrl: imageUrl,
          onTap: onTap,
          icon: icon,
        ),
      );
    }

    for (final Playlist playlist in <Playlist>[
      ...feed.recommended,
      ...feed.playlists,
      ...feed.editorialPlaylists,
    ]) {
      addFeature(
        key: 'playlist-${playlist.id}',
        title: playlist.name,
        subtitle: playlist.description.trim().isNotEmpty
            ? playlist.description
            : playlist.trackCount > 0
            ? _countSongs(context, playlist.trackCount)
            : null,
        imageUrl: playlist.coverUrl,
        onTap: () => widget.actions.onOpenPlaylist(playlist),
      );
    }
    if (feed.featured != null) {
      final Album album = feed.featured!;
      addFeature(
        key: 'album-${album.id}',
        title: album.title,
        subtitle: [
          album.artist,
          album.year,
        ].where((String value) => value.trim().isNotEmpty).join(' · '),
        imageUrl: album.coverUrl,
        onTap: () => widget.actions.onOpenAlbum(album),
        icon: Icons.album_rounded,
      );
    }
    for (final Album album in feed.albums) {
      addFeature(
        key: 'album-${album.id}',
        title: album.title,
        subtitle: [
          album.artist,
          album.year,
        ].where((String value) => value.trim().isNotEmpty).join(' · '),
        imageUrl: album.coverUrl,
        onTap: () => widget.actions.onOpenAlbum(album),
        icon: Icons.album_rounded,
      );
    }

    final List<Widget> sections = <Widget>[];
    void addSection(Widget shelf) {
      if (sections.isNotEmpty) {
        sections.add(const SizedBox(height: LargeScreenMetrics.shelfGap));
      }
      sections.add(shelf);
    }

    addSection(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.symmetric(horizontal: inset),
            child: const LargeScreenSectionHeader(title: '为你打造'),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: inset),
            // The same filled card as the 电台 strip, on every platform: the
            // cover mosaic and the two caption lines fill the whole tile. A
            // guest gets the login sheet instead of a dead tile, and keeping
            // the top shelf actionable also gives the page a focus anchor.
            child: HomeActionShelf(
              serverLibrary: _state.isNavidrome,
              busy: _startingStation,
              covers: covers,
              large: true,
              onDaily: !_state.signedIn
                  ? () => unawaited(showLegacyLoginDialog(context, _state))
                  : feed.quick.isEmpty
                  ? null
                  : () => _state.playQueue(feed.quick),
              onFm: _state.signedIn
                  ? () => _playStation(_state.catalog.personalFmTracks)
                  : () => unawaited(showLegacyLoginDialog(context, _state)),
              onHeart: !_state.signedIn
                  ? () => unawaited(showLegacyLoginDialog(context, _state))
                  : _state.collections.liked == null
                  ? null
                  : () => unawaited(_startHeartMode()),
              onReplay: recent.isEmpty ? null : () => _state.playQueue(recent),
            ),
          ),
        ],
      ),
    );

    if (features.isNotEmpty) {
      addSection(
        LargeScreenShelf(
          title: '精选推荐',
          height: LargeScreenMetrics.featureCardHeight(width),
          itemCount: features.length,
          itemBuilder: (BuildContext context, int index) {
            final _FeatureEntry feature = features[index];
            return LargeScreenFeatureCard(
              width: featureWidth,
              title: feature.title,
              subtitle: feature.subtitle,
              imageUrl: feature.imageUrl,
              icon: feature.icon,
              onTap: feature.onTap,
            );
          },
        ),
      );
    }

    if (recent.isNotEmpty) {
      addSection(
        LargeScreenShelf(
          title: '最近播放',
          subtitle: _countSongs(context, recent.length),
          height: LargeScreenMetrics.artworkCardHeight(width),
          itemCount: recent.length,
          itemBuilder: (BuildContext context, int index) {
            final Track track = recent[index];
            return LargeScreenMediaCard(
              width: artWidth,
              title: track.title,
              subtitle: track.artist,
              imageUrl: track.coverUrl,
              onTap: () => widget.actions.onPlayTracks(recent, index),
            );
          },
        ),
      );
    }

    if (feed.albums.isNotEmpty) {
      addSection(
        LargeScreenShelf(
          title: '新发行',
          subtitle: _countAlbums(context, feed.albums.length),
          height: LargeScreenMetrics.artworkCardHeight(width),
          itemCount: feed.albums.length,
          itemBuilder: (BuildContext context, int index) {
            final Album album = feed.albums[index];
            return LargeScreenMediaCard(
              width: artWidth,
              title: album.title,
              subtitle: album.artist,
              imageUrl: album.coverUrl,
              icon: Icons.album_rounded,
              onTap: () => widget.actions.onOpenAlbum(album),
            );
          },
        ),
      );
    }

    if (!_state.isNavidrome) {
      addSection(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: EdgeInsets.symmetric(horizontal: inset),
              child: const LargeScreenSectionHeader(title: '排行榜'),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: inset),
              // The chart shelf keeps the desktop/mobile card: a cover mosaic,
              // the board logo and its top three rows, with the same paging
              // behaviour; the loading card is the shared one too.
              child: charts.isNotEmpty
                  ? ChartShelf(
                      charts: charts,
                      onOpen: widget.actions.onOpenChart,
                      large: true,
                    )
                  : ChartLoadCard(
                      loading: _state.discoveryChartsLoading,
                      message: _state.discoveryChartsError,
                      large: true,
                      onRetry: () =>
                          unawaited(_state.refreshDiscoveryCharts(force: true)),
                    ),
            ),
          ],
        ),
      );
    }

    if (recommendations.isNotEmpty) {
      addSection(
        LargeScreenShelf(
          title: '猜你喜欢',
          height: LargeScreenMetrics.artworkCardHeight(width),
          itemCount: recommendations.length,
          itemBuilder: (BuildContext context, int index) {
            final Playlist playlist = recommendations[index];
            return LargeScreenMediaCard(
              width: artWidth,
              title: playlist.name,
              subtitle: playlist.trackCount > 0
                  ? _countSongs(context, playlist.trackCount)
                  : playlist.description,
              imageUrl: playlist.coverUrl,
              icon: Icons.queue_music_rounded,
              onTap: () => widget.actions.onOpenPlaylist(playlist),
            );
          },
        ),
      );
    }

    if (feed.editorialPlaylists.isNotEmpty) {
      addSection(
        LargeScreenShelf(
          title: '网易云编辑精选',
          height: LargeScreenMetrics.artworkCardHeight(width),
          itemCount: feed.editorialPlaylists.length,
          itemBuilder: (BuildContext context, int index) {
            final Playlist playlist = feed.editorialPlaylists[index];
            return LargeScreenMediaCard(
              width: artWidth,
              title: playlist.name,
              subtitle: playlist.description,
              imageUrl: playlist.coverUrl,
              icon: Icons.auto_awesome_rounded,
              onTap: () => widget.actions.onOpenPlaylist(playlist),
            );
          },
        ),
      );
    }

    return SingleChildScrollView(
      key: const PageStorageKey<String>('large-screen-home'),
      padding: const EdgeInsets.only(
        top: 18,
        bottom: LargeScreenMetrics.floatingBarInset,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: sections,
      ),
    );
  }
}

class _FeatureEntry {
  const _FeatureEntry({
    required this.title,
    required this.subtitle,
    required this.imageUrl,
    required this.onTap,
    required this.icon,
  });

  final String title;
  final String? subtitle;
  final String? imageUrl;
  final VoidCallback onTap;
  final IconData icon;
}

// ---------------------------------------------------------------------------
// 资料库
// ---------------------------------------------------------------------------

/// The library categories shown in the rail.
enum LargeScreenLibraryFilter { playlists, artists, songs }

extension LargeScreenLibraryFilterLabels on LargeScreenLibraryFilter {
  String get label => switch (this) {
    LargeScreenLibraryFilter.playlists => '播放列表',
    LargeScreenLibraryFilter.artists => '歌手',
    LargeScreenLibraryFilter.songs => '歌曲',
  };
}

/// The rail-and-grid library. The rail keeps every category one press away and
/// the grid answers with artwork: the same shape Apple Music uses on a TV.
class LargeScreenLibraryPage extends StatefulWidget {
  const LargeScreenLibraryPage({
    super.key,
    required this.state,
    required this.actions,
    this.initialFilter = LargeScreenLibraryFilter.playlists,
  });

  final AppState state;
  final LargeScreenActions actions;
  final LargeScreenLibraryFilter initialFilter;

  @override
  State<LargeScreenLibraryPage> createState() => _LargeScreenLibraryPageState();
}

class _LargeScreenLibraryPageState extends State<LargeScreenLibraryPage> {
  late LargeScreenLibraryFilter _filter = widget.initialFilter;
  AppState? _cachedState;
  UserCollections? _cachedCollections;
  HomeFeed? _cachedHome;
  List<Playlist> _cachedMine = const <Playlist>[];
  List<Playlist> _cachedPlaylists = const <Playlist>[];
  List<Album> _cachedAlbums = const <Album>[];
  List<TrackPlayStat>? _cachedStatsSource;
  Map<String, int> _cachedPlayCounts = const <String, int>{};
  int _cachedTotalPlays = 0;
  Duration _cachedTotalListenTime = Duration.zero;

  @override
  void initState() {
    super.initState();
    // The play record is cached for five minutes, so re-entering the library
    // is instant; a listen on another device shows up once that snapshot
    // expires instead of stalling every visit on a network round trip.
    unawaited(widget.state.loadPlayStats());
  }

  @override
  void didUpdateWidget(covariant LargeScreenLibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialFilter != widget.initialFilter) {
      _filter = widget.initialFilter;
    }
  }

  void _refreshDerivedData() {
    final AppState state = widget.state;
    final UserCollections collections = state.collections;
    final HomeFeed? home = state.home;
    if (identical(_cachedState, state) &&
        identical(_cachedCollections, collections) &&
        identical(_cachedHome, home)) {
      return;
    }
    _cachedState = state;
    _cachedCollections = collections;
    _cachedHome = home;
    _cachedMine = _uniquePlaylists(<Playlist>[
      if (collections.liked != null) collections.liked!,
      ...collections.created,
      ...collections.subscribed,
    ]);
    _cachedPlaylists = _uniquePlaylists(<Playlist>[
      ..._cachedMine,
      ...?home?.playlists,
      ...?home?.recommended,
    ]);
    _cachedAlbums = _uniqueAlbums(<Album>[
      ...?home?.albums,
      if (home?.featured != null) home!.featured!,
    ]);
  }

  void _refreshPlayStats() {
    final List<TrackPlayStat> stats = widget.state.playStats;
    if (identical(_cachedStatsSource, stats)) return;
    _cachedStatsSource = stats;
    final Map<String, int> playCounts = <String, int>{};
    var totalPlays = 0;
    var totalListenTime = Duration.zero;
    for (final TrackPlayStat stat in stats) {
      playCounts[stat.songId] = stat.playCount;
      totalPlays += stat.playCount;
      totalListenTime += stat.duration * stat.playCount;
    }
    _cachedPlayCounts = playCounts;
    _cachedTotalPlays = totalPlays;
    _cachedTotalListenTime = totalListenTime;
  }

  @override
  Widget build(BuildContext context) {
    _refreshDerivedData();
    _refreshPlayStats();
    final List<Track> songs = widget.state.recentTracks;
    final List<ArtistRef> artists = _artistsFrom(songs, _cachedAlbums);
    final double width = MediaQuery.sizeOf(context).width;
    final double rail = LargeScreenMetrics.railWidth(width);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          width: rail,
          child: _LibraryRail(
            selected: _filter,
            onSelect: (LargeScreenLibraryFilter value) =>
                setState(() => _filter = value),
            onLocalMusic: widget.actions.onOpenLocalMusic,
            onLikes: widget.actions.onOpenLikes,
          ),
        ),
        Expanded(
          child: Padding(
            padding: EdgeInsets.fromLTRB(10, 16, 0, 0),
            child: _LibraryPane(
              filter: _filter,
              playlists: _cachedPlaylists,
              artists: artists,
              songs: songs,
              actions: widget.actions,
              playCounts: _cachedPlayCounts,
              totalPlays: _cachedTotalPlays,
              totalListenTime: _cachedTotalListenTime,
            ),
          ),
        ),
      ],
    );
  }
}

class _LibraryRail extends StatelessWidget {
  const _LibraryRail({
    required this.selected,
    required this.onSelect,
    required this.onLocalMusic,
    required this.onLikes,
  });

  final LargeScreenLibraryFilter selected;
  final ValueChanged<LargeScreenLibraryFilter> onSelect;
  final VoidCallback onLocalMusic;
  final VoidCallback onLikes;

  @override
  Widget build(BuildContext context) {
    final double inset = LargeScreenMetrics.pageInset(
      MediaQuery.sizeOf(context).width,
    );
    return SingleChildScrollView(
      key: const PageStorageKey<String>('large-screen-library-rail'),
      padding: EdgeInsets.fromLTRB(
        inset,
        20,
        18,
        LargeScreenMetrics.floatingBarInset,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _RailLabel(label: '资料库'),
          const SizedBox(height: 10),
          for (final LargeScreenLibraryFilter filter
              in LargeScreenLibraryFilter.values)
            _RailButton(
              label: filter.label,
              selected: filter == selected,
              onTap: () => onSelect(filter),
            ),
          const SizedBox(height: 26),
          _RailLabel(label: '更多'),
          const SizedBox(height: 10),
          _RailButton(
            label: '本地音乐',
            icon: Icons.folder_rounded,
            onTap: onLocalMusic,
          ),
          _RailButton(
            label: '我喜欢的音乐',
            icon: Icons.favorite_rounded,
            onTap: onLikes,
          ),
        ],
      ),
    );
  }
}

class _RailLabel extends StatelessWidget {
  const _RailLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Text(
        context.tr(label),
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
          color: apple.tertiaryLabel,
        ),
      ),
    );
  }
}

class _RailButton extends StatefulWidget {
  const _RailButton({
    required this.label,
    this.icon,
    this.selected = false,
    required this.onTap,
  });

  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_RailButton> createState() => _RailButtonState();
}

class _RailButtonState extends State<_RailButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: LargeScreenTapTarget(
        onTap: feedbackAction(context, widget.onTap),
        onFocusChange: (bool value) => setState(() => _focused = value),
        borderRadius: BorderRadius.circular(12),
        focusScale: 1.015,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: double.infinity,
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: widget.selected
                ? apple.label.withValues(alpha: .12)
                : _focused
                ? apple.fill
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: <Widget>[
              if (widget.icon != null) ...<Widget>[
                Icon(
                  widget.icon,
                  size: 19,
                  color: widget.selected ? apple.label : apple.secondaryLabel,
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  context.tr(widget.label),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: LargeScreenType.cardTitle(context).copyWith(
                    fontSize: 19,
                    fontWeight: widget.selected
                        ? FontWeight.w700
                        : FontWeight.w500,
                    color: widget.selected
                        ? apple.label
                        : apple.label.withValues(alpha: .82),
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

class _LibraryPane extends StatelessWidget {
  const _LibraryPane({
    required this.filter,
    required this.playlists,
    required this.artists,
    required this.songs,
    required this.actions,
    required this.playCounts,
    required this.totalPlays,
    required this.totalListenTime,
  });

  final LargeScreenLibraryFilter filter;
  final List<Playlist> playlists;
  final List<ArtistRef> artists;
  final List<Track> songs;
  final LargeScreenActions actions;
  final Map<String, int> playCounts;
  final int totalPlays;
  final Duration totalListenTime;

  @override
  Widget build(BuildContext context) {
    final int count = switch (filter) {
      LargeScreenLibraryFilter.playlists => playlists.length,
      LargeScreenLibraryFilter.artists => artists.length,
      LargeScreenLibraryFilter.songs => songs.length,
    };
    final String hours = (totalListenTime.inMinutes / 60).toStringAsFixed(1);
    final String? subtitle =
        filter == LargeScreenLibraryFilter.songs && playCounts.isNotEmpty
        ? context.tr('累计播放 $totalPlays 次 · $hours 小时')
        : count == 0
        ? null
        : _countForFilter(context, filter, count);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(
            18,
            6,
            LargeScreenMetrics.pageInset(MediaQuery.sizeOf(context).width),
            18,
          ),
          child: LargeScreenSectionHeader(
            title: filter.label,
            subtitle: subtitle,
          ),
        ),
        Expanded(child: _body(context)),
      ],
    );
  }

  Widget _body(BuildContext context) {
    switch (filter) {
      case LargeScreenLibraryFilter.songs:
        if (songs.isEmpty) {
          return const LargeScreenNotice(message: '还没有最近播放记录');
        }
        return ListView.builder(
          key: const PageStorageKey<String>('large-screen-library-songs'),
          padding: const EdgeInsets.fromLTRB(
            10,
            0,
            24,
            LargeScreenMetrics.floatingBarInset,
          ),
          itemCount: songs.length,
          scrollCacheExtent: const ScrollCacheExtent.pixels(1400),
          itemBuilder: (BuildContext context, int index) {
            final Track track = songs[index];
            final int? plays = playCounts[track.id];
            return LargeScreenTrackRow(
              index: index,
              title: track.title,
              artist: track.artist,
              imageUrl: track.coverUrl,
              duration: track.duration,
              trailing: plays == null
                  ? null
                  : Text(
                      context.tr('播放 $plays 次'),
                      style: LargeScreenType.rowMeta(
                        context,
                      ).copyWith(fontSize: 14),
                    ),
              onTap: () => actions.onPlayTracks(songs, index),
            );
          },
        );
      case LargeScreenLibraryFilter.artists:
        if (artists.isEmpty) {
          return const LargeScreenNotice(
            message: '还没有歌手资料',
            icon: Icons.person_rounded,
          );
        }
        return _ArtworkGrid(
          itemCount: artists.length,
          builder: (BuildContext context, int index, double cell) {
            final ArtistRef artist = artists[index];
            return LargeScreenMediaCard(
              width: cell,
              title: artist.name,
              imageUrl: artist.coverUrl,
              icon: Icons.person_rounded,
              circular: true,
              centerCaption: true,
              onTap: () => actions.onOpenArtist(artist),
            );
          },
        );
      case LargeScreenLibraryFilter.playlists:
        if (playlists.isEmpty) {
          return const LargeScreenNotice(message: '还没有歌单。');
        }
        return _ArtworkGrid(
          itemCount: playlists.length,
          builder: (BuildContext context, int index, double cell) {
            final Playlist playlist = playlists[index];
            return LargeScreenMediaCard(
              width: cell,
              title: playlist.name,
              subtitle: playlist.trackCount > 0
                  ? _countSongs(context, playlist.trackCount)
                  : playlist.description,
              imageUrl: playlist.coverUrl,
              icon: Icons.queue_music_rounded,
              centerCaption: true,
              onTap: () => actions.onOpenPlaylist(playlist),
            );
          },
        );
    }
  }
}

class _ArtworkGrid extends StatelessWidget {
  const _ArtworkGrid({required this.itemCount, required this.builder});

  final int itemCount;
  final Widget Function(BuildContext context, int index, double cell) builder;

  @override
  Widget build(BuildContext context) {
    final double rightInset = LargeScreenMetrics.pageInset(
      MediaQuery.sizeOf(context).width,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double available = math.max(200, constraints.maxWidth - 24);
        const double gap = 26;
        final int columns = math.max(
          2,
          ((available + gap) / (258 + gap)).floor(),
        );
        final double cell = (available - (columns - 1) * gap) / columns;
        return GridView.builder(
          padding: EdgeInsets.fromLTRB(
            14,
            0,
            rightInset,
            LargeScreenMetrics.floatingBarInset,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: gap,
            mainAxisSpacing: 24,
            mainAxisExtent: cell + 96,
          ),
          itemCount: itemCount,
          scrollCacheExtent: const ScrollCacheExtent.pixels(1400),
          itemBuilder: (BuildContext context, int index) =>
              builder(context, index, cell),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 歌单 / 专辑
// ---------------------------------------------------------------------------

/// A playlist or album detail page with the large hero and track list.
class LargeScreenCollectionPage extends StatefulWidget {
  const LargeScreenCollectionPage({
    super.key,
    required this.state,
    required this.playlist,
    this.album,
  });

  final AppState state;
  final Playlist playlist;
  final Album? album;

  @override
  State<LargeScreenCollectionPage> createState() =>
      _LargeScreenCollectionPageState();
}

class _LargeScreenCollectionPageState extends State<LargeScreenCollectionPage> {
  List<Track>? _tracks;
  String? _note;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant LargeScreenCollectionPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playlist.id != widget.playlist.id ||
        oldWidget.album?.id != widget.album?.id) {
      _tracks = null;
      _note = null;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    if (mounted) setState(() => _error = null);
    try {
      final Album? album = widget.album;
      final List<Track> tracks;
      String? note;
      if (album != null) {
        final AlbumDetails details = await widget.state.catalog.albumDetailsFor(
          album.id,
        );
        tracks = details.tracks;
        note = details.description;
      } else {
        tracks = await widget.state.catalog.playlistTracks(widget.playlist.id);
      }
      if (!mounted) return;
      setState(() {
        _tracks = tracks;
        _note = note;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '歌单读取失败，请重试。');
    }
  }

  void _play({required bool shuffle}) {
    final List<Track>? tracks = _tracks;
    if (tracks == null || tracks.isEmpty) return;
    final List<Track> queue = List<Track>.of(tracks);
    if (shuffle) queue.shuffle();
    widget.state.playQueue(queue);
  }

  @override
  Widget build(BuildContext context) {
    final List<Track>? tracks = _tracks;
    final double inset = LargeScreenMetrics.pageInset(
      MediaQuery.sizeOf(context).width,
    );
    final String title = widget.playlist.name;
    final String meta = widget.album != null
        ? [
            widget.album!.artist,
            widget.album!.year,
          ].where((String value) => value.trim().isNotEmpty).join(' · ')
        : _countSongs(
            context,
            // Once the list has loaded, its real length beats the stub count
            // the feed carried: a playlist can grow or shrink between them.
            tracks?.length ??
                (widget.playlist.trackCount > 0
                    ? widget.playlist.trackCount
                    : 0),
          );
    final String? note = _note ?? widget.album?.note;
    final bool narrow = MediaQuery.sizeOf(context).width < 860;
    final Widget artwork = LargeScreenArtwork(
      url: widget.playlist.coverUrl,
      size: narrow ? 200 : 256,
      radius: 20,
      icon: widget.album != null
          ? Icons.album_rounded
          : Icons.queue_music_rounded,
      iconScale: .18,
    );
    final Widget info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: LargeScreenType.display(context),
        ),
        const SizedBox(height: 8),
        Text(
          meta,
          style: LargeScreenType.cardMeta(context).copyWith(fontSize: 18),
        ),
        if ((note ?? '').trim().isNotEmpty) ...<Widget>[
          const SizedBox(height: 10),
          Text(
            note!.trim(),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: LargeScreenType.cardMeta(context),
          ),
        ],
        const SizedBox(height: 22),
        Wrap(
          spacing: 12,
          runSpacing: 10,
          children: <Widget>[
            LargeScreenPrimaryButton(
              label: '播放全部',
              icon: Icons.play_arrow_rounded,
              onTap: tracks == null || tracks.isEmpty
                  ? null
                  : () => _play(shuffle: false),
            ),
            LargeScreenSecondaryButton(
              label: '随机播放',
              icon: Icons.shuffle_rounded,
              onTap: tracks == null || tracks.isEmpty
                  ? null
                  : () => _play(shuffle: true),
            ),
          ],
        ),
      ],
    );
    return CustomScrollView(
      key: PageStorageKey<String>(
        'large-screen-collection-${widget.playlist.id}',
      ),
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(inset, 20, inset, 12),
            child: narrow
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      artwork,
                      const SizedBox(height: 18),
                      info,
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      artwork,
                      const SizedBox(width: 34),
                      Expanded(child: info),
                    ],
                  ),
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(inset, 12, inset, 6),
          sliver: SliverToBoxAdapter(
            child: _error != null
                ? LargeScreenNotice(
                    message: _error!,
                    action: LargeScreenPrimaryButton(
                      label: '重试',
                      icon: Icons.refresh_rounded,
                      onTap: () => unawaited(_load()),
                    ),
                  )
                : tracks == null
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 40),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : tracks.isEmpty
                ? const LargeScreenNotice(message: '这个歌单还没有可播放的曲目。')
                : LargeScreenSectionHeader(
                    title: '歌曲',
                    subtitle: _countSongs(context, tracks.length),
                  ),
          ),
        ),
        if (tracks != null && tracks.isNotEmpty)
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: inset),
            sliver: SliverList.builder(
              itemCount: tracks.length,
              itemBuilder: (BuildContext context, int index) {
                final Track track = tracks[index];
                return LargeScreenTrackRow(
                  index: index,
                  title: track.title,
                  artist: track.artist,
                  imageUrl: track.coverUrl,
                  duration: track.duration,
                  current: widget.state.current?.id == track.id,
                  playing: widget.state.playing,
                  onTap: () =>
                      widget.state.playQueue(tracks, startIndex: index),
                );
              },
            ),
          ),
        const SliverToBoxAdapter(
          child: SizedBox(height: LargeScreenMetrics.floatingBarInset),
        ),
      ],
    );
  }
}

/// 我喜欢: the liked playlist, or a sign-in invitation for a guest.
class LargeScreenLikesPage extends StatelessWidget {
  const LargeScreenLikesPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    if (state.isGuest) {
      return LargeScreenNotice(
        message: '登录后查看喜欢的音乐。',
        icon: Icons.favorite_border_rounded,
        action: LargeScreenPrimaryButton(
          label: '登录',
          icon: Icons.person_rounded,
          onTap: () => unawaited(showLegacyLoginDialog(context, state)),
        ),
      );
    }
    final Playlist? liked = state.collections.liked;
    if (liked == null) {
      return const LargeScreenNotice(
        message: '正在加载资料…',
        icon: Icons.favorite_border_rounded,
      );
    }
    return LargeScreenCollectionPage(state: state, playlist: liked);
  }
}

// ---------------------------------------------------------------------------
// 歌手
// ---------------------------------------------------------------------------

class LargeScreenArtistPage extends StatefulWidget {
  const LargeScreenArtistPage({
    super.key,
    required this.state,
    required this.artist,
  });

  final AppState state;
  final ArtistRef artist;

  @override
  State<LargeScreenArtistPage> createState() => _LargeScreenArtistPageState();
}

class _LargeScreenArtistPageState extends State<LargeScreenArtistPage> {
  ArtistDetails? _details;
  List<Album> _albums = const <Album>[];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant LargeScreenArtistPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artist.key != widget.artist.key) unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ArtistDetails details = await widget.state.catalog.artistDetails(
        widget.artist,
      );
      final ArtistAlbumPage albums = await widget.state.catalog
          .artistAlbumPageFor(widget.artist, offset: 0);
      if (!mounted) return;
      setState(() {
        _details = details;
        _albums = albums.albums;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '歌手资料加载失败，请重试。';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ArtistRef artist = _details?.artist ?? widget.artist;
    final List<Track> tracks = _details?.tracks ?? const <Track>[];
    final double width = MediaQuery.sizeOf(context).width;
    final double inset = LargeScreenMetrics.pageInset(width);
    final double artWidth = LargeScreenMetrics.artworkCardWidth(width);
    final bool narrow = width < 860;
    final Widget artwork = LargeScreenArtwork(
      url: artist.coverUrl,
      size: narrow ? 176 : 216,
      circular: true,
      icon: Icons.person_rounded,
      iconScale: .3,
    );
    final Widget info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          artist.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: LargeScreenType.display(context),
        ),
        if (_details != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            context.tr(
              '${_details!.musicCount} 首歌曲 · ${_details!.albumCount} 张专辑',
            ),
            style: LargeScreenType.cardMeta(context).copyWith(fontSize: 18),
          ),
        ],
        const SizedBox(height: 22),
        LargeScreenPrimaryButton(
          label: '播放热门歌曲',
          icon: Icons.play_arrow_rounded,
          onTap: tracks.isEmpty ? null : () => widget.state.playQueue(tracks),
        ),
      ],
    );
    return SingleChildScrollView(
      key: PageStorageKey<String>('large-screen-artist-${artist.key}'),
      padding: EdgeInsets.fromLTRB(
        inset,
        22,
        inset,
        LargeScreenMetrics.floatingBarInset,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (narrow) ...<Widget>[
            artwork,
            const SizedBox(height: 18),
            info,
          ] else
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                artwork,
                const SizedBox(width: 32),
                Expanded(child: info),
              ],
            ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 64),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            LargeScreenNotice(
              message: _error!,
              action: LargeScreenPrimaryButton(
                label: '重试',
                icon: Icons.refresh_rounded,
                onTap: () => unawaited(_load()),
              ),
            )
          else ...<Widget>[
            if (tracks.isNotEmpty) ...<Widget>[
              const SizedBox(height: 34),
              const LargeScreenSectionHeader(title: '热门歌曲'),
              const SizedBox(height: 10),
              for (int i = 0; i < math.min(10, tracks.length); i++)
                LargeScreenTrackRow(
                  index: i,
                  title: tracks[i].title,
                  artist: tracks[i].artist,
                  imageUrl: tracks[i].coverUrl,
                  duration: tracks[i].duration,
                  current: widget.state.current?.id == tracks[i].id,
                  playing: widget.state.playing,
                  onTap: () => widget.state.playQueue(tracks, startIndex: i),
                ),
            ],
            if (_albums.isNotEmpty) ...<Widget>[
              const SizedBox(height: 36),
              LargeScreenSectionHeader(
                title: '专辑',
                subtitle: _countAlbums(context, _albums.length),
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: artWidth + 96,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: _albums.length,
                  scrollCacheExtent: const ScrollCacheExtent.pixels(1200),
                  itemBuilder: (BuildContext context, int index) {
                    final Album album = _albums[index];
                    return Padding(
                      padding: EdgeInsets.only(
                        right: index == _albums.length - 1
                            ? 0
                            : LargeScreenMetrics.cardGap,
                      ),
                      child: LargeScreenMediaCard(
                        width: artWidth,
                        title: album.title,
                        subtitle: album.artist,
                        imageUrl: album.coverUrl,
                        icon: Icons.album_rounded,
                        onTap: () => _openAlbum(album),
                      ),
                    );
                  },
                ),
              ),
            ],
            if ((_details?.description ?? '').trim().isNotEmpty) ...<Widget>[
              const SizedBox(height: 36),
              const LargeScreenSectionHeader(title: '关于'),
              const SizedBox(height: 12),
              Text(
                _details!.description.trim(),
                style: LargeScreenType.cardMeta(
                  context,
                ).copyWith(fontSize: 16, height: 1.6),
              ),
            ],
          ],
        ],
      ),
    );
  }

  void _openAlbum(Album album) {
    // The shell owns detail navigation; an album request is the same channel
    // the desktop pages use, so both compositions share one route.
    albumDetailRequest.value = album;
  }
}

// ---------------------------------------------------------------------------
// 排行榜
// ---------------------------------------------------------------------------

class LargeScreenChartPage extends StatefulWidget {
  const LargeScreenChartPage({
    super.key,
    required this.state,
    required this.chart,
  });

  final AppState state;
  final MusicChart chart;

  @override
  State<LargeScreenChartPage> createState() => _LargeScreenChartPageState();
}

class _LargeScreenChartPageState extends State<LargeScreenChartPage> {
  late MusicChart _chart = widget.chart;
  bool _matching = false;
  int _serial = 0;

  @override
  void initState() {
    super.initState();
    _matching = _chart.entries.any((ChartEntry entry) => entry.track == null);
    unawaited(_match());
  }

  Future<void> _match() async {
    if (!_matching) return;
    final int serial = ++_serial;
    try {
      final MusicChart matched = await widget.state.catalog.prepareChart(
        _chart,
      );
      if (!mounted || serial != _serial) return;
      setState(() {
        _chart = matched;
        _matching = false;
      });
    } catch (_) {
      if (mounted && serial == _serial) setState(() => _matching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final double inset = LargeScreenMetrics.pageInset(
      MediaQuery.sizeOf(context).width,
    );
    final Color accent = Color(_chart.accent);
    final List<Track> playable = <Track>[
      for (final ChartEntry entry in _chart.entries)
        if (entry.track != null) entry.track!,
    ];
    return CustomScrollView(
      key: PageStorageKey<String>('large-screen-chart-${_chart.id}'),
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Container(
            margin: EdgeInsets.fromLTRB(inset, 20, inset, 24),
            padding: const EdgeInsets.fromLTRB(34, 30, 34, 30),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[accent, Color.lerp(accent, Colors.black, .62)!],
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        _chart.source,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.1,
                          color: Color(0xCCFFFFFF),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _chart.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 36,
                          height: 1.14,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _chart.issueLabel,
                        style: const TextStyle(
                          fontSize: 16,
                          color: Color(0xCCFFFFFF),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 24),
                if (_matching)
                  Text(
                    context.tr('正在载入排行榜…'),
                    style: const TextStyle(
                      fontSize: 14,
                      color: Color(0xCCFFFFFF),
                    ),
                  )
                else if (playable.isNotEmpty)
                  LargeScreenPrimaryButton(
                    label: '播放全部',
                    icon: Icons.play_arrow_rounded,
                    onTap: () => widget.state.playQueue(playable),
                  ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(inset, 0, inset, 8),
          sliver: SliverToBoxAdapter(
            child: _chart.entries.isEmpty
                ? const LargeScreenNotice(message: '暂无榜单数据')
                : const LargeScreenSectionHeader(title: '本期上榜'),
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: inset),
          sliver: SliverList.builder(
            itemCount: _chart.entries.length,
            itemBuilder: (BuildContext context, int index) {
              final ChartEntry entry = _chart.entries[index];
              final Track? track = entry.track;
              final String trend = entry.changeLabel ?? '';
              return LargeScreenTrackRow(
                index: entry.rank > 0 ? entry.rank - 1 : index,
                title: entry.title,
                artist: entry.artist,
                imageUrl: entry.coverUrl,
                trailing: trend.isEmpty
                    ? null
                    : Text(
                        trend,
                        style: LargeScreenType.rowMeta(context).copyWith(
                          fontSize: 14,
                          color: trend.startsWith('+')
                              ? AppleColors.systemGreen
                              : trend.startsWith('-')
                              ? AppleColors.systemRed
                              : null,
                        ),
                      ),
                onTap: track == null
                    ? null
                    : () => widget.state.playQueue(
                        playable,
                        startIndex: playable.indexOf(track),
                      ),
              );
            },
          ),
        ),
        const SliverToBoxAdapter(
          child: SizedBox(height: LargeScreenMetrics.floatingBarInset),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 搜索
// ---------------------------------------------------------------------------

enum _SearchKind { songs, albums, artists, playlists }

extension _SearchKindLabels on _SearchKind {
  String get label => switch (this) {
    _SearchKind.songs => '歌曲',
    _SearchKind.albums => '专辑',
    _SearchKind.artists => '歌手',
    _SearchKind.playlists => '歌单',
  };
}

class LargeScreenSearchPage extends StatefulWidget {
  const LargeScreenSearchPage({
    super.key,
    required this.state,
    required this.actions,
  });

  final AppState state;
  final LargeScreenActions actions;

  @override
  State<LargeScreenSearchPage> createState() => _LargeScreenSearchPageState();
}

class _LargeScreenSearchPageState extends State<LargeScreenSearchPage> {
  final TextEditingController _controller = TextEditingController();
  SearchResults _results = SearchResults.empty;
  _SearchKind _kind = _SearchKind.songs;
  bool _searching = false;
  String? _error;
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    // Typing only updates the clear affordance. A query is committed on
    // Enter, so the remote/keyboard does not fire a request per keystroke.
    if (value.trim().isNotEmpty) {
      setState(() {});
      return;
    }
    setState(() {
      _query = '';
      _results = SearchResults.empty;
      _searching = false;
      _error = null;
    });
  }

  void _submit(String value) {
    final String query = value.trim();
    setState(() => _query = query);
    if (query.isNotEmpty) unawaited(_search(query));
  }

  Future<void> _search(String query) async {
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final SearchResults results = await widget.state.search(query);
      if (!mounted || _controller.text.trim() != query) return;
      setState(() {
        _results = results;
        _searching = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '搜索失败，请检查网络后重试。';
        _searching = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final double width = MediaQuery.sizeOf(context).width;
    final double inset = LargeScreenMetrics.pageInset(width);
    // The stock search bar and its suggestions are drawn at desktop sizes;
    // a ten-foot page lifts the field's type by a notch so the query and the
    // results stay readable without changing the layout rhythm.
    final MediaQueryData media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(textScaler: TextScaler.linear(1.14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.fromLTRB(inset, 14, inset, 14),
            child: AppleSearchField(
              controller: _controller,
              onChanged: _onChanged,
              onSubmitted: _submit,
              hintText: '搜索歌曲、歌手或歌单',
              height: 68,
              onClear: () {
                _controller.clear();
                _onChanged('');
              },
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: inset),
            child: Row(
              children: <Widget>[
                for (final _SearchKind kind in _SearchKind.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: LargeScreenChoiceChip(
                      label: kind.label,
                      selected: kind == _kind,
                      onTap: () => setState(() => _kind = kind),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_error != null) {
      return LargeScreenNotice(
        message: _error!,
        action: LargeScreenPrimaryButton(
          label: '重试',
          icon: Icons.refresh_rounded,
          onTap: () => unawaited(_search(_query)),
        ),
      );
    }
    if (_query.isEmpty) {
      return const LargeScreenNotice(
        message: '搜索歌曲、歌手或歌单',
        icon: Icons.search_rounded,
      );
    }
    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }
    final double inset = LargeScreenMetrics.pageInset(
      MediaQuery.sizeOf(context).width,
    );
    switch (_kind) {
      case _SearchKind.songs:
        if (_results.tracks.isEmpty) {
          return const LargeScreenNotice(message: '暂无歌曲');
        }
        return ListView.builder(
          padding: EdgeInsets.fromLTRB(
            inset - 8,
            0,
            inset,
            LargeScreenMetrics.floatingBarInset,
          ),
          itemCount: _results.tracks.length,
          scrollCacheExtent: const ScrollCacheExtent.pixels(1400),
          itemBuilder: (BuildContext context, int index) {
            final Track track = _results.tracks[index];
            return LargeScreenTrackRow(
              index: index,
              title: track.title,
              artist: track.artist,
              imageUrl: track.coverUrl,
              duration: track.duration,
              onTap: () =>
                  widget.state.playQueue(_results.tracks, startIndex: index),
            );
          },
        );
      case _SearchKind.albums:
        if (_results.albums.isEmpty) {
          return const LargeScreenNotice(message: '暂无专辑');
        }
        return _SearchGrid(
          itemCount: _results.albums.length,
          builder: (BuildContext context, int index, double cell) {
            final Album album = _results.albums[index];
            return LargeScreenMediaCard(
              width: cell,
              title: album.title,
              subtitle: album.artist,
              imageUrl: album.coverUrl,
              icon: Icons.album_rounded,
              centerCaption: true,
              onTap: () => widget.actions.onOpenAlbum(album),
            );
          },
        );
      case _SearchKind.artists:
        if (_results.artists.isEmpty) {
          return const LargeScreenNotice(
            message: '还没有歌手资料',
            icon: Icons.person_rounded,
          );
        }
        return _SearchGrid(
          itemCount: _results.artists.length,
          builder: (BuildContext context, int index, double cell) {
            final ArtistRef artist = _results.artists[index];
            return LargeScreenMediaCard(
              width: cell,
              title: artist.name,
              imageUrl: artist.coverUrl,
              icon: Icons.person_rounded,
              circular: true,
              centerCaption: true,
              onTap: () => widget.actions.onOpenArtist(artist),
            );
          },
        );
      case _SearchKind.playlists:
        if (_results.playlists.isEmpty) {
          return const LargeScreenNotice(message: '暂无歌单');
        }
        return _SearchGrid(
          itemCount: _results.playlists.length,
          builder: (BuildContext context, int index, double cell) {
            final Playlist playlist = _results.playlists[index];
            return LargeScreenMediaCard(
              width: cell,
              title: playlist.name,
              subtitle: playlist.trackCount > 0
                  ? _countSongs(context, playlist.trackCount)
                  : playlist.description,
              imageUrl: playlist.coverUrl,
              icon: Icons.queue_music_rounded,
              centerCaption: true,
              onTap: () => widget.actions.onOpenPlaylist(playlist),
            );
          },
        );
    }
  }
}

class _SearchGrid extends StatelessWidget {
  const _SearchGrid({required this.itemCount, required this.builder});

  final int itemCount;
  final Widget Function(BuildContext context, int index, double cell) builder;

  @override
  Widget build(BuildContext context) {
    final double inset = LargeScreenMetrics.pageInset(
      MediaQuery.sizeOf(context).width,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double available = math.max(
          200,
          constraints.maxWidth - inset * 2,
        );
        const double gap = 26;
        final int columns = math.max(
          2,
          ((available + gap) / (258 + gap)).floor(),
        );
        final double cell = (available - (columns - 1) * gap) / columns;
        return GridView.builder(
          padding: EdgeInsets.fromLTRB(
            inset,
            0,
            inset,
            LargeScreenMetrics.floatingBarInset,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: gap,
            mainAxisSpacing: 24,
            mainAxisExtent: cell + 96,
          ),
          itemCount: itemCount,
          scrollCacheExtent: const ScrollCacheExtent.pixels(1400),
          itemBuilder: (BuildContext context, int index) =>
              builder(context, index, cell),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Reused desktop surfaces, resized for the room
// ---------------------------------------------------------------------------

/// Settings, local music and comments keep their existing behaviour; this
/// wrapper widens their reading measure and scales the type up so they remain
/// legible at ten feet without forking a second set of controls.
class LargeScreenReusedPage extends StatelessWidget {
  const LargeScreenReusedPage({
    super.key,
    required this.child,
    this.maxWidth = 1180,
    this.textScale = 1.16,
    this.bottomInset = 0,
  });

  final Widget child;
  final double maxWidth;
  final double textScale;

  /// Room kept clear for the floating transport strip.
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    final MediaQueryData media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(textScaler: TextScaler.linear(textScale)),
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: child,
          ),
        ),
      ),
    );
  }
}

class LargeScreenSettingsPage extends StatelessWidget {
  const LargeScreenSettingsPage({
    super.key,
    required this.state,
    required this.onOpenLocalMusic,
    this.backgroundImagePicker,
  });

  final AppState state;
  final VoidCallback onOpenLocalMusic;

  /// Forwarded to [LegacySettingsPage]; the television UI shares the same
  /// picture picker so a big-screen install can change its backdrop too.
  final Future<String?> Function()? backgroundImagePicker;

  @override
  Widget build(BuildContext context) => LargeScreenReusedPage(
    maxWidth: 980,
    bottomInset: LargeScreenMetrics.floatingBarInset,
    child: LegacySettingsPage(
      state: state,
      onOpenLocalMusic: onOpenLocalMusic,
      backgroundImagePicker: backgroundImagePicker,
    ),
  );
}

class LargeScreenLocalMusicPage extends StatelessWidget {
  const LargeScreenLocalMusicPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) => LargeScreenReusedPage(
    maxWidth: 1240,
    bottomInset: LargeScreenMetrics.floatingBarInset,
    child: LocalMusicPage(state: state),
  );
}

class LargeScreenCommentsPage extends StatelessWidget {
  const LargeScreenCommentsPage({
    super.key,
    required this.state,
    required this.track,
    required this.controller,
  });

  final AppState state;
  final Track track;
  final SongCommentsController controller;

  @override
  Widget build(BuildContext context) {
    final double inset = LargeScreenMetrics.pageInset(
      MediaQuery.sizeOf(context).width,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(inset, 18, inset, 12),
          child: LargeScreenPageTitle(title: '评论', subtitle: track.title),
        ),
        Expanded(
          child: LargeScreenReusedPage(
            maxWidth: 1180,
            textScale: 1.12,
            bottomInset: LargeScreenMetrics.floatingBarInset,
            child: SongCommentsView(
              state: state,
              track: track,
              controller: controller,
            ),
          ),
        ),
      ],
    );
  }
}
