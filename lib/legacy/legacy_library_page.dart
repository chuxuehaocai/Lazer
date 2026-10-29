import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../data/catalog.dart';
import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../local/local_music_import.dart';
import '../local/local_music_page.dart';
import '../state/app_state.dart';
import '../state/ui_preferences.dart';
import '../theme/apple_design.dart';
import '../widgets/apple_ui.dart';
import '../widgets/interaction_feedback.dart';
import '../widgets/playlist_picker_dialog.dart';
import '../widgets/ui_scaling.dart';
import 'legacy_login.dart';
import 'legacy_page_utils.dart';
import 'legacy_widgets.dart';

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
    final List<Playlist> mine = _arrangePlaylists(
      uniquePlaylists(<Playlist>[
        if (collections.liked != null) collections.liked!,
        ...collections.created,
        ...collections.subscribed,
      ]),
      state.playlistOrder,
    );
    final List<Playlist> publicLists = uniquePlaylists(
      state.home?.playlists ?? const <Playlist>[],
    );
    final double inset = legacyPageInset(context);
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
                        trailing: _playlistArrangementButton(context, state),
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
///
/// A grid that carries an [onReorder] can be rearranged. Holding a card lifts
/// it onto the overlay; while the pointer is over another card the grid
/// previews the order it would land in, so the cards make room before the
/// listener lets go. The lift then settles into the slot it was dropped on —
/// or back onto its own slot when it is released anywhere else. A mouse or
/// stylus skips the hold: there is no scroll gesture to protect there, so the
/// card follows the pointer as soon as it moves.
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
    with TickerProviderStateMixin {
  /// One key per card, so the lift can measure the box it has to settle into.
  final Map<String, GlobalKey> _boxes = <String, GlobalKey>{};

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
  final ValueNotifier<Rect?> _flight = ValueNotifier<Rect?>(null);
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

  @override
  void initState() {
    super.initState();
    _settle.addListener(_settleTick);
    _reflow.addListener(_reflowTick);
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
    return object.localToGlobal(Offset.zero) & object.size;
  }

  /// How far [id] is still behind its slot while the grid slides over.
  Offset _shiftOf(String id) {
    final Offset? from = _reflowShift[id];
    if (from == null) return Offset.zero;
    final double left = 1 - Curves.easeOutCubic.transform(_reflow.value);
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

  /// The card under [globalPosition].
  ///
  /// While the pointer is moving the card in the air is skipped: it cannot be
  /// dropped onto itself. When the listener lets go it counts again, so
  /// releasing over the slot the preview already claimed keeps that slot.
  String? _cardAt(Offset globalPosition, {bool includeDragged = false}) {
    for (final String id in _boxes.keys) {
      if (!includeDragged && id == _dragging) continue;
      final Rect? rect = _boxOf(id);
      if (rect != null && rect.contains(globalPosition)) return id;
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
    // The same tap-strength pulse a card gets when it is picked up anywhere
    // else in the app.
    final AppState? app = InteractionFeedback.of(context);
    if (app != null) unawaited(app.feedback());
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
    _proxy = OverlayEntry(
      builder: (BuildContext context) => _flightLayer(playlist),
    );
    Overlay.of(context, rootOverlay: true).insert(_proxy!);
  }

  void _updateDrag(Offset globalPosition) {
    final String? dragging = _dragging;
    final Rect? flight = _flight.value;
    if (dragging == null || flight == null) return;
    _flight.value = Rect.fromLTWH(
      globalPosition.dx - _grab.dx,
      globalPosition.dy - _grab.dy,
      flight.width,
      flight.height,
    );
    final String? over = _cardAt(globalPosition);
    if (over == null) return;
    final List<String> base = _preview ?? _committed;
    final List<String> moved = <String>[...base]..remove(dragging);
    final int at = moved.indexOf(over);
    if (at < 0) return;
    moved.insert(at, dragging);
    if (listEquals(moved, base)) return;
    // The grid moves the moment the pointer does: the card the listener is
    // holding claims the slot, and every card behind it glides over on an
    // eased curve instead of jumping there.
    final Map<String, Offset> travel = _travel(_shown, _orderOf(moved));
    setState(() => _preview = moved);
    _slide(travel);
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
    // Released over a card: commit that order. Released over empty grid space
    // (or outside the grid): the preview is dropped and the card goes home.
    if (preview != null &&
        _cardAt(globalPosition, includeDragged: true) != null) {
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
        Curves.easeOutCubic.transform(_settle.value),
      );
    }
    // The slot stays empty until the preview has actually arrived: revealing
    // it earlier made a long drop look like it flew part of the way and then
    // snapped into place. [_finishDrag] hands the slot back on the same frame
    // the preview is removed.
  }

  void _finishDrag() {
    _heldByLongPress = false;
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
  Widget _flightLayer(Playlist playlist) => AnimatedBuilder(
    animation: Listenable.merge(<Listenable>[_flight, _lift, _settle]),
    builder: (BuildContext context, Widget? child) {
      final Rect? rect = _flight.value;
      if (rect == null) return const SizedBox.shrink();
      final double lift = _lift.value;
      final double settle = _settle.value;
      // Picking the card up grows it a hair on a spring; putting it down
      // shrinks that growth away as it travels.
      final double scale = settle > 0
          ? 1.02 - .02 * Curves.easeOutCubic.transform(settle)
          : .9 + .12 * Curves.easeOutBack.transform(lift);
      return Positioned.fromRect(
        rect: rect,
        child: IgnorePointer(
          child: Opacity(
            opacity: settle > .9 ? (1 - (settle - .9) / .1).clamp(0.0, 1.0) : 1,
            child: Transform.scale(scale: scale, child: child),
          ),
        ),
      );
    },
    child: _PlaylistDragStill(playlist: playlist, side: widget.cell),
  );

  Widget _cell(Playlist playlist) {
    final GlobalKey box = _boxes.putIfAbsent(playlist.id, () => GlobalKey());
    Widget card = LegacyPlaylistCard(
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
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
      opacity: lifted ? .22 : (landing ? 0 : 1),
      child: AnimatedScale(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
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
            child: LegacyCover(url: playlist.coverUrl, size: side, radius: 14),
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
