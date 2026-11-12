import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/ui/background.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/widgets/artwork_image.dart';
import 'package:lazer_nextgen/widgets/shared_browse_background.dart';

class _State extends AppState {
  Track? track;
  @override
  Track? get current => track;

  void report() => notifyListeners();
}

const _first = Track(
  id: 'resource-first',
  title: 'First',
  artist: 'Artist',
  album: 'Album',
  coverSeed: 18,
  duration: Duration(minutes: 3),
);
const _second = Track(
  id: 'resource-second',
  title: 'Second',
  artist: 'Artist',
  album: 'Album',
  coverSeed: 210,
  duration: Duration(minutes: 3),
);

Future<void> _cover(File file, int width, int height) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawPaint(Paint()..color = const Color(0xffb62a58));
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await file.writeAsBytes(data!.buffer.asUint8List());
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Future<ui.Image> _displayDecode(ImageProvider provider) {
  final complete = Completer<ui.Image>();
  final stream = provider.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener((info, _) {
    complete.complete(info.image.clone());
    info.dispose();
    stream.removeListener(listener);
  }, onError: complete.completeError);
  stream.addListener(listener);
  return complete.future;
}

Future<Uint8List> _pixels(ui.Image image) async {
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return bytes!.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
}

Color _vividReference(Color color) {
  final hsl = HSLColor.fromColor(color);
  return hsl
      .withSaturation((hsl.saturation * 1.08).clamp(0, 1))
      .withLightness((hsl.lightness * .92).clamp(0, 1))
      .toColor();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'palette pixels are bounded and do not retain full display images',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lazer-palette-size-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final cache = PaintingBinding.instance.imageCache;
      cache.clear();
      cache.clearLiveImages();
      final file = File('${directory.path}/large.png');
      await _cover(file, 2048, 1024);
      final provider = ArtworkImage(file.uri.toString());
      final full = await _displayDecode(provider);
      final fullPixels = await _pixels(full);
      final previousBytes = full.width * full.height * 4;
      final seed = albumSeedFromPixels(fullPixels, full.width, full.height);
      final mesh = albumMeshColorsFromPixels(
        fullPixels,
        full.width,
        full.height,
      );
      full.dispose();
      expect(cache.currentSizeBytes, previousBytes);
      await provider.evict();
      cache.clearLiveImages();

      final compact = (await decodeAlbumPaletteImage(file.uri.toString()))!;
      try {
        expect(compact.width, 96);
        expect(compact.height, 48);
        expect(compact.width * compact.height * 4, 18432);
        final pixels = await _pixels(compact);
        expect(
          albumSeedFromPixels(pixels, compact.width, compact.height),
          seed,
        );
        expect(
          albumMeshColorsFromPixels(pixels, compact.width, compact.height),
          mesh,
        );
      } finally {
        compact.dispose();
      }
      expect(cache.currentSizeBytes, 0);
      final palette = await albumPaletteForCover(file.uri.toString());
      expect(palette!.seed, seed);
      expect(palette.mesh, mesh);
      expect(cache.currentSizeBytes, 0);
      debugPrint(
        'Palette RGBA: $previousBytes -> 18432 bytes; retained display cache: $previousBytes -> 0 bytes',
      );
    },
  );

  test(
    'palette decode preserves aspect ratio and never upscales small covers',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lazer-palette-aspect-',
      );
      addTearDown(() => directory.delete(recursive: true));
      for (final (width, height, expectedWidth, expectedHeight) in [
        (1024, 2048, 48, 96),
        (32, 16, 32, 16),
        (16, 32, 16, 32),
        (64, 64, 64, 64),
        (2048, 1, 96, 1),
        (1, 2048, 1, 96),
      ]) {
        final file = File('${directory.path}/$width-$height.png');
        await _cover(file, width, height);
        final image = (await decodeAlbumPaletteImage(file.uri.toString()))!;
        expect((image.width, image.height), (expectedWidth, expectedHeight));
        image.dispose();
      }
    },
  );

  testWidgets(
    'mesh motion reuses a settled palette without repeated HSL work',
    (tester) async {
      final colors = albumFlowColors(const Color(0xffb62a58));
      final previous = albumFlowRenderer.debugPaletteBuilds;
      final frames = albumFlowRenderer.debugFrameBuilds;
      await tester.pumpWidget(
        MaterialApp(home: AlbumFlowBackground(colors: colors, frameRate: null)),
      );
      for (var frame = 0; frame < 120; frame++) {
        await tester.pump(const Duration(microseconds: 16667));
      }
      expect(albumFlowRenderer.debugPaletteBuilds - previous, 1);
      expect(albumFlowRenderer.debugFrameBuilds - frames, greaterThan(110));
      final settled = albumFlowRenderer.debugPaletteBuilds;
      await tester.pumpWidget(
        MaterialApp(
          home: AlbumFlowBackground(
            colors: albumFlowColors(const Color(0xff225ccc)),
            frameRate: null,
          ),
        ),
      );
      for (var frame = 0; frame < 50; frame++) {
        await tester.pump(const Duration(microseconds: 16667));
      }
      expect(albumFlowRenderer.debugPaletteBuilds, greaterThan(settled + 10));
      final afterFade = albumFlowRenderer.debugPaletteBuilds;
      for (var frame = 0; frame < 120; frame++) {
        await tester.pump(const Duration(microseconds: 16667));
      }
      expect(albumFlowRenderer.debugPaletteBuilds, afterFade);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );

  testWidgets(
    'cached palette paints the same pixels through a song crossfade',
    (tester) async {
      const size = Size(320, 240);
      final boundary = GlobalKey();
      final from = albumFlowColors(const Color(0xffb62a58));
      final to = albumFlowColors(const Color(0xff225ccc));
      Widget page(List<Color> colors) => MaterialApp(
        home: Center(
          child: SizedBox.fromSize(
            size: size,
            child: RepaintBoundary(
              key: boundary,
              child: AlbumFlowBackground(colors: colors, frameRate: null),
            ),
          ),
        ),
      );
      await tester.pumpWidget(page(from));
      Future<void> compare(double fraction) async {
        final eased = (1 - math.cos(math.pi * fraction)) / 2;
        final expectedColors = [
          for (var i = 0; i < 5; i++)
            _vividReference(Color.lerp(from[i], to[i], eased)!),
        ];
        final phase =
            albumFlowClock.elapsed.inMicroseconds /
            Duration.microsecondsPerSecond %
            10000;
        final precision = DynamicBackgroundPrecision.of(
          kDynamicBackgroundQualityDefault,
        );
        await tester.runAsync(() async {
          final actual =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final recorder = ui.PictureRecorder();
          albumFlowRenderer.paint(
            Canvas(recorder),
            size,
            expectedColors,
            phase,
            precision.columns,
            precision.rows,
          );
          final picture = recorder.endRecording();
          final expected = await picture.toImage(
            size.width.toInt(),
            size.height.toInt(),
          );
          try {
            expect(
              await _pixels(actual),
              orderedEquals(await _pixels(expected)),
            );
          } finally {
            expected.dispose();
            actual.dispose();
            picture.dispose();
          }
        });
      }

      await compare(0);
      await tester.pumpWidget(page(to));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      await compare(.4);
      await tester.pump(const Duration(milliseconds: 390));
      await compare(1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'unrelated state reports leave the browsing background widget intact',
    (tester) async {
      final state = _State()
        ..track = _first
        // The backdrop is opt-in by default; this test keeps it painted.
        ..backgroundMode = AppBackgroundMode.nowPlayingDynamic;
      final navigation = BrowseNavigationObserver();
      addTearDown(state.dispose);
      addTearDown(navigation.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: SharedBrowseBackground(
            state: state,
            navigation: navigation,
            child: const SizedBox.expand(),
          ),
        ),
      );
      final original = tester.widget<AlbumBlurFlowCanvas>(
        find.byType(AlbumBlurFlowCanvas),
      );
      for (var report = 0; report < 100; report++) {
        state.report();
        await tester.pump(const Duration(milliseconds: 20));
        expect(
          tester.widget<AlbumBlurFlowCanvas>(find.byType(AlbumBlurFlowCanvas)),
          same(original),
        );
      }
      state.track = _second;
      state.report();
      await tester.pump();
      expect(
        tester.widget<AlbumBlurFlowCanvas>(find.byType(AlbumBlurFlowCanvas)).track,
        same(_second),
      );
      await state.setDynamicBackgroundQuality(.3);
      await tester.pump();
      expect(
        tester.widget<AlbumBlurFlowCanvas>(find.byType(AlbumBlurFlowCanvas)).quality,
        .3,
      );
      state.playerPresented.value = true;
      await tester.pump();
      final tickerMode = tester.widget<TickerMode>(
        find
            .ancestor(
              of: find.byType(AlbumBlurFlowCanvas),
              matching: find.byType(TickerMode),
            )
            .first,
      );
      expect(tickerMode.enabled, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      state.report();
      expect(tester.takeException(), isNull);
    },
  );
}
