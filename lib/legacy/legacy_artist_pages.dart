import 'dart:async';

import 'package:flutter/material.dart';

import '../data/catalog_details.dart';
import '../data/models.dart';
import '../downloads/download_dialog.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../theme/apple_design.dart';
import '../widgets/apple_ui.dart';
import '../widgets/app_scroll_behavior.dart';
import '../widgets/catalog_links.dart';
import '../widgets/interaction_feedback.dart';
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
    if (oldWidget.artist.id != widget.artist.id ||
        oldWidget.state != widget.state) {
      _details = null;
      unawaited(_load());
    }
  }

  Future<void> _load({bool force = false}) async {
    final int generation = ++_generation;
    final artist = widget.artist;
    final catalog = widget.state.catalog;
    setState(() {
      _loading = true;
      _error = null;
      _albums.clear();
    });
    try {
      final ArtistDetails details = await catalog.artistDetails(
        artist,
        force: force,
      );
      if (!mounted || generation != _generation) return;
      setState(() => _details = details);
      var offset = 0;
      var more = true;
      final Set<String> ids = <String>{};
      while (more) {
        final ArtistAlbumPage page = await catalog.artistAlbumPage(
          artist.id,
          offset: offset,
          force: force,
        );
        if (!mounted || generation != _generation) return;
        final added = page.albums.where((album) => ids.add(album.id)).toList();
        if (added.isNotEmpty) {
          setState(() => _albums.addAll(added));
        }
        offset += page.receivedCount;
        more = page.more && page.receivedCount > 0;
      }
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
    final double inset = legacyPageInset(context);
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
              if (_error != null) ...<Widget>[
                const SizedBox(height: 20),
                LegacyNotice(
                  message: _error!,
                  action: FilledButton(
                    onPressed: () => unawaited(_load(force: true)),
                    child: const TrText('重试'),
                  ),
                ),
              ],
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
                            child: LegacyArtistTrackCard(
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
                  subtitle:
                      '${fullAlbums.length} 张全长专辑${_loading ? '（加载中）' : ''}',
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
                  subtitle: '${singles.length} 张${_loading ? '（加载中）' : ''}',
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
  bool _loading = false;
  int _requestSerial = 0;

  String get _title => widget.group == AlbumReleaseGroup.album
      ? '全部专辑' // i18n:key
      : '全部单曲 / EP'; // i18n:key

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant LegacyArtistReleasesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artist.id != widget.artist.id ||
        oldWidget.group != widget.group ||
        oldWidget.state != widget.state) {
      _albums = null;
      unawaited(_load());
    }
  }

  Future<void> _load({bool force = false}) async {
    final int serial = ++_requestSerial;
    final int artistId = widget.artist.id;
    final AlbumReleaseGroup group = widget.group;
    setState(() {
      _error = null;
      _loading = true;
      if (force) _albums = null;
    });
    try {
      var offset = 0;
      var more = true;
      final List<Album> releases = <Album>[];
      final Set<String> ids = <String>{};
      while (more) {
        final ArtistAlbumPage page = await widget.state.catalog.artistAlbumPage(
          artistId,
          offset: offset,
          force: force,
        );
        if (!mounted || serial != _requestSerial) return;
        for (final Album album in page.albums) {
          final bool matches = group == AlbumReleaseGroup.album
              ? album.releaseGroup == AlbumReleaseGroup.album
              : album.releaseGroup != AlbumReleaseGroup.album;
          if (matches && ids.add(album.id)) releases.add(album);
        }
        offset += page.receivedCount;
        more = page.more && page.receivedCount > 0;
        if (releases.isNotEmpty || !more) {
          setState(() => _albums = List<Album>.of(releases));
        }
      }
    } catch (_) {
      if (mounted && serial == _requestSerial) {
        setState(
          () => _error = '发行作品加载失败，请重试。', // i18n:key
        );
      }
    } finally {
      if (mounted && serial == _requestSerial) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<Album>? albums = _albums;
    final double inset = legacyPageInset(context);
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
                      : '${widget.artist.name} · ${albums.length} 张${_loading ? '（加载中）' : ''}',
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
              ),
            if (albums == null && _error == null)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (albums != null && albums.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: LegacyNotice(
                  message: widget.group == AlbumReleaseGroup.album
                      ? '暂无专辑'
                      : '暂无单曲 / EP',
                ),
              )
            else if (albums != null && albums.isNotEmpty)
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
  int _requestSerial = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant LegacyArtistSongsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artist.id != widget.artist.id ||
        oldWidget.state != widget.state) {
      _tracks = null;
      unawaited(_load());
    }
  }

  Future<void> _load({bool force = false}) async {
    final int serial = ++_requestSerial;
    final artist = widget.artist;
    final catalog = widget.state.catalog;
    setState(() => _error = null);
    try {
      final tracks = await catalog.artistSongs(artist.id, force: force);
      if (mounted && serial == _requestSerial) {
        setState(() => _tracks = tracks);
      }
    } catch (_) {
      if (!mounted || serial != _requestSerial) return;
      try {
        final fallback = await catalog.artistDetails(artist);
        if (!mounted || serial != _requestSerial) return;
        if (fallback.tracks.isNotEmpty) {
          setState(() => _tracks = fallback.tracks);
          return;
        }
      } catch (_) {}
      if (mounted && serial == _requestSerial) {
        setState(
          () => _error = '全部歌曲加载失败，请重试。', // i18n:key
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<Track>? tracks = _tracks;
    final double inset = legacyPageInset(context);
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
