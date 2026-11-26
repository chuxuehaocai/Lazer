import 'build_safe_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import '../state/app_state.dart';
import '../theme/apple_design.dart';
import '../theme/lazer_theme.dart';
import 'haptic_seek_slider.dart';

/// The tones the seek rail paints with, resolved once per build.
///
/// The rail has to work on two very different canvases.
///
/// * The built-in player draws it straight on the cover-art wash (a dark,
///   unpredictable image). White is the only ink that survives that, so
///   [PlayerSeekInk.wash] keeps exactly the tones the rail always had.
/// * A paper skin (`backgroundPlayMode == 'off'`) drops the wash and paints its
///   own page — parchment `#F0EEE6`. White on parchment is nothing: the buffered
///   lane at 68% white reads as a bright stripe, and the thumb, also white, has
///   no edge at all. [PlayerSeekInk.of] therefore reads the skin and paints the
///   rail in its `accent` (clay `#D97757`), the same tone the design system
///   reserves for the playhead.
@immutable
class PlayerSeekInk {
  const PlayerSeekInk({
    required this.active,
    required this.buffered,
    required this.inactive,
    required this.thumb,
    required this.overlay,
  });

  /// The lane between the start and the playhead.
  final Color active;

  /// The lane the player can accept a seek into. Material paints this from the
  /// playhead up to `secondaryTrackValue`, which the seek slider sets to the
  /// buffered limit — so on a playing track this is most of the visible rail.
  final Color buffered;

  /// The lane past that limit, where a seek would be rejected.
  final Color inactive;

  final Color thumb;

  /// The halo under the thumb while hovering or dragging.
  final Color overlay;

  /// One tone at four weights — the shape the rail has always had.
  factory PlayerSeekInk.mono(Color color) => PlayerSeekInk(
    active: color,
    buffered: color.withValues(alpha: .68),
    inactive: color.withValues(alpha: .32),
    thumb: color,
    overlay: color.withValues(alpha: .18),
  );

  /// White on the cover-art wash: the built-in Mio player, and every skin that
  /// still plays the album colour flow.
  static final PlayerSeekInk wash = PlayerSeekInk.mono(Colors.white);

  /// The accent the skin declared, for the brightness actually in effect.
  ///
  /// Deliberately the token, not `ColorScheme.primary`: [buildAppleTheme] runs
  /// that through `adaptiveAccent`, which drags an accent to 4.5:1 against the
  /// page because buttons and body text are inked with it. Clay on parchment is
  /// 2.7:1, so the button accent lands on `#B54B29` — brown. A 3 px rail is a
  /// graphic, not body copy; it should stay the clay the design system named.
  static Color _accent(BuildContext context) {
    final LazerThemeTokens skin = LazerThemeTokens.of(context);
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Map<String, Color> preferred = dark ? skin.darkColors : skin.colors;
    final Map<String, Color> fallback = dark ? skin.colors : skin.darkColors;
    return preferred['accent'] ??
        fallback['accent'] ??
        AppleSemanticColors.of(context).accent;
  }

  /// Resolves the rail for the skin mounted above [context].
  factory PlayerSeekInk.of(BuildContext context) {
    final LazerThemeTokens skin = LazerThemeTokens.of(context);
    if (skin.backgroundPlayMode != 'off') return wash;
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    // A paper skin's dark variant keeps a dark page, and white is still right
    // there. Only the light parchment page needs the clay.
    if (apple.background.computeLuminance() < .5) return wash;
    final Color clay = _accent(context);
    return PlayerSeekInk(
      active: clay,
      // 34% clay over parchment is `#E9CCBE`: unmistakably the same family as
      // the playhead, quiet enough that a 3 px rail stops being the brightest
      // line on the page.
      buffered: clay.withValues(alpha: .34),
      // Past the seek limit: the stone hairline the rest of the design uses for
      // dividers, so the rail never looks like a second, louder accent.
      inactive: apple.separator,
      thumb: clay,
      overlay: clay.withValues(alpha: .16),
    );
  }
}

/// Apple Music style rail: a plain bar over the player's canvas.
///
/// The rail stays thin at rest and swells on press, so the drag target is
/// comfortable without turning the rail into a heavy element on screen. Its ink
/// follows the surface underneath — see [PlayerSeekInk].
class PlayerSeekBar extends StatefulWidget {
  const PlayerSeekBar({
    super.key,
    required this.state,
    this.trackHeight = 4,
    this.thumbRadius = 7,
    this.color,
  });

  final AppState state;
  final double trackHeight, thumbRadius;

  /// One flat tone for the whole rail, expanded by [PlayerSeekInk.mono]. Left
  /// null, the rail follows the skin ([PlayerSeekInk.of]). The shell player bar
  /// passes `ColorScheme.primary` because it sits on the dark player surface
  /// rather than on the page.
  final Color? color;

  @override
  State<PlayerSeekBar> createState() => _PlayerSeekBarState();
}

class _PlayerSeekBarState extends State<PlayerSeekBar>
    with WidgetsBindingObserver, BuildSafeState<PlayerSeekBar> {
  bool _grabbing = false;
  Object? _grabSource;

  Object get _source =>
      (widget.state, widget.state.current?.id, widget.state.queueIndex);
  bool get _seekable =>
      widget.state.current != null &&
      widget.state.current!.duration > Duration.zero &&
      widget.state.seekLimitFraction > 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _setGrabbing(false);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _setGrabbing(bool value) {
    if (_grabbing == value) return;
    setState(() => _grabbing = value);
  }

  @override
  Widget build(BuildContext context) {
    // Leaf: the only part of Now Playing that consumes 100 ms ticks.
    final Color? flat = widget.color;
    final PlayerSeekInk ink = flat == null
        ? PlayerSeekInk.of(context)
        : PlayerSeekInk.mono(flat);
    return Listener(
      onPointerDown: (event) {
        if (_seekable && event.buttons == kPrimaryButton) {
          _grabSource = _source;
          _setGrabbing(true);
        }
      },
      onPointerUp: (_) => _setGrabbing(false),
      onPointerCancel: (_) => _setGrabbing(false),
      child: AnimatedBuilder(
        // TickerMode only mutes animation controllers, not position updates.
        animation: TickerMode.valuesOf(context).enabled
            ? widget.state.all
            : widget.state,
        builder: (BuildContext context, _) => SliderTheme(
          data: SliderThemeData(
            trackHeight: _grabbing && _grabSource == _source && _seekable
                ? widget.trackHeight + 3
                : widget.trackHeight,
            activeTrackColor: ink.active,
            secondaryActiveTrackColor: ink.buffered,
            inactiveTrackColor: ink.inactive,
            thumbColor: ink.thumb,
            overlayColor: ink.overlay,
            thumbShape: RoundSliderThumbShape(
              enabledThumbRadius:
                  _grabbing && _grabSource == _source && _seekable
                  ? widget.thumbRadius + 3
                  : widget.thumbRadius,
            ),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            trackShape: const RoundedRectSliderTrackShape(),
          ),
          child: HapticSeekSlider(state: widget.state),
        ),
      ),
    );
  }
}
