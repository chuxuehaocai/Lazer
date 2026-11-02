import '../animation/apple_spring.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../l10n/app_localizations.dart';

/// Window title shown in the title area — also pushed to the native window so
/// the taskbar and Alt+Tab agree with the bar.
const String kWindowTitle = 'Lazer';

/// Height of the title area: 40px = 10 × the 4px base unit. Caption buttons are
/// 46px wide and fill that height, flush to the trailing edge the way native
/// system buttons sit.
const double kWindowTitleAreaHeight = 40;
const double kWindowCaptionButtonWidth = 46;
const double _glyphBox = 18;

/// Whether the platform draws its own caption buttons. macOS must keep its
/// native traffic lights in the leading corner; Windows and Linux draw the
/// app's own hairline glyphs on the trailing edge.
bool get usesNativeWindowButtons =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

/// Leading inset of the window title: clear of the macOS traffic lights,
/// quiet chrome padding everywhere else.
double get _titleInset => usesNativeWindowButtons ? 84 : 16;

/// The independent window title area: a fixed strip above every page that
/// holds the window title on the leading edge and — on Windows and Linux —
/// the minimize, fullscreen and close buttons on the trailing edge.
///
/// The strip is window chrome, not page content: the whole bar drags the
/// window and a double click toggles maximize ([DragToMoveArea] owns both). It
/// sits outside the navigator (see `WindowFrame`), so pushed routes and the
/// now-playing page never cover or move it.
class WindowTitleArea extends StatefulWidget {
  const WindowTitleArea({super.key});

  @override
  State<WindowTitleArea> createState() => _WindowTitleAreaState();
}

class _WindowTitleAreaState extends State<WindowTitleArea> with WindowListener {
  bool _maximized = false;
  bool _fullScreen = false;
  bool _focused = true;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    // A window restored from a saved maximized/fullscreen state must show the
    // restore glyph, not the fullscreen glyph. No window channel (tests,
    // headless capture): keep the windowed, focused shape.
    Future<void>(() async {
      try {
        final bool maximized = await windowManager.isMaximized();
        final bool fullScreen = await windowManager.isFullScreen();
        final bool focused = await windowManager.isFocused();
        if (!mounted) return;
        setState(() {
          _maximized = maximized;
          _fullScreen = fullScreen;
          _focused = focused;
        });
      } catch (_) {
        // Window state unavailable — assume the default windowed shape.
      }
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => _apply(maximized: true);

  @override
  void onWindowUnmaximize() => _apply(maximized: false);

  @override
  void onWindowEnterFullScreen() => _apply(fullScreen: true);

  @override
  void onWindowLeaveFullScreen() => _apply(fullScreen: false);

  @override
  void onWindowFocus() => _apply(focused: true);

  @override
  void onWindowBlur() => _apply(focused: false);

  void _apply({bool? maximized, bool? fullScreen, bool? focused}) {
    if (!mounted) return;
    setState(() {
      _maximized = maximized ?? _maximized;
      _fullScreen = fullScreen ?? _fullScreen;
      _focused = focused ?? _focused;
    });
  }

  /// Whether the window already fills the workspace, either maximized or in
  /// the player's fullscreen mode. The middle button reads as "全屏" until then
  /// and as "还原窗口" afterwards.
  bool get _expanded => _maximized || _fullScreen;

  Future<void> _toggleWindowSize() async {
    try {
      if (_fullScreen) {
        // The now-playing page can also enter fullscreen; the title button
        // exits it instead of stacking a maximize on top.
        await windowManager.setFullScreen(false);
      } else if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
      } else {
        await windowManager.maximize();
      }
    } catch (_) {
      // Ignore: the window may be gone mid-teardown.
    }
  }

  Future<void> _minimize() async {
    try {
      await windowManager.minimize();
    } catch (_) {
      // Ignore: the window may be gone mid-teardown.
    }
  }

  Future<void> _close() async {
    try {
      await windowManager.close();
    } catch (_) {
      // Ignore: the window may be gone mid-teardown.
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextStyle titleStyle =
        (theme.textTheme.labelMedium ?? const TextStyle()).copyWith(
          color: _focused
              ? scheme.onSurfaceVariant
              : scheme.onSurfaceVariant.withValues(alpha: .5),
          fontWeight: FontWeight.w400,
          letterSpacing: .2,
          decoration: TextDecoration.none,
        );
    final String middleLabel = context.tr(_expanded ? '还原窗口' : '全屏');

    return SizedBox(
      height: kWindowTitleAreaHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surface,
          // A hairline closes the chrome off from the page; never a shadow.
          border: Border(
            bottom: BorderSide(color: scheme.outlineVariant, width: .5),
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // The strip is chrome: drag from anywhere, double-click to
            // maximize. Buttons above it take their own taps first.
            const DragToMoveArea(child: SizedBox.expand()),
            IgnorePointer(
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Padding(
                  padding: EdgeInsetsDirectional.only(
                    start: _titleInset,
                    // Keep the label clear of the caption cluster.
                    end: usesNativeWindowButtons
                        ? 16
                        : kWindowCaptionButtonWidth * 3 + 12,
                  ),
                  child: AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 140),
                    style: titleStyle,
                    child: Text(
                      kWindowTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ),
            if (!usesNativeWindowButtons)
              PositionedDirectional(
                top: 0,
                end: 0,
                bottom: 0,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    _CaptionButton(
                      key: const ValueKey<String>('window-title-minimize'),
                      glyph: _CaptionGlyph.minimize,
                      label: context.tr('最小化'),
                      onPressed: _minimize,
                    ),
                    _CaptionButton(
                      key: const ValueKey<String>('window-title-fullscreen'),
                      glyph: _expanded
                          ? _CaptionGlyph.restore
                          : _CaptionGlyph.maximize,
                      label: middleLabel,
                      onPressed: _toggleWindowSize,
                    ),
                    _CaptionButton(
                      key: const ValueKey<String>('window-title-close'),
                      glyph: _CaptionGlyph.close,
                      label: context.tr('关闭窗口'),
                      onPressed: _close,
                      destructive: true,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

enum _CaptionGlyph { minimize, maximize, restore, close }

/// One caption button: flat fill, no radius, no shadow. Hover moves the tone
/// (a quiet gray for minimize/fullscreen, the error fill for close); press
/// deepens it. Glyphs stay hairline drawing so they read as system chrome.
class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    super.key,
    required this.glyph,
    required this.label,
    required this.onPressed,
    this.destructive = false,
  });

  final _CaptionGlyph glyph;
  final String label;
  final Future<void> Function() onPressed;
  final bool destructive;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hovering = false;
  bool _pressing = false;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color hover = widget.destructive
        ? scheme.error
        : scheme.onSurface.withValues(alpha: .07);
    final Color pressed = widget.destructive
        ? scheme.error.withValues(alpha: .82)
        : scheme.onSurface.withValues(alpha: .13);
    final Color fill = _pressing
        ? pressed
        : (_hovering ? hover : Colors.transparent);
    final Color glyph = widget.destructive && (_hovering || _pressing)
        ? scheme.onError
        : scheme.onSurfaceVariant;

    return Semantics(
      container: true,
      button: true,
      label: widget.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() {
          _hovering = false;
          _pressing = false;
        }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressing = true),
          onTapUp: (_) => setState(() => _pressing = false),
          onTapCancel: () => setState(() => _pressing = false),
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : AppleSpring.responsive.duration,
            curve: const AppleSpringCurve(),
            width: kWindowCaptionButtonWidth,
            height: kWindowTitleAreaHeight,
            color: fill,
            alignment: Alignment.center,
            child: SizedBox(
              width: _glyphBox,
              height: _glyphBox,
              child: CustomPaint(
                painter: _CaptionGlyphPainter(
                  glyph: widget.glyph,
                  color: glyph,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 1px hairline glyphs drawn on half-pixel seams so they stay crisp:
/// a bar, a square, the stacked pair for restore, a cross for close.
class _CaptionGlyphPainter extends CustomPainter {
  const _CaptionGlyphPainter({required this.glyph, required this.color});

  final _CaptionGlyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double cx = size.width / 2;
    final double cy = size.height / 2;
    final Paint stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    switch (glyph) {
      case _CaptionGlyph.minimize:
        canvas.drawLine(
          Offset(cx - 4.5, cy + 0.5),
          Offset(cx + 4.5, cy + 0.5),
          stroke,
        );
      case _CaptionGlyph.maximize:
        canvas.drawRect(
          Rect.fromLTRB(cx - 4.5, cy - 4.5, cx + 4.5, cy + 4.5),
          stroke,
        );
      case _CaptionGlyph.restore:
        // Back window shows only its top and right edges — the parts the
        // front square doesn't already cover.
        final Path back = Path()
          ..moveTo(cx - 1.5, cy - 7.5)
          ..lineTo(cx + 7.5, cy - 7.5)
          ..lineTo(cx + 7.5, cy + 1.5);
        canvas.drawPath(back, stroke);
        canvas.drawRect(
          Rect.fromLTRB(cx - 7.5, cy - 1.5, cx + 1.5, cy + 7.5),
          stroke,
        );
      case _CaptionGlyph.close:
        canvas.drawLine(
          Offset(cx - 4.5, cy - 4.5),
          Offset(cx + 4.5, cy + 4.5),
          stroke,
        );
        canvas.drawLine(
          Offset(cx + 4.5, cy - 4.5),
          Offset(cx - 4.5, cy + 4.5),
          stroke,
        );
    }
  }

  @override
  bool shouldRepaint(_CaptionGlyphPainter oldDelegate) =>
      oldDelegate.glyph != glyph || oldDelegate.color != color;
}
