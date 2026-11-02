import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/ui/playlist_page.dart';
import 'package:lazer_nextgen/ui/widgets.dart';
import 'package:lazer_nextgen/tv/large_screen_pages.dart';
import 'package:lazer_nextgen/tv/large_screen_widgets.dart';
import 'package:lazer_nextgen/widgets/artwork_reveal.dart';
import 'package:lazer_nextgen/widgets/cover_transition.dart';

Future<Color> _centerPixel(WidgetTester tester, GlobalKey boundaryKey) async {
  return (await tester.runAsync(() async {
    final boundary =
        boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage();
    try {
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final offset = ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4;
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

Widget _host(
  GlobalKey boundary, {
  required bool ready,
  bool synchronous = false,
  bool reduceMotion = false,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: Center(
      child: RepaintBoundary(
        key: boundary,
        child: SizedBox.square(
          dimension: 64,
          child: ArtworkReveal(
            ready: ready,
            synchronous: synchronous,
            placeholder: const ColoredBox(color: Color(0xffff0000)),
            child: const ColoredBox(color: Color(0xff0000ff)),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  for (final initiallyReady in [false, true]) {
    testWidgets(
      '${initiallyReady ? 'first asynchronous frame' : 'a frame arriving after the cover flight'} fades over the placeholder',
      (tester) async {
        final boundary = GlobalKey();
        await tester.pumpWidget(_host(boundary, ready: initiallyReady));
        if (!initiallyReady) {
          await tester.pump(const Duration(milliseconds: 700));
          expect(await _centerPixel(tester, boundary), const Color(0xffff0000));
          await tester.pumpWidget(_host(boundary, ready: true));
        }
        expect(await _centerPixel(tester, boundary), const Color(0xffff0000));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        final middle = await _centerPixel(tester, boundary);
        expect(middle.a, 1);
        expect(middle.r, inExclusiveRange(.2, .8));
        expect(middle.b, inExclusiveRange(.2, .8));
        expect(middle.g, 0);
        await tester.pump(const Duration(milliseconds: 120));
        expect(await _centerPixel(tester, boundary), const Color(0xff0000ff));
        await tester.pump(const Duration(milliseconds: 1));
        expect(tester.binding.transientCallbackCount, 0);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final synchronous in [true, false]) {
    testWidgets(
      '${synchronous ? 'synchronously cached images' : 'reduced motion'} skip the reveal animation',
      (tester) async {
        final boundary = GlobalKey();
        await tester.pumpWidget(
          _host(
            boundary,
            ready: false,
            synchronous: synchronous,
            reduceMotion: !synchronous,
          ),
        );
        expect(await _centerPixel(tester, boundary), const Color(0xffff0000));
        await tester.pumpWidget(
          _host(
            boundary,
            ready: true,
            synchronous: synchronous,
            reduceMotion: !synchronous,
          ),
        );
        expect(await _centerPixel(tester, boundary), const Color(0xff0000ff));
        expect(tester.binding.transientCallbackCount, 0);
        expect(
          find.descendant(
            of: find.byType(ArtworkReveal),
            matching: find.byType(FadeTransition),
          ),
          findsNothing,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final tv in [false, true]) {
    testWidgets(
      '${tv ? 'TV' : 'standard'} image frame builder reveals late frames and resets for a new URL',
      (tester) async {
        Future<ImageFrameBuilder> frameBuilder(String url) async {
          await tester.pumpWidget(
            MaterialApp(
              home: Center(
                child: SizedBox.square(
                  dimension: 64,
                  child: tv
                      ? LargeScreenArtwork(url: url, size: 64, fadeIn: true)
                      : AppCover(url: url, size: 64, fadeIn: true),
                ),
              ),
            ),
          );
          return tester.widget<Image>(find.byType(Image)).frameBuilder!;
        }

        final first = await frameBuilder(
          'https://example.test/reveal-first.png',
        );
        final second = await frameBuilder(
          'https://example.test/reveal-second.png',
        );
        final boundary = GlobalKey();
        Widget imageFrame(
          ImageFrameBuilder builder,
          int? frame, {
          bool synchronous = false,
        }) => MaterialApp(
          home: Center(
            child: RepaintBoundary(
              key: boundary,
              child: SizedBox.square(
                dimension: 64,
                child: ColoredBox(
                  color: Colors.black,
                  child: Builder(
                    builder: (context) => builder(
                      context,
                      const ColoredBox(color: Color(0xff0000ff)),
                      frame,
                      synchronous,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpWidget(imageFrame(first, null));
        final placeholder = await _centerPixel(tester, boundary);
        expect(placeholder, isNot(const Color(0xff0000ff)));
        await tester.pump(const Duration(milliseconds: 700));
        expect(await _centerPixel(tester, boundary), placeholder);
        await tester.pumpWidget(imageFrame(first, 0));
        expect(await _centerPixel(tester, boundary), placeholder);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 90));
        final mixture = await _centerPixel(tester, boundary);
        expect(mixture, isNot(placeholder));
        expect(mixture, isNot(const Color(0xff0000ff)));
        expect(mixture.a, 1);
        await tester.pump(const Duration(milliseconds: 120));
        expect(await _centerPixel(tester, boundary), const Color(0xff0000ff));
        await tester.pumpWidget(imageFrame(second, null));
        expect(await _centerPixel(tester, boundary), placeholder);
        await tester.pumpWidget(imageFrame(second, 0, synchronous: true));
        expect(await _centerPixel(tester, boundary), const Color(0xff0000ff));
        expect(tester.binding.transientCallbackCount, 0);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('only collection detail artwork opts into the image reveal', (
    tester,
  ) async {
    addTearDown(cancelCoverTransitions);
    const playlist = Playlist(
      id: 'reveal',
      name: 'Reveal detail',
      trackIds: [],
      coverSeed: 1,
    );
    expect(const AppCover().fadeIn, isFalse);
    expect(const LargeScreenArtwork(size: 60).fadeIn, isFalse);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AppPlaylistHeader(
            playlist: playlist,
            compact: false,
            onPlay: null,
          ),
        ),
      ),
    );
    expect(tester.widget<AppCover>(find.byType(AppCover)).fadeIn, isTrue);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: LargeScreenCollectionHeader(
            title: 'TV detail',
            metadata: '1 track',
            transitionIdentity: 'reveal-tv',
            actions: [],
          ),
        ),
      ),
    );
    expect(
      tester.widget<LargeScreenArtwork>(find.byType(LargeScreenArtwork)).fadeIn,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });
}
