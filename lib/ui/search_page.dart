import '../widgets/build_safe_state.dart';
import '../widgets/spring_buttons.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../data/catalog.dart';
import '../data/models.dart';
import '../downloads/download_dialog.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../state/detail_requests.dart';
import '../theme/apple_design.dart';
import '../widgets/apple_ui.dart';
import '../widgets/catalog_links.dart';
import 'widgets.dart';
import 'playlist_grid.dart';
import '../animation/view_transitions.dart';

export 'playlist_grid.dart' show AppPlaylistGrid;

/// Search page reached from the rail (desktop) or the 搜索 tab (phones).
///
/// The field lives here rather than in the toolbar, so the page owns the
/// query and the results. Switching pages disposes it, which is
/// also what resets the search.
class AppSearchPage extends StatefulWidget {
  const AppSearchPage({
    super.key,
    required this.state,
    required this.onOpenPlaylist,
    this.topInset = 0,
  });

  final AppState state;
  final ValueChanged<Playlist> onOpenPlaylist;
  final double topInset;

  @override
  State<AppSearchPage> createState() => _AppSearchPageState();
}

class _AppSearchPageState extends State<AppSearchPage>
    with BuildSafeState<AppSearchPage> {
  final TextEditingController _search = TextEditingController();
  SearchResults? _results;
  _SearchTab _tab = _SearchTab.songs;
  String _query = '';
  bool _loading = false;
  String? _error;
  int _generation = 0;
  late String _sourceKey;
  (String?, bool)? _playback;

  @override
  void initState() {
    super.initState();
    _sourceKey = widget.state.activeContentKey;
    widget.state.addListener(_stateChanged);
  }

  void _stateChanged() {
    if (!mounted) return;
    final state = widget.state;
    if (_sourceKey != state.activeContentKey) {
      _resetSource();
      return;
    }
    final playback = (state.current?.id, state.playing);
    if (_playback != playback) {
      _playback = playback;
      setState(() {});
    }
  }

  void _resetSource() {
    _sourceKey = widget.state.activeContentKey;
    _generation++;
    _loading = false;
    _results = null;
    _error = null;
    if (widget.state.isLocalPlayback) _tab = _SearchTab.songs;
    if (_query.isNotEmpty) {
      unawaited(_run(_query));
    } else {
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(covariant AppSearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_stateChanged);
      widget.state.addListener(_stateChanged);
      _resetSource();
    } else if (_sourceKey != widget.state.activeContentKey) {
      _resetSource();
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_stateChanged);
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

  /// Whether the field takes focus as the page opens.
  ///
  /// A phone or tablet answers a focused text field by raising its on-screen
  /// keyboard, which covers the results the listener came to look at before
  /// they have typed anything. Desktops keep the focus: with a physical
  /// keyboard in front of it, arriving in a ready-to-type field is a comfort
  /// rather than an interruption. The platform is read from the theme so a
  /// layout that forces a desktop or mobile shape keeps the matching input.
  bool get _autoFocusField {
    final TargetPlatform platform = Theme.of(context).platform;
    return platform != TargetPlatform.android && platform != TargetPlatform.iOS;
  }

  Future<void> _run(String query) async {
    if (query.isNotEmpty && _loading && query == _query) return;
    final int generation = ++_generation;
    final owner = widget.state;
    final source = owner.activeContentKey;
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
      final SearchResults results = await owner.search(query);
      if (!mounted ||
          generation != _generation ||
          widget.state != owner ||
          owner.activeContentKey != source) {
        return;
      }
      setState(() {
        _results = results;
        _loading = false;
        if (owner.isLocalPlayback) {
          _tab = _SearchTab.songs;
        } else if (_count(results, _tab) == 0) {
          _tab =
              _SearchTab.values
                  .where((tab) => _count(results, tab) > 0)
                  .firstOrNull ??
              _SearchTab.songs;
        }
      });
    } catch (_) {
      if (!mounted ||
          generation != _generation ||
          widget.state != owner ||
          owner.activeContentKey != source) {
        return;
      }
      setState(() {
        _loading = false;
        _error = widget.state.isLocalPlayback
            ? '本地音乐库暂时无法读取，请重试。'
            : '搜索失败，请检查网络后重试。';
      });
    }
  }

  int _count(SearchResults results, _SearchTab tab) => switch (tab) {
    _SearchTab.songs => results.tracks.length,
    _SearchTab.albums => results.albums.length,
    _SearchTab.artists => results.artists.length,
    _SearchTab.playlists => results.playlists.length,
  };

  @override
  Widget build(BuildContext context) {
    final double inset = pageInset(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1180),
        child: widget.topInset == 0
            ? _pageContent(inset)
            : NestedScrollView(
                // Collapse only the empty toolbar space; keep the search
                // controls available while the result list keeps scrolling.
                headerSliverBuilder: (context, innerBoxIsScrolled) => <Widget>[
                  SliverToBoxAdapter(child: SizedBox(height: widget.topInset)),
                ],
                body: _pageContent(inset),
              ),
      ),
    );
  }

  Widget _pageContent(double inset) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      Padding(
        padding: EdgeInsets.fromLTRB(inset, 14, inset, 12),
        child: AppleSearchField(
          hintText: widget.state.isLocalPlayback ? '搜索本地音乐' : null,
          controller: _search,
          autofocus: _autoFocusField,
          onChanged: _onChanged,
          onSubmitted: _submit,
          onClear: _clear,
        ),
      ),
      Expanded(child: _body(inset)),
    ],
  );

  Widget _body(double inset) {
    final double bottomInset = MediaQuery.paddingOf(context).bottom;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return AppNotice(
        message: _error!,
        icon: Icons.search_off_rounded,
        action: SpringFilledButton(
          onPressed: () => unawaited(_run(_query)),
          child: const TrText('重试'),
        ),
      );
    }
    final SearchResults? results = _results;
    if (_query.isEmpty) {
      return AppNotice(
        message: widget.state.isLocalPlayback ? '搜索本地歌曲、歌手或专辑。' : '搜索歌曲、歌手或歌单。',
        icon: Icons.search_rounded,
      );
    }
    if (results == null || results.hits == 0) {
      return const AppNotice(message: '没有找到相关结果。', icon: Icons.search_rounded);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (!widget.state.isLocalPlayback)
          Padding(
            padding: EdgeInsets.fromLTRB(inset, 0, inset, 10),
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              children: <Widget>[
                _SearchTabButton(
                  label: '歌曲',
                  active: _tab == _SearchTab.songs,
                  onTap: () => setState(() => _tab = _SearchTab.songs),
                ),
                _SearchTabButton(
                  label: '专辑',
                  active: _tab == _SearchTab.albums,
                  onTap: () => setState(() => _tab = _SearchTab.albums),
                ),
                _SearchTabButton(
                  label: '歌手',
                  active: _tab == _SearchTab.artists,
                  onTap: () => setState(() => _tab = _SearchTab.artists),
                ),
                _SearchTabButton(
                  label: '歌单',
                  active: _tab == _SearchTab.playlists,
                  onTap: () => setState(() => _tab = _SearchTab.playlists),
                ),
              ],
            ),
          ),
        Expanded(
          child: ViewTransitionSwitcher(
            child: KeyedSubtree(
              key: ValueKey(_tab),
              child: _count(results, _tab) == 0
                  ? const AppNotice(
                      message: '没有找到相关结果。',
                      icon: Icons.search_rounded,
                    )
                  : switch (_tab) {
                      _SearchTab.songs => ListView.builder(
                        primary: widget.topInset > 0 ? true : null,
                        padding: EdgeInsets.fromLTRB(
                          inset,
                          0,
                          inset,
                          28 + bottomInset,
                        ),
                        itemCount: results.tracks.length,
                        itemBuilder: (BuildContext context, int i) {
                          final Track track = results.tracks[i];
                          return AppTrackRow(
                            track: track,
                            index: i,
                            current: widget.state.current?.id == track.id,
                            playing: widget.state.playing,
                            onTap: () => widget.state.playQueue(
                              results.tracks,
                              startIndex: i,
                            ),
                            onMenuRequested: (Offset position) =>
                                showTrackActions(
                                  context,
                                  widget.state,
                                  track,
                                  position,
                                ),
                          );
                        },
                      ),
                      _SearchTab.albums => ListView.builder(
                        primary: widget.topInset > 0 ? true : null,
                        padding: EdgeInsets.fromLTRB(
                          inset,
                          0,
                          inset,
                          28 + bottomInset,
                        ),
                        itemCount: results.albums.length,
                        itemBuilder: (BuildContext context, int i) {
                          final Album album = results.albums[i];
                          return AppleListTile(
                            title: album.title,
                            subtitle: album.artist,
                            minHeight: 56,
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            leading: AppCover(
                              url: album.coverUrl,
                              size: 44,
                              radius: 6,
                            ),
                            onTap: () => unawaited(
                              openAlbumDetails(context, widget.state, album),
                            ),
                          );
                        },
                      ),
                      _SearchTab.artists => ListView.builder(
                        primary: widget.topInset > 0 ? true : null,
                        padding: EdgeInsets.fromLTRB(
                          inset,
                          0,
                          inset,
                          28 + bottomInset,
                        ),
                        itemCount: results.artists.length,
                        itemBuilder: (BuildContext context, int i) {
                          final ArtistRef artist = results.artists[i];
                          return AppleListTile(
                            title: artist.name,
                            subtitle: context.tr('歌手'),
                            minHeight: 56,
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            leading: ClipOval(
                              child: AppCover(
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
                          final AppPlaylistGridLayout grid =
                              AppPlaylistGridLayout(
                                (box.maxWidth - inset * 2).clamp(
                                  0,
                                  double.infinity,
                                ),
                              );
                          return CustomScrollView(
                            primary: widget.topInset > 0 ? true : null,
                            slivers: <Widget>[
                              SliverPadding(
                                padding: EdgeInsets.fromLTRB(
                                  inset,
                                  0,
                                  inset,
                                  28 + bottomInset,
                                ),
                                sliver: AppPlaylistRowsSliver(
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
          ),
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
      selected: active,
      child: SpringTextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          backgroundColor: active ? apple.label.withValues(alpha: .1) : null,
          foregroundColor: active ? apple.label : apple.secondaryLabel,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          minimumSize: const Size(44, 44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: Text(
          context.tr(label),
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: active ? apple.label : apple.secondaryLabel,
            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
