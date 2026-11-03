part of 'cover_transition.dart';

enum CoverTextRole { title, detail }

/// Text that travels with its cover between a card and a collection header.
class CoverTransitionText extends StatefulWidget {
  const CoverTransitionText.source({
    super.key,
    required GlobalKey coverKey,
    required this.role,
    required this.child,
  }) : sourceKey = coverKey,
       identity = null;

  const CoverTransitionText.target({
    super.key,
    required this.identity,
    required this.role,
    required this.child,
  }) : sourceKey = null,
       assert(identity != null);

  final GlobalKey? sourceKey;
  final String? identity;
  final CoverTextRole role;
  final Widget child;

  @override
  State<CoverTransitionText> createState() => _CoverTransitionTextState();
}

final Map<GlobalKey, Map<CoverTextRole, _CoverTransitionTextState>>
_sourceText = {};
final Map<String, Map<CoverTextRole, _CoverTransitionTextState>> _targetText =
    {};

class _CoverTransitionTextState extends State<CoverTransitionText> {
  bool _hidden = false, _scheduled = false, _active = true;

  Map<CoverTextRole, _CoverTransitionTextState> _registry(
    CoverTransitionText widget,
  ) => widget.sourceKey != null
      ? _sourceText.putIfAbsent(widget.sourceKey!, () => {})
      : _targetText.putIfAbsent(widget.identity!, () => {});

  void _unregister(CoverTransitionText widget) {
    final registry = widget.sourceKey == null
        ? _targetText[widget.identity]
        : _sourceText[widget.sourceKey];
    if (registry?[widget.role] == this) registry!.remove(widget.role);
    if (registry?.isEmpty ?? false) {
      if (widget.sourceKey == null) {
        _targetText.remove(widget.identity);
      } else {
        _sourceText.remove(widget.sourceKey);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _registry(widget)[widget.role] = this;
  }

  @override
  void didUpdateWidget(CoverTransitionText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sourceKey != widget.sourceKey ||
        oldWidget.identity != widget.identity ||
        oldWidget.role != widget.role) {
      _unregister(oldWidget);
      _registry(widget)[widget.role] = this;
      _hidden = false;
    }
  }

  void hide(bool value) {
    if (_hidden == value) return;
    _hidden = value;
    void refresh() {
      _scheduled = false;
      if (!mounted || !_active) return;
      setState(() {});
      _refreshSnapshots(context);
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (!_scheduled) {
        _scheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) => refresh());
      }
    } else {
      refresh();
    }
  }

  RenderParagraph? _paragraph() {
    if (!mounted || !_active) return null;
    RenderParagraph? result;
    void visit(RenderObject object) {
      if (result != null) return;
      if (object is RenderParagraph) {
        result = object;
      } else {
        object.visitChildren(visit);
      }
    }

    final object = context.findRenderObject();
    if (object != null) visit(object);
    final paragraph = result;
    return paragraph != null &&
            paragraph.attached &&
            paragraph.hasSize &&
            !paragraph.size.isEmpty
        ? paragraph
        : null;
  }

  Rect? measureRect() {
    final box = _paragraph();
    if (box == null) return null;
    return Rect.fromPoints(
      box.localToGlobal(Offset.zero),
      box.localToGlobal(box.size.bottomRight(Offset.zero)),
    );
  }

  _CoverTextEndpoint? measure() {
    final paragraph = _paragraph();
    final rect = measureRect();
    if (paragraph == null || rect == null) return null;
    // Keep the paragraph's original constraints, shaping and line breaks.
    // Interpolating font metrics inside a changing rect can drop the last
    // glyph or create an ellipsis on the frame immediately before handoff.
    return _CoverTextEndpoint(
      rect,
      SizedBox.fromSize(
        size: paragraph.size,
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: paragraph.constraints.minWidth,
          maxWidth: paragraph.constraints.maxWidth,
          minHeight: paragraph.constraints.minHeight,
          maxHeight: paragraph.constraints.maxHeight,
          child: RepaintBoundary(
            child: RichText(
              text: paragraph.text,
              textAlign: paragraph.textAlign,
              textDirection: paragraph.textDirection,
              softWrap: paragraph.softWrap,
              overflow: paragraph.overflow,
              textScaler: paragraph.textScaler,
              maxLines: paragraph.maxLines,
              locale: paragraph.locale,
              strutStyle: paragraph.strutStyle,
              textWidthBasis: paragraph.textWidthBasis,
              textHeightBehavior: paragraph.textHeightBehavior,
            ),
          ),
        ),
      ),
    );
  }

  @override
  void deactivate() {
    _active = false;
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _active = true;
  }

  @override
  void dispose() {
    _unregister(widget);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Opacity(opacity: _hidden ? 0 : 1, child: widget.child);
}

void _setSourceTextHidden(
  GlobalKey key,
  bool hidden, [
  Iterable<CoverTextRole>? roles,
]) {
  final entries = _sourceText[key];
  if (entries == null) return;
  for (final role in roles ?? entries.keys) {
    entries[role]?.hide(hidden);
  }
}

void _setTargetTextHidden(
  String identity,
  bool hidden, [
  Iterable<CoverTextRole>? roles,
]) {
  final entries = _targetText[identity];
  if (entries == null) return;
  for (final role in roles ?? entries.keys) {
    entries[role]?.hide(hidden);
  }
}

Map<CoverTextRole, _CoverTextEndpoint> _captureSourceText(GlobalKey key) {
  final captured = <CoverTextRole, _CoverTextEndpoint>{};
  for (final entry
      in (_sourceText[key] ?? <CoverTextRole, _CoverTransitionTextState>{})
          .entries) {
    final endpoint = entry.value.measure();
    if (endpoint != null) captured[entry.key] = endpoint;
  }
  return captured;
}

class _CoverTextEndpoint {
  const _CoverTextEndpoint(this.rect, this.paragraph);
  final Rect rect;
  final Widget paragraph;

  _CoverTextEndpoint inOverlay(RenderBox overlay) {
    final local = Rect.fromPoints(
      overlay.globalToLocal(rect.topLeft),
      overlay.globalToLocal(rect.bottomRight),
    );
    return _CoverTextEndpoint(local, paragraph);
  }
}

class _CoverTextFlight {
  const _CoverTextFlight(
    this.role,
    this.source,
    this.target,
    this.initial,
    this.destination,
  );
  final CoverTextRole role;
  final _CoverTextEndpoint source, target;
  final _CoverPresentation initial;
  final Rect? Function() destination;
}

List<_CoverTextFlight> _textFlights({
  required _CoverOrigin origin,
  required String identity,
  required RenderBox overlay,
  required bool returning,
  required GlobalKey Function() sourceKey,
  required Map<CoverTextRole, _CoverPresentation> initial,
  double? fromBlend,
  Offset Function()? targetTranslation,
}) {
  final flights = <_CoverTextFlight>[];
  for (final entry in origin.text.entries) {
    final target = _targetText[identity]?[entry.key]?.measure()?.inOverlay(
      overlay,
    );
    if (target == null) continue;
    final source = entry.value.inOverlay(overlay);
    final blend = fromBlend ?? (returning ? 1.0 : 0.0);
    Rect? destination() {
      if (!overlay.attached) return null;
      final registry = returning
          ? _sourceText[sourceKey()]
          : _targetText[identity];
      final state = registry?[entry.key];
      final rect = state?.measureRect();
      return rect == null
          ? null
          : Rect.fromPoints(
              overlay.globalToLocal(rect.topLeft),
              overlay.globalToLocal(rect.bottomRight),
            ).shift(-(targetTranslation?.call() ?? Offset.zero));
    }

    flights.add(
      _CoverTextFlight(
        entry.key,
        source,
        target,
        initial[entry.key] ??
            _CoverPresentation(
              Rect.lerp(source.rect, target.rect, blend)!,
              Rect.zero,
              blend,
              0,
            ),
        destination,
      ),
    );
  }
  return flights;
}

Widget _buildFlyingText(
  _CoverTextFlight flight,
  _CoverPresentation frame,
  void Function(CoverTextRole, _CoverPresentation)? onPresentation,
) {
  onPresentation?.call(flight.role, frame);
  final t = frame.blend.clamp(0.0, 1.0);
  // Keep differently wrapped paragraphs from remaining superimposed for most
  // of the flight. Both ends are fully opaque well before geometry settles.
  final blend = Curves.easeInOutQuint.transform(t);
  Widget label(_CoverTextEndpoint endpoint, double opacity) => Opacity(
    opacity: opacity,
    child: FittedBox(
      fit: BoxFit.contain,
      alignment: Alignment.topLeft,
      child: endpoint.paragraph,
    ),
  );
  return Positioned.fromRect(
    rect: frame.rect,
    child: Stack(
      key: ValueKey('cover-transition-text-${flight.role.name}'),
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [label(flight.source, 1 - blend), label(flight.target, blend)],
    ),
  );
}
