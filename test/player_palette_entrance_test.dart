import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/animation/motion_snapshot.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/ui/background.dart';

Track _track(String url) => Track(
  id: url,
  title: 'Palette',
  artist: 'Artist',
  album: 'Album',
  duration: const Duration(minutes: 3),
  coverSeed: 150,
  coverUrl: url,
);

Future<void> _redCover(File file) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawPaint(Paint()..color = const Color(0xffee2222));
  final picture = recorder.endRecording();
  final image = await picture.toImage(32, 32);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await file.writeAsBytes(data!.buffer.asUint8List());
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Future<(int, int)> _colors(WidgetTester tester, GlobalKey key) async =>
    (await tester.runAsync(() async {
      final image =
          await (key.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage();
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final pixels = data!.buffer.asUint8List();
        var red = 0, blue = 0;
        for (var i = 0; i < pixels.length; i += 64) {
          red += pixels[i];
          blue += pixels[i + 2];
        }
        return (red, blue);
      } finally {
        image.dispose();
      }
    }))!;

void main() {
  testWidgets(
    'opening a player paints its cached artwork palette on the first frame',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'lazer-open-palette-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final file = File('${directory.path}/red.png');
      await tester.runAsync(() async {
        await _redCover(file);
        expect(await albumPaletteForCover(file.uri.toString()), isNotNull);
      });
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: boundary,
            child: AlbumBlurFlow(
              track: _track(file.uri.toString()),
              mode: AppBackgroundMode.nowPlayingDynamic,
              pageColor: Colors.black,
            ),
          ),
        ),
      );
      final color = await _colors(tester, boundary);
      expect(color.$1, greaterThan(color.$2 * 2));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a late palette refreshes frozen entrance pixels before the slide ends',
    (tester) async {
      final palette = Completer<AlbumCoverPalette?>();
      final motion = AnimationController(
        vsync: tester,
        duration: const Duration(seconds: 2),
      );
      addTearDown(motion.dispose);
      motion.forward();
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: boundary,
            child: MotionSnapshot(
              animation: motion,
              child: AlbumBlurFlow(
                track: _track('https://cover.test/entrance'),
                mode: AppBackgroundMode.nowPlayingDynamic,
                pageColor: Colors.black,
                preview: true,
                animationsEnabled: false,
                paletteLoader: (_) => palette.future,
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 80));
      palette.complete(
        AlbumCoverPalette(
          seed: Colors.blue,
          mesh: List.filled(5, const Color(0xff2222ee)),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(motion.isAnimating, isTrue);
      final color = await _colors(tester, boundary);
      expect(color.$2, greaterThan(color.$1 * 2));
      motion.stop();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
