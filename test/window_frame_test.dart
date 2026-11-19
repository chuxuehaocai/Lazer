import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/widgets/apple_ui.dart';
import 'package:lazer_nextgen/widgets/window_chrome.dart';
import 'package:lazer_nextgen/widgets/window_frame.dart';

const _backdropColor = Color(0xffff00ff);
const _titleColor = Color(0xff101010);
const _bodyKey = ValueKey('frame-body');
const _contentKey = ValueKey('safe-content');
const _minimizeKey = ValueKey('window-title-minimize');
const _windowChannel = MethodChannel('window_manager');

/// Intentionally paints outside its layout bounds, as a blurred/transformed
/// background can. The frame must clip this below the classic title bar.
class _OverflowingBackdrop extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) => canvas.drawRect(
    Rect.fromLTRB(-100, -100, size.width + 100, size.height + 100),
    Paint()..color = _backdropColor,
  );

  @override
  bool shouldRepaint(_OverflowingBackdrop oldDelegate) => false;
}

class _FrameHarness {
  _FrameHarness(this.tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _windowChannel,
      (call) async {
        windowCalls.add(call.method);
        return switch (call.method) {
          'isMaximized' || 'isFullScreen' => false,
          'isFocused' => true,
          _ => null,
        };
      },
    );
  }

  final WidgetTester tester;
  final state = AppState();
  final captureKey = GlobalKey();
  final windowCalls = <String>[];
  MediaQueryData? bodyMedia;
  int bodyTaps = 0;

  Future<void> mount(DesktopTitleBarStyle style) async {
    state.titleBarStyle = style;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: const ColorScheme.light(surface: _titleColor),
        ),
        home: RepaintBoundary(
          key: captureKey,
          child: ListenableBuilder(
            listenable: state,
            builder: (context, _) => WindowFrame(
              enabled: true,
              state: state,
              child: Builder(
                builder: (context) {
                  bodyMedia = MediaQuery.of(context);
                  return GestureDetector(
                    key: _bodyKey,
                    behavior: HitTestBehavior.opaque,
                    onTap: () => bodyTaps++,
                    child: CustomPaint(
                      painter: _OverflowingBackdrop(),
                      child: const SafeArea(
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: SizedBox(
                            key: _contentKey,
                            width: 20,
                            height: 20,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<Color> pixel(int x, int y) async {
    final boundary =
        captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    return (await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final offset = (y * image.width + x) * 4;
        return Color.fromARGB(
          bytes.getUint8(offset + 3),
          bytes.getUint8(offset),
          bytes.getUint8(offset + 1),
          bytes.getUint8(offset + 2),
        );
      } finally {
        image.dispose();
      }
    }))!;
  }

  Future<void> expectCaptionsAccessible() async {
    for (final name in ['minimize', 'fullscreen', 'close']) {
      expect(
        find.byKey(ValueKey('window-title-$name')).hitTestable(),
        findsOneWidget,
      );
    }
    final center = tester.getCenter(find.byKey(_minimizeKey));
    expect(
      await pixel(center.dx.floor(), center.dy.floor()),
      isNot(_backdropColor),
    );
    await tester.tap(find.byKey(_minimizeKey));
    await tester.pumpAndSettle();
    expect(windowCalls.where((call) => call == 'minimize'), hasLength(1));
    expect(bodyTaps, 0);
  }

  Future<void> dispose() async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _windowChannel,
      null,
    );
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'macOS keeps native title space in automatic and forced phone layouts',
    (tester) async {
      tester.view.physicalSize = const Size(475, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final harness = _FrameHarness(tester);
      try {
        await harness.mount(DesktopTitleBarStyle.inline);
        for (final layout in [AppLayoutStyle.auto, AppLayoutStyle.phone]) {
          await harness.state.setLayoutStyle(layout);
          await tester.pumpAndSettle();
          expect(tester.getSize(find.byType(WindowTitleArea)).height, 40);
          expect(tester.getTopLeft(find.byKey(_bodyKey)).dy, 40);
          expect(tester.getTopLeft(find.byKey(_contentKey)).dy, 40);
          expect(find.byKey(_minimizeKey), findsNothing);
          expect(tester.takeException(), isNull);
        }
      } finally {
        await harness.dispose();
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  for (final style in DesktopTitleBarStyle.values) {
    testWidgets('$style keeps captions above clipped page content', (
      tester,
    ) async {
      final harness = _FrameHarness(tester);
      try {
        await harness.mount(style);
        final inline = style == DesktopTitleBarStyle.inline;
        // Inline chrome floats: the page starts at the window's top edge and
        // keeps no reserved band, so no MediaQuery inset is fabricated either.
        expect(tester.getTopLeft(find.byKey(_bodyKey)).dy, inline ? 0 : 40);
        expect(tester.getTopLeft(find.byKey(_contentKey)).dy, inline ? 0 : 40);
        expect(harness.bodyMedia!.padding.top, 0);
        expect(harness.bodyMedia!.viewPadding.top, 0);
        if (inline) {
          expect(
            tester.getTopLeft(find.byKey(_minimizeKey)).dy,
            kWindowChromeTop,
          );
          expect(
            tester.getTopRight(find.byKey(_minimizeKey)).dx,
            lessThanOrEqualTo(1280 - kWindowChromeEnd),
          );
        }
        // The same overflowing page paint must extend under Inline chrome,
        // while the classic strip remains entirely outside its paint bounds.
        expect(
          await harness.pixel(300, 10),
          inline ? _backdropColor : _titleColor,
        );
        expect(await harness.pixel(300, 60), _backdropColor);
        await harness.expectCaptionsAccessible();
      } finally {
        await harness.dispose();
      }
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('$style hides phone chrome without losing native close', (
      tester,
    ) async {
      final harness = _FrameHarness(tester);
      harness.state.layoutStyle = AppLayoutStyle.desktop;
      harness.state.desktopCloseAction = DesktopCloseAction.background;
      try {
        await harness.mount(style);
        final titleState = tester.state(find.byType(WindowTitleArea));

        await harness.state.setLayoutStyle(AppLayoutStyle.phone);
        await tester.pumpAndSettle();
        for (final name in ['minimize', 'fullscreen', 'close']) {
          expect(find.byKey(ValueKey('window-title-$name')), findsNothing);
        }
        expect(tester.getTopLeft(find.byKey(_bodyKey)).dy, 0);
        expect(tester.getTopLeft(find.byKey(_contentKey)).dy, 0);
        expect(harness.bodyMedia!.padding.top, 0);
        expect(harness.bodyMedia!.viewPadding.top, 0);
        final scope = tester.widget<WindowChromeScope>(
          find.byType(WindowChromeScope),
        );
        expect(scope.inline, isFalse);
        expect(scope.reveal, isNull);

        // Windows still dispatches a native close while its buttons are hidden.
        harness.windowCalls.clear();
        for (final listener in windowManager.listeners) {
          listener.onWindowClose();
        }
        await tester.pumpAndSettle();
        expect(harness.windowCalls, contains('hide'));

        await harness.state.setLayoutStyle(AppLayoutStyle.desktop);
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(WindowTitleArea)), same(titleState));
        expect(find.byKey(_minimizeKey).hitTestable(), findsOneWidget);
        expect(
          tester.getTopLeft(find.byKey(_contentKey)).dy,
          style == DesktopTitleBarStyle.inline ? 0 : 40,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await harness.dispose();
      }
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  }

  testWidgets('automatic phone chrome follows resizing and layout overrides', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(475, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final harness = _FrameHarness(tester);
    try {
      await harness.mount(DesktopTitleBarStyle.inline);
      expect(find.byKey(_minimizeKey), findsNothing);
      expect(tester.getTopLeft(find.byKey(_contentKey)).dy, 0);

      // Phone and tablet ranges are exclusive, including explicit desktop.
      tester.view.physicalSize = const Size(650, 900);
      await tester.pumpAndSettle();
      expect(find.byKey(_minimizeKey), findsNothing);
      expect(tester.getTopLeft(find.byKey(_contentKey)).dy, 0);

      tester.view.physicalSize = const Size(475, 900);
      await tester.pumpAndSettle();
      expect(find.byKey(_minimizeKey), findsNothing);
      await harness.state.setLayoutStyle(AppLayoutStyle.desktop);
      await tester.pumpAndSettle();
      expect(find.byKey(_minimizeKey), findsNothing);
      expect(tester.getTopLeft(find.byKey(_contentKey)).dy, 0);
      tester.view.physicalSize = const Size(720, 900);
      await tester.pumpAndSettle();
      expect(find.byKey(_minimizeKey).hitTestable(), findsOneWidget);
      expect(tester.getTopLeft(find.byKey(_contentKey)).dy, 0);
      expect(tester.takeException(), isNull);
    } finally {
      await harness.dispose();
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('title preference changes move content on the next frame', (
    tester,
  ) async {
    final harness = _FrameHarness(tester);
    try {
      await harness.mount(DesktopTitleBarStyle.classic);
      expect(tester.getTopLeft(find.byKey(_contentKey)).dy, 40);
      await harness.state.setTitleBarStyle(DesktopTitleBarStyle.inline);
      await tester.pump();
      expect(tester.getTopLeft(find.byKey(_bodyKey)).dy, 0);
      // Inline releases the strip entirely: the page already fills the top.
      expect(tester.getTopLeft(find.byKey(_contentKey)).dy, 0);
      expect(
        tester.widget<WindowTitleArea>(find.byType(WindowTitleArea)).inline,
        true,
      );
      await harness.state.setTitleBarStyle(DesktopTitleBarStyle.classic);
      await tester.pump();
      expect(tester.getTopLeft(find.byKey(_bodyKey)).dy, 40);
      expect(tester.getTopLeft(find.byKey(_contentKey)).dy, 40);
      expect(
        tester.widget<WindowTitleArea>(find.byType(WindowTitleArea)).inline,
        false,
      );
      await tester.pumpAndSettle();
    } finally {
      await harness.dispose();
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('a presented player cannot fold the classic strip away', (
    tester,
  ) async {
    final harness = _FrameHarness(tester);
    final controls = ValueNotifier<bool>(true);
    addTearDown(controls.dispose);
    try {
      await harness.mount(DesktopTitleBarStyle.classic);
      final controller = tester
          .widget<WindowChromeScope>(find.byType(WindowChromeScope))
          .controller;
      addTearDown(() => controller.detach(controls));
      // Stand-in for the now-playing page: its idle countdown hides the player
      // controls through the same controller the frame exposes.
      controller.attach(controls);
      controls.value = false;
      await tester.pumpAndSettle();

      expect(controller.value, isFalse);
      // The strip is window chrome with a real band. Hiding the page's own
      // controls may not take the strip — or the page's top edge — away.
      expect(tester.getSize(find.byType(WindowTitleArea)).height, 40);
      expect(tester.getTopLeft(find.byKey(_bodyKey)).dy, 40);
      expect(tester.getTopLeft(find.byKey(_contentKey)).dy, 40);
      expect(await harness.pixel(300, 10), _titleColor);
      await harness.expectCaptionsAccessible();
      expect(tester.takeException(), isNull);
    } finally {
      await harness.dispose();
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('the floating capsule paints the settings it is given', (
    tester,
  ) async {
    const Color custom = Color(0xFF3366FF);
    final harness = _FrameHarness(tester);
    Finder capsuleGlass() => find.descendant(
      of: find.byType(WindowChromeSurface),
      matching: find.byType(AppleGlass),
    );
    try {
      await harness.mount(DesktopTitleBarStyle.inline);

      // Default: the theme accent washed into the glass, blurred at the
      // default strength, no custom colour.
      final AppleSemanticColors apple = AppleSemanticColors.of(
        tester.element(find.byType(WindowChromeSurface)),
      );
      expect(
        tester.widget<AppleGlass>(capsuleGlass()).color,
        windowChromeTint(apple, opacity: kWindowChromeOpacityDefault),
      );
      expect(
        tester.widget<AppleGlass>(capsuleGlass()).blurSigma,
        kWindowChromeBlurDefault,
      );

      await harness.state.setWindowChromeColor(custom);
      await harness.state.setWindowChromeOpacity(.5);
      await harness.state.setWindowChromeBlur(24);
      await tester.pumpAndSettle();
      expect(
        tester.widget<AppleGlass>(capsuleGlass()).color,
        custom.withValues(alpha: .5),
      );
      expect(tester.widget<AppleGlass>(capsuleGlass()).blurSigma, 24);

      // Blur off paints the same tint without a backdrop filter at all.
      await harness.state.setWindowChromeBlurEnabled(false);
      await tester.pumpAndSettle();
      expect(capsuleGlass(), findsNothing);
      final DecoratedBox box = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(WindowChromeSurface),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      expect((box.decoration as BoxDecoration).color, custom.withValues(alpha: .5));
      expect(tester.takeException(), isNull);
    } finally {
      await harness.dispose();
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
