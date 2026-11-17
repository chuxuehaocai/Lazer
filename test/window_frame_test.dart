import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
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

  for (final style in DesktopTitleBarStyle.values) {
    testWidgets('$style keeps captions above clipped page content', (
      tester,
    ) async {
      final harness = _FrameHarness(tester);
      try {
        await harness.mount(style);
        final inline = style == DesktopTitleBarStyle.inline;
        expect(tester.getTopLeft(find.byKey(_bodyKey)).dy, inline ? 0 : 40);
        expect(tester.getTopLeft(find.byKey(_contentKey)).dy, inline ? 46 : 40);
        expect(harness.bodyMedia!.padding.top, inline ? 46 : 0);
        expect(harness.bodyMedia!.viewPadding.top, inline ? 46 : 0);
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
  }

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
      expect(tester.getTopLeft(find.byKey(_contentKey)).dy, 46);
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
}
