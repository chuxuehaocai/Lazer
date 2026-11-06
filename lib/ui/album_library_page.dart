import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/catalog_details.dart';
import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../theme/apple_design.dart';
import '../theme/font_preferences.dart';
import '../widgets/apple_ui.dart';
import '../widgets/build_safe_state.dart';
import '../widgets/catalog_links.dart';
import '../widgets/cover_transition.dart';
import '../widgets/interaction_feedback.dart';
import '../widgets/spring_buttons.dart';
import '../widgets/ui_scaling.dart';
import 'login.dart';
import 'widgets.dart';

/// 收藏的专辑: the albums the signed-in account saved, in one place.
///
/// The library answers "what did I collect?" with playlists; this page answers
/// the other half — "which album do I feel like hearing?" — with covers, a
/// count and a filter.
class AppSavedAlbumsPage extends StatefulWidget {
  const AppSavedAlbumsPage({super.key, required this.state});

  final AppState state;

  @override
  State<AppSavedAlbumsPage> createState() => _AppSavedAlbumsPageState();
}

class _AppSavedAlbumsPageState extends State<AppSavedAlbumsPage>
    with BuildSafeState<AppSavedAlbumsPage> {
  /// How many further pages a filter may read on its own.
  ///
  /// Walking a whole collection to answer a query is what the service reads as
  /// a burst: one request per page, from a single keystroke. The walk stops at
  /// this many pages and says so, instead of quietly asking for all of them.
  static const int _filterPageBudget = 8;

  final TextEditingController _search = TextEditingController();
  final ScrollController _scroll = ScrollController();

  /// One cover key per album: a key made inside `itemBuilder` would remount
  /// the cover — and re-register its flight source — on every rebuild.
  final Map<String, GlobalKey> _coverKeys = <String, GlobalKey>{};

  final List<Album> _albums = <Album>[];
  final Set<String> _ids = <String>{};

  /// Where the next page starts. Kept beside the list because deduplication
  /// can make `_albums.length` lag behind the service's own offset.
  int _offset = 0;

  /// The whole collection, when the service reports it. The header shows this
  /// rather than the loaded count, which would creep up as the pages arrive.
  int? _total;

  /// The account the list is for. A session change reloads: another account's
  /// albums must never be shown as if they were the new one's.
  int _loadedUid = -1;

  /// Pages the current filter has already walked past its first page.
  int _filterPages = 0;

  /// Whether the filter stopped because of [_filterPageBudget].
  bool _filterTruncated = false;

  bool _loading = false;
  bool _more = false;
  String? _error;
  String _query = '';

  /// Invalidates in-flight loads when the page is disposed or reloaded.
  int _serial = 0;

  /// The account whose collection this page may read, or 0 when nobody is
  /// signed in. A session with no user id cannot own a collection.
  int get _uid {
    final AppState state = widget.state;
    return state.isGuest ? 0 : state.user.userId;
  }

  bool get _signedIn => _uid > 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    widget.state.addListener(_onSessionChanged);
    unawaited(_load(reset: true));
  }

  @override
  void dispose() {
    ++_serial;
    widget.state.removeListener(_onSessionChanged);
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  /// Signing in, signing out or signing in as somebody else hands this page a
  /// different collection. [AppState] notifies constantly during playback, so
  /// this only compares the owner and leaves the list alone otherwise.
  void _onSessionChanged() {
    if (!mounted || _loading) return;
    final int uid = _uid;
    if (uid <= 0 || uid == _loadedUid) return;
    unawaited(_load(reset: true));
  }

  /// Loads one page. [reset] starts the collection over at offset zero.
  Future<void> _load({required bool reset, bool force = false}) async {
    if (!mounted || _loading) return;
    final AppState state = widget.state;
    final int uid = _uid;
    if (uid <= 0) {
      setState(() {
        _albums.clear();
        _ids.clear();
        _offset = 0;
        _total = null;
        _more = false;
        _error = null;
        _loadedUid = -1;
      });
      return;
    }
    final int serial = ++_serial;
    setState(() {
      _loading = true;
      _error = null;
      _loadedUid = uid;
      if (reset) {
        _albums.clear();
        _ids.clear();
        _offset = 0;
        _total = null;
        _more = false;
        _filterPages = 0;
        _filterTruncated = false;
      }
    });
    try {
      final AlbumPage page = await state.catalog.savedAlbums(
        uid,
        offset: reset ? 0 : _offset,
        force: force,
      );
      if (!mounted || serial != _serial) return;
      setState(() {
        for (final Album album in page.albums) {
          if (_ids.add(album.id)) _albums.add(album);
        }
        _offset += page.receivedCount;
        _total = page.total ?? _total;
        // A page that answered with nothing must not be read again: `hasMore`
        // alone would loop forever on a service that keeps saying "more".
        _more = page.more && page.receivedCount > 0;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || serial != _serial) return;
      setState(() {
        _error = '收藏的专辑加载失败，请重试。'; // i18n:key
        _more = false;
        _loading = false;
      });
      return;
    }
    _walkFilter(force: force);
  }

  /// Continues a filter through the pages it has not read yet.
  ///
  /// Only while nothing matches: as soon as the query turns something up, the
  /// list is useful and the walk stops. [AppState] rebuilds this page often,
  /// so the walk is driven by completed reads rather than by every frame.
  void _walkFilter({required bool force}) {
    if (!mounted || !_more || _query.trim().isEmpty) return;
    if (_shown.isNotEmpty) return;
    if (_filterPages >= _filterPageBudget) {
      setState(() => _filterTruncated = true);
      return;
    }
    _filterPages++;
    unawaited(_load(reset: false, force: force));
  }

  void _onScroll() {
    if (!_scroll.hasClients || _loading || !_more) return;
    // The filter path walks its own pages; scrolling would race it.
    if (_query.trim().isNotEmpty) return;
    if (_scroll.position.extentAfter > 800) return;
    unawaited(_load(reset: false));
  }

  Future<void> _signIn() async {
    await showAppLoginDialog(context, widget.state);
    if (!mounted || !_signedIn) return;
    await _load(reset: true, force: true);
  }

  void _onQueryChanged(String value) {
    setState(() {
      _query = value;
      _filterPages = 0;
      _filterTruncated = false;
    });
    // The first keystroke asks for the rest of the collection: a filter that
    // only sees the pages already on screen would quietly miss albums.
    if (value.trim().isNotEmpty && _more && !_loading) {
      unawaited(_load(reset: false));
    }
  }

  /// What the grid shows: the whole collection, or the part matching [_query].
  List<Album> get _shown {
    final String query = _query.trim().toLowerCase();
    if (query.isEmpty) return _albums;
    return <Album>[
      for (final Album album in _albums)
        if (album.title.toLowerCase().contains(query) ||
            album.artist.toLowerCase().contains(query))
          album,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final bool guest = !_signedIn;
    final List<Album> shown = _shown;
    final double inset = pageInset(context);
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: adaptiveContentMaxWidth(context, 1180),
        ),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final double width = math.max(0, constraints.maxWidth - inset * 2);
            const double gap = 18;
            final int columns = _albumColumns(width);
            final double cell = _albumCell(width, columns, gap);
            // The caption block grows with the text scale; the extent has to
            // follow it or a large type setting clips the artist name.
            final double caption =
                8 + MediaQuery.textScalerOf(context).scale(40);
            return CustomScrollView(
              controller: _scroll,
              slivers: <Widget>[
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(inset, 8, inset, 0),
                  sliver: SliverList.list(
                    children: <Widget>[
                      ApplePageTitle(
                        title: '收藏的专辑',
                        subtitle: guest ? '登录后同步收藏的专辑' : _subtitle(shown),
                        // Refresh stays reachable with an empty collection too:
                        // a newly saved album is one press away instead of one
                        // cache lifetime away.
                        trailing: guest
                            ? null
                            : IconButton(
                                tooltip: context.tr('刷新'),
                                onPressed: _loading
                                    ? null
                                    : () => unawaited(
                                        _load(reset: true, force: true),
                                      ),
                                icon: const Icon(Icons.sync_rounded, size: 19),
                              ),
                        padding: const EdgeInsets.fromLTRB(0, 12, 0, 18),
                      ),
                      if (!guest) ...<Widget>[
                        AppleSearchField(
                          controller: _search,
                          hintText: '搜索收藏的专辑',
                          height: 46,
                          onChanged: _onQueryChanged,
                          onClear: () {
                            _search.clear();
                            _onQueryChanged('');
                          },
                        ),
                        // Breathing room under the field: the covers used to
                        // start on its bottom edge and read as a continuation
                        // of the field rather than as their own shelf.
                        const SizedBox(height: 24),
                      ],
                    ],
                  ),
                ),
                ..._body(
                  guest: guest,
                  shown: shown,
                  columns: columns,
                  cell: cell,
                  caption: caption,
                  gap: gap,
                  inset: inset,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// The header count: the whole collection while browsing, the matches while
  /// a filter is narrowing it.
  String _subtitle(List<Album> shown) => _query.trim().isEmpty
      ? '${_total ?? _albums.length} 张'
      : '${shown.length} 张';

  List<Widget> _body({
    required bool guest,
    required List<Album> shown,
    required int columns,
    required double cell,
    required double caption,
    required double gap,
    required double inset,
  }) {
    if (guest) {
      return <Widget>[
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: inset),
          sliver: SliverToBoxAdapter(
            child: AppNotice(
              message: '登录后同步收藏的专辑',
              action: SpringFilledButton(
                onPressed: () => unawaited(_signIn()),
                child: const TrText('登录'),
              ),
            ),
          ),
        ),
      ];
    }
    if (_error != null) {
      return <Widget>[
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: inset),
          sliver: SliverToBoxAdapter(
            child: AppNotice(
              message: _error!,
              action: SpringFilledButton(
                onPressed: () => unawaited(_load(reset: true, force: true)),
                child: const TrText('重试'),
              ),
            ),
          ),
        ),
      ];
    }
    if (_albums.isEmpty && _loading) {
      return const <Widget>[
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (_albums.isEmpty) {
      return <Widget>[
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: inset),
          sliver: const SliverToBoxAdapter(
            child: AppNotice(message: '还没有收藏的专辑'),
          ),
        ),
      ];
    }
    if (shown.isEmpty) {
      return <Widget>[
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: inset),
          sliver: SliverToBoxAdapter(
            child: AppNotice(
              message: _filterTruncated ? '没有找到匹配的专辑，试试更精确的关键词' : '没有找到匹配的专辑',
            ),
          ),
        ),
      ];
    }
    return <Widget>[
      SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: inset),
        sliver: SliverGrid.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: gap,
            mainAxisSpacing: 22,
            mainAxisExtent: cell + caption,
          ),
          itemCount: shown.length,
          itemBuilder: (BuildContext context, int index) =>
              _albumCard(context, shown[index], cell),
        ),
      ),
      if (_loading)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: 22),
            child: Center(
              child: SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
        ),
      const SliverToBoxAdapter(child: SizedBox(height: 36)),
    ];
  }

  Widget _albumCard(BuildContext context, Album album, double side) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final GlobalKey coverKey = _coverKeys.putIfAbsent(
      album.id,
      () => GlobalKey(),
    );
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: feedbackAction(context, () {
          // The shell owns the album detail slot; naming the cover lets the
          // artwork fly from this card into the page it opens.
          rememberCoverTransition('playlist:${album.id}', coverKey);
          unawaited(openAlbumDetails(context, widget.state, album));
        }),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            CoverTransitionSource(
              key: coverKey,
              identity: 'playlist:${album.id}',
              child: AppCover(url: album.coverUrl, size: side, radius: 14),
            ),
            const SizedBox(height: 8),
            Text(
              album.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: apple.label,
                fontWeight: context.fonts.weightFor(
                  FontCategory.title,
                  FontWeight.w600,
                ),
              ),
            ),
            if (album.artist.isNotEmpty)
              Text(
                album.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: apple.secondaryLabel,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// How many covers share a row. The saved albums use the library's own
/// density so the two pages read as the same shelf.
int _albumColumns(double width) => switch (width) {
  >= 1100 => 6,
  >= 860 => 5,
  >= 660 => 4,
  >= 430 => 3,
  _ => 2,
};

/// Side of one cover in the saved-album grid: exactly one cell, so the covers
/// stay even across the row.
double _albumCell(double width, int columns, double gap) =>
    math.max(64, (width - gap * (columns - 1)) / columns);
