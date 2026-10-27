import 'dart:async';

import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, listEquals;
import 'package:flutter/material.dart';

import '../audio/audio_device_report.dart';
import '../data/audio_quality.dart';
import '../data/catalog.dart';
import '../data/catalog_details.dart';
import '../data/models.dart';
import '../diagnostics/build_info.dart';
import '../downloads/download_dialog.dart';
import '../downloads/download_queue_sheet.dart';
import '../l10n/app_language.dart';
import '../l10n/app_localizations.dart';
import '../local/local_music_import.dart';
import '../local/local_music_page.dart';
import '../scrolling/scroll_motion.dart';
import '../state/app_state.dart';
import '../state/media_shortcuts.dart';
import '../state/ui_preferences.dart';
import '../theme/apple_design.dart';
import '../widgets/accessible_controls.dart';
import '../widgets/app_scroll_behavior.dart';
import '../widgets/apple_ui.dart';
import '../widgets/catalog_links.dart';
import '../widgets/interaction_feedback.dart';
import '../widgets/listen_together_dialog.dart';
import '../widgets/playlist_picker_dialog.dart';
import '../widgets/shortcut_recorder_dialog.dart';
import '../state/detail_requests.dart';
import '../tv/tv_mode.dart';
import '../updates/update_dialog.dart';
import '../utils/background_image.dart';
import '../utils/byte_format.dart';
import '../widgets/ui_scaling.dart';
import 'legacy_login.dart';
import 'legacy_widgets.dart';

/// Apple Music-inspired artist overview that lives inside the shell's content
/// pane. It deliberately keeps the hero compact and lets releases carry the
/// visual weight below it.
class LegacyArtistPage extends StatefulWidget {
  const LegacyArtistPage({
    super.key,
    required this.state,
    required this.artist,
    required this.onOpenAllSongs,
    required this.onOpenAlbums,
    required this.onOpenSingles,
  });

  final AppState state;
  final ArtistRef artist;
  final VoidCallback onOpenAllSongs;
  final VoidCallback onOpenAlbums;
  final VoidCallback onOpenSingles;

  @override
  State<LegacyArtistPage> createState() => _LegacyArtistPageState();
}

class _LegacyArtistPageState extends State<LegacyArtistPage> {
  ArtistDetails? _details;
  final List<Album> _albums = <Album>[];
  String? _error;
  bool _loading = true;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant LegacyArtistPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artist.id != widget.artist.id) unawaited(_load());
  }

  Future<void> _load({bool force = false}) async {
    final int generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _albums.clear();
    });
    try {
      final ArtistDetails details = await widget.state.catalog.artistDetails(
        widget.artist,
        force: force,
      );
      if (!mounted || generation != _generation) return;
      setState(() => _details = details);
      var offset = 0;
      var more = true;
      final List<Album> albums = <Album>[];
      final Set<String> ids = <String>{};
      while (more) {
        final ArtistAlbumPage page = await widget.state.catalog.artistAlbumPage(
          widget.artist.id,
          offset: offset,
          force: force,
        );
        albums.addAll(page.albums.where((album) => ids.add(album.id)));
        offset += page.receivedCount;
        more = page.more && page.receivedCount > 0;
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _albums.addAll(albums);
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(
          () => _error = '歌手资料加载失败，请重试。', // i18n:key
        );
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ArtistRef artist = _details?.artist ?? widget.artist;
    final List<Track> popular =
        _details?.tracks.take(9).toList() ?? const <Track>[];
    final List<Album> fullAlbums = _albums
        .where((album) => album.releaseGroup == AlbumReleaseGroup.album)
        .toList();
    final List<Album> singles = _albums
        .where((album) => album.releaseGroup != AlbumReleaseGroup.album)
        .toList();
    final double inset = _pageInset(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1180),
        child: ListView(
          padding: EdgeInsets.fromLTRB(inset, 20, inset, 42),
          children: <Widget>[
            _ArtistHero(
              artist: artist,
              songCount: _details?.musicCount ?? 0,
              albumCount: _details?.albumCount ?? 0,
              onPlay: popular.isEmpty
                  ? null
                  : () => widget.state.playQueue(_details!.tracks),
            ),
            if (_loading && _details == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 72),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null && _details == null)
              LegacyNotice(
                message: _error!,
                action: FilledButton(
                  onPressed: () => unawaited(_load(force: true)),
                  child: const TrText('重试'),
                ),
              )
            else ...<Widget>[
              const SizedBox(height: 38),
              LegacySectionHeader(
                title: '歌曲排行',
                subtitle: popular.isEmpty ? null : '热门 ${popular.length} 首',
                trailing: TextButton.icon(
                  key: const ValueKey<String>('artist-all-songs'),
                  onPressed: widget.onOpenAllSongs,
                  iconAlignment: IconAlignment.end,
                  icon: const Icon(Icons.chevron_right_rounded, size: 18),
                  label: const TrText('查看全部'),
                ),
              ),
              const SizedBox(height: 10),
              if (popular.isEmpty)
                const LegacyNotice(message: '暂无热门歌曲')
              else
                LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints box) {
                    final int columns = box.maxWidth >= 920
                        ? 3
                        : box.maxWidth >= 560
                        ? 2
                        : 1;
                    final double width =
                        (box.maxWidth - (columns - 1) * 10) / columns;
                    return Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: <Widget>[
                        for (int i = 0; i < popular.length; i++)
                          SizedBox(
                            width: width,
                            child: _ArtistTrackCard(
                              track: popular[i],
                              current:
                                  widget.state.current?.id == popular[i].id,
                              onTap: () => widget.state.playQueue(
                                _details!.tracks,
                                startIndex: i,
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              if (fullAlbums.isNotEmpty) ...<Widget>[
                const SizedBox(height: 36),
                LegacySectionHeader(
                  title: '专辑',
                  subtitle: '${fullAlbums.length} 张全长专辑',
                  trailing: TextButton.icon(
                    key: const ValueKey<String>('artist-all-albums'),
                    onPressed: widget.onOpenAlbums,
                    iconAlignment: IconAlignment.end,
                    icon: const Icon(Icons.chevron_right_rounded, size: 18),
                    label: const TrText('查看全部'),
                  ),
                ),
                const SizedBox(height: 14),
                _ArtistReleaseShelf(state: widget.state, albums: fullAlbums),
              ],
              if (singles.isNotEmpty) ...<Widget>[
                const SizedBox(height: 36),
                LegacySectionHeader(
                  title: '单曲 / EP',
                  subtitle: '${singles.length} 张',
                  trailing: TextButton.icon(
                    key: const ValueKey<String>('artist-all-singles'),
                    onPressed: widget.onOpenSingles,
                    iconAlignment: IconAlignment.end,
                    icon: const Icon(Icons.chevron_right_rounded, size: 18),
                    label: const TrText('查看全部'),
                  ),
                ),
                const SizedBox(height: 14),
                _ArtistReleaseShelf(state: widget.state, albums: singles),
              ],
              if ((_details?.description ?? '').trim().isNotEmpty) ...<Widget>[
                const SizedBox(height: 38),
                const LegacySectionHeader(title: '关于'),
                const SizedBox(height: 12),
                Text(
                  _details!.description,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    height: 1.55,
                    color: AppleSemanticColors.of(context).secondaryLabel,
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _ArtistHero extends StatelessWidget {
  const _ArtistHero({
    required this.artist,
    required this.songCount,
    required this.albumCount,
    required this.onPlay,
  });

  final ArtistRef artist;
  final int songCount;
  final int albumCount;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return Column(
      children: <Widget>[
        ClipOval(
          child: SizedBox.square(
            dimension: 180,
            child: LegacyCover(
              url: artist.coverUrl,
              size: 180,
              radius: 0,
              iconSize: 50,
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          artist.name,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.displaySmall?.copyWith(
            color: apple.label,
            fontWeight: FontWeight.w800,
            letterSpacing: -1.1,
          ),
        ),
        if (songCount > 0 || albumCount > 0) ...<Widget>[
          const SizedBox(height: 7),
          Text(
            <String>[
              if (songCount > 0) context.tr('$songCount 首歌曲'),
              if (albumCount > 0) context.tr('$albumCount 张发行'),
            ].join(' · '),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: apple.secondaryLabel),
          ),
        ],
        const SizedBox(height: 17),
        FilledButton.icon(
          onPressed: onPlay,
          icon: const Icon(Icons.play_arrow_rounded, size: 23),
          label: const TrText('播放'),
          style: FilledButton.styleFrom(
            shape: const StadiumBorder(),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 13),
          ),
        ),
      ],
    );
  }
}

class _ArtistTrackCard extends StatefulWidget {
  const _ArtistTrackCard({
    required this.track,
    required this.current,
    required this.onTap,
  });
  final Track track;
  final bool current;
  final VoidCallback onTap;

  @override
  State<_ArtistTrackCard> createState() => _ArtistTrackCardState();
}

class _ArtistTrackCardState extends State<_ArtistTrackCard> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: feedbackAction(context, widget.onTap),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: 66,
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: widget.current
                  ? apple.accentSoft
                  : _hover
                  ? apple.fill
                  : apple.secondaryGroupedBackground,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: apple.separator, width: .5),
            ),
            child: Row(
              children: <Widget>[
                LegacyCover(url: widget.track.coverUrl, size: 52, radius: 6),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        widget.track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: widget.current ? apple.accent : apple.label,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        <String>[
                          widget.track.album,
                          if (widget.track.duration > Duration.zero)
                            legacyDuration(widget.track.duration),
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: apple.secondaryLabel,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.more_horiz_rounded, color: apple.tertiaryLabel),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ArtistReleaseShelf extends StatelessWidget {
  const _ArtistReleaseShelf({required this.state, required this.albums});
  final AppState state;
  final List<Album> albums;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 220,
    child: ScrollConfiguration(
      behavior: shelfScrollBehavior(context),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: albums.length,
        separatorBuilder: (_, _) => const SizedBox(width: 16),
        itemBuilder: (BuildContext context, int index) {
          final Album album = albums[index];
          return SizedBox(
            width: 160,
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: feedbackAction(
                context,
                () => unawaited(openAlbumDetails(context, state, album)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  LegacyCover(url: album.coverUrl, size: 160, radius: 9),
                  const SizedBox(height: 8),
                  Text(
                    album.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    <String>[
                      if (album.year.isNotEmpty) album.year,
                      if (album.releaseType.isNotEmpty) album.releaseType,
                    ].join(' · '),
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
      ),
    ),
  );
}

class LegacyArtistReleasesPage extends StatefulWidget {
  const LegacyArtistReleasesPage({
    super.key,
    required this.state,
    required this.artist,
    required this.group,
  });

  final AppState state;
  final ArtistRef artist;
  final AlbumReleaseGroup group;

  @override
  State<LegacyArtistReleasesPage> createState() =>
      _LegacyArtistReleasesPageState();
}

class _LegacyArtistReleasesPageState extends State<LegacyArtistReleasesPage> {
  List<Album>? _albums;
  String? _error;

  String get _title => widget.group == AlbumReleaseGroup.album
      ? '全部专辑' // i18n:key
      : '全部单曲 / EP'; // i18n:key

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool force = false}) async {
    setState(() {
      _error = null;
      if (force) _albums = null;
    });
    try {
      var offset = 0;
      var more = true;
      final List<Album> releases = <Album>[];
      final Set<String> ids = <String>{};
      while (more) {
        final ArtistAlbumPage page = await widget.state.catalog.artistAlbumPage(
          widget.artist.id,
          offset: offset,
          force: force,
        );
        for (final Album album in page.albums) {
          final bool matches = widget.group == AlbumReleaseGroup.album
              ? album.releaseGroup == AlbumReleaseGroup.album
              : album.releaseGroup != AlbumReleaseGroup.album;
          if (matches && ids.add(album.id)) releases.add(album);
        }
        offset += page.receivedCount;
        more = page.more && page.receivedCount > 0;
      }
      if (mounted) setState(() => _albums = releases);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = '发行作品加载失败，请重试。', // i18n:key
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<Album>? albums = _albums;
    final double inset = _pageInset(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980),
        child: CustomScrollView(
          slivers: <Widget>[
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, 12, inset, 16),
              sliver: SliverToBoxAdapter(
                child: ApplePageTitle(
                  title: _title,
                  subtitle: albums == null
                      ? widget.artist.name
                      : '${widget.artist.name} · ${albums.length} 张',
                  padding: EdgeInsets.zero,
                ),
              ),
            ),
            if (_error != null)
              SliverToBoxAdapter(
                child: LegacyNotice(
                  message: _error!,
                  action: FilledButton(
                    onPressed: () => unawaited(_load(force: true)),
                    child: const TrText('重试'),
                  ),
                ),
              )
            else if (albums == null)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (albums.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: LegacyNotice(
                  message: widget.group == AlbumReleaseGroup.album
                      ? '暂无专辑'
                      : '暂无单曲 / EP',
                ),
              )
            else
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: inset),
                sliver: SliverList.separated(
                  itemCount: albums.length,
                  separatorBuilder: (_, _) =>
                      Divider(height: 1, indent: 80, color: apple.separator),
                  itemBuilder: (BuildContext context, int index) {
                    final Album album = albums[index];
                    final String detail = <String>[
                      if (album.year.isNotEmpty) album.year,
                      if (album.releaseType.isNotEmpty) album.releaseType,
                      if (album.trackCount != null)
                        context.tr('${album.trackCount} 首'),
                    ].join(' · ');
                    return Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: feedbackAction(
                          context,
                          () => unawaited(
                            openAlbumDetails(context, widget.state, album),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 10,
                          ),
                          child: Row(
                            children: <Widget>[
                              LegacyCover(
                                url: album.coverUrl,
                                size: 62,
                                radius: 7,
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      album.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyLarge
                                          ?.copyWith(
                                            color: apple.label,
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                    if (detail.isNotEmpty) ...<Widget>[
                                      const SizedBox(height: 3),
                                      Text(
                                        detail,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: apple.secondaryLabel,
                                            ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              Icon(
                                Icons.chevron_right_rounded,
                                color: apple.tertiaryLabel,
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 36)),
          ],
        ),
      ),
    );
  }
}

class LegacyArtistSongsPage extends StatefulWidget {
  const LegacyArtistSongsPage({
    super.key,
    required this.state,
    required this.artist,
  });
  final AppState state;
  final ArtistRef artist;

  @override
  State<LegacyArtistSongsPage> createState() => _LegacyArtistSongsPageState();
}

class _LegacyArtistSongsPageState extends State<LegacyArtistSongsPage> {
  List<Track>? _tracks;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool force = false}) async {
    setState(() => _error = null);
    try {
      final tracks = await widget.state.catalog.artistSongs(
        widget.artist.id,
        force: force,
      );
      if (mounted) setState(() => _tracks = tracks);
    } catch (_) {
      try {
        final fallback = await widget.state.catalog.artistDetails(
          widget.artist,
        );
        if (mounted && fallback.tracks.isNotEmpty) {
          setState(() => _tracks = fallback.tracks);
          return;
        }
      } catch (_) {}
      if (mounted) {
        setState(
          () => _error = '全部歌曲加载失败，请重试。', // i18n:key
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<Track>? tracks = _tracks;
    final double inset = _pageInset(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: CustomScrollView(
          slivers: <Widget>[
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, 12, inset, 8),
              sliver: SliverToBoxAdapter(
                child: ApplePageTitle(
                  title: '全部歌曲',
                  subtitle: tracks == null
                      ? widget.artist.name
                      : '${widget.artist.name} · ${tracks.length} 首',
                  padding: EdgeInsets.zero,
                  trailing: tracks == null || tracks.isEmpty
                      ? null
                      : FilledButton.icon(
                          onPressed: () => widget.state.playQueue(tracks),
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: const TrText('播放'),
                        ),
                ),
              ),
            ),
            if (_error != null)
              SliverToBoxAdapter(
                child: LegacyNotice(
                  message: _error!,
                  action: FilledButton(
                    onPressed: () => unawaited(_load(force: true)),
                    child: const TrText('重试'),
                  ),
                ),
              )
            else if (tracks == null)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (tracks.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: LegacyNotice(message: '暂无可播放歌曲'),
              )
            else
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: inset),
                sliver: SliverList.builder(
                  itemCount: tracks.length,
                  itemBuilder: (BuildContext context, int index) =>
                      LegacyTrackRow(
                        track: tracks[index],
                        index: index,
                        current: widget.state.current?.id == tracks[index].id,
                        playing: widget.state.playing,
                        onTap: () =>
                            widget.state.playQueue(tracks, startIndex: index),
                        onMenuRequested: (Offset position) => showTrackActions(
                          context,
                          widget.state,
                          tracks[index],
                          position,
                        ),
                      ),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 36)),
          ],
        ),
      ),
    );
  }
}

/// Horizontal page margin. Phones use the 16 pt iOS inset; windowed layouts
/// breathe with a 24 pt margin, while the content itself is capped below.
double _pageInset(BuildContext context) =>
    MediaQuery.sizeOf(context).width < 720 ? 16 : 24;

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
    final List<Playlist> recommendations = _uniquePlaylists(feed.recommended);
    final List<Track> recent = widget.state.recentTracks;
    final ArtistRef? stationArtist = recent
        .expand((track) => track.artists)
        .where((artist) => artist.id > 0)
        .firstOrNull;
    final double inset = _pageInset(context);
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
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 18),
  );
  // The 18-second drift is slow enough that display-rate updates are
  // invisible, while a full-rate ticker rebuilt every visible mosaic 100+
  // times a second. Sample the controller at 30 fps instead.
  final ValueNotifier<double> _phase = ValueNotifier<double>(0);
  final Stopwatch _gate = Stopwatch()..start();
  int _lastSampleMs = 0;

  @override
  void initState() {
    super.initState();
    _motion.addListener(_sample);
  }

  void _sample() {
    final int now = _gate.elapsedMilliseconds;
    if (now - _lastSampleMs < 33) return;
    _lastSampleMs = now;
    _phase.value = _motion.value;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _motion.stop();
    } else if (!_motion.isAnimating) {
      _motion.repeat();
    }
  }

  @override
  void dispose() {
    _motion
      ..removeListener(_sample)
      ..dispose();
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
                  _ArtistTrackCard(
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
                        .map(_chartEntryCover)
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
                      _ChartLogo(chart: chart, large: large),
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

String? _chartEntryCover(ChartEntry entry) =>
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

class _ChartLogo extends StatelessWidget {
  const _ChartLogo({required this.chart, this.large = false});
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

class LegacyChartPage extends StatefulWidget {
  const LegacyChartPage({super.key, required this.state, required this.chart});
  final AppState state;
  final MusicChart chart;

  @override
  State<LegacyChartPage> createState() => _LegacyChartPageState();
}

class _LegacyChartPageState extends State<LegacyChartPage> {
  MusicChart? _chart;
  bool _loading = true;
  bool _matching = false;
  int _requestSerial = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final serial = ++_requestSerial;
    final source = widget.chart;
    if (mounted) {
      setState(() {
        _chart = source;
        _loading = false;
        _matching = source.entries.any((entry) => entry.track == null);
      });
    }
    if (source.entries.any((entry) => entry.track == null)) {
      unawaited(_matchInBackground(source, serial));
    }
  }

  Future<void> _matchInBackground(
    MusicChart source,
    int serial, {
    bool force = false,
  }) async {
    try {
      final matched = await widget.state.catalog.prepareChart(
        source,
        force: force,
      );
      if (!mounted || serial != _requestSerial) return;
      setState(() {
        _chart = matched;
        _matching = false;
      });
    } catch (_) {
      // Covers, ranks and source links remain usable without a NetEase match.
      if (mounted && serial == _requestSerial) {
        setState(() => _matching = false);
      }
    }
  }

  /// Re-runs the match after a board came back without a single playable row.
  Future<void> _retryMatching() async {
    if (_matching) return;
    final source = _chart ?? widget.chart;
    final serial = ++_requestSerial;
    setState(() => _matching = true);
    await _matchInBackground(source, serial, force: true);
  }

  Future<void> _selectIssue(ChartIssue issue) async {
    final current = _chart ?? widget.chart;
    if (issue.id == current.selectedIssueId || _loading) return;
    final serial = ++_requestSerial;
    setState(() {
      _loading = true;
      _matching = false;
    });
    try {
      final raw = await widget.state.catalog.chartIssue(current, issue);
      if (!mounted || serial != _requestSerial) return;
      setState(() {
        _chart = raw;
        _loading = false;
        _matching = raw.entries.any((entry) => entry.track == null);
      });
      unawaited(_matchInBackground(raw, serial));
    } catch (_) {
      if (mounted && serial == _requestSerial) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.tr('这一期暂时载入失败，请稍后重试。'))));
      }
    } finally {
      if (mounted && serial == _requestSerial && _loading) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final chart = _chart ?? widget.chart;
    final Color accent = Color(chart.accent);
    final double inset = _pageInset(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1180),
        child: CustomScrollView(
          slivers: <Widget>[
            SliverToBoxAdapter(
              child: Container(
                margin: EdgeInsets.fromLTRB(inset, 20, inset, 28),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[
                      accent,
                      Color.lerp(accent, Colors.black, .66)!,
                    ],
                  ),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: accent.withValues(alpha: .2),
                      blurRadius: 30,
                      offset: const Offset(0, 14),
                    ),
                  ],
                ),
                child: _ChartHero(
                  chart: chart,
                  loading: _loading,
                  onIssueSelected: _selectIssue,
                ),
              ),
            ),
            if (_loading)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.only(bottom: 18),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ),
            if (!_loading &&
                !_matching &&
                chart.entries.isNotEmpty &&
                chart.entries.every((entry) => entry.track == null))
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(inset, 0, inset, 16),
                  child: ChartLoadCard(
                    loading: false,
                    message: '这些歌曲暂时匹配不到网易云，可以重新匹配', // i18n:key
                    onRetry: () => unawaited(_retryMatching()),
                  ),
                ),
              ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, 0, inset, 40),
              sliver: SliverList.separated(
                itemCount: chart.entries.length,
                separatorBuilder: (_, _) => const SizedBox(height: 2),
                itemBuilder: (context, index) => _ChartTrackRow(
                  entry: chart.entries[index],
                  matching: _matching && chart.entries[index].track == null,
                  onTap: chart.entries[index].track == null
                      ? null
                      : () => widget.state.playQueue(
                          chart.entries
                              .map((entry) => entry.track)
                              .whereType<Track>()
                              .toList(),
                          startIndex: chart.entries
                              .take(index)
                              .where((entry) => entry.track != null)
                              .length,
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChartHero extends StatelessWidget {
  const _ChartHero({
    required this.chart,
    required this.loading,
    required this.onIssueSelected,
  });

  final MusicChart chart;
  final bool loading;
  final ValueChanged<ChartIssue> onIssueSelected;

  Widget _info(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      _ChartLogo(chart: chart, large: true),
      const SizedBox(height: 18),
      Text(
        chart.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.displaySmall?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w900,
          letterSpacing: -1.1,
        ),
      ),
      const SizedBox(height: 9),
      Row(
        children: <Widget>[
          Flexible(
            child: _ChartIssuePicker(
              chart: chart,
              loading: loading,
              onSelected: onIssueSelected,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            context.tr('${chart.entries.length} 首'),
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
          ),
        ],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 700;
      if (compact) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 25, 24, 16),
              child: _info(context),
            ),
            SizedBox(
              height: 178,
              child: _ChartHeroArtwork(entries: chart.entries.take(3).toList()),
            ),
          ],
        );
      }
      return SizedBox(
        height: 286,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Positioned(
              top: -28,
              right: -24,
              bottom: -28,
              width: constraints.maxWidth * .61,
              child: _ChartHeroArtwork(entries: chart.entries.take(3).toList()),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: <Color>[
                    Color(0xEE16080D),
                    Color(0xC816080D),
                    Color(0x0016080D),
                  ],
                  stops: <double>[0, .47, .78],
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: constraints.maxWidth * .52,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(32, 30, 20, 30),
                  child: _info(context),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _ChartHeroArtwork extends StatelessWidget {
  const _ChartHeroArtwork({required this.entries});
  final List<ChartEntry> entries;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final covers = entries.map(_chartEntryCover).toList(growable: false);
      final side = math.min(
        constraints.maxHeight * .78,
        constraints.maxWidth * .42,
      );
      return Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          for (var index = covers.length - 1; index >= 0; index--)
            Positioned(
              left: constraints.maxWidth * (.07 + index * .205),
              top: constraints.maxHeight * (.1 + index * .045),
              child: Transform.rotate(
                angle: (index - 1) * .055,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: const <BoxShadow>[
                      BoxShadow(
                        color: Color(0x66000000),
                        blurRadius: 28,
                        offset: Offset(0, 14),
                      ),
                    ],
                  ),
                  child: LegacyCover(
                    url: covers[index],
                    size: side,
                    radius: 16,
                    iconSize: 34,
                  ),
                ),
              ),
            ),
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[Color(0x00000000), Color(0xB8000000)],
                  stops: <double>[.48, 1],
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

class _ChartIssuePicker extends StatelessWidget {
  const _ChartIssuePicker({
    required this.chart,
    required this.loading,
    required this.onSelected,
  });

  final MusicChart chart;
  final bool loading;
  final ValueChanged<ChartIssue> onSelected;

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: Colors.white,
      fontWeight: FontWeight.w700,
    );
    if (chart.issues.length < 2) {
      return TrText(chart.issueLabel, style: textStyle);
    }
    return PopupMenuButton<ChartIssue>(
      enabled: !loading,
      tooltip: context.tr('选择榜单期数'),
      onSelected: onSelected,
      itemBuilder: (context) => <PopupMenuEntry<ChartIssue>>[
        for (final issue in chart.issues)
          PopupMenuItem<ChartIssue>(
            value: issue,
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 20,
                  child: issue.id == chart.selectedIssueId
                      ? const Icon(Icons.check_rounded, size: 17)
                      : null,
                ),
                const SizedBox(width: 8),
                TrText(issue.label),
              ],
            ),
          ),
      ],
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .14),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white24, width: .5),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TrText(chart.issueLabel, style: textStyle),
              const SizedBox(width: 4),
              if (loading)
                const SizedBox.square(
                  dimension: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: Colors.white,
                  ),
                )
              else
                const Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 17,
                  color: Colors.white,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChartTrackRow extends StatelessWidget {
  const _ChartTrackRow({
    required this.entry,
    this.matching = false,
    this.onTap,
  });
  final ChartEntry entry;
  final bool matching;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final apple = AppleSemanticColors.of(context);
    final roomy = MediaQuery.sizeOf(context).width >= 760;
    final int? previous = entry.previousRank;
    final IconData? trend = switch (entry.changeLabel) {
      'NEW' => Icons.fiber_new_rounded,
      '重返' || '重投' => Icons.replay_rounded, // i18n:key
      _ when previous != null && previous > entry.rank =>
        Icons.arrow_upward_rounded,
      _ when previous != null && previous < entry.rank =>
        Icons.arrow_downward_rounded,
      _ when previous != null => Icons.remove_rounded,
      _ => null,
    };
    return ListTile(
      minTileHeight: 68,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      tileColor: apple.secondaryGroupedBackground,
      onTap: onTap == null ? null : feedbackAction(context, onTap!),
      leading: SizedBox(
        width: 84,
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 38,
              child: Text(
                '${entry.rank}',
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.visible,
                textAlign: TextAlign.right,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(width: 6),
            LegacyCover(
              url: entry.track?.coverUrl ?? entry.coverUrl,
              size: 40,
              radius: 6,
            ),
          ],
        ),
      ),
      title: Text(
        entry.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        <String>[
          entry.artist.isNotEmpty ? entry.artist : entry.track?.artist ?? '',
          if (entry.peakRank != null) context.tr('最高 #${entry.peakRank}'),
          if (entry.weeksOnChart != null) context.tr('${entry.weeksOnChart} 周'),
          if (!roomy && entry.score != null)
            context.tr('${_formatChartScore(entry.score!)} 点'),
        ].where((value) => value.isNotEmpty).join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (roomy && entry.score != null) ...<Widget>[
            TrText(
              '${_formatChartScore(entry.score!)} 点',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: apple.secondaryLabel,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 10),
          ],
          if (roomy && entry.trend.length > 1) ...<Widget>[
            SizedBox(
              width: 64,
              height: 28,
              child: CustomPaint(
                painter: _ChartSparklinePainter(
                  values: entry.trend,
                  color: apple.accent,
                ),
              ),
            ),
            const SizedBox(width: 10),
          ],
          if (trend != null) Icon(trend, size: 16, color: apple.secondaryLabel),
          if (entry.changeLabel != null) ...<Widget>[
            if (trend != null) const SizedBox(width: 3),
            TrText(
              entry.changeLabel!,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: apple.secondaryLabel,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          if (trend != null || entry.changeLabel != null)
            const SizedBox(width: 10),
          if (matching)
            const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 1.7),
            )
          else
            Icon(
              onTap == null ? Icons.link_off_rounded : Icons.play_arrow_rounded,
              color: onTap == null ? apple.tertiaryLabel : apple.accent,
            ),
        ],
      ),
    );
  }
}

String _formatChartScore(int score) {
  final String digits = score.toString();
  final StringBuffer grouped = StringBuffer();
  for (int i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) grouped.write(',');
    grouped.write(digits[i]);
  }
  return grouped.toString();
}

class _ChartSparklinePainter extends CustomPainter {
  const _ChartSparklinePainter({required this.values, required this.color});

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final minValue = values.reduce(math.min);
    final maxValue = values.reduce(math.max);
    final span = math.max(1.0, maxValue - minValue);
    final path = Path();
    for (var index = 0; index < values.length; index++) {
      final x = size.width * index / (values.length - 1);
      final y = size.height - ((values[index] - minValue) / span * size.height);
      if (index == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_ChartSparklinePainter oldDelegate) =>
      oldDelegate.color != color || !listEquals(oldDelegate.values, values);
}

/// Large recommendation hero. Album art is the content; a bottom scrim keeps
/// white typography legible over any cover.
class _FeaturedPlaylistCard extends StatefulWidget {
  const _FeaturedPlaylistCard({
    required this.playlist,
    required this.onTap,
    required this.compact,
  });

  final Playlist playlist;
  final VoidCallback onTap;
  final bool compact;

  @override
  State<_FeaturedPlaylistCard> createState() => _FeaturedPlaylistCardState();
}

class _FeaturedPlaylistCardState extends State<_FeaturedPlaylistCard> {
  bool _hovering = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final bool raised = _hovering || _focused;
    final String subtitle = <String>[
      if (widget.playlist.trackCount > 0)
        context.tr('${widget.playlist.trackCount} 首歌曲'),
      if (widget.playlist.description.isNotEmpty) widget.playlist.description,
    ].join(' · ');
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: TvTapTarget(
        onTap: widget.onTap,
        onFocusChange: (bool value) => setState(() => _focused = value),
        borderRadius: BorderRadius.circular(18),
        focusScale: 1.006,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: raised ? 1.004 : 1,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: Container(
              height: widget.compact ? 190 : 248,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: apple.separator.withValues(alpha: .4),
                  width: .5,
                ),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: .16),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  if (widget.playlist.coverUrl?.isNotEmpty ?? false)
                    LegacyCover(
                      url: widget.playlist.coverUrl,
                      size: widget.compact ? 190 : 248,
                      radius: 0,
                    )
                  else
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: <Color>[
                            apple.accent,
                            Color.lerp(
                              apple.accent,
                              AppleColors.systemPurple,
                              .38,
                            )!,
                          ],
                        ),
                      ),
                    ),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: <Color>[
                          Color(0x00000000),
                          Color(0x33000000),
                          Color(0xD9000000),
                        ],
                        stops: <double>[.2, .54, 1],
                      ),
                    ),
                  ),
                  Positioned(
                    left: widget.compact ? 18 : 24,
                    right: widget.compact ? 18 : 24,
                    bottom: widget.compact ? 16 : 22,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: <Widget>[
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Text(
                                context.tr('为你精选'),
                                style: Theme.of(context).textTheme.labelMedium
                                    ?.copyWith(
                                      color: Colors.white.withValues(
                                        alpha: .72,
                                      ),
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: .4,
                                    ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                widget.playlist.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.headlineSmall
                                    ?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: -.4,
                                    ),
                              ),
                              if (subtitle.isNotEmpty) ...<Widget>[
                                const SizedBox(height: 4),
                                Text(
                                  subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: Colors.white.withValues(
                                          alpha: .72,
                                        ),
                                      ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 16),
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(
                              alpha: raised ? 1 : .86,
                            ),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.play_arrow_rounded,
                            size: 27,
                            color: Colors.black,
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

/// Library: local files first, then owned playlists and public
/// recommendations. Local music sits above the playlists so a guest can import
/// files without signing in.
class LegacyLibraryPage extends StatelessWidget {
  const LegacyLibraryPage({
    super.key,
    required this.state,
    required this.onOpenPlaylist,
    required this.onOpenLocalMusic,
    this.localImporter = const LocalMusicImporter(),
  });

  final AppState state;
  final ValueChanged<Playlist> onOpenPlaylist;
  final VoidCallback onOpenLocalMusic;

  /// Lets tests hand in a fake chooser; production uses the system picker.
  final LocalMusicImporter localImporter;

  @override
  Widget build(BuildContext context) {
    final UserCollections collections = state.collections;
    final List<Playlist> mine = _uniquePlaylists(<Playlist>[
      if (collections.liked != null) collections.liked!,
      ...collections.created,
      ...collections.subscribed,
    ]);
    final List<Playlist> publicLists = _uniquePlaylists(
      state.home?.playlists ?? const <Playlist>[],
    );
    final double inset = _pageInset(context);
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: adaptiveContentMaxWidth(context, 1180),
        ),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            // The grid is built lazily row by row: an account can hold a
            // thousand playlists, and a Wrap used to mount every card (and
            // every cover image) on the frame the library opened.
            final double width = math.max(0, constraints.maxWidth - inset * 2);
            final int columns = switch (width) {
              >= 1100 => 6,
              >= 860 => 5,
              >= 660 => 4,
              >= 430 => 3,
              _ => 2,
            };
            const double gap = 18;
            final double cell = ((width - gap * (columns - 1)) / columns).clamp(
              112.0,
              180.0,
            );
            return CustomScrollView(
              slivers: <Widget>[
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(inset, 8, inset, 0),
                  sliver: SliverList.list(
                    children: <Widget>[
                      ApplePageTitle(
                        title: '资料库',
                        subtitle: state.isGuest
                            ? '登录后同步你的歌单'
                            : '${state.user.name} 的音乐',
                        padding: const EdgeInsets.fromLTRB(0, 12, 0, 18),
                      ),
                      LocalMusicCard(
                        state: state,
                        onOpen: onOpenLocalMusic,
                        importer: localImporter,
                      ),
                      if (mine.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 30),
                        LegacySectionHeader(
                          title: '我的音乐',
                          subtitle: state.isGuest ? '游客模式' : null,
                          trailing: state.signedIn
                              ? Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    IconButton(
                                      tooltip: context.tr('创建歌单'),
                                      onPressed: () => unawaited(
                                        showCreateCloudPlaylistDialog(
                                          context,
                                          state,
                                        ),
                                      ),
                                      icon: const Icon(
                                        Icons.add_rounded,
                                        size: 20,
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: context.tr('刷新歌单'),
                                      onPressed: () => unawaited(
                                        state.refreshCollections(force: true),
                                      ),
                                      icon: const Icon(
                                        Icons.sync_rounded,
                                        size: 19,
                                      ),
                                    ),
                                  ],
                                )
                              : null,
                        ),
                        const SizedBox(height: 14),
                      ],
                    ],
                  ),
                ),
                if (mine.isNotEmpty)
                  SliverPadding(
                    padding: EdgeInsets.symmetric(horizontal: inset),
                    sliver: _PlaylistRowsSliver(
                      playlists: mine,
                      columns: columns,
                      cell: cell,
                      gap: gap,
                      onOpen: onOpenPlaylist,
                    ),
                  ),
                if (publicLists.isNotEmpty)
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      inset,
                      mine.isEmpty ? 30 : 34,
                      inset,
                      0,
                    ),
                    sliver: SliverList.list(
                      children: <Widget>[
                        const LegacySectionHeader(title: '推荐歌单'),
                        const SizedBox(height: 14),
                      ],
                    ),
                  ),
                if (publicLists.isNotEmpty)
                  SliverPadding(
                    padding: EdgeInsets.symmetric(horizontal: inset),
                    sliver: _PlaylistRowsSliver(
                      playlists: publicLists,
                      columns: columns,
                      cell: cell,
                      gap: gap,
                      onOpen: onOpenPlaylist,
                    ),
                  ),
                if (mine.isEmpty && publicLists.isEmpty)
                  SliverPadding(
                    padding: EdgeInsets.symmetric(horizontal: inset),
                    sliver: SliverToBoxAdapter(
                      child: LegacyNotice(
                        message: state.isGuest ? '登录后同步你的歌单' : '还没有歌单。',
                        action: state.isGuest
                            ? FilledButton(
                                onPressed: () => unawaited(
                                  showLegacyLoginDialog(context, state),
                                ),
                                child: const TrText('登录'),
                              )
                            : null,
                      ),
                    ),
                  ),
                const SliverToBoxAdapter(child: SizedBox(height: 28)),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// A lazily built playlist grid: one sliver row per [columns] cards.
///
/// A sliver list keeps the intrinsic card height (so text scaling never
/// overflows a fixed grid extent) while only mounting the rows on screen.
class _PlaylistRowsSliver extends StatelessWidget {
  const _PlaylistRowsSliver({
    required this.playlists,
    required this.columns,
    required this.cell,
    required this.gap,
    required this.onOpen,
  });

  final List<Playlist> playlists;
  final int columns;
  final double cell;
  final double gap;
  final ValueChanged<Playlist> onOpen;

  @override
  Widget build(BuildContext context) {
    final int count = (playlists.length + columns - 1) ~/ columns;
    return SliverList.builder(
      itemCount: count,
      itemBuilder: (BuildContext context, int row) {
        final int start = row * columns;
        final int end = math.min(start + columns, playlists.length);
        return Padding(
          padding: EdgeInsets.only(bottom: row == count - 1 ? 0 : 24),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (var i = start; i < end; i++) ...<Widget>[
                if (i > start) SizedBox(width: gap),
                LegacyPlaylistCard(
                  playlist: playlists[i],
                  width: cell,
                  onTap: () => onOpen(playlists[i]),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

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
  void dispose() {
    _scroll.removeListener(_scheduleLocateRefresh);
    widget.state.removeListener(_scheduleLocateRefresh);
    _showLocate.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    final Album? album = widget.album;
    if (album == null && _tracks == null) {
      // Last session's track list paints immediately; the live request below
      // replaces it as soon as the gateway answers.
      final List<Track>? stored = await widget.state.catalog
          .cachedPlaylistTracks(widget.playlist.id);
      if (mounted && stored != null && _tracks == null) {
        setState(() {
          _tracks = stored;
          _metricsDirty = true;
          _rowIndexTrackId = null;
          _rowIndexCache = -1;
        });
        _scheduleLocateRefresh();
      }
    }
    try {
      final List<Track> tracks;
      String? note;
      if (album != null) {
        // The list row only carries a stub Album; the full description lives
        // on the album detail endpoint.
        final details = await widget.state.catalog.albumDetails(
          int.parse(album.id),
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
        _metricsDirty = true;
        _rowIndexTrackId = null;
        _rowIndexCache = -1;
      });
      _scheduleLocateRefresh();
    } catch (_) {
      if (!mounted) return;
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
    final double inset = _pageInset(context);
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

/// Search page reached from the rail (desktop) or the 搜索 tab (phones).
///
/// The field lives here rather than in the toolbar, so the page owns the
/// query, the debounce and the results. Switching pages disposes it, which is
/// also what resets the search.
class LegacySearchPage extends StatefulWidget {
  const LegacySearchPage({
    super.key,
    required this.state,
    required this.onOpenPlaylist,
  });

  final AppState state;
  final ValueChanged<Playlist> onOpenPlaylist;

  @override
  State<LegacySearchPage> createState() => _LegacySearchPageState();
}

class _LegacySearchPageState extends State<LegacySearchPage> {
  final TextEditingController _search = TextEditingController();
  SearchResults? _results;
  _SearchTab _tab = _SearchTab.songs;
  String _query = '';
  bool _loading = false;
  String? _error;
  int _generation = 0;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    // The field must not search while the user is still typing. Only Enter
    // (or the IME search action) commits the query; clearing the text resets
    // the page immediately.
    if (value.trim().isNotEmpty) {
      setState(() {});
      return;
    }
    _generation++;
    setState(() {
      _query = '';
      _results = null;
      _loading = false;
      _error = null;
    });
  }

  void _submit(String value) => unawaited(_run(value.trim()));

  void _clear() {
    _search.clear();
    _generation++;
    setState(() {
      _query = '';
      _results = null;
      _loading = false;
      _error = null;
    });
  }

  Future<void> _run(String query) async {
    final int generation = ++_generation;
    if (query.isEmpty) {
      setState(() {
        _query = '';
        _results = null;
        _loading = false;
        _error = null;
      });
      return;
    }
    setState(() {
      _query = query;
      _loading = true;
      _error = null;
    });
    try {
      final SearchResults results = await widget.state.search(query);
      if (!mounted || generation != _generation) return;
      setState(() {
        _results = results;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = '搜索失败，请检查网络后重试。'; // i18n:key
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final double inset = _pageInset(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1180),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: EdgeInsets.fromLTRB(inset, 14, inset, 12),
              child: AppleSearchField(
                controller: _search,
                autofocus: true,
                onChanged: _onChanged,
                onSubmitted: _submit,
                onClear: _clear,
              ),
            ),
            Expanded(child: _body(inset)),
          ],
        ),
      ),
    );
  }

  Widget _body(double inset) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return LegacyNotice(
        message: _error!,
        icon: Icons.search_off_rounded,
        action: FilledButton(
          onPressed: () => unawaited(_run(_query)),
          child: const TrText('重试'),
        ),
      );
    }
    final SearchResults? results = _results;
    if (_query.isEmpty) {
      return const LegacyNotice(
        message: '搜索歌曲、歌手或歌单。',
        icon: Icons.search_rounded,
      );
    }
    if (results == null || results.hits == 0) {
      return const LegacyNotice(
        message: '没有找到相关结果。',
        icon: Icons.search_rounded,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(inset, 0, inset, 10),
          child: Row(
            children: <Widget>[
              _SearchTabButton(
                label: '歌曲',
                active: _tab == _SearchTab.songs,
                onTap: () => setState(() => _tab = _SearchTab.songs),
              ),
              const SizedBox(width: 8),
              _SearchTabButton(
                label: '专辑',
                active: _tab == _SearchTab.albums,
                onTap: () => setState(() => _tab = _SearchTab.albums),
              ),
              const SizedBox(width: 8),
              _SearchTabButton(
                label: '歌手',
                active: _tab == _SearchTab.artists,
                onTap: () => setState(() => _tab = _SearchTab.artists),
              ),
              const SizedBox(width: 8),
              _SearchTabButton(
                label: '歌单',
                active: _tab == _SearchTab.playlists,
                onTap: () => setState(() => _tab = _SearchTab.playlists),
              ),
            ],
          ),
        ),
        Expanded(
          child: switch (_tab) {
            _SearchTab.songs => ListView(
              padding: EdgeInsets.fromLTRB(inset, 0, inset, 28),
              children: <Widget>[
                for (int i = 0; i < results.tracks.length; i++)
                  LegacyTrackRow(
                    track: results.tracks[i],
                    index: i,
                    current: widget.state.current?.id == results.tracks[i].id,
                    playing: widget.state.playing,
                    onTap: () =>
                        widget.state.playQueue(results.tracks, startIndex: i),
                    onMenuRequested: (Offset position) => showTrackActions(
                      context,
                      widget.state,
                      results.tracks[i],
                      position,
                    ),
                  ),
              ],
            ),
            _SearchTab.albums => ListView(
              padding: EdgeInsets.fromLTRB(inset, 0, inset, 28),
              children: <Widget>[
                for (final Album album in results.albums)
                  AppleListTile(
                    title: album.title,
                    subtitle: album.artist,
                    minHeight: 56,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    leading: LegacyCover(
                      url: album.coverUrl,
                      size: 44,
                      radius: 6,
                    ),
                    onTap: () => unawaited(
                      openAlbumDetails(context, widget.state, album),
                    ),
                  ),
              ],
            ),
            _SearchTab.artists => ListView(
              padding: EdgeInsets.fromLTRB(inset, 0, inset, 28),
              children: <Widget>[
                for (final ArtistRef artist in results.artists)
                  AppleListTile(
                    title: artist.name,
                    subtitle: context.tr('歌手'),
                    minHeight: 56,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    leading: ClipOval(
                      child: LegacyCover(
                        url: artist.coverUrl,
                        size: 44,
                        radius: 22,
                      ),
                    ),
                    onTap: () => artistDetailRequest.value = artist,
                  ),
              ],
            ),
            _SearchTab.playlists => ListView(
              padding: EdgeInsets.fromLTRB(inset, 0, inset, 28),
              children: <Widget>[
                LegacyPlaylistGrid(
                  playlists: results.playlists,
                  onOpen: widget.onOpenPlaylist,
                ),
              ],
            ),
          },
        ),
      ],
    );
  }
}

/// Tabs across the top of the search results.
enum _SearchTab { songs, albums, artists, playlists }

class _SearchTabButton extends StatelessWidget {
  const _SearchTabButton({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return Semantics(
      button: true,
      selected: active,
      child: TvTapTarget(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        focusScale: 1.04,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: active ? apple.label.withValues(alpha: .1) : null,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                context.tr(label),
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: active ? apple.label : apple.secondaryLabel,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A single-column, inset-grouped Settings page, following the iOS Settings
/// information architecture rather than a desktop form grid.
class LegacySettingsPage extends StatelessWidget {
  const LegacySettingsPage({
    super.key,
    required this.state,
    this.onOpenLocalMusic,
    this.backgroundImagePicker,
  });

  final AppState state;

  /// Jumps to the local-music page from the download settings group.
  final VoidCallback? onOpenLocalMusic;

  /// Overrides the platform picture picker. Tests and platform forks can
  /// supply a stored file without opening a system dialog.
  final Future<String?> Function()? backgroundImagePicker;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final double minScale = UiMetrics.minScaleOf(context);
    final double shownScale = UiMetrics.scaleOf(context);
    final bool car = UiMetrics.carOf(context);
    final bool shortcutsCustomised = MediaShortcutAction.values.any(
      (MediaShortcutAction action) =>
          state.mediaShortcuts[action] != kDefaultMediaShortcuts[action],
    );
    final DynamicBackgroundPrecision flowPrecision =
        DynamicBackgroundPrecision.of(state.dynamicBackgroundQuality);
    final double inset = _pageInset(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: EdgeInsets.fromLTRB(inset, 8, inset, 36),
          children: <Widget>[
            const ApplePageTitle(
              title: '设置',
              subtitle: '外观、界面和账户。',
              padding: EdgeInsets.fromLTRB(0, 12, 0, 20),
            ),
            const _LegacySectionLabel('界面'),
            AppleGroupedCard(
              margin: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  _LegacySettingRow(
                    label: '配色',
                    subtitle: state.legacyPalette.detail,
                    trailing: DropdownButton<LegacyPaletteMode>(
                      value: state.legacyPalette,
                      underline: const SizedBox.shrink(),
                      borderRadius: BorderRadius.circular(12),
                      items: <DropdownMenuItem<LegacyPaletteMode>>[
                        for (final LegacyPaletteMode mode
                            in LegacyPaletteMode.values)
                          DropdownMenuItem<LegacyPaletteMode>(
                            value: mode,
                            child: TrText(mode.label),
                          ),
                      ],
                      onChanged: (LegacyPaletteMode? value) {
                        if (value == null) return;
                        unawaited(state.setLegacyPalette(value));
                        if (value == LegacyPaletteMode.custom &&
                            state.legacyAccentColor == null) {
                          unawaited(_pickLegacyAccent(context, state));
                        }
                      },
                    ),
                  ),
                  if (state.legacyPalette == LegacyPaletteMode.custom)
                    _LegacySettingRow(
                      label: '强调色',
                      subtitle: '点按色块挑选主题强调色',
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            _accentHex(
                              state.legacyAccentColor ?? AppleColors.musicRed,
                            ),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: apple.secondaryLabel,
                              fontFeatures: const <FontFeature>[
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          _LegacyAccentSwatch(
                            key: const ValueKey('legacy-accent-swatch'),
                            color:
                                state.legacyAccentColor ?? AppleColors.musicRed,
                            onTap: () =>
                                unawaited(_pickLegacyAccent(context, state)),
                          ),
                        ],
                      ),
                    ),
                  _LegacySettingRow(
                    label: '设备形态',
                    subtitle: state.surface.detail,
                    trailing: DropdownButton<AppSurface>(
                      value: state.surface,
                      underline: const SizedBox.shrink(),
                      borderRadius: BorderRadius.circular(12),
                      items: <DropdownMenuItem<AppSurface>>[
                        for (final AppSurface surface in AppSurface.values)
                          DropdownMenuItem<AppSurface>(
                            value: surface,
                            child: TrText(surface.label),
                          ),
                      ],
                      onChanged: (AppSurface? value) {
                        if (value != null) unawaited(state.setSurface(value));
                      },
                    ),
                  ),
                  _LegacySettingRow(
                    label: '界面布局',
                    subtitle: state.uiMode.detail,
                    trailing: DropdownButton<AppUiMode>(
                      value: state.uiMode,
                      underline: const SizedBox.shrink(),
                      borderRadius: BorderRadius.circular(12),
                      items: <DropdownMenuItem<AppUiMode>>[
                        for (final AppUiMode mode in AppUiMode.values)
                          DropdownMenuItem<AppUiMode>(
                            value: mode,
                            child: TrText(mode.label),
                          ),
                      ],
                      onChanged: (AppUiMode? value) {
                        if (value != null) unawaited(state.setUiMode(value));
                      },
                    ),
                  ),
                  _LegacySliderRow(
                    key: const ValueKey('dpi-scale-slider'),
                    label: 'DPI 缩放',
                    valueText: '${(shownScale * 100).round()}%',
                    subtitle: state.autoDpiScale
                        ? '自动推算 · 拖动拉杆即改为手动'
                        : car
                        ? '车机形态已把界面放大到 ${(minScale * 100).round()}% 起'
                        : '按比例放大整块界面，适合高分屏',
                    value: shownScale.clamp(minScale, kDpiScaleMax),
                    min: minScale,
                    max: kDpiScaleMax,
                    divisions: ((kDpiScaleMax - minScale) / kDpiScaleStep)
                        .round(),
                    onChanged: (double value) =>
                        unawaited(state.setDpiScale(value)),
                    action: TextButton(
                      key: const ValueKey('dpi-scale-reset'),
                      onPressed: () => unawaited(state.resetDpiScale()),
                      child: const TrText('恢复默认'),
                    ),
                  ),
                  _LegacySwitchRow(
                    key: const ValueKey('auto-dpi-switch'),
                    label: '自动调节 DPI 缩放',
                    subtitle: '按窗口可用空间自动推算',
                    value: state.autoDpiScale,
                    onChanged: (bool value) =>
                        unawaited(state.setAutoDpiScale(value)),
                  ),
                  _LegacySettingRow(
                    label: '背景',
                    subtitle: state.legacyBackground.detail,
                    trailing: DropdownButton<LegacyBackgroundMode>(
                      value: state.legacyBackground,
                      underline: const SizedBox.shrink(),
                      borderRadius: BorderRadius.circular(12),
                      items: <DropdownMenuItem<LegacyBackgroundMode>>[
                        for (final LegacyBackgroundMode mode
                            in LegacyBackgroundMode.values)
                          DropdownMenuItem<LegacyBackgroundMode>(
                            value: mode,
                            child: TrText(mode.label),
                          ),
                      ],
                      onChanged: (LegacyBackgroundMode? value) {
                        if (value == null) return;
                        unawaited(state.setLegacyBackground(value));
                        if (value == LegacyBackgroundMode.customImage &&
                            state.legacyBackgroundImagePath == null) {
                          unawaited(
                            _pickBackgroundImage(
                              context,
                              state,
                              backgroundImagePicker,
                            ),
                          );
                        }
                      },
                    ),
                  ),
                  if (state.legacyBackground ==
                      LegacyBackgroundMode.customImage)
                    _LegacySettingRow(
                      label: '背景图片',
                      subtitle: state.legacyBackgroundImagePath == null
                          ? '尚未选择图片，点按右侧选择'
                          : '已选择图片，可更换或移除',
                      trailing: Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          if (state.legacyBackgroundImagePath != null)
                            TextButton(
                              key: const ValueKey('background-image-clear'),
                              onPressed: () {
                                final String? path =
                                    state.legacyBackgroundImagePath;
                                unawaited(state.setLegacyBackgroundImage(null));
                                unawaited(
                                  state.setLegacyBackground(
                                    LegacyBackgroundMode.off,
                                  ),
                                );
                                unawaited(deleteCustomBackgroundImage(path));
                              },
                              child: const TrText('移除'),
                            ),
                          OutlinedButton(
                            key: const ValueKey('background-image-pick'),
                            onPressed: () => unawaited(
                              _pickBackgroundImage(
                                context,
                                state,
                                backgroundImagePicker,
                              ),
                            ),
                            child: Text(
                              context.tr(
                                state.legacyBackgroundImagePath == null
                                    ? '选择图片'
                                    : '更换',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  _LegacySliderRow(
                    key: const ValueKey('legacy-ui-alpha'),
                    label: '内容不透明度',
                    valueText: '${(state.legacyUiAlpha * 100).round()}%',
                    subtitle: '数值越小，背景越明显',
                    value: state.legacyUiAlpha.clamp(0.4, 1.0),
                    min: 0.4,
                    max: 1.0,
                    divisions: 12,
                    onChanged:
                        state.legacyBackground == LegacyBackgroundMode.off
                        ? null
                        : (double value) =>
                              unawaited(state.setLegacyUiAlpha(value)),
                  ),
                  // The flowing canvas is the app's only continuously
                  // repainting surface, so its precision is the setting a
                  // struggling GPU needs. Both halves of it are shown —
                  // the mesh it draws and how often it redraws it — so the
                  // value is verifiable rather than a blind percentage.
                  _LegacySliderRow(
                    key: const ValueKey('dynamic-background-quality'),
                    label: '动态背景渲染精度',
                    valueText:
                        '${(state.dynamicBackgroundQuality * 100).round()}%',
                    // One literal on purpose: the translation table matches
                    // it as a single pattern key.
                    subtitle:
                        '网格 ${flowPrecision.columns}×${flowPrecision.rows}，每 ${flowPrecision.frameInterval.inMilliseconds} ms 刷新一次',
                    value: state.dynamicBackgroundQuality,
                    min: kDynamicBackgroundQualityMin,
                    max: kDynamicBackgroundQualityMax,
                    divisions:
                        ((kDynamicBackgroundQualityMax -
                                    kDynamicBackgroundQualityMin) /
                                kDynamicBackgroundQualityStep)
                            .round(),
                    onChanged: (double value) =>
                        unawaited(state.setDynamicBackgroundQuality(value)),
                    action: TextButton(
                      key: const ValueKey('dynamic-background-quality-reset'),
                      onPressed: () =>
                          unawaited(state.resetDynamicBackgroundQuality()),
                      child: const TrText('恢复默认'),
                    ),
                  ),
                ],
              ),
            ),
            const _LegacySectionLabel('外观'),
            AppleGroupedCard(
              margin: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  _LegacySettingRow(
                    label: '主题',
                    subtitle: switch (state.themeMode) {
                      ThemeMode.system => '跟随系统',
                      ThemeMode.light => '浅色',
                      ThemeMode.dark => '深色',
                    },
                    trailing: DropdownButton<ThemeMode>(
                      value: state.themeMode,
                      underline: const SizedBox.shrink(),
                      borderRadius: BorderRadius.circular(12),
                      items: const <DropdownMenuItem<ThemeMode>>[
                        DropdownMenuItem<ThemeMode>(
                          value: ThemeMode.system,
                          child: TrText('跟随系统'),
                        ),
                        DropdownMenuItem<ThemeMode>(
                          value: ThemeMode.light,
                          child: TrText('浅色'),
                        ),
                        DropdownMenuItem<ThemeMode>(
                          value: ThemeMode.dark,
                          child: TrText('深色'),
                        ),
                      ],
                      onChanged: (ThemeMode? value) {
                        if (value != null) {
                          unawaited(state.setThemeMode(value));
                        }
                      },
                    ),
                  ),
                  _LegacySettingRow(
                    label: '语言',
                    subtitle: state.language.name,
                    trailing: DropdownButton<AppLanguage>(
                      value: state.language,
                      underline: const SizedBox.shrink(),
                      borderRadius: BorderRadius.circular(12),
                      items: <DropdownMenuItem<AppLanguage>>[
                        for (final AppLanguage language in AppLanguage.values)
                          DropdownMenuItem<AppLanguage>(
                            value: language,
                            child: Text(language.name),
                          ),
                      ],
                      onChanged: (AppLanguage? value) {
                        if (value != null) {
                          unawaited(state.setLanguage(value));
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
            const _LegacySectionLabel('播放'),
            AppleGroupedCard(
              margin: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  _LegacySettingRow(
                    label: '播放音质',
                    subtitle: state.playbackQuality.detail,
                    trailing: DropdownButton<AudioQuality>(
                      key: const ValueKey('playback-quality'),
                      value: state.playbackQuality,
                      underline: const SizedBox.shrink(),
                      borderRadius: BorderRadius.circular(12),
                      items: <DropdownMenuItem<AudioQuality>>[
                        for (final AudioQuality quality in AudioQuality.values)
                          DropdownMenuItem<AudioQuality>(
                            value: quality,
                            child: TrText(quality.label),
                          ),
                      ],
                      onChanged: (AudioQuality? value) {
                        if (value != null) {
                          unawaited(state.setPlaybackQuality(value));
                        }
                      },
                    ),
                  ),
                  _LegacySwitchRow(
                    label: '独立播放',
                    subtitle: '不接入系统媒体控制',
                    value: state.independentPlayback,
                    onChanged: (bool value) =>
                        unawaited(state.setIndependentPlayback(value)),
                  ),
                ],
              ),
            ),
            const _LegacySectionLabel('下载'),
            AppleGroupedCard(
              margin: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  _LegacySettingRow(
                    label: '下载音质',
                    subtitle: state.downloadQuality.detail,
                    trailing: DropdownButton<AudioQuality>(
                      key: const ValueKey('download-quality'),
                      value: state.downloadQuality,
                      underline: const SizedBox.shrink(),
                      borderRadius: BorderRadius.circular(12),
                      items: <DropdownMenuItem<AudioQuality>>[
                        for (final AudioQuality quality in AudioQuality.values)
                          DropdownMenuItem<AudioQuality>(
                            value: quality,
                            child: TrText(quality.label),
                          ),
                      ],
                      onChanged: (AudioQuality? value) {
                        if (value != null) {
                          unawaited(state.setDownloadQuality(value));
                        }
                      },
                    ),
                  ),
                  _LegacySettingRow(
                    label: '下载任务',
                    subtitle: '查看进度、取消或重试下载',
                    trailing: AnimatedBuilder(
                      animation: state.downloadManager,
                      builder: (BuildContext context, Widget? child) {
                        final int active = state.downloadManager.activeCount;
                        final int done = state.downloadManager.completedCount;
                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(
                              context.tr(
                                active > 0 ? '$active 进行中' : '$done 已完成',
                              ),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: apple.secondaryLabel,
                              ),
                            ),
                            const SizedBox(width: 6),
                            TextButton(
                              key: const ValueKey('open-download-queue'),
                              onPressed: () =>
                                  showDownloadQueueSheet(context, state),
                              child: const TrText('查看'),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                  if (onOpenLocalMusic != null)
                    AnimatedBuilder(
                      animation: state.localLibrary,
                      builder: (BuildContext context, Widget? child) {
                        final int count = state.localLibrary.availableCount;
                        return _LegacySettingRow(
                          label: '本地音乐',
                          subtitle: count == 0
                              ? '下载和导入的歌曲会保存在这里'
                              : '$count 首 · ${formatBytes(state.localLibrary.totalBytes)}',
                          trailing: TextButton(
                            key: const ValueKey('open-local-music-settings'),
                            onPressed: onOpenLocalMusic,
                            child: const TrText('管理'),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
            const _LegacySectionLabel('交互'),
            AppleGroupedCard(
              margin: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  _LegacySwitchRow(
                    label: '震动反馈',
                    subtitle: '点击可操作的元素和拖动进度条、数值条时反馈',
                    value: state.hapticsEnabled,
                    onChanged: (bool value) =>
                        unawaited(state.setHapticsEnabled(value)),
                  ),
                  if (defaultTargetPlatform == TargetPlatform.iOS ||
                      defaultTargetPlatform == TargetPlatform.android)
                    _LegacySliderRow(
                      label: '震动强度',
                      valueText: '${(state.hapticIntensity * 100).round()}%',
                      value: state.hapticIntensity.clamp(0.0, 1.0),
                      min: 0,
                      max: 1,
                      divisions: 20,
                      onChanged: state.hapticsEnabled
                          ? (double value) =>
                                unawaited(state.setHapticIntensity(value))
                          : null,
                    ),
                  _LegacySliderRow(
                    label: '歌词控件自动隐藏',
                    valueText:
                        '${state.lyricControlsSeconds.toStringAsFixed(1)} 秒',
                    subtitle: '闲置一会儿后收起歌词页的控件',
                    value: state.lyricControlsSeconds.clamp(1.0, 10.0),
                    min: 1,
                    max: 10,
                    divisions: 18,
                    onChanged: (double value) =>
                        unawaited(state.setLyricControlsSeconds(value)),
                  ),
                ],
              ),
            ),
            const _LegacySectionLabel('快捷键'),
            AppleGroupedCard(
              margin: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  _LegacySettingRow(
                    label: '媒体快捷键',
                    subtitle: '在应用内用键盘控制播放；在文本框中输入时快捷键不会触发',
                    trailing: TextButton(
                      key: const ValueKey('media-shortcut-reset'),
                      onPressed: shortcutsCustomised
                          ? () => unawaited(state.resetMediaShortcuts())
                          : null,
                      child: const TrText('恢复默认'),
                    ),
                  ),
                  for (final MediaShortcutAction action
                      in MediaShortcutAction.values)
                    _LegacySettingRow(
                      label: action.label,
                      subtitle: action.detail,
                      trailing: OutlinedButton(
                        key: ValueKey('media-shortcut-${action.name}'),
                        onPressed: () =>
                            unawaited(_editMediaShortcut(context, state, action)),
                        child: Text(
                          state.mediaShortcutFor(action)?.label ??
                              context.tr('未设置'),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const _LegacySectionLabel('歌词'),
            AppleGroupedCard(
              margin: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  _LegacySliderRow(
                    label: '歌词字号',
                    valueText: '${state.lyricFontSize.round()}',
                    value: state.lyricFontSize.clamp(14.0, 40.0),
                    min: 14,
                    max: 40,
                    divisions: 26,
                    onChanged: (double value) =>
                        unawaited(state.setLyricFontSize(value)),
                  ),
                  _LegacyChoiceRow(
                    label: '歌词粗细',
                    valueText: context.tr(switch (state.lyricFontWeight) {
                      400 => '常规',
                      500 => '中等',
                      600 => '半粗',
                      _ => '粗体',
                    }),
                    choices: const <int>[400, 500, 600, 700],
                    selected: state.lyricFontWeight,
                    labelOf: (int weight) => context.tr(switch (weight) {
                      400 => '常规',
                      500 => '中等',
                      600 => '半粗',
                      _ => '粗体',
                    }),
                    onSelected: (int weight) =>
                        unawaited(state.setLyricFontWeight(weight)),
                  ),
                  _LegacySwitchRow(
                    label: '歌词模糊',
                    subtitle: '距离当前歌词越远，模糊越强；手动浏览时渐隐',
                    value: state.lyricBlurEnabled,
                    onChanged: (bool value) =>
                        unawaited(state.setLyricBlurEnabled(value)),
                  ),
                  _LegacySliderRow(
                    label: '手动浏览后恢复跟随',
                    valueText:
                        '${state.lyricResumeSeconds.toStringAsFixed(1)} 秒',
                    subtitle: '松开手后多久回到当前行',
                    value: state.lyricResumeSeconds.clamp(1.0, 10.0),
                    min: 1,
                    max: 10,
                    divisions: 18,
                    onChanged: (double value) =>
                        unawaited(state.setLyricResumeSeconds(value)),
                  ),
                ],
              ),
            ),
            const _LegacySectionLabel('滚动'),
            AppleGroupedCard(
              margin: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  _LegacySliderRow(
                    label: '滚动惯性',
                    valueText: '${(state.scrollRetention * 100).round()}%',
                    subtitle: '85–98%；数值越高，松手后滑行越久、越远',
                    value: state.scrollRetention,
                    min: ScrollMotion.minRetention,
                    max: ScrollMotion.maxRetention,
                    divisions: 13,
                    onChanged: (double value) =>
                        unawaited(state.setScrollRetention(value)),
                    action: TextButton(
                      onPressed: () => unawaited(
                        state.setScrollRetention(ScrollMotion.defaultRetention),
                      ),
                      child: const TrText('恢复默认'),
                    ),
                  ),
                  _LegacySliderRow(
                    label: '滚动加速度',
                    valueText: '${(state.scrollAcceleration * 100).round()}%',
                    subtitle: '50–300%；数值越高，滚轮和连续甩动提速越明显',
                    value: state.scrollAcceleration,
                    min: ScrollMotion.minAcceleration,
                    max: ScrollMotion.maxAcceleration,
                    divisions: 25,
                    onChanged: (double value) =>
                        unawaited(state.setScrollAcceleration(value)),
                    action: TextButton(
                      onPressed: () => unawaited(
                        state.setScrollAcceleration(
                          ScrollMotion.defaultAcceleration,
                        ),
                      ),
                      child: const TrText('恢复默认'),
                    ),
                  ),
                ],
              ),
            ),
            const _LegacySectionLabel('性能'),
            AppleGroupedCard(
              margin: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  _LegacySettingRow(
                    label: '动画帧预算',
                    subtitle: '全部界面动画按 10 ms 设计；低帧目标不低于 90 fps',
                    trailing: Text(
                      '10 ms',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: apple.secondaryLabel,
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (state.debugOptionsEnabled) ...<Widget>[
              const _LegacySectionLabel('调试'),
              AppleGroupedCard(
                margin: EdgeInsets.zero,
                child: Column(
                  children: <Widget>[
                    _LegacySwitchRow(
                      label: '显示帧数',
                      subtitle: '实时显示 UI、GPU、低帧和 100 fps 帧预算',
                      value: state.showFrameStats,
                      onChanged: (bool value) =>
                          unawaited(state.setShowFrameStats(value)),
                    ),
                    _LegacySettingRow(
                      label: '音频设备',
                      subtitle: '查看当前音频输出端点和音频会话详情',
                      trailing: OutlinedButton(
                        key: const ValueKey('open-audio-device-info'),
                        onPressed: () =>
                            unawaited(showAudioDeviceInfoDialog(context)),
                        child: const TrText('查看'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const _LegacySectionLabel('账户'),
            AppleGroupedCard(
              margin: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  _LegacySettingRow(
                    label: state.isGuest ? '游客' : state.user.name,
                    subtitle: state.isGuest
                        ? '登录后同步歌单和每日推荐'
                        : state.user.vipLabel ?? '普通用户',
                    trailing: state.isGuest
                        ? FilledButton(
                            onPressed: () => unawaited(
                              showLegacyLoginDialog(context, state),
                            ),
                            child: const TrText('登录'),
                          )
                        : TextButton(
                            onPressed: state.signOut,
                            child: const TrText('退出登录'),
                          ),
                  ),
                  _LegacySettingRow(
                    label: '一起听',
                    subtitle: '和朋友同步听歌',
                    trailing: OutlinedButton(
                      onPressed: () =>
                          unawaited(showListenTogetherDialog(context, state)),
                      child: const TrText('打开'),
                    ),
                  ),
                  _LegacySettingRow(
                    label: '刷新曲库',
                    subtitle: '重新拉取首页、歌单和每日推荐',
                    trailing: OutlinedButton(
                      onPressed: () =>
                          unawaited(state.refreshHome(force: true)),
                      child: const TrText('刷新'),
                    ),
                  ),
                ],
              ),
            ),
            const _LegacySectionLabel('关于'),
            AppleGroupedCard(
              margin: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  _VersionSecretTile(state: state),
                  _LegacySettingRow(
                    label: '检查更新',
                    subtitle: '从 GitHub 获取最新版本',
                    trailing: state.updateChecking
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : OutlinedButton(
                            onPressed: () => unawaited(
                              checkUpdatesFromSettings(context, state),
                            ),
                            child: const TrText('检查更新'),
                          ),
                  ),
                  if (state.skippedUpdateVersion != null)
                    _LegacySettingRow(
                      label: context.tr('已跳过 v${state.skippedUpdateVersion}'),
                      subtitle: '自动提醒不再提示这个版本',
                      trailing: TextButton(
                        onPressed: () => unawaited(state.clearSkippedUpdate()),
                        child: const TrText('恢复提醒'),
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

class _LegacySectionLabel extends StatelessWidget {
  const _LegacySectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 22, 12, 7),
      child: Text(
        context.tr(label),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: apple.secondaryLabel,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _LegacySettingRow extends StatelessWidget {
  const _LegacySettingRow({
    required this.label,
    required this.subtitle,
    required this.trailing,
  });

  final String label;
  final String subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final bool stacked = MediaQuery.sizeOf(context).width < 360;
    final Widget heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          context.tr(label),
          style: theme.textTheme.bodyLarge?.copyWith(color: apple.label),
        ),
        if (subtitle.isNotEmpty) ...<Widget>[
          const SizedBox(height: 2),
          Text(
            context.tr(subtitle),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: apple.secondaryLabel,
            ),
          ),
        ],
      ],
    );
    return TvFocusHighlight(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: apple.separator, width: .5)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: stacked
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  heading,
                  const SizedBox(height: 8),
                  Align(alignment: Alignment.centerLeft, child: trailing),
                ],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Expanded(flex: 4, child: heading),
                  const SizedBox(width: 12),
                  Flexible(
                    flex: 9,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: trailing,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _LegacySwitchRow extends StatelessWidget {
  const _LegacySwitchRow({
    super.key,
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return _LegacySettingRow(
      label: label,
      subtitle: subtitle,
      trailing: Switch(value: value, onChanged: onChanged),
    );
  }
}

/// The 关于 version card doubles as the hidden switch for the debug section:
/// seven taps inside four seconds toggle it. The tap target is invisible, so
/// ordinary users only ever see an ordinary version row.
class _VersionSecretTile extends StatefulWidget {
  const _VersionSecretTile({required this.state});

  final AppState state;

  @override
  State<_VersionSecretTile> createState() => _VersionSecretTileState();
}

class _VersionSecretTileState extends State<_VersionSecretTile> {
  static const int _tapsToToggle = 7;
  static const Duration _window = Duration(seconds: 4);

  int _taps = 0;
  DateTime? _firstTap;

  void _tap() {
    final DateTime now = DateTime.now();
    final DateTime? first = _firstTap;
    if (first == null || now.difference(first) > _window) {
      _firstTap = now;
      _taps = 0;
    }
    if (++_taps < _tapsToToggle) return;
    _taps = 0;
    _firstTap = null;
    final bool enabled = !widget.state.debugOptionsEnabled;
    unawaited(widget.state.setDebugOptionsEnabled(enabled));
    final String message = enabled
        ? context.tr('调试选项已开启')
        : context.tr('调试选项已关闭');
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return AppleListTile(
      title: 'Lazer',
      subtitle: context.tr('提交 ${BuildInfo.shortCommit}'),
      onTap: _tap,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: Image.asset(
          'assets/app_icon.png',
          width: 30,
          height: 30,
          fit: BoxFit.cover,
        ),
      ),
      trailing: Text(
        BuildInfo.displayVersion,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: apple.secondaryLabel,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// Debug-only panel listing the current audio endpoints and the session
/// attributes the player asked the platform for.
Future<void> showAudioDeviceInfoDialog(BuildContext context) =>
    showDialog<void>(
      context: context,
      builder: (BuildContext context) => const _AudioDeviceDialog(),
    );

class _AudioDeviceDialog extends StatefulWidget {
  const _AudioDeviceDialog();

  @override
  State<_AudioDeviceDialog> createState() => _AudioDeviceDialogState();
}

class _AudioDeviceDialogState extends State<_AudioDeviceDialog> {
  late Future<AudioDeviceReport> _report = AudioDeviceReport.collect();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const TrText('音频设备'),
      contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
      content: SizedBox(
        width: 420,
        child: FutureBuilder<AudioDeviceReport>(
          future: _report,
          builder:
              (
                BuildContext context,
                AsyncSnapshot<AudioDeviceReport> snapshot,
              ) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const SizedBox(
                    height: 120,
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                return _body(context, snapshot.data);
              },
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => setState(() {
            _report = AudioDeviceReport.collect();
          }),
          child: const TrText('刷新'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const TrText('完成'),
        ),
      ],
    );
  }

  Widget _body(BuildContext context, AudioDeviceReport? report) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final TextStyle labelStyle =
        theme.textTheme.bodyMedium?.copyWith(color: apple.label) ??
        const TextStyle();
    final TextStyle valueStyle =
        theme.textTheme.bodySmall?.copyWith(color: apple.secondaryLabel) ??
        const TextStyle();
    final List<Widget> children = <Widget>[];
    if (report == null) {
      children.add(Text(context.tr('读取音频设备失败。'), style: valueStyle));
    } else {
      for (final AudioSessionAttribute attribute in report.attributes) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(
                  width: 84,
                  child: Text(context.tr(attribute.label), style: valueStyle),
                ),
                Expanded(child: Text(attribute.value, style: valueStyle)),
              ],
            ),
          ),
        );
      }
      if (report.error != null) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              context.tr('读取失败：${report.error}'),
              style: valueStyle.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        );
      }
      if (report.outputs.isEmpty) {
        if (report.error == null) {
          children.add(
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                context.tr('当前平台不支持读取音频设备（仅 Android 与 iOS 支持）。'),
                style: valueStyle,
              ),
            ),
          );
        }
      } else {
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 6),
            child: Text(
              context.tr('可用输出设备（${report.outputs.length}）'),
              style: labelStyle,
            ),
          ),
        );
        for (final AudioDeviceInfo device in report.outputs) {
          children.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(device.name, style: labelStyle),
                  const SizedBox(height: 1),
                  Text(context.tr(device.typeLabel), style: valueStyle),
                  Text(
                    context.tr('ID：${device.id}'),
                    style: valueStyle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          );
        }
      }
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 360),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );
  }
}

class _LegacySliderRow extends StatelessWidget {
  const _LegacySliderRow({
    super.key,
    required this.label,
    required this.valueText,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.subtitle,
    this.divisions,
    this.action,
  });

  final String label;
  final String valueText;
  final String? subtitle;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double>? onChanged;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return TvFocusHighlight(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: apple.separator, width: .5)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 13, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    context.tr(label),
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: apple.label,
                    ),
                  ),
                ),
                if (action != null) ...<Widget>[
                  action!,
                  const SizedBox(width: 4),
                ],
                Text(
                  context.tr(valueText),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: apple.secondaryLabel,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ],
            ),
            if (subtitle != null) ...<Widget>[
              const SizedBox(height: 2),
              Text(
                context.tr(subtitle!),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: apple.secondaryLabel,
                ),
              ),
            ],
            AccessibleSlider(
              semanticLabel: label,
              label: valueText,
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              detentFeedback: onChanged != null,
              onChanged: onChanged,
            ),
          ],
        ),
      ),
    );
  }
}

class _LegacyChoiceRow extends StatelessWidget {
  const _LegacyChoiceRow({
    required this.label,
    required this.valueText,
    required this.choices,
    required this.selected,
    required this.labelOf,
    required this.onSelected,
  });

  final String label;
  final String valueText;
  final List<int> choices;
  final int selected;
  final String Function(int value) labelOf;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return TvFocusHighlight(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: apple.separator, width: .5)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 13, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    context.tr(label),
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: apple.label,
                    ),
                  ),
                ),
                Text(
                  context.tr(valueText),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: apple.secondaryLabel,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final int choice in choices)
                  ChoiceChip(
                    label: Text(
                      context.tr(labelOf(choice)),
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.values[choice ~/ 100 - 1],
                        color: selected == choice ? apple.accent : apple.label,
                      ),
                    ),
                    showCheckmark: false,
                    selected: selected == choice,
                    selectedColor: apple.accentSoft,
                    backgroundColor: apple.fill,
                    side: BorderSide.none,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    onSelected: (_) => onSelected(choice),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// `#RRGGBB` label shown beside the custom accent swatch.
String _accentHex(Color color) =>
    '#${((color.toARGB32() & 0xFFFFFF).toRadixString(16)).padLeft(6, '0').toUpperCase()}';

/// Opens the custom-accent picker and persists the chosen colour.
Future<void> _pickLegacyAccent(BuildContext context, AppState state) async {
  final Color initial = state.legacyAccentColor ?? AppleColors.musicRed;
  final Color? picked = await showDialog<Color>(
    context: context,
    builder: (BuildContext context) => _LegacyAccentDialog(initial: initial),
  );
  if (picked != null) await state.setLegacyAccent(picked);
}

/// Picks a picture, stores a copy and switches the backdrop to it.
Future<void> _pickBackgroundImage(
  BuildContext context,
  AppState state, [
  Future<String?> Function()? picker,
]) async {
  String? stored;
  try {
    stored = await (picker ?? pickCustomBackgroundImage)();
  } catch (_) {
    // No picker on this platform, or the copy failed; leave the setting as is.
    return;
  }
  if (stored == null) return;
  final String? previous = state.legacyBackgroundImagePath;
  await state.setLegacyBackgroundImage(stored);
  await state.setLegacyBackground(LegacyBackgroundMode.customImage);
  if (previous != stored) await deleteCustomBackgroundImage(previous);
}

/// Opens the key recorder for [action] and persists the chosen combination.
Future<void> _editMediaShortcut(
  BuildContext context,
  AppState state,
  MediaShortcutAction action,
) async {
  final ShortcutSelection? selection = await showShortcutRecorderDialog(
    context,
    action: action,
    current: state.mediaShortcutFor(action),
    conflict: (MediaShortcutBinding binding) => mediaShortcutConflict(
      state.mediaShortcuts,
      action: action,
      binding: binding,
    ),
  );
  if (selection == null) return;
  if (selection.cleared) {
    await state.setMediaShortcut(action, null);
    return;
  }
  final MediaShortcutBinding? binding = selection.binding;
  if (binding == null) return;
  if (mediaShortcutConflict(
        state.mediaShortcuts,
        action: action,
        binding: binding,
      ) !=
      null) {
    return;
  }
  await state.setMediaShortcut(action, binding);
}

class _LegacyAccentSwatch extends StatelessWidget {
  const _LegacyAccentSwatch({
    super.key,
    required this.color,
    required this.onTap,
  });

  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return Semantics(
      button: true,
      label: context.tr('选择强调色'),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: TvTapTarget(
          onTap: onTap,
          borderRadius: BorderRadius.circular(15),
          focusScale: 1.12,
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: apple.separator, width: .75),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Hue/saturation/value picker for the custom accent.
class _LegacyAccentDialog extends StatefulWidget {
  const _LegacyAccentDialog({required this.initial});

  final Color initial;

  @override
  State<_LegacyAccentDialog> createState() => _LegacyAccentDialogState();
}

class _LegacyAccentDialogState extends State<_LegacyAccentDialog> {
  static const List<Color> _presets = <Color>[
    AppleColors.musicRed,
    AppleColors.systemPink,
    AppleColors.systemPurple,
    AppleColors.systemBlue,
    AppleColors.systemTeal,
    AppleColors.systemGreen,
    AppleColors.systemOrange,
    AppleColors.systemYellow,
  ];

  late HSVColor _hsv = HSVColor.fromColor(widget.initial);

  Color get _color => _hsv.toColor();

  void _selectPreset(Color color) =>
      setState(() => _hsv = HSVColor.fromColor(color));

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return AlertDialog(
      title: const TrText('自定义主题色'),
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                height: 54,
                decoration: BoxDecoration(
                  color: _color,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: apple.separator, width: .5),
                ),
              ),
              const SizedBox(height: 14),
              for (int row = 0; row < 2; row++) ...<Widget>[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    for (final Color preset in _presets.skip(row * 4).take(4))
                      _LegacyPresetSwatch(
                        color: preset,
                        selected: preset.toARGB32() == _color.toARGB32(),
                        onTap: () => _selectPreset(preset),
                      ),
                  ],
                ),
                if (row == 0) const SizedBox(height: 10),
              ],
              _LegacyGradientSlider(
                label: '色相',
                value: _hsv.hue,
                max: 360,
                colors: const <Color>[
                  Color(0xFFFF0000),
                  Color(0xFFFFFF00),
                  Color(0xFF00FF00),
                  Color(0xFF00FFFF),
                  Color(0xFF0000FF),
                  Color(0xFFFF00FF),
                  Color(0xFFFF0000),
                ],
                onChanged: (double value) =>
                    setState(() => _hsv = _hsv.withHue(value)),
              ),
              _LegacyGradientSlider(
                label: '饱和度',
                value: _hsv.saturation,
                colors: <Color>[
                  Colors.white,
                  HSVColor.fromAHSV(1, _hsv.hue, 1, 1).toColor(),
                ],
                onChanged: (double value) =>
                    setState(() => _hsv = _hsv.withSaturation(value)),
              ),
              _LegacyGradientSlider(
                label: '明度',
                value: _hsv.value,
                colors: <Color>[
                  Colors.black,
                  HSVColor.fromAHSV(1, _hsv.hue, _hsv.saturation, 1).toColor(),
                ],
                onChanged: (double value) =>
                    setState(() => _hsv = _hsv.withValue(value)),
              ),
              const SizedBox(height: 4),
              Text(
                _accentHex(_color),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: apple.secondaryLabel,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const TrText('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_color),
          child: const TrText('完成'),
        ),
      ],
    );
  }
}

class _LegacyPresetSwatch extends StatelessWidget {
  const _LegacyPresetSwatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final Color check =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : Colors.black;
    return Semantics(
      button: true,
      selected: selected,
      child: InkResponse(
        onTap: onTap,
        radius: 20,
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? apple.label : apple.separator,
              width: selected ? 2 : .5,
            ),
          ),
          child: selected
              ? Icon(Icons.check_rounded, size: 18, color: check)
              : null,
        ),
      ),
    );
  }
}

/// A slider painted over its own gradient track.
class _LegacyGradientSlider extends StatelessWidget {
  const _LegacyGradientSlider({
    required this.label,
    required this.value,
    required this.colors,
    required this.onChanged,
    this.max = 1,
  });

  final String label;
  final double value;
  final double max;
  final List<Color> colors;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            context.tr(label),
            style: theme.textTheme.labelMedium?.copyWith(
              color: apple.secondaryLabel,
            ),
          ),
          SizedBox(
            height: 40,
            child: Stack(
              alignment: Alignment.center,
              children: <Widget>[
                Positioned(
                  left: 0,
                  right: 0,
                  child: Container(
                    height: 14,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: colors),
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(color: apple.separator, width: .5),
                    ),
                  ),
                ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 14,
                    activeTrackColor: Colors.transparent,
                    inactiveTrackColor: Colors.transparent,
                    secondaryActiveTrackColor: Colors.transparent,
                    thumbColor: Colors.white,
                    overlayColor: Colors.white.withValues(alpha: .18),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 18,
                    ),
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 9,
                      elevation: 2,
                    ),
                    tickMarkShape: SliderTickMarkShape.noTickMark,
                  ),
                  child: Slider(
                    value: value.clamp(0, max),
                    min: 0,
                    max: max,
                    onChanged: onChanged,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Responsive playlist grid shared by Library and Search. It opts into more
/// columns on desktop and two on phones, matching Music's density.
class LegacyPlaylistGrid extends StatelessWidget {
  const LegacyPlaylistGrid({
    super.key,
    required this.playlists,
    required this.onOpen,
  });

  final List<Playlist> playlists;
  final ValueChanged<Playlist> onOpen;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        final int columns = switch (width) {
          >= 1100 => 6,
          >= 860 => 5,
          >= 660 => 4,
          >= 430 => 3,
          _ => 2,
        };
        const double gap = 18;
        final double cell = ((width - gap * (columns - 1)) / columns).clamp(
          112.0,
          180.0,
        );
        return Wrap(
          spacing: gap,
          runSpacing: 24,
          children: <Widget>[
            for (final Playlist playlist in playlists)
              LegacyPlaylistCard(
                playlist: playlist,
                width: cell,
                onTap: () => onOpen(playlist),
              ),
          ],
        );
      },
    );
  }
}

List<Playlist> _uniquePlaylists(List<Playlist> input) {
  final Set<String> seen = <String>{};
  return <Playlist>[
    for (final Playlist playlist in input)
      if (seen.add(playlist.id)) playlist,
  ];
}
