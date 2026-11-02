import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/animation/apple_spring.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/widgets/animated_track_cover.dart';
import 'package:lazer_nextgen/widgets/artwork_image.dart';

const Track _first = Track(
  id: 'cover-first',
  title: 'First',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 3),
  coverSeed: 1,
);

const Track _second = Track(
  id: 'cover-second',
  title: 'Second',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 3),
  coverSeed: 2,
);

Widget _host(Track track, {AppleSpring spring = AppleSpring.responsive}) =>
    MaterialApp(
      home: Center(
        child: SizedBox.square(
          dimension: 240,
          child: AnimatedTrackCover(track: track, direction: 1, spring: spring),
        ),
      ),
    );

Future<Uint8List> _pixels(WidgetTester tester, GlobalKey key) async {
  late Uint8List pixels;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      pixels = Uint8List.fromList(data!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
  return pixels;
}

Future<Track> _cover(
  WidgetTester tester,
  Directory directory,
  String id,
  Color color,
) async {
  final file = File('${directory.path}/$id.png');
  await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawPaint(Paint()..color = color);
    final picture = recorder.endRecording();
    final image = await picture.toImage(4, 4);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
      picture.dispose();
    }
  });
  return Track(
    id: id,
    title: id,
    artist: 'Artist',
    album: 'Album',
    duration: const Duration(minutes: 3),
    coverSeed: 1,
    coverUrl: file.uri.toString(),
  );
}

void main() {
  testWidgets('continuous different-track changes retire old cover layers', (
    tester,
  ) async {
    Widget host(int index) => _host(
      Track(
        id: 'stress-$index',
        title: 'Track $index',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(minutes: 3),
        coverSeed: index,
      ),
      spring: AppleSpring.smooth,
    );

    await tester.pumpWidget(host(0));
    for (var index = 1; index <= 240; index++) {
      await tester.pumpWidget(host(index));
      await tester.pump(const Duration(milliseconds: 16));
      if (index >= 120) {
        expect(
          find
              .descendant(
                of: find.byType(AnimatedTrackCover),
                matching: find.byType(FadeTransition),
              )
              .evaluate()
              .length,
          lessThan(90),
          reason: 'retiring layers must not accumulate throughout a long burst',
        );
        expect(
          find.byKey(ValueKey<String>('stress-${index - 120}')),
          findsNothing,
          reason: 'a cover older than 1.9 seconds has finished its dissolve',
        );
      }
    }
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AnimatedTrackCover),
        matching: find.byType(FadeTransition),
      ),
      findsOneWidget,
    );
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop artwork keeps a slower dissolve than mobile artwork', (
    tester,
  ) async {
    Future<double> remainingOpacity(AppleSpring spring) async {
      await tester.pumpWidget(_host(_first, spring: spring));
      await tester.pumpWidget(_host(_second, spring: spring));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 140));
      final first = find.byKey(const ValueKey<String>('cover-first'));
      final fade = tester.widget<FadeTransition>(
        find.ancestor(of: first, matching: find.byType(FadeTransition)).first,
      );
      final remaining = fade.opacity.value;
      await tester.pumpAndSettle();
      expect(first, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      return remaining;
    }

    final desktop = await remainingOpacity(
      const AppleSpring(duration: Duration(milliseconds: 500)),
    );
    final mobile = await remainingOpacity(
      const AppleSpring(duration: Duration(milliseconds: 280)),
    );
    expect(desktop, greaterThan(mobile));
    expect(desktop, inExclusiveRange(0.0, 1.0));
    expect(mobile, inExclusiveRange(0.0, 1.0));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reversing a visible track reuses its plate and opacity velocity',
    (tester) async {
      await tester.pumpWidget(_host(_first));
      final first = find.byKey(const ValueKey<String>('cover-first'));
      final element = tester.element(first);
      await tester.pumpWidget(_host(_second));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));
      final fade = tester.widget<FadeTransition>(
        find.ancestor(of: first, matching: find.byType(FadeTransition)).first,
      );
      final opacity = fade.opacity as AnimationController;
      final value = opacity.value;
      final velocity = opacity.velocity;
      expect(value, inExclusiveRange(0.0, 1.0));
      expect(velocity, lessThan(0));
      await tester.pumpWidget(_host(_first));
      expect(tester.element(first), same(element));
      expect(opacity.value, closeTo(value, .000001));
      expect(opacity.velocity, closeTo(velocity, .000001));
      await tester.pump(const Duration(milliseconds: 1));
      expect(
        opacity.value,
        lessThan(value),
        reason: 'momentum continues before the spring turns around',
      );
      await tester.pumpAndSettle();
      expect(first, findsOneWidget);
      expect(find.byKey(const ValueKey<String>('cover-second')), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets('a track change dissolves the artwork', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(_first));
    await tester.pumpAndSettle();

    await tester.pumpWidget(_host(_second));
    await tester.pump(const Duration(milliseconds: 90));

    // The dissolve keeps both plates alive and drives them with a fade; there
    // is no slide left in the cover transition.
    expect(find.byKey(const ValueKey<String>('cover-first')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('cover-second')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AnimatedTrackCover),
        matching: find.byType(FadeTransition),
      ),
      findsWidgets,
    );
    expect(
      find.descendant(
        of: find.byType(AnimatedTrackCover),
        matching: find.byType(SlideTransition),
      ),
      findsNothing,
    );

    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('cover-first')), findsNothing);
    expect(find.byKey(const ValueKey<String>('cover-second')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'dissolves keep opaque pixels and interrupted changes continuous',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('lazer-dissolve-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final firstTrack = await _cover(
        tester,
        directory,
        'red',
        const Color(0xffb4465a),
      );
      final secondTrack = await _cover(
        tester,
        directory,
        'green',
        const Color(0xff3cb45a),
      );
      final thirdTrack = await _cover(
        tester,
        directory,
        'blue',
        const Color(0xff505ad2),
      );
      final boundary = GlobalKey();
      Widget host(Track track) => MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: boundary,
            child: SizedBox.square(
              dimension: 80,
              child: ColoredBox(
                color: Colors.black,
                child: AnimatedTrackCover(track: track, direction: 1, size: 80),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.runAsync(() async {
        final context = tester.element(find.byType(Navigator));
        for (final track in [firstTrack, secondTrack, thirdTrack]) {
          await precacheImage(
            ArtworkImage.forSize(
              track.coverUrl!,
              logicalEdge: 80,
              devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
            ),
            context,
          );
        }
      });
      await tester.pumpWidget(host(firstTrack));
      await tester.pumpAndSettle();
      final first = await _pixels(tester, boundary);
      expect(first.sublist(0, 4), [180, 70, 90, 255]);
      await tester.pumpWidget(host(secondTrack));
      await tester.pumpAndSettle();
      final second = await _pixels(tester, boundary);
      expect(second.sublist(0, 4), [60, 180, 90, 255]);
      await tester.pumpWidget(host(firstTrack));
      await tester.pumpAndSettle();
      await tester.pumpWidget(host(secondTrack));
      await tester.pump(const Duration(milliseconds: 210));
      final middle = await _pixels(tester, boundary);
      for (var i = 0; i < middle.length; i++) {
        final lower = first[i] < second[i] ? first[i] : second[i];
        final upper = first[i] > second[i] ? first[i] : second[i];
        expect(
          middle[i],
          inInclusiveRange(
            (lower - 2).clamp(0, 255),
            (upper + 2).clamp(0, 255),
          ),
          reason:
              'a dissolve must blend the covers without a dark background dip',
        );
      }
      await tester.pumpAndSettle();
      await tester.pumpWidget(host(firstTrack));
      await tester.pumpAndSettle();
      await tester.pumpWidget(host(secondTrack));
      await tester.pump(const Duration(milliseconds: 100));
      final beforeInterrupt = await _pixels(tester, boundary);
      await tester.pumpWidget(host(thirdTrack));
      final interrupted = await _pixels(tester, boundary);
      for (var i = 0; i < beforeInterrupt.length; i++) {
        expect(
          interrupted[i],
          closeTo(beforeInterrupt[i], 2),
          reason: 'rapid next/previous must start from the visible composition',
        );
      }
      // B's partial entrance exits in 100 ms, while A remains until 420 ms.
      // Removing B must not recreate A's fading wrapper at full opacity.
      await tester.pump(const Duration(milliseconds: 98));
      final beforeRemoval = await _pixels(tester, boundary);
      await tester.pump(const Duration(milliseconds: 4));
      final afterRemoval = await _pixels(tester, boundary);
      for (var i = 0; i < beforeRemoval.length; i++) {
        expect(
          afterRemoval[i],
          closeTo(beforeRemoval[i], 12),
          reason:
              'removing a shorter interrupted fade must not reset older fades',
        );
      }
      await tester.pumpAndSettle();
      expect((await _pixels(tester, boundary)).sublist(0, 4), [
        80,
        90,
        210,
        255,
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reduced motion changes the artwork immediately', (tester) async {
    Widget host(Track track) => MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: SizedBox.square(
          dimension: 80,
          child: AnimatedTrackCover(track: track, direction: 1),
        ),
      ),
    );
    await tester.pumpWidget(host(_first));
    await tester.pumpWidget(host(_second));
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('cover-first')), findsNothing);
    expect(find.byKey(const ValueKey<String>('cover-second')), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);
  });
}
