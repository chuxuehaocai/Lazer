import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:window_manager/window_manager.dart';

import '../animation/apple_spring.dart';
import '../state/app_state.dart';
import '../state/ui_preferences.dart';
import '../tv/tv_mode.dart';
import 'window_chrome.dart';
import 'window_title_area.dart';

export 'window_title_area.dart';

/// Whether this run draws its own window frame instead of the system one.
/// Off on web/mobile and under `flutter test` — goldens cover page content
/// only, and no plugin channel is ever touched from the test runtime.
final bool kCustomWindowFrame =
    !kIsWeb &&
    (Platform.isWindows || Platform.isMacOS || Platform.isLinux) &&
    !Platform.environment.containsKey('FLUTTER_TEST');

/// Strips the system title bar before the first frame reaches the screen. The
/// runner only shows the window once Flutter has rendered, so the native bar
/// never flashes. No-op off desktop and under tests.
Future<void> initWindowFrame({bool preventClose = false}) async {
  if (!kCustomWindowFrame) return;
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: usesNativeWindowButtons,
    ),
  );
  if (Platform.isWindows) {
    await windowManager.setAsFrameless();
    // Keep the DWM frame on Windows: it is what supplies the drop shadow and
    // the Windows 11 rounded corners. Turning it off (the previous behaviour)
    // left the window a flat white rectangle with no edge against the equally
    // white desktop behind it.
    await windowManager.setHasShadow(true);
  } else if (Platform.isMacOS) {
    await windowManager.setHasShadow(false);
  }
  await windowManager.setTitle(kWindowTitle);
  if (preventClose) {
    await syncWindowPreventClose(true);
  }
}

/// Synchronizes the native preventClose flag on platforms with custom window frame.
Future<void> syncWindowPreventClose(bool preventClose) async {
  if (!kCustomWindowFrame) return;
  try {
    await windowManager.setPreventClose(preventClose);
  } catch (_) {}
}

/// Places the independent title area above the whole app (outside the
/// Navigator, so pushed routes and the now-playing page never cover it).
///
/// The strip carries the window title and — on Windows and Linux — the
/// minimize, fullscreen and close buttons. macOS keeps its native traffic
/// lights in the same strip. Falls through to the plain child wherever the
/// system frame is in charge.
class WindowFrame extends StatefulWidget {
  const WindowFrame({
    super.key,
    required this.child,
    this.state,
    this.navigatorKey,
    this.enabled,
  });

  final Widget child;
  final AppState? state;
  final GlobalKey<NavigatorState>? navigatorKey;

  /// Override frame availability for embedded previews and widget tests.
  final bool? enabled;

  @override
  State<WindowFrame> createState() => _WindowFrameState();
}

class _WindowFrameState extends State<WindowFrame>
    with TickerProviderStateMixin {
  static const _spring = AppleSpring(
    duration: Duration(milliseconds: 500),
    bounce: .08,
  );

  late final WindowChromeController _chrome = WindowChromeController(
    vsync: this,
  );
  late final _reveal = AnimationController.unbounded(vsync: this, value: 1);
  bool _revealTarget = true;
  double _extensionWidth = 0;

  /// Serialized capsule paint settings. The frame owns the material every
  /// capsule in the window paints, so a page that draws its own capsule has to
  /// be rebuilt when the listener changes the tint, the opacity or the blur —
  /// and must not be rebuilt on every unrelated state notification, which would
  /// re-run the backdrop filter for nothing.
  late String _capsuleKey = _currentCapsuleKey();
  bool _capsuleRebuildScheduled = false;

  String _currentCapsuleKey() {
    final AppState? state = widget.state;
    if (state == null) return '';
    // The tint resolves from [windowChromeColor] or the theme's own background,
    // which is fixed per brightness: neither the accent nor the palette mode
    // repaints a capsule, and both already rebuild the app root.
    return <Object?>[
      state.windowChromeBlurEnabled,
      state.windowChromeBlur,
      state.windowChromeOpacity,
      state.windowChromeColor?.toARGB32(),
    ].join('|');
  }

  void _onStateChanged() {
    if (!mounted) return;
    final String key = _currentCapsuleKey();
    if (key == _capsuleKey) return;
    _capsuleKey = key;
    // Pages report state from build. Calling setState on the frame while the
    // framework is already building throws, so take that report on the frame
    // that is running instead.
    final SchedulerPhase phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks) {
      if (_capsuleRebuildScheduled) return;
      _capsuleRebuildScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _capsuleRebuildScheduled = false;
        if (mounted) setState(() {});
      });
      return;
    }
    setState(() {});
  }

  bool get _inline =>
      widget.state?.titleBarStyle == DesktopTitleBarStyle.inline &&
      !usesNativeWindowButtons;

  bool get _revealVisible => _inline ? !_chrome.actionsExpanded : _chrome.value;

  bool get _captionVisible => _inline || _chrome.value;

  bool _phoneLayout(BuildContext context) {
    final state = widget.state;
    if (state == null ||
        largeScreenModeOf(context) ||
        state.layoutStyle == AppLayoutStyle.tv) {
      return false;
    }
    final width = MediaQuery.sizeOf(context).width;
    return useCompactLayout(
      state.uiMode,
      width,
      layoutStyle: state.layoutStyle,
    );
  }

  @override
  void initState() {
    super.initState();
    widget.state?.addListener(_onStateChanged);
    _chrome.addListener(_chromeChanged);
    // The pill's leading extension travels with the handover: it narrows
    // behind the command that is leaving and only grows again once the next
    // set starts arriving, so the surface never promises buttons it is not
    // painting.
    _chrome.handover?.addListener(_chromeChanged);
    _reveal.addListener(_revealChanged);
    _revealChanged();
  }

  /// Keeps the controller informed of how far the capsule is unfolded, so it
  /// can tell a real handover on screen from one hidden inside a collapse.
  void _revealChanged() => _chrome.syncRevealed(math.max(0, 1 - _reveal.value));

  void _chromeChanged() {
    if (!mounted) return;
    final double painted = _chrome.paintedActionsWidth;
    if (painted > 0) _extensionWidth = painted;
    _retarget();
    setState(() {});
  }

  bool _retarget() {
    final bool visible = _revealVisible;
    if (_revealTarget == visible) return false;
    _revealTarget = visible;
    _reveal.springTo(
      visible ? 1 : 0,
      spring: _spring,
      reduceMotion: MediaQuery.disableAnimationsOf(context),
    );
    return true;
  }

  @override
  void didUpdateWidget(covariant WindowFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.state != oldWidget.state) {
      oldWidget.state?.removeListener(_onStateChanged);
      widget.state?.addListener(_onStateChanged);
      _capsuleKey = _currentCapsuleKey();
    }
    _retarget();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _chrome.syncReduceMotion(MediaQuery.disableAnimationsOf(context));
    if (MediaQuery.disableAnimationsOf(context)) {
      _revealTarget = _revealVisible;
      _reveal.value = _revealTarget ? 1 : 0;
    }
  }

  @override
  void dispose() {
    widget.state?.removeListener(_onStateChanged);
    _chrome.removeListener(_chromeChanged);
    _chrome.handover?.removeListener(_chromeChanged);
    _reveal.removeListener(_revealChanged);
    _chrome.dispose();
    _reveal.dispose();
    super.dispose();
  }

  Widget _title({
    required bool inline,
    required bool visible,
    double leadingWidth = 0,
  }) => Listener(
    onPointerDown: (event) => _chrome.pointerDown(event.pointer),
    onPointerUp: (event) => _chrome.pointerUp(event.pointer),
    onPointerCancel: (event) => _chrome.pointerUp(event.pointer),
    child: WindowTitleArea(
      state: widget.state,
      navigatorKey: widget.navigatorKey,
      inline: inline,
      leadingWidth: leadingWidth,
      visible: visible,
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (!(widget.enabled ?? kCustomWindowFrame)) return widget.child;
    final bool inline = _inline;
    // Native macOS traffic lights remain visible outside Flutter, so their
    // title strip must keep its space even when the page uses a phone layout.
    final bool showChrome = usesNativeWindowButtons || !_phoneLayout(context);
    final bool captionVisible = showChrome && _captionVisible;
    final Widget title = inline
        ? AnimatedBuilder(
            animation: _reveal,
            builder: (context, _) => _title(
              inline: true,
              visible: showChrome,
              leadingWidth: _extensionWidth * math.max(0, 1 - _reveal.value),
            ),
          )
        : _title(inline: false, visible: showChrome);
    return WindowChromeScope(
      controller: _chrome,
      inline: inline && showChrome,
      reveal: inline && showChrome ? _reveal : null,
      chromeTheme: Theme.of(context),
      capsule: windowChromeCapsuleStyleOf(widget.state),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Overlay.wrap(
          child: inline
              ? Stack(
                  fit: StackFit.expand,
                  children: [
                    // The page owns the whole window: it paints and scrolls
                    // underneath the capsule instead of starting below a
                    // reserved header band.
                    ClipRect(child: widget.child),
                    PositionedDirectional(
                      top: kWindowChromeTop,
                      end: kWindowChromeEnd,
                      child: ExcludeFocus(
                        excluding: !captionVisible,
                        child: ExcludeSemantics(
                          excluding: !captionVisible,
                          child: IgnorePointer(
                            ignoring: !captionVisible,
                            child: Opacity(
                              key: const ValueKey('window-chrome-fade'),
                              opacity: 1,
                              child: title,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                )
              : Column(
                  children: <Widget>[
                    // Classic chrome is a strip of the window, not part of the
                    // page: it keeps its band while a presented player hides
                    // its own controls, exactly as it does around the native
                    // traffic lights. The player only owns the capsule in
                    // Inline chrome, where the strip is an overlay and has no
                    // height to give back.
                    title,
                    Expanded(child: ClipRect(child: widget.child)),
                  ],
                ),
        ),
      ),
    );
  }
}
