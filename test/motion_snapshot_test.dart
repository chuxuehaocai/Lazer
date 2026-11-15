import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/animation/motion_snapshot.dart';

void main() {
  testWidgets('keyboard metrics release a frozen full-window snapshot', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    addTearDown(tester.view.reset);
    final motion = AnimationController.unbounded(vsync: tester)..value = .3;
    addTearDown(motion.dispose);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: boundary,
          child: MotionSnapshot(
            animation: motion,
            child: const Scaffold(
              backgroundColor: Colors.blue,
              body: SizedBox.expand(child: ColoredBox(color: Colors.red)),
            ),
          ),
        ),
      ),
    );
    final snapshot = tester.widget<SnapshotWidget>(find.byType(SnapshotWidget));
    expect(snapshot.controller.allowSnapshotting, isTrue);
    tester.view.viewInsets = const FakeViewPadding();
    await tester.pump();
    expect(snapshot.controller.allowSnapshotting, isFalse);
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await render.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final pixel = (550 * image.width + 400) * 4;
      expect(bytes!.getUint8(pixel), Colors.red.r * 255);
      expect(bytes.getUint8(pixel + 2), Colors.red.b * 255);
      image.dispose();
    });
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('snapshot policy changes take effect without a new animation', (
    tester,
  ) async {
    final motion = AnimationController.unbounded(vsync: tester)..value = .3;
    addTearDown(motion.dispose);
    Widget host(bool enabled) => MaterialApp(
      home: MotionSnapshot(
        animation: motion,
        snapshotForward: enabled,
        child: const Text('page'),
      ),
    );
    await tester.pumpWidget(host(true));
    final snapshot = tester.widget<SnapshotWidget>(find.byType(SnapshotWidget));
    expect(snapshot.controller.allowSnapshotting, isTrue);
    await tester.pumpWidget(host(false));
    expect(snapshot.controller.allowSnapshotting, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('transition raster is bounded without changing child DPI', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(2400, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final motion = AnimationController.unbounded(vsync: tester)..value = .3;
    addTearDown(motion.dispose);
    double? childDpr;
    await tester.pumpWidget(
      MaterialApp(
        home: MotionSnapshot(
          animation: motion,
          child: Builder(
            builder: (context) {
              childDpr = MediaQuery.devicePixelRatioOf(context);
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    final snapshot = find.byType(SnapshotWidget);
    final ratio = MediaQuery.devicePixelRatioOf(tester.element(snapshot));
    final size = tester.getSize(snapshot);
    final pixels = size.width * size.height * ratio * ratio;
    expect(pixels, closeTo(2000000, .01));
    expect(childDpr, 2);
    debugPrint('Transition RGBA budget: 15360000 -> 8000000 bytes');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
