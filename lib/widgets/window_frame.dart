import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
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
    with SingleTickerProviderStateMixin {
  static const _spring = AppleSpring(
    duration: Duration(milliseconds: 500),
    bounce: .08,
  );

  final WindowChromeController _chrome = WindowChromeController();
  late final _reveal = AnimationController.unbounded(vsync: this, value: 1);
  bool _revealTarget = true;
  double _extensionWidth = 0;

  bool get _inline =>
      widget.state?.titleBarStyle == DesktopTitleBarStyle.inline &&
      !usesNativeWindowButtons;

  bool get _revealVisible => _inline
      ? !(_chrome.playerPresented && _chrome.actionsActive)
      : _chrome.value;

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
    _chrome.addListener(_chromeChanged);
  }

  void _chromeChanged() {
    if (!mounted) return;
    if (_chrome.actionsWidth > 0) _extensionWidth = _chrome.actionsWidth;
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
    _retarget();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _revealTarget = _revealVisible;
      _reveal.value = _revealTarget ? 1 : 0;
    }
  }

  @override
  void dispose() {
    _chrome.removeListener(_chromeChanged);
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
    final MediaQueryData media = MediaQuery.of(context);
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
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Overlay.wrap(
          child: inline
              ? Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRect(
                      child: MediaQuery(
                        // Keep page geometry steady while the caption capsule
                        // extends. The player header consumes this inset itself.
                        data: showChrome
                            ? media.copyWith(
                                padding: media.padding.copyWith(top: 56),
                                viewPadding: media.viewPadding.copyWith(
                                  top: 56,
                                ),
                              )
                            : media,
                        child: widget.child,
                      ),
                    ),
                    Positioned(
                      top: 12,
                      left: 0,
                      right: 20,
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
                    // Native traffic lights stay outside Flutter's animation.
                    if (usesNativeWindowButtons)
                      title
                    else
                      WindowChromeTransition(
                        visible: _chrome.value,
                        child: title,
                      ),
                    Expanded(child: ClipRect(child: widget.child)),
                  ],
                ),
        ),
      ),
    );
  }
}
