import '../state/build_safe_notifier.dart';
import '../widgets/build_safe_state.dart';
import '../animation/apple_spring.dart';
import '../animation/view_transitions.dart';
import '../widgets/spring_buttons.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../data/catalog.dart';
import '../data/models.dart';
import '../downloads/download_dialog.dart';
import '../gateway/music_models.dart';
import '../l10n/app_localizations.dart';
import '../local/local_music_import.dart';
import '../local/local_music_page.dart';
import '../network/network_sources_page.dart';
import '../state/app_state.dart';
import '../state/ui_preferences.dart';
import '../theme/apple_design.dart';
import '../widgets/apple_ui.dart';
import '../widgets/interaction_feedback.dart';
import '../widgets/playlist_picker_dialog.dart';
import '../widgets/ui_scaling.dart';
import 'home_pages.dart';
import 'login.dart';
import 'listening_statistics_page.dart';
import 'page_utils.dart';
import 'widgets.dart';

/// Library: local files first, then owned playlists and public
/// recommendations. Local music sits above the playlists so a guest can import
/// files without signing in.
class AppLibraryPage extends StatelessWidget {
  const AppLibraryPage({
    super.key,
    required this.state,
    required this.onOpenPlaylist,
    required this.onOpenLocalMusic,
    required this.onOpenSavedAlbums,
    this.topInset = 0,
    this.onOpenListeningStatistics,
    this.onOpenNetworkSources,
    this.localImporter = const LocalMusicImporter(),
  });

  final AppState state;
  final double topInset;
  final ValueChanged<Playlist> onOpenPlaylist;
  final VoidCallback onOpenLocalMusic;

  /// 音乐库 → 收藏的专辑: the account's saved albums have their own page, so
  /// someone looking for an album does not have to read through playlists.
  final VoidCallback onOpenSavedAlbums;
  final VoidCallback? onOpenListeningStatistics;

  /// 音乐库 → 网络源. Null opens the hub as a pushed page, which is also how
  /// the library card works outside the shell's content pane.
  final VoidCallback? onOpenNetworkSources;

  /// Lets tests hand in a fake chooser; production uses the system picker.
  final LocalMusicImporter localImporter;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final UserCollections collections = state.collections;
    final List<Playlist> mine = _arrangePlaylists(
      uniquePlaylists(<Playlist>[
        if (collections.liked != null) collections.liked!,
        ...collections.created,
        ...collections.subscribed,
      ]),
      state.playlistOrder,
    );
    final mineIds = mine.map((playlist) => playlist.id).toSet();
    final List<Playlist> publicLists = uniquePlaylists(
      state.home?.playlists ?? const <Playlist>[],
    ).where((playlist) => !mineIds.contains(playlist.id)).toList();
    final double inset = pageInset(context);
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
            const double gap = 18;
            final bool arranged = state.playlistColumns > 0;
            final int columns = _libraryColumns(
              state.playlistColumns,
              width,
              gap,
            );
            final double cell = _playlistCell(
              width,
              columns,
              gap,
              fill: arranged,
            );
            // A desktop window has the width for two columns of entry cards.
            // Stacking them in one column left half the pane empty and made the
            // library read like a phone page blown up.
            final bool wide = width >= 940;
            return CustomScrollView(
              slivers: <Widget>[
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(inset, 8 + topInset, inset, 0),
                  sliver: SliverList.list(
                    children: <Widget>[
                      ApplePageTitle(
                        title: '资料库',
                        subtitle: state.isGuest
                            ? '登录后同步你的歌单'
                            : '${state.user.name} 的音乐',
                        trailing: _playlistArrangementButton(context, state),
                        padding: const EdgeInsets.fromLTRB(0, 12, 0, 18),
                      ),
                      _householdEntries(context, apple, wide: wide),
                      if (state.recentTracks.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 30),
                        const AppSectionHeader(title: '最近播放'),
                        const SizedBox(height: 14),
                        HomeRecentTrackShelf(
                          currentTrackId: state.current?.id,
                          tracks: state.recentTracks,
                          onPlay: (List<Track> tracks, int index) =>
                              state.playQueue(tracks, startIndex: index),
                          onMenuRequested: (Track track, Offset position) =>
                              showTrackActions(context, state, track, position),
                        ),
                      ],
                      if (mine.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 30),
                        AppSectionHeader(
                          title: '我的音乐',
                          subtitle: state.isGuest
                              ? '游客模式'
                              : mine.length > 1
                              ? '长按拖动排序'
                              : null,
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
                      onReorder: (List<String> order) =>
                          unawaited(state.setPlaylistOrder(order)),
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
                        const AppSectionHeader(title: '推荐歌单'),
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
                      child: AppNotice(
                        message: state.isGuest ? '登录后同步你的歌单' : '还没有歌单。',
                        action: state.isGuest
                            ? SpringFilledButton(
                                onPressed: () => unawaited(
                                  showAppLoginDialog(context, state),
                                ),
                                child: const TrText('登录'),
                              )
                            : null,
                      ),
                    ),
                  ),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 28 + MediaQuery.paddingOf(context).bottom,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
  /// The library's own doors: local files, sources, saved albums, statistics.
  ///
  /// A desktop pane has room for two columns — files on the left, sources and
  /// shortcuts on the right — which is what a player's library page looks like;
  /// one column of full-width rows left half the window empty. The right side is
  /// a single grouped surface rather than three separate cards: one row per
  /// shortcut matches the rows on the left, so both columns end on the same line
  /// instead of leaving a ragged bottom edge.
  Widget _householdEntries(
    BuildContext context,
    AppleSemanticColors apple, {
    required bool wide,
  }) {
    final Widget local = LocalMusicCard(
      state: state,
      onOpen: onOpenLocalMusic,
      importer: localImporter,
    );
    final List<Widget> shortcuts = <Widget>[
      NetworkSourcesCard(
        state: state,
        asTile: true,
        onOpen:
            onOpenNetworkSources ??
            () => unawaited(openNetworkSourcesPage(context, state)),
      ),
      if (state.supportsMusic(MusicCapability.savedAlbums))
        AppleListTile(
          key: const ValueKey<String>('open-saved-albums'),
          title: context.tr('收藏的专辑'),
          subtitle: state.isGuest
              ? context.tr('登录后同步收藏的专辑')
              : context.tr('按专辑浏览你的收藏'),
          leading: AppleIconTile(
            icon: Icons.album_rounded,
            color: apple.accent,
          ),
          showChevron: true,
          onTap: onOpenSavedAlbums,
        ),
      AppleListTile(
        key: const ValueKey('open-listening-statistics'),
        title: context.tr('听歌统计'),
        subtitle: context.tr('听歌时长、习惯与切歌记录'),
        leading: AppleIconTile(
          icon: Icons.insights_rounded,
          color: apple.accent,
        ),
        showChevron: true,
        onTap:
            onOpenListeningStatistics ??
            () => unawaited(
              Navigator.of(context).push<void>(
                ApplePageRoute<void>(
                  settings: const RouteSettings(name: '/listening-statistics'),
                  builder: (_) => AppListeningStatisticsPage(
                    statistics: state.listeningStatistics,
                  ),
                ),
              ),
            ),
      ),
    ];
    final Widget shortcutsCard = AppleGroupedCard(
      margin: EdgeInsets.zero,
      child: Column(
        children: <Widget>[
          for (int index = 0; index < shortcuts.length; index++) ...<Widget>[
            if (index > 0) Container(height: .5, color: apple.separator),
            shortcuts[index],
          ],
        ],
      ),
    );
    if (!wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          local,
          const SizedBox(height: 12),
          shortcutsCard,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(flex: 3, child: local),
        const SizedBox(width: 18),
        Expanded(flex: 2, child: shortcutsCard),
      ],
    );
  }
}

/// The band at the top and the bottom of the page that moves the page itself.
///
/// A card held in it is carried past the rows that happen to be on screen: the
/// grid slides under the pointer instead of the listener having to reach the
/// next row by hand.
const double _kEdgeBand = 96;

/// How fast the page travels with the pointer on the very rim, in logical
/// pixels per second. The band scales it away from the rim, so the first pixel
/// into the band creeps and the edge itself moves.
const double _kEdgeSpeed = 1200;

/// A lazily built playlist grid: one sliver row per [columns] cards.
///
/// A sliver list keeps the intrinsic card height (so text scaling never
/// overflows a fixed grid extent) while only mounting the rows on screen.
///
/// A grid that carries an [onReorder] can be rearranged. Holding a card lifts
/// it onto the overlay; while the pointer is over another card the grid
/// previews the order it would land in, so the cards make room before the
/// listener lets go. The lift then settles into the slot it was dropped on —
/// or back onto its own slot when it is released anywhere else. Carrying the
/// lift into the band at the top or the bottom of the page scrolls the grid
/// under the pointer, so a playlist can be taken past the rows that are on
/// screen without letting go of it. A mouse or stylus skips the hold: there is
/// no scroll gesture to protect there, so the card follows the pointer as soon
/// as it moves.
class _PlaylistRowsSliver extends StatefulWidget {
  const _PlaylistRowsSliver({
    required this.playlists,
    required this.columns,
    required this.cell,
    required this.gap,
    required this.onOpen,
    this.onReorder,
  });

  final List<Playlist> playlists;
  final int columns;
  final double cell;
  final double gap;
  final ValueChanged<Playlist> onOpen;

  /// Receives the order the grid was rearranged into. Null keeps the grid
  /// static: no lift, no preview, no settle.
  final ValueChanged<List<String>>? onReorder;

  @override
  State<_PlaylistRowsSliver> createState() => _PlaylistRowsSliverState();
}

class _PlaylistRowsSliverState extends State<_PlaylistRowsSliver>
    with TickerProviderStateMixin, BuildSafeState<_PlaylistRowsSliver> {
  /// One key per card, so the lift can measure the box it has to settle into.
  final Map<String, GlobalKey> _boxes = <String, GlobalKey>{};

  /// Slot numbers belonging to the most recent layout. Multiple pointer
  /// reports can arrive before the preview has had another frame to lay out.
  Map<String, int> _laidOutSlots = <String, int>{};

  /// The card in the listener's hand, if any.
  String? _dragging;

  /// The order the grid previews while a card is in the air. Null means the
  /// grid is showing what the catalogue says.
  List<String>? _preview;

  /// The card whose slot is waiting for the lifted preview to land on it.
  String? _landing;

  /// The card's height grows with the lift; the width is the grid's cell.
  late final AnimationController _lift = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );

  /// The trip from the pointer to the slot the card belongs to.
  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );

  /// How the cards slide over when the preview moves them: every card that
  /// changes slot keeps its old position for an instant and glides to the new
  /// one instead of teleporting.
  late final AnimationController _reflow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );

  /// The distance each card owes the eye, in pixels, at the start of a reflow.
  Map<String, Offset> _reflowShift = <String, Offset>{};

  /// Measured card heights. The grid predicts slot positions from them instead
  /// of waiting for a layout pass, which is what makes the slide start on the
  /// same frame the order changes.
  final Map<String, double> _heights = <String, double>{};

  /// Where the lifted card is right now, in global coordinates.
  final ValueNotifier<Rect?> _flight = BuildSafeValueNotifier<Rect?>(null);
  Rect? _settleFrom;
  Rect? _settleTo;
  Offset _grab = Offset.zero;
  OverlayEntry? _proxy;

  /// The mouse or stylus pointer being watched for a direct drag.
  ///
  /// Touch keeps the long press: lifting on the first movement there would
  /// steal the scroll. A mouse has no scroll gesture to protect, and making a
  /// desktop listener hold the button for half a second before the card
  /// follows the cursor reads as "nothing happened".
  int? _pointer;
  Offset _pointerDown = Offset.zero;
  bool _pointerDragging = false;
  Playlist? _pointerCard;

  /// Whether the card in the air was picked up by a long press. The long
  /// press recognizer reports a cancel the moment the arena drops it — which
  /// is exactly what a desktop drag does when it starts — so only the hold may
  /// act on those callbacks.
  bool _heldByLongPress = false;

  /// The pointer's latest global position while a card is in the air.
  ///
  /// The rim scroll reads this rather than the movement events: a finger held
  /// still against the edge of the page reports nothing at all, and that is
  /// exactly when the grid has to keep travelling.
  Offset? _heldAt;

  /// The page the grid is laid out in, so the rim bands are measured against
  /// the box the cards are seen through rather than the window.
  ScrollableState? _page;

  /// Walks the page along while [_heldAt] sits in a rim band.
  Ticker? _edge;
  Duration _edgeElapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _settle.addListener(_settleTick);
    _reflow.addListener(_reflowTick);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _page = Scrollable.maybeOf(context);
  }

  @override
  void didUpdateWidget(covariant _PlaylistRowsSliver oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The catalogue has caught up with the drop: the preview is the committed
    // order now, so drop the extra layer without touching the pixels.
    final List<String>? preview = _preview;
    if (preview != null && listEquals(_committed, preview)) {
      _preview = null;
    }
  }

  @override
  void dispose() {
    _proxy?.remove();
    _proxy = null;
    _edge?.dispose();
    _edge = null;
    _settle.dispose();
    _reflow.dispose();
    _lift.dispose();
    _flight.dispose();
    super.dispose();
  }

  /// Slots the committed order, which is what the grid falls back to when a
  /// drag is abandoned.
  List<String> get _committed => <String>[
    for (final Playlist playlist in widget.playlists) playlist.id,
  ];

  /// The order the rows are painted in: the preview while a card is in the
  /// air, the committed order otherwise.
  List<Playlist> get _shown {
    final List<String>? preview = _preview;
    if (preview == null) return widget.playlists;
    final Map<String, Playlist> byId = <String, Playlist>{
      for (final Playlist playlist in widget.playlists) playlist.id: playlist,
    };
    return <Playlist>[
      for (final String id in preview)
        if (byId[id] != null) byId[id]!,
    ];
  }

  Rect? _boxOf(String id) {
    final RenderObject? object = _boxes[id]?.currentContext?.findRenderObject();
    if (object is! RenderBox || !object.hasSize) return null;
    // The key sits on the slide wrapper itself, and a render object never
    // counts its own transform in `localToGlobal`: this is the slot, exactly
    // where hit tests and landings need it, even mid-slide.
    return Rect.fromPoints(
      object.localToGlobal(Offset.zero),
      object.localToGlobal(object.size.bottomRight(Offset.zero)),
    );
  }

  /// How far [id] is still behind its slot while the grid slides over.
  Offset _shiftOf(String id) {
    final Offset? from = _reflowShift[id];
    if (from == null) return Offset.zero;
    final double left = 1 - const AppleSpringCurve().transform(_reflow.value);
    return from * left;
  }

  /// Records every card's height so slot positions can be predicted without a
  /// layout pass.
  void _measureCards() {
    for (final MapEntry<String, GlobalKey> entry in _boxes.entries) {
      final RenderObject? object = entry.value.currentContext
          ?.findRenderObject();
      if (object is RenderBox && object.hasSize) {
        _heights[entry.key] = object.size.height;
      }
    }
  }

  /// Where each card sits for [shown], in the grid's own coordinates.
  ///
  /// The rows are uniform enough to describe with arithmetic: a card's box is
  /// the cell wide, the row is as tall as its tallest card, and rows are 24
  /// apart — the same numbers the sliver lays out with.
  Map<String, Offset> _slotTops(List<Playlist> shown) {
    final double fallback = widget.cell + 47;
    final Map<String, Offset> tops = <String, Offset>{};
    double y = 0;
    for (int start = 0; start < shown.length; start += widget.columns) {
      final int end = math.min(start + widget.columns, shown.length);
      double rowHeight = 0;
      for (int i = start; i < end; i++) {
        rowHeight = math.max(rowHeight, _heights[shown[i].id] ?? fallback);
      }
      for (int i = start; i < end; i++) {
        tops[shown[i].id] = Offset((i - start) * (widget.cell + widget.gap), y);
      }
      y += rowHeight + 24;
    }
    return tops;
  }

  /// The distance every card has to cover to get from [from] to [to].
  Map<String, Offset> _travel(List<Playlist> from, List<Playlist> to) {
    final Map<String, Offset> before = _slotTops(from);
    final Map<String, Offset> after = _slotTops(to);
    return <String, Offset>{
      for (final MapEntry<String, Offset> entry in before.entries)
        if (after[entry.key] != null && after[entry.key] != entry.value)
          // Where the card is painted right now, not where it was laid out: a
          // change that lands mid-slide continues the glide instead of
          // snapping back to the slot it had already left.
          entry.key: _shiftOf(entry.key) + entry.value - after[entry.key]!,
    };
  }

  /// [ids] resolved against the playlists this grid is showing.
  List<Playlist> _orderOf(List<String> ids) {
    final Map<String, Playlist> byId = <String, Playlist>{
      for (final Playlist playlist in widget.playlists) playlist.id: playlist,
    };
    return <Playlist>[
      for (final String id in ids)
        if (byId[id] != null) byId[id]!,
    ];
  }

  /// Starts the slide from the cards' current slots to the new ones.
  void _slide(Map<String, Offset> travel) {
    _reflowShift = travel;
    if (travel.isEmpty) {
      _reflow.value = 0;
      return;
    }
    _reflow.forward(from: 0);
  }

  void _reflowTick() {
    if (!mounted) return;
    // Each card rebuilds its own offset through an [AnimatedBuilder]; the only
    // work left here is dropping the travel once it has been spent.
    if (_reflow.isCompleted && _reflowShift.isNotEmpty) {
      setState(() => _reflowShift = <String, Offset>{});
    }
  }

  /// The logical slot under [globalPosition]. The lifted placeholder counts
  /// too: staying over that slot leaves the preview still.
  /// Reflow transforms do not change the slot being pointed at.
  int? _slotAt(Offset globalPosition) {
    for (final String id in _boxes.keys) {
      final int? slot = _laidOutSlots[id];
      if (slot == null) continue;
      final Rect? rect = _boxOf(id);
      if (rect != null && rect.contains(globalPosition)) return slot;
    }
    return null;
  }

  void _pointerPressed(Playlist playlist, PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse &&
        event.kind != PointerDeviceKind.stylus) {
      return;
    }
    _pointer = event.pointer;
    _pointerDown = event.position;
    _pointerDragging = false;
    _pointerCard = playlist;
  }

  void _pointerMoved(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    final Playlist? playlist = _pointerCard;
    if (playlist == null) return;
    if (!_pointerDragging) {
      if ((event.position - _pointerDown).distance < kTouchSlop) return;
      _pointerDragging = true;
      // Anchor on the press: by the time the drag is recognised the pointer
      // has already left the pixel the card was grabbed at, and anchoring
      // there would trail the cursor by that distance for the whole drag.
      _startDrag(
        playlist,
        grabAt: _pointerDown,
        at: event.position,
        fromHold: false,
      );
    }
    _updateDrag(event.position);
  }

  void _pointerReleased(PointerEvent event) {
    if (event.pointer != _pointer) return;
    final bool dragging = _pointerDragging;
    _forgetPointer();
    if (dragging) unawaited(_endDrag(event.position));
  }

  void _pointerCancelled() {
    final bool dragging = _pointerDragging;
    _forgetPointer();
    if (dragging) unawaited(_cancelDrag());
  }

  void _forgetPointer() {
    _pointer = null;
    _pointerDragging = false;
    _pointerCard = null;
  }

  void _startDrag(
    Playlist playlist, {
    required Offset grabAt,
    required Offset at,
    required bool fromHold,
  }) {
    if (_dragging != null) return;
    _measureCards();
    final Rect? box = _boxOf(playlist.id);
    if (box == null) return;
    _grab = grabAt - box.topLeft;
    _heldByLongPress = fromHold;
    _heldAt = at;
    // The same tap-strength pulse a card gets when it is picked up anywhere
    // else in the app.
    final FeedbackCallback? feedback = InteractionFeedback.of(context);
    if (feedback != null) unawaited(feedback());
    setState(() {
      _dragging = playlist.id;
      _preview = null;
    });
    _flight.value = Rect.fromLTWH(
      at.dx - _grab.dx,
      at.dy - _grab.dy,
      box.width,
      box.height,
    );
    _settle.value = 0;
    _lift.forward(from: 0);
    final overlay = Overlay.of(context, rootOverlay: true);
    _proxy = OverlayEntry(
      builder: (BuildContext context) => _flightLayer(playlist, overlay),
    );
    overlay.insert(_proxy!);
    _startEdgeScroll();
  }

  void _updateDrag(Offset globalPosition) {
    _heldAt = globalPosition;
    final String? dragging = _dragging;
    final Rect? flight = _flight.value;
    if (dragging == null || flight == null) return;
    if (_nearRim(globalPosition)) {
      _startEdgeScroll();
    } else {
      _stopEdgeScroll();
    }
    _flight.value = Rect.fromLTWH(
      globalPosition.dx - _grab.dx,
      globalPosition.dy - _grab.dy,
      flight.width,
      flight.height,
    );
    final List<String> base = _preview ?? _committed;
    final int? at = _claimedSlot(globalPosition);
    if (at == null || at >= base.length) return;
    // Claim the pointed slot before removing the lifted card. Looking up the
    // neighbour afterwards shifts forward moves back by one, forcing the
    // pointer onto the next card to reach the intended position.
    final int from = base.indexOf(dragging);
    if (from < 0 || from == at) return;
    final List<String> moved = <String>[...base]..removeAt(from);
    moved.insert(at, dragging);
    if (listEquals(moved, base)) return;
    // The grid moves the moment the pointer does: the card the listener is
    // holding claims the slot, and every card behind it glides over on an
    // eased curve instead of jumping there.
    final Map<String, Offset> travel = _travel(_shown, _orderOf(moved));
    setState(() => _preview = moved);
    _slide(travel);
  }

  /// Starts the rim scroll, or leaves it running if it already is.
  void _startEdgeScroll() {
    final Ticker ticker = _edge ??= createTicker(_edgeStep);
    if (ticker.isActive) return;
    _edgeElapsed = Duration.zero;
    ticker.start();
  }

  void _stopEdgeScroll() {
    final Ticker? ticker = _edge;
    if (ticker == null) return;
    if (ticker.isActive) ticker.stop();
    _edgeElapsed = Duration.zero;
  }

  /// Carries the page under a card that is being held against a rim.
  ///
  /// The pointer is not moving while this runs — it is parked at the edge —
  /// so the travel cannot come from a gesture. The card keeps the position it
  /// was last reported at, the page moves beneath it, and the slot under the
  /// pointer is read again after the scroll has been laid out.
  void _edgeStep(Duration elapsed) {
    final Duration since = elapsed - _edgeElapsed;
    _edgeElapsed = elapsed;
    final Offset? held = _heldAt;
    final ScrollPosition? position = _page?.position;
    if (held == null || position == null || _dragging == null) {
      _stopEdgeScroll();
      return;
    }
    final double seconds = since.inMicroseconds / Duration.microsecondsPerSecond;
    // A stalled frame is not a reason to leap: one step never covers more than
    // a frame's worth of travel.
    if (seconds <= 0 || seconds > .1) return;
    final Rect? view = _pageRect();
    if (view == null) {
      _stopEdgeScroll();
      return;
    }
    final double pull = _edgePull(view, held.dy);
    if (pull == 0 || !_overColumns(held.dx)) {
      // Back in the middle of the page — or off the columns — there is nothing
      // to scroll, and no reason to keep asking for frames.
      _stopEdgeScroll();
      return;
    }
    final next = (position.pixels + _kEdgeSpeed * pull * pull.abs() * seconds)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (next == position.pixels) return;
    position.jumpTo(next);
    // The jump only moves pixels; the cards keep their old global boxes until
    // this frame has been laid out, so the slot under the finger has to be
    // read again once it has been. The pointer did not move — the page did.
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      final Offset? latest = _heldAt;
      if (!mounted || _dragging == null || latest == null) return;
      _updateDrag(latest);
    });
  }

  /// The box the cards are seen through: what the rim bands are measured from.
  Rect? _pageRect() {
    final ScrollableState? page = _page;
    if (page == null || !page.mounted) return null;
    final RenderObject? object = page.context.findRenderObject();
    if (object is! RenderBox || !object.hasSize) return null;
    return object.localToGlobal(Offset.zero) & object.size;
  }

  /// How hard [y] pulls the page towards a rim: -1 on the top edge, +1 on the
  /// bottom one, 0 anywhere in the middle.
  double _edgePull(Rect view, double y) {
    // A page shorter than two bands has no middle to return to, so half its
    // height each is the most the bands may take.
    final double band = math.min(_kEdgeBand, view.height / 2);
    if (band <= 0) return 0;
    final double top = view.top + band;
    if (y < top) return ((y - top) / band).clamp(-1.0, 1.0);
    final double bottom = view.bottom - band;
    if (y > bottom) return ((y - bottom) / band).clamp(0.0, 1.0);
    return 0;
  }

  /// Whether [globalPosition] is close enough to a rim for the grid to be
  /// scrolling itself.
  bool _nearRim(Offset globalPosition) {
    final Rect? view = _pageRect();
    if (view == null || _edgePull(view, globalPosition.dy) == 0) return false;
    // Sideways off the columns the card has nowhere to land, and a page that
    // kept scrolling would leave the placeholder it holds far behind.
    return _overColumns(globalPosition.dx);
  }

  /// Whether [x] is in the columns of the grid, gutter included.
  bool _overColumns(double x) {
    double? left;
    double? right;
    for (final String id in _boxes.keys) {
      final Rect? rect = _boxOf(id);
      if (rect == null) continue;
      left = left == null ? rect.left : math.min(left, rect.left);
      right = right == null ? rect.right : math.max(right, rect.right);
    }
    if (left == null || right == null) return false;
    return x >= left - widget.gap && x <= right + widget.gap;
  }

  /// The slot the pointer is claiming.
  ///
  /// A card under the pointer wins. Failing that — and only in the rim bands,
  /// where the page chrome can sit between the rim and the first row while the
  /// grid slides by underneath — the nearest slot in the pointer's own column
  /// is claimed, so a playlist carried to the top of the list is not thrown
  /// away by letting go over the header.
  int? _claimedSlot(Offset globalPosition) {
    final int? under = _slotAt(globalPosition);
    if (under != null) return under;
    if (!_nearRim(globalPosition)) return null;
    return _nearestSlot(globalPosition);
  }

  /// The slot closest to [globalPosition] among the cards that share its
  /// column, for a pointer held over the page chrome rather than over a card.
  int? _nearestSlot(Offset globalPosition) {
    int? best;
    double closest = double.infinity;
    for (final String id in _boxes.keys) {
      final int? slot = _laidOutSlots[id];
      final Rect? rect = _boxOf(id);
      if (slot == null || rect == null) continue;
      final double sideways = globalPosition.dx < rect.left
          ? rect.left - globalPosition.dx
          : globalPosition.dx > rect.right
          ? globalPosition.dx - rect.right
          : 0;
      // Further out than the gutter is another column's business.
      if (sideways > widget.gap) continue;
      final double score =
          sideways * 4 + (globalPosition.dy - rect.center.dy).abs();
      if (score < closest) {
        closest = score;
        best = slot;
      }
    }
    return best;
  }

  Future<void> _endDrag(Offset globalPosition) async {
    final String? dragging = _dragging;
    final Rect? from = _flight.value;
    if (dragging == null) return;
    if (from == null) {
      _finishDrag();
      return;
    }
    final List<String>? preview = _preview;
    // Released over a card — or held at a rim, where the nearest slot counts:
    // commit that order. Released over empty grid space (or outside the grid):
    // the preview is dropped and the card goes home.
    if (preview != null && _claimedSlot(globalPosition) != null) {
      // The preview already is the order on screen; the catalogue catches up
      // on the next rebuild, so nothing moves here.
      widget.onReorder?.call(preview);
    } else {
      _revertPreview();
    }
    await _settleInto(dragging, from);
  }

  Future<void> _cancelDrag() async {
    final String? dragging = _dragging;
    final Rect? from = _flight.value;
    if (dragging == null || from == null || !_heldByLongPress) return;
    _revertPreview();
    await _settleInto(dragging, from);
  }

  /// Drops the preview and slides the cards back where the catalogue has them.
  void _revertPreview() {
    final List<String>? preview = _preview;
    if (preview == null) return;
    final Map<String, Offset> travel = _travel(_shown, widget.playlists);
    setState(() => _preview = null);
    _slide(travel);
  }

  /// Flies the lifted card from [from] into the slot it owns now, then hands
  /// the slot back to the real card.
  Future<void> _settleInto(String id, Rect from) async {
    setState(() {
      _dragging = null;
      _landing = id;
    });
    // The row has to lay out the order the card was released into before its
    // slot can be measured.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    _settleFrom = from;
    _settleTo = _boxOf(id) ?? from;
    _flight.value = from;
    await _settle.forward(from: 0);
    if (!mounted) return;
    _finishDrag();
  }

  void _settleTick() {
    final Rect? from = _settleFrom;
    final Rect? to = _settleTo;
    if (from != null && to != null) {
      _flight.value = Rect.lerp(
        from,
        to,
        const AppleSpringCurve().transform(_settle.value),
      );
    }
    // The slot stays empty until the preview has actually arrived: revealing
    // it earlier made a long drop look like it flew part of the way and then
    // snapped into place. [_finishDrag] hands the slot back on the same frame
    // the preview is removed.
  }

  void _finishDrag() {
    _heldByLongPress = false;
    _heldAt = null;
    _stopEdgeScroll();
    _proxy?.remove();
    _proxy = null;
    _settle.stop();
    _settleFrom = null;
    _settleTo = null;
    // Back to zero, not just stopped: the landing animation fades the card out
    // over its last frames, and a controller left at 1.0 would hand the *next*
    // lift an opacity of zero — a card in the air that nobody can see.
    _settle.value = 0;
    _flight.value = null;
    _lift.value = 0;
    if (!mounted) return;
    setState(() {
      _dragging = null;
      _landing = null;
      if (listEquals(_committed, _preview)) _preview = null;
    });
  }

  /// The overlay layer the lifted card lives on while it is in the air.
  ///
  /// The card itself is built once and handed in as the builder's child: the
  /// overlay only rewrites a matrix and an opacity per frame, never the cover
  /// or the label.
  Widget _flightLayer(Playlist playlist, OverlayState overlay) =>
      AnimatedBuilder(
        animation: Listenable.merge(<Listenable>[_flight, _lift, _settle]),
        builder: (BuildContext context, Widget? child) {
          final Rect? rect = _flight.value;
          if (rect == null) return const SizedBox.shrink();
          final overlayBox = overlay.context.findRenderObject()! as RenderBox;
          final localRect = Rect.fromPoints(
            overlayBox.globalToLocal(rect.topLeft),
            overlayBox.globalToLocal(rect.bottomRight),
          );
          final double lift = _lift.value;
          final double settle = _settle.value;
          // Picking the card up grows it a hair on a spring; putting it down
          // shrinks that growth away as it travels.
          final double scale = settle > 0
              ? 1.02 - .02 * const AppleSpringCurve().transform(settle)
              : 1 + .025 * const AppleSpringCurve().transform(lift);
          return Positioned.fromRect(
            rect: localRect,
            child: IgnorePointer(
              child: Opacity(
                opacity: 1,
                child: Transform.scale(scale: scale, child: child),
              ),
            ),
          );
        },
        child: _PlaylistDragStill(playlist: playlist, side: widget.cell),
      );

  Widget _cell(Playlist playlist) {
    final GlobalKey box = _boxes.putIfAbsent(playlist.id, () => GlobalKey());
    Widget card = AppPlaylistCard(
      playlist: playlist,
      width: widget.cell,
      onTap: () => widget.onOpen(playlist),
    );
    if (widget.onReorder != null) {
      card = Listener(
        onPointerDown: (PointerDownEvent event) =>
            _pointerPressed(playlist, event),
        onPointerMove: _pointerMoved,
        onPointerUp: _pointerReleased,
        onPointerCancel: (PointerCancelEvent event) => _pointerCancelled(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPressStart: (LongPressStartDetails details) => _startDrag(
            playlist,
            grabAt: details.globalPosition,
            at: details.globalPosition,
            fromHold: true,
          ),
          onLongPressMoveUpdate: (LongPressMoveUpdateDetails details) {
            if (_heldByLongPress) _updateDrag(details.globalPosition);
          },
          onLongPressEnd: (LongPressEndDetails details) {
            if (_heldByLongPress) {
              unawaited(_endDrag(details.globalPosition));
            }
          },
          onLongPressCancel: () => unawaited(_cancelDrag()),
          child: card,
        ),
      );
    }
    // In the air: a hollow placeholder marks the slot the card is about to
    // claim. Landing: the slot stays empty until the preview drops onto it.
    final bool lifted = _dragging == playlist.id;
    final bool landing = _landing == playlist.id;
    final Widget content = AnimatedOpacity(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : AppleSpring.responsive.duration,
      curve: const AppleSpringCurve(),
      opacity: lifted ? .22 : (landing ? 0 : 1),
      child: AnimatedScale(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : AppleSpring.responsive.duration,
        curve: const AppleSpringCurve(),
        scale: lifted ? .94 : 1,
        child: card,
      ),
    );
    // Always wrapped, even at rest: a wrapper that comes and goes would
    // rebuild the card's element — and drop the gesture recognizer — in the
    // middle of the very drag that asks for the slide. The builder keeps the
    // per-frame work down to one matrix per card.
    return KeyedSubtree(
      key: box,
      child: AnimatedBuilder(
        animation: _reflow,
        builder: (BuildContext context, Widget? child) =>
            Transform.translate(offset: _shiftOf(playlist.id), child: child),
        child: content,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<Playlist> shown = _shown;
    _laidOutSlots = <String, int>{
      for (int i = 0; i < shown.length; i++) shown[i].id: i,
    };
    final int columns = widget.columns;
    final int count = (shown.length + columns - 1) ~/ columns;
    return SliverList.builder(
      itemCount: count,
      itemBuilder: (BuildContext context, int row) {
        final int start = row * columns;
        final int end = math.min(start + columns, shown.length);
        return Padding(
          padding: EdgeInsets.only(bottom: row == count - 1 ? 0 : 24),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (var i = start; i < end; i++) ...<Widget>[
                if (i > start) SizedBox(width: widget.gap),
                _cell(shown[i]),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// The still of a card that rides the pointer while a playlist is dragged.
///
/// Apple's lift, not a screenshot: the cover grows on a short spring while its
/// shadow blooms underneath it, and the card left in the grid sinks and fades.
/// The still paints the cover and the title only, so the overlay does not mount
/// a second hover surface or a second cover animation for every frame of the
/// drag.
class _PlaylistDragStill extends StatelessWidget {
  const _PlaylistDragStill({required this.playlist, required this.side});

  final Playlist playlist;
  final double side;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return SizedBox(
      key: const ValueKey('playlist-drag-preview'),
      width: side,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: .34),
                  blurRadius: 30,
                  spreadRadius: 2,
                  offset: const Offset(0, 16),
                ),
              ],
            ),
            child: AppCover(url: playlist.coverUrl, size: side, radius: 14),
          ),
          const SizedBox(height: 8),
          Text(
            playlist.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: apple.label,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// Applies the order the library was dragged into.
///
/// The saved order nudges the catalogue instead of replacing it: playlists it
/// does not mention keep their catalogue order behind the arranged ones, so a
/// new subscription still shows up and a deleted one never leaves a hole.
List<Playlist> _arrangePlaylists(List<Playlist> playlists, List<String> order) {
  if (order.isEmpty || playlists.length < 2) return playlists;
  final Map<String, int> rank = <String, int>{
    for (int i = 0; i < order.length; i++) order[i]: i,
  };
  int next = order.length;
  for (final Playlist playlist in playlists) {
    rank.putIfAbsent(playlist.id, () => next++);
  }
  final List<Playlist> arranged = <Playlist>[...playlists];
  arranged.sort((Playlist a, Playlist b) => rank[a.id]!.compareTo(rank[b.id]!));
  return arranged;
}

/// Narrowest card the grid allows before it gives up a column.
const double _kPlaylistCardFloor = 76;

/// How many cards the library grid puts in a row.
///
/// Without a preference the density follows the window width, the way the
/// library opens on its own. A fixed choice is honoured until the cards would
/// stop being readable, at which point the width wins: the grid drops a column
/// instead of squashing the cards under [_kPlaylistCardFloor].
int _libraryColumns(int preference, double width, double gap) {
  if (preference <= 0) {
    return switch (width) {
      >= 1100 => 6,
      >= 860 => 5,
      >= 660 => 4,
      >= 430 => 3,
      _ => 2,
    };
  }
  int columns = preference.clamp(1, kPlaylistColumnsMax);
  while (columns > 1 &&
      (width - gap * (columns - 1)) / columns < _kPlaylistCardFloor) {
    columns--;
  }
  return columns;
}

/// Side of one card in the library grid.
///
/// An automatic density keeps the cards at their authored size and lets a wide
/// window leave the slack on the right. A chosen density — 歌单排列 — fills the
/// row instead: the listener asked for that many cards across, so they get
/// exactly that, edge to edge.
double _playlistCell(
  double width,
  int columns,
  double gap, {
  required bool fill,
}) {
  final double side = (width - gap * (columns - 1)) / columns;
  return side.clamp(_kPlaylistCardFloor, fill ? double.infinity : 190.0);
}

/// `歌单排列`: the listener's own density for the library grids.
Widget _playlistArrangementButton(BuildContext context, AppState state) =>
    PopupMenuButton<int>(
      tooltip: context.tr('歌单排列'),
      initialValue: state.playlistColumns,
      icon: const Icon(Icons.grid_view_rounded, size: 20),
      onSelected: (int value) => unawaited(state.setPlaylistColumns(value)),
      itemBuilder: (BuildContext context) => <PopupMenuEntry<int>>[
        for (final int value in kPlaylistColumnChoices)
          PopupMenuItem<int>(
            value: value,
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 26,
                  child: value == state.playlistColumns
                      ? Icon(
                          Icons.check_rounded,
                          size: 18,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : null,
                ),
                Text(value == 0 ? context.tr('跟随窗口宽度') : '$value×$value'),
              ],
            ),
          ),
      ],
    );
