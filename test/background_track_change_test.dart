// The reported bug: after a song change the backdrop kept painting the previous
// cover's dominant colours.
//
// `_AlbumFlowBackgroundState` crossfades `_from` (the palette on screen) into
// `_to` (the new one). `_rawPalette()` interpolates between them, so a crossfade
// that never advances leaves the canvas on `_from` — literally the previous
// song's cover colours — and the next song change makes that stuck frame the new
// origin. These tests pin both the normal path and the case where no frames
// arrive to advance the fade, and they write the rendered canvases to
// build/verify/ so the colours can be looked at instead of trusted.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/legacy/legacy_background.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';

const Color _green = Color(0xFF2E7D32);
const Color _red = Color(0xFFB71C1C);

Track _track(String id, String cover, {int seed = 1}) => Track(
  id: id,
  title: id,
  artist: 'Artist',
  album: 'Album',
  duration: const Duration(minutes: 3),
  coverSeed: seed,
  coverUrl: cover,
);

AlbumCoverPalette _palette(Color seed) =>
    AlbumCoverPalette(seed: seed, mesh: albumFlowColors(seed));

Future<AlbumCoverPalette?> _loader(String? url) async =>
    url!.endsWith('/a') ? _palette(_red) : _palette(_green);

/// Bottom-centre pixel of the canvas: the cheap preview ramp ends in the
/// palette's last colour, so it is a stable read of "which song is painted".
Future<Color> _bottomPixel(
  WidgetTester tester,
  Key boundary,
  String shot,
) async {
  final RenderRepaintBoundary render = tester
      .renderObject<RenderRepaintBoundary>(find.byKey(boundary));
  late final ui.Image image;
  late final ByteData? bytes;
  await tester.runAsync(() async {
    image = await render.toImage();
    bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  });
  final ByteData data = bytes!;
  final int width = image.width;
  final int height = image.height;
  final int index = ((height - 2) * width + width ~/ 2) * 4;
  final Color color = Color.fromARGB(
    255,
    data.getUint8(index),
    data.getUint8(index + 1),
    data.getUint8(index + 2),
  );
  // Keep the frame for the human check the fix was asked for.
  final Directory directory = Directory('build/verify');
  directory.createSync(recursive: true);
  final ByteData? png = await tester.runAsync<ByteData?>(
    () async => image.toByteData(format: ui.ImageByteFormat.png),
  );
  File(
    '${directory.path}/bga-$shot.png',
  ).writeAsBytesSync(png!.buffer.asUint8List());
  return color;
}

void main() {
  testWidgets(
    'the canvas follows the new cover when no frames advance the fade',
    (tester) async {
      // A muted ticker is what a paused canvas, an inactive route or a
      // `TickerMode(enabled: false)` subtree produces: `forward()` starts a
      // controller whose ticker never ticks.
      final GlobalKey boundary = GlobalKey();
      Widget page(Track track) => MaterialApp(
        home: TickerMode(
          enabled: false,
          child: AlbumBlurFlow(
            boundaryKey: boundary,
            track: track,
            mode: LegacyBackgroundMode.nowPlayingDynamic,
            animationsEnabled: true,
            preview: true,
            pageColor: Colors.black,
            paletteLoader: _loader,
          ),
        ),
      );

      await tester.pumpWidget(page(_track('a', 'https://cover.test/a')));
      await tester.pump();
      final Color first = await _bottomPixel(tester, boundary, '1a-stuck-fade');
      expect(first.r, greaterThan(first.g), reason: 'track a is the red cover');

      await tester.pumpWidget(page(_track('b', 'https://cover.test/b')));
      await tester.pump();
      final Color second = await _bottomPixel(
        tester,
        boundary,
        '1b-stuck-fade',
      );
      expect(
        second.g,
        greaterThan(second.r),
        reason: 'the canvas still paints the previous cover\'s colours',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('the crossfade lands on the new cover when frames do arrive', (
    tester,
  ) async {
    final GlobalKey boundary = GlobalKey();
    Widget page(Track track) => MaterialApp(
      home: AlbumBlurFlow(
        boundaryKey: boundary,
        track: track,
        mode: LegacyBackgroundMode.nowPlayingDynamic,
        animationsEnabled: true,
        preview: true,
        pageColor: Colors.black,
        paletteLoader: _loader,
      ),
    );

    await tester.pumpWidget(page(_track('a', 'https://cover.test/a')));
    await tester.pump();
    await _bottomPixel(tester, boundary, '2a-crossfade');

    await tester.pumpWidget(page(_track('b', 'https://cover.test/b')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    final Color second = await _bottomPixel(tester, boundary, '2b-crossfade');
    expect(second.g, greaterThan(second.r));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a cover that arrives late still moves the canvas', (
    tester,
  ) async {
    // Exactly what a slow cover cache looks like: the first reads miss while the
    // artwork is still downloading, and the palette must win once it lands.
    int misses = 0;
    final GlobalKey boundary = GlobalKey();
    Widget page(Track track) => MaterialApp(
      home: AlbumBlurFlow(
        boundaryKey: boundary,
        track: track,
        mode: LegacyBackgroundMode.nowPlayingStatic,
        pageColor: Colors.black,
        preview: true,
        paletteLoader: (String? url) async {
          if (!url!.endsWith('/b')) return _palette(_red);
          misses++;
          return misses <= 2 ? null : _palette(_green);
        },
      ),
    );

    await tester.pumpWidget(page(_track('a', 'https://cover.test/a')));
    await tester.pump();
    final Color first = await _bottomPixel(tester, boundary, '3a-late-cover');
    expect(first.r, greaterThan(first.g));

    await tester.pumpWidget(page(_track('b', 'https://cover.test/b')));
    expect(
      tester
          .widget<AlbumFlowBackground>(find.byType(AlbumFlowBackground))
          .colors,
      albumFlowColors(
        albumFallbackSeedForTrack(_track('b', 'https://cover.test/b')),
      ),
      reason: 'the old cover must be cleared before the artwork retries finish',
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(misses, greaterThan(2), reason: 'the reader retried while waiting');
    final Color second = await _bottomPixel(tester, boundary, '3b-late-cover');
    expect(second.g, greaterThan(second.r));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a cover that never arrives still changes with the song', (
    tester,
  ) async {
    // No palette at all: the canvas must fall back to each track's own seed
    // instead of freezing on the shared default for the whole session.
    final List<List<Color>> painted = <List<Color>>[];
    Widget page(Track track) => MaterialApp(
      home: AlbumBlurFlow(
        track: track,
        mode: LegacyBackgroundMode.nowPlayingStatic,
        pageColor: Colors.black,
        preview: true,
        paletteLoader: (String? url) async => null,
      ),
    );

    for (final Track track in <Track>[
      _track('a', 'https://cover.test/a', seed: 40),
      _track('b', 'https://cover.test/b', seed: 200),
    ]) {
      await tester.pumpWidget(page(track));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      painted.add(
        tester
            .widget<AlbumFlowBackground>(find.byType(AlbumFlowBackground))
            .colors,
      );
    }
    expect(painted[0], isNot(equals(painted[1])));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
