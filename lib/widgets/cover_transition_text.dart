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
final Map<String, Set<CoverTextRole>> _hiddenTargetText = {};

class _CoverTransitionTextState extends State<CoverTransitionText>
    with BuildSafeState<CoverTransitionText> {
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
    _hidden =
        _hiddenTargetText[widget.identity]?.contains(widget.role) ?? false;
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
      _hidden =
          _hiddenTargetText[widget.identity]?.contains(widget.role) ?? false;
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
  final selected = roles?.toList() ?? CoverTextRole.values;
  if (hidden) {
    (_hiddenTargetText[identity] ??= {}).addAll(selected);
  } else {
    _hiddenTargetText[identity]?.removeAll(selected);
    if (_hiddenTargetText[identity]?.isEmpty ?? false) {
      _hiddenTargetText.remove(identity);
    }
  }
  final entries = _targetText[identity];
  if (entries == null) return;
  for (final role in selected) {
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

// Children keep their original paragraph constraints. Only their retained
// paint layers follow the flight; animation ticks never relayout the labels.
class _CoverTextSurface extends MultiChildRenderObjectWidget {
  _CoverTextSurface({
    required this.animation,
    required this.presentation,
    required _CoverTextFlight flight,
  }) : super(children: [flight.source.paragraph, flight.target.paragraph]);
  final Animation<double> animation;
  final _CoverPresentation Function() presentation;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderCoverTextSurface(animation, presentation);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderCoverTextSurface renderObject,
  ) {
    renderObject
      ..animation = animation
      ..presentation = presentation;
  }
}

class _CoverTextParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderCoverTextSurface extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _CoverTextParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _CoverTextParentData> {
  _RenderCoverTextSurface(this._animation, this._presentation);
  Animation<double> _animation;
  _CoverPresentation Function() _presentation;
  final _frameLayer = LayerHandle<TransformLayer>();
  final _transforms = List.generate(2, (_) => LayerHandle<TransformLayer>());
  final _opacities = List.generate(2, (_) => LayerHandle<OpacityLayer>());

  set animation(Animation<double> value) {
    if (_animation == value) return;
    if (attached) _animation.removeListener(markNeedsPaint);
    _animation = value;
    if (attached) _animation.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  set presentation(_CoverPresentation Function() value) {
    _presentation = value;
    markNeedsPaint();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _CoverTextParentData) {
      child.parentData = _CoverTextParentData();
    }
  }

  @override
  void performLayout() {
    size = constraints.biggest;
    RenderBox? child = firstChild;
    while (child != null) {
      child.layout(const BoxConstraints(), parentUsesSize: true);
      child = childAfter(child);
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _animation.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _animation.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void dispose() {
    _frameLayer.layer = null;
    for (final handle in _transforms) {
      handle.layer = null;
    }
    for (final handle in _opacities) {
      handle.layer = null;
    }
    super.dispose();
  }

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    final frame = _presentation();
    final rect = frame.rect;
    if (size.isEmpty || rect.isEmpty) return;
    final blend = frame.blend.clamp(0.0, 1.0);
    // The enclosing Flow maps our fixed box to the flight rectangle. Undo its
    // nonuniform scale before fitting each paragraph at its natural aspect.
    _frameLayer.layer = context.pushTransform(
      true,
      offset,
      Matrix4.diagonal3Values(
        size.width / rect.width,
        size.height / rect.height,
        1,
      ),
      (frameContext, frameOffset) {
        RenderBox? child = firstChild;
        for (var i = 0; child != null; i++) {
          final current = child;
          final alpha = ((i == 0 ? 1 - blend : blend) * 255).round();
          if (alpha > 0 && !current.size.isEmpty) {
            final scale = math.min(
              rect.width / current.size.width,
              rect.height / current.size.height,
            );
            _opacities[i].layer = frameContext.pushOpacity(frameOffset, alpha, (
              opacityContext,
              opacityOffset,
            ) {
              _transforms[i].layer = opacityContext.pushTransform(
                true,
                opacityOffset,
                Matrix4.diagonal3Values(scale, scale, 1),
                (textContext, textOffset) =>
                    textContext.paintChild(current, textOffset),
                oldLayer: _transforms[i].layer,
              );
            }, oldLayer: _opacities[i].layer);
          } else {
            _opacities[i].layer = null;
          }
          child = childAfter(current);
        }
      },
      oldLayer: _frameLayer.layer,
    );
  }
}
