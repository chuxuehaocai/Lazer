import 'dart:async';

import 'package:flutter/material.dart';

import '../data/catalog.dart';
import '../data/models.dart';
import '../downloads/download_dialog.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../state/detail_requests.dart';
import '../theme/apple_design.dart';
import '../tv/tv_mode.dart';
import '../widgets/apple_ui.dart';
import '../widgets/catalog_links.dart';
import 'legacy_widgets.dart';
import 'legacy_playlist_grid.dart';

export 'legacy_playlist_grid.dart' show LegacyPlaylistGrid;

/// Search page reached from the rail (desktop) or the 搜索 tab (phones).
///
/// The field lives here rather than in the toolbar, so the page owns the
/// query and the results. Switching pages disposes it, which is
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
  void didUpdateWidget(covariant LegacySearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      _generation++;
      _loading = false;
      if (_query.isNotEmpty) unawaited(_run(_query));
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    // The field must not search while the user is still typing. Only Enter
    // (or the IME search action) commits the query; clearing the text resets
    // the page immediately.
    if (value.trim().isNotEmpty) return;
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
    if (query.isNotEmpty && _loading && query == _query) return;
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
    final double inset = legacyPageInset(context);
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
            _SearchTab.songs => ListView.builder(
              padding: EdgeInsets.fromLTRB(inset, 0, inset, 28),
              itemCount: results.tracks.length,
              itemBuilder: (BuildContext context, int i) {
                final Track track = results.tracks[i];
                return LegacyTrackRow(
                  track: track,
                  index: i,
                  current: widget.state.current?.id == track.id,
                  playing: widget.state.playing,
                  onTap: () =>
                      widget.state.playQueue(results.tracks, startIndex: i),
                  onMenuRequested: (Offset position) =>
                      showTrackActions(context, widget.state, track, position),
                );
              },
            ),
            _SearchTab.albums => ListView.builder(
              padding: EdgeInsets.fromLTRB(inset, 0, inset, 28),
              itemCount: results.albums.length,
              itemBuilder: (BuildContext context, int i) {
                final Album album = results.albums[i];
                return AppleListTile(
                  title: album.title,
                  subtitle: album.artist,
                  minHeight: 56,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  leading: LegacyCover(
                    url: album.coverUrl,
                    size: 44,
                    radius: 6,
                  ),
                  onTap: () =>
                      unawaited(openAlbumDetails(context, widget.state, album)),
                );
              },
            ),
            _SearchTab.artists => ListView.builder(
              padding: EdgeInsets.fromLTRB(inset, 0, inset, 28),
              itemCount: results.artists.length,
              itemBuilder: (BuildContext context, int i) {
                final ArtistRef artist = results.artists[i];
                return AppleListTile(
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
                );
              },
            ),
            _SearchTab.playlists => LayoutBuilder(
              builder: (BuildContext context, BoxConstraints box) {
                final LegacyPlaylistGridLayout grid = LegacyPlaylistGridLayout(
                  (box.maxWidth - inset * 2).clamp(0, double.infinity),
                );
                return CustomScrollView(
                  slivers: <Widget>[
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(inset, 0, inset, 28),
                      sliver: LegacyPlaylistRowsSliver(
                        playlists: results.playlists,
                        layout: grid,
                        onOpen: widget.onOpenPlaylist,
                      ),
                    ),
                  ],
                );
              },
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
