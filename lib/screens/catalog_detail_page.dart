import 'dart:async';

import 'package:flutter/material.dart';

import '../data/catalog_details.dart';
import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../theme/app_palette.dart';
import '../theme/paper_widgets.dart';
import '../widgets/accessible_controls.dart';
import '../widgets/catalog_links.dart';
import '../widgets/interaction_feedback.dart';
import '../widgets/plate_art.dart';
import '../player/now_playing_route.dart';
import '../widgets/player_controls_bar.dart';

class CatalogDetailPage extends StatefulWidget {
  const CatalogDetailPage.artist({
    super.key,
    required this.state,
    required ArtistRef this.artist,
  }) : album = null;
  const CatalogDetailPage.album({
    super.key,
    required this.state,
    required Album this.album,
  }) : artist = null;
  final AppState state;
  final ArtistRef? artist;
  final Album? album;
  String get identity =>
      artist == null ? 'album:${album!.id}' : 'artist:${artist!.key}';
  @override
  State<CatalogDetailPage> createState() => _CatalogDetailPageState();
}

class _CatalogDetailPageState extends State<CatalogDetailPage> {
  ArtistDetails? _artist;
  AlbumDetails? _album;
  final _albums = <Album>[];
  final _scroll = ScrollController();
  bool _loading = true,
      _albumsLoading = false,
      _moreAlbums = false,
      _showAlbums = false,
      _expanded = false;
  String? _error, _albumsError;
  int _generation = 0, _albumOffset = 0;
  bool get _isArtist => widget.artist != null;
  List<Track> get _tracks =>
      _isArtist ? _artist?.tracks ?? const [] : _album?.tracks ?? const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant CatalogDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity != widget.identity ||
        oldWidget.state != widget.state) {
      _artist = null;
      _album = null;
      _albums.clear();
      _showAlbums = false;
      _expanded = false;
      unawaited(_load());
    }
  }

  Future<void> _load({bool force = false}) async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    if (_isArtist) {
      unawaited(_loadAlbums(generation, reset: true, force: force));
    }
    try {
      if (_isArtist) {
        final data = await widget.state.catalog.artistDetails(
          widget.artist!,
          force: force,
        );
        if (mounted && generation == _generation) {
          setState(() => _artist = data);
        }
      } else {
        final data = await widget.state.catalog.albumDetailsFor(
          widget.album!.id,
          force: force,
        );
        if (mounted && generation == _generation) setState(() => _album = data);
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(
          () => _error = _isArtist ? '歌手资料加载失败，请重试。' : '专辑资料加载失败，请重试。',
        ); // i18n:key
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _loadAlbums(
    int generation, {
    bool reset = false,
    bool force = false,
  }) async {
    if (!reset && _albumsLoading) return;
    setState(() {
      _albumsLoading = true;
      _albumsError = null;
    });
    try {
      final page = await widget.state.catalog.artistAlbumPageFor(
        widget.artist!,
        offset: reset ? 0 : _albumOffset,
        force: force,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        if (reset) _albums.clear();
        final ids = _albums.map((album) => album.id).toSet();
        _albums.addAll(page.albums.where((album) => ids.add(album.id)));
        _albumOffset = (reset ? 0 : _albumOffset) + page.receivedCount;
        _moreAlbums = page.more;
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _albumsError = '专辑加载失败，请重试。'); // i18n:key
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _albumsLoading = false);
      }
    }
  }

  Widget _header(BuildContext context, bool narrow) {
    final artist = _artist?.artist ?? widget.artist;
    final album = _album?.album ?? widget.album;
    final title = _isArtist ? artist!.name : album!.title;
    final description = _isArtist
        ? _artist?.description ?? ''
        : _album?.description ?? '';
    final side = narrow ? 152.0 : 216.0;
    final artUrl = _isArtist ? artist?.coverUrl : album?.coverUrl;
    final image = SizedBox.square(
      dimension: side,
      child: artUrl == null && _isArtist
          ? ColoredBox(
              color: context.colors.oatWarm,
              child: Icon(
                Icons.person_outline_rounded,
                size: 64,
                color: context.colors.cloudDark,
              ),
            )
          : PlateArt(
              seed: _isArtist ? artist!.id : album!.coverSeed,
              coverUrl: artUrl,
              size: side,
            ),
    );
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        InlineLabel(_isArtist ? '歌手' : '专辑'),
        const SizedBox(height: 12),
        Text(
          title,
          style: context.type.heading.copyWith(
            fontSize: narrow ? 30 : 40,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 12),
        if (!_isArtist)
          ArtistNameLink(
            state: widget.state,
            artists: album!.artists,
            fallback: album.artist,
            style: context.type.bodyMuted,
          ),
        if (_isArtist && (_artist?.musicCount ?? 0) > 0)
          TrText(
            '${_artist!.musicCount} 首歌曲 · ${_artist!.albumCount} 张专辑',
            style: context.type.bodySmMuted,
          ),
        if (!_isArtist) ...[
          const SizedBox(height: 8),
          Text(
            [
              if ((_album?.publishTime ?? 0) > 0)
                MaterialLocalizations.of(context).formatFullDate(
                  DateTime.fromMillisecondsSinceEpoch(_album!.publishTime!),
                )
              else if (album!.year.isNotEmpty)
                album.year,
              if (_album?.company.isNotEmpty ?? false) _album!.company,
            ].join(' · '),
            style: context.type.captionMuted,
          ),
          const SizedBox(height: 8),
          TrText(
            '${_tracks.isEmpty ? album!.trackCount ?? 0 : _tracks.length} 首曲目',
            style: context.type.bodySmMuted,
          ),
        ],
        const SizedBox(height: 20),
        AnimatedBuilder(
          animation: widget.state,
          builder: (context, _) => FilledButton.icon(
            style: FilledButton.styleFrom(
              shape: const RoundedRectangleBorder(),
              minimumSize: const Size(0, 48),
              backgroundColor: context.colors.clay,
              foregroundColor: Colors.white,
            ),
            onPressed: _tracks.isEmpty
                ? null
                : feedbackAction(
                    context,
                    () => widget.state.playQueue(_tracks),
                  ),
            icon: const Icon(Icons.play_arrow_rounded),
            label: TrText(_isArtist ? '播放热门歌曲' : '播放全部'),
          ),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (narrow) ...[
            image,
            const SizedBox(height: 24),
            details,
          ] else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                image,
                const SizedBox(width: 32),
                Expanded(child: details),
              ],
            ),
          const SizedBox(height: 28),
          const SectionHeading('介绍'),
          const SizedBox(height: 12),
          AnimatedSize(
            duration: const Duration(milliseconds: 240),
            alignment: Alignment.topLeft,
            child: description.isEmpty
                ? TrText(
                    _loading ? '正在加载资料…' : '暂无介绍',
                    style: context.type.bodySmMuted,
                  )
                : Text(
                    description,
                    maxLines: _expanded ? null : 4,
                    overflow: _expanded
                        ? TextOverflow.visible
                        : TextOverflow.ellipsis,
                    style: context.type.bodySm.copyWith(height: 1.7),
                  ),
          ),
          if (description.length > 120)
            TextButton(
              onPressed: () => setState(() => _expanded = !_expanded),
              child: TrText(_expanded ? '收起介绍' : '展开介绍'),
            ),
        ],
      ),
    );
  }

  Widget _message(String text, {VoidCallback? retry}) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TrText(text, style: context.type.bodySmMuted),
        if (retry != null)
          TextButton(onPressed: retry, child: const TrText('重试')),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: TrText(_isArtist ? '歌手详情' : '专辑详情'),
      actions: [
        AccessibleIconButton(
          tooltip: '刷新',
          onPressed: _loading || _albumsLoading
              ? null
              : () => unawaited(_load(force: true)),
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
    ),
    body: Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) => CustomScrollView(
              controller: _scroll,
              slivers: [
                SliverToBoxAdapter(child: _header(context, box.maxWidth < 640)),
                if (_isArtist)
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: _DetailTabs(
                      showAlbums: _showAlbums,
                      onChanged: (value) => setState(() => _showAlbums = value),
                      background: context.colors.ivoryMedium,
                    ),
                  ),
                if (!_isArtist || !_showAlbums) ...[
                  if (!_isArtist)
                    const SliverPadding(
                      padding: EdgeInsets.fromLTRB(24, 4, 24, 12),
                      sliver: SliverToBoxAdapter(child: SectionHeading('曲目')),
                    ),
                  if (_loading && _tracks.isEmpty)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.all(40),
                        child: Center(
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ),
                  if (_error != null)
                    SliverToBoxAdapter(
                      child: _message(
                        _error!,
                        retry: () => unawaited(_load(force: true)),
                      ),
                    ),
                  if (!_loading && _error == null && _tracks.isEmpty)
                    SliverToBoxAdapter(child: _message('暂无歌曲')),
                  SliverList.builder(
                    itemCount: _tracks.length,
                    itemBuilder: (context, index) => AnimatedBuilder(
                      animation: widget.state,
                      builder: (context, _) => TrackRow(
                        state: widget.state,
                        track: _tracks[index],
                        index: index + 1,
                        isCurrent:
                            widget.state.current?.id == _tracks[index].id,
                        onPlay: () =>
                            widget.state.playQueue(_tracks, startIndex: index),
                      ),
                    ),
                  ),
                ] else ...[
                  SliverPadding(
                    padding: const EdgeInsets.all(24),
                    sliver: SliverGrid.builder(
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 240,
                            crossAxisSpacing: 20,
                            mainAxisSpacing: 24,
                            childAspectRatio: .74,
                          ),
                      itemCount: _albums.length,
                      itemBuilder: (context, index) {
                        final album = _albums[index];
                        return Material(
                          color: Colors.transparent,
                          child: InkWell(
                            borderRadius: BorderRadius.zero,
                            onTap: feedbackAction(
                              context,
                              () => unawaited(
                                openAlbumDetails(context, widget.state, album),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: AspectRatio(
                                    aspectRatio: 1,
                                    child: PlateArt(
                                      seed: album.coverSeed,
                                      coverUrl: album.coverUrl,
                                      size: 240,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  album.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: context.type.bodySm,
                                ),
                                Text(
                                  album.year,
                                  style: context.type.captionMuted,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  if (_albumsLoading)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ),
                  if (_albumsError != null)
                    SliverToBoxAdapter(
                      child: _message(
                        _albumsError!,
                        retry: () => unawaited(
                          _loadAlbums(
                            _generation,
                            reset: _albums.isEmpty,
                            force: true,
                          ),
                        ),
                      ),
                    ),
                  if (!_albumsLoading &&
                      _albumsError == null &&
                      _albums.isEmpty)
                    SliverToBoxAdapter(child: _message('暂无专辑')),
                  if (_moreAlbums && !_albumsLoading && _albumsError == null)
                    SliverToBoxAdapter(
                      child: Center(
                        child: TextButton(
                          onPressed: () => unawaited(_loadAlbums(_generation)),
                          child: const TrText('加载更多专辑'),
                        ),
                      ),
                    ),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: 40)),
              ],
            ),
          ),
        ),
        PlayerControlsBar(
          state: widget.state,
          includeBottomSafeArea: true,
          onExpand: () => unawaited(
            Navigator.of(context).push(NowPlayingRoute(state: widget.state)),
          ),
        ),
      ],
    ),
  );

  @override
  void dispose() {
    ++_generation;
    _scroll.dispose();
    super.dispose();
  }
}

class _DetailTabs extends SliverPersistentHeaderDelegate {
  _DetailTabs({
    required this.showAlbums,
    required this.onChanged,
    required this.background,
  });
  final bool showAlbums;
  final ValueChanged<bool> onChanged;
  final Color background;
  @override
  double get minExtent => 56;
  @override
  double get maxExtent => 56;
  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => SizedBox(
    height: maxExtent,
    child: ColoredBox(
      color: background,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final albums in [false, true])
            Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      width: 2,
                      color: showAlbums == albums
                          ? context.colors.slateDark
                          : Colors.transparent,
                    ),
                  ),
                ),
                child: TextButton(
                  onPressed: () => onChanged(albums),
                  child: TrText(
                    albums ? '专辑' : '热门歌曲',
                    style: context.type.bodySm.copyWith(
                      color: showAlbums == albums
                          ? context.colors.slateDark
                          : context.colors.cloudDark,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
  @override
  bool shouldRebuild(_DetailTabs oldDelegate) =>
      oldDelegate.showAlbums != showAlbums ||
      oldDelegate.background != background;
}
