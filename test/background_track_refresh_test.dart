import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/ui/background.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';

Future<void> _cover(File file, Color color) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawPaint(Paint()..color = color);
  final picture = recorder.endRecording();
  final image = await picture.toImage(32, 32);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  await file.writeAsBytes(data!.buffer.asUint8List());
  image.dispose();
  picture.dispose();
}

class _State extends AppState {
  Track? track;
  @override
  Track? get current => track;
  @override
  bool get playing => true;
  @override
  Future<void> ensureCurrentLyrics({bool force = false}) async {}
  void switchTo(Track value) {
    track = value;
    notifyListeners();
  }
}

Track _track(File file) => Track(
  id: file.path,
  title: 'Test',
  artist: 'Artist',
  album: 'Album',
  duration: const Duration(minutes: 3),
  coverSeed: 1,
  coverUrl: file.uri.toString(),
);

Future<(int, int)> _redBlue(WidgetTester tester, Finder boundary) async =>
    (await tester.runAsync(() async {
      final image =
          await (tester.renderObject(boundary) as RenderRepaintBoundary)
              .toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final pixels = data!.buffer.asUint8List();
      var red = 0, blue = 0;
      for (var offset = 0; offset < pixels.length; offset += 64) {
        red += pixels[offset];
        blue += pixels[offset + 2];
      }
      image.dispose();
      return (red, blue);
    }))!;

Future<void> _waitForPalette(WidgetTester tester, {required bool blue}) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final colors = tester
        .widget<AlbumFlowBackground>(find.byType(AlbumFlowBackground))
        .colors;
    if (colors.every((color) => blue ? color.b > color.r : color.r > color.b)) {
      return;
    }
  }
  fail(
    'The ${blue ? 'blue' : 'red'} artwork palette did not reach the mounted backdrop',
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'cold palette requests complete, share in-flight work and cache their result',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lazer-palette-future-',
      );
      try {
        final file = File('${root.path}/red.png');
        await _cover(file, const Color(0xffee2222));
        final first = albumPaletteForCover(file.uri.toString());
        final simultaneous = albumPaletteForCover(file.uri.toString());
        expect(identical(first, simultaneous), isTrue);
        final palette = await first.timeout(const Duration(seconds: 5));
        expect(palette, isNotNull);
        expect(palette!.seed.r, greaterThan(palette.seed.b));
        expect(await simultaneous, same(palette));
        expect(await albumPaletteForCover(file.uri.toString()), same(palette));
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test('an artwork decode failure can retry after the file arrives', () async {
    final root = await Directory.systemTemp.createTemp('lazer-palette-late-');
    try {
      final file = File('${root.path}/late.png');
      expect(
        await albumPaletteForCover(
          file.uri.toString(),
        ).timeout(const Duration(seconds: 5)),
        isNull,
      );
      await _cover(file, const Color(0xff2222ee));
      final palette = await albumPaletteForCover(
        file.uri.toString(),
      ).timeout(const Duration(seconds: 5));
      expect(palette, isNotNull);
      expect(palette!.seed.b, greaterThan(palette.seed.r));
    } finally {
      await root.delete(recursive: true);
    }
  });

  for (final player in [true, false]) {
    testWidgets(
      'a mounted ${player ? 'player' : 'browse page'} repaints its backdrop when artwork changes',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final root = Directory.systemTemp.createTempSync('lazer-palette-');
        addTearDown(() => root.deleteSync(recursive: true));
        final red = File('${root.path}/red.png'),
            blue = File('${root.path}/blue.png');
        await tester.runAsync(() async {
          await _cover(red, const Color(0xffee2222));
          await _cover(blue, const Color(0xff2222ee));
        });
        final state = _State()..switchTo(_track(red));
        addTearDown(state.dispose);
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            home: player
                ? NowPlayingPage(state: state)
                : AnimatedBuilder(
                    animation: state,
                    builder: (_, _) => RepaintBoundary(
                      key: boundaryKey,
                      child: AppAlbumBackdrop(
                        track: state.current,
                        mode: AppBackgroundMode.nowPlayingDynamic,
                        uiAlpha: 0,
                      ),
                    ),
                  ),
          ),
        );
        await _waitForPalette(tester, blue: false);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        final boundary = player
            ? find
                  .descendant(
                    of: find.byType(AlbumBlurFlow),
                    matching: find.byType(RepaintBoundary),
                  )
                  .first
            : find.byKey(boundaryKey);
        final before = await _redBlue(tester, boundary);
        expect(before.$1, greaterThan(before.$2));
        state.switchTo(_track(blue));
        await _waitForPalette(tester, blue: true);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        final after = await _redBlue(tester, boundary);
        expect(after.$2, greaterThan(after.$1));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
