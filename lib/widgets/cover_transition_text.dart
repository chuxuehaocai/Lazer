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
  final Text child;

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

  _CoverTextEndpoint? measure() {
    if (!mounted || !_active || (widget.child.data ?? '').isEmpty) return null;
    final box = context.findRenderObject();
    if (box is! RenderBox ||
        !box.attached ||
        !box.hasSize ||
        box.size.isEmpty) {
      return null;
    }
    final rect = Rect.fromPoints(
      box.localToGlobal(Offset.zero),
      box.localToGlobal(box.size.bottomRight(Offset.zero)),
    );
    final text = widget.child;
    final style = DefaultTextStyle.of(context).style.merge(text.style);
    final scaler = text.textScaler ?? MediaQuery.textScalerOf(context);
    final scale = rect.height / box.size.height;
    return _CoverTextEndpoint(
      rect,
      text.data!,
      style.copyWith(
        fontSize: scaler.scale(style.fontSize ?? 14) * scale,
        letterSpacing: (style.letterSpacing ?? 0) * scale,
      ),
      text.textAlign ?? TextAlign.start,
      text.textDirection ?? Directionality.of(context),
      text.maxLines ?? 2,
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
  const _CoverTextEndpoint(
    this.rect,
    this.text,
    this.style,
    this.align,
    this.direction,
    this.lines,
  );
  final Rect rect;
  final String text;
  final TextStyle style;
  final TextAlign align;
  final TextDirection direction;
  final int lines;

  _CoverTextEndpoint inOverlay(RenderBox overlay) {
    final local = Rect.fromPoints(
      overlay.globalToLocal(rect.topLeft),
      overlay.globalToLocal(rect.bottomRight),
    );
    final scale = rect.height == 0 ? 1.0 : local.height / rect.height;
    return _CoverTextEndpoint(
      local,
      text,
      style.copyWith(
        fontSize: (style.fontSize ?? 14) * scale,
        letterSpacing: (style.letterSpacing ?? 0) * scale,
      ),
      align,
      direction,
      lines,
    );
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
      return state?.measure()?.inOverlay(overlay).rect;
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
  var style = TextStyle.lerp(flight.source.style, flight.target.style, t)!;
  final from = (flight.source.style.fontWeight ?? FontWeight.w400).value;
  final to = (flight.target.style.fontWeight ?? FontWeight.w400).value;
  final speed = frame.velocity.topLeft.distance;
  final weight =
      (ui.lerpDouble(from, to, t)! - 120 * (speed / 1600).clamp(0.0, 1.0))
          .clamp(100.0, 900.0);
  style = style.copyWith(
    fontWeight: FontWeight.lerp(
      FontWeight.w100,
      FontWeight.w900,
      (weight - 100) / 800,
    ),
    fontVariations: [
      for (final axis in style.fontVariations ?? const <ui.FontVariation>[])
        if (axis.axis != 'wght') axis,
      ui.FontVariation('wght', weight),
    ],
  );
  Widget label(_CoverTextEndpoint endpoint) => Text(
    endpoint.text,
    style: style,
    textAlign: endpoint.align,
    textDirection: endpoint.direction,
    textScaler: TextScaler.noScaling,
    maxLines: endpoint.lines,
    overflow: TextOverflow.ellipsis,
  );
  final identicalLayout =
      flight.source.text == flight.target.text &&
      flight.source.align == flight.target.align &&
      flight.source.lines == flight.target.lines;
  return Positioned.fromRect(
    rect: frame.rect,
    child: ClipRect(
      key: ValueKey('cover-transition-text-${flight.role.name}'),
      child: identicalLayout
          ? label(flight.target)
          : Stack(
              fit: StackFit.expand,
              children: [
                Opacity(opacity: 1 - t, child: label(flight.source)),
                Opacity(opacity: t, child: label(flight.target)),
              ],
            ),
    ),
  );
}
