import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/cache/current_artwork.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/animation/motion_snapshot.dart';
import 'package:lazer_nextgen/widgets/plate_art.dart';

class _DelayedCover extends ImageProvider<_DelayedCover> {
  final frame = Completer<ImageInfo>();

  @override
  Future<_DelayedCover> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _DelayedCover key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(frame.future);
}

class _Catalog extends Catalog {
  final resolvingAudio = Completer<String?>();
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) => resolvingAudio.future;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => null;
}

Future<Track> _cover(Directory directory, String id, Color color) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawPaint(Paint()..color = color);
  final picture = recorder.endRecording();
  final image = await picture.toImage(1024, 1024);
  final file = File('${directory.path}/$id.png');
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
  } finally {
    image.dispose();
    picture.dispose();
  }
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
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a late cover refreshes frozen pixels before entrance ends', (
    tester,
  ) async {
    final motion = AnimationController(
      vsync: tester,
      duration: const Duration(seconds: 2),
    );
    addTearDown(motion.dispose);
    final provider = _DelayedCover();
    final boundary = GlobalKey();
    motion.forward();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: boundary,
            child: SizedBox.square(
              dimension: 64,
              child: MotionSnapshot(
                animation: motion,
                child: PlateArt(seed: 1, image: provider),
              ),
            ),
          ),
        ),
      ),
    );
    final image = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawPaint(Paint()..color = Colors.red);
      final picture = recorder.endRecording();
      try {
        return await picture.toImage(16, 16);
      } finally {
        picture.dispose();
      }
    });
    provider.frame.complete(ImageInfo(image: image!));
    await tester.pump();
    await tester.pump();
    expect(motion.isAnimating, isTrue);
    final pixel = await tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final captured = await render.toImage();
      try {
        final data = await captured.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        final offset = (32 * 64 + 32) * 4;
        return data!.buffer.asUint8List().sublist(offset, offset + 4);
      } finally {
        captured.dispose();
      }
    });
    expect(pixel, [244, 67, 54, 255]);
    motion.stop();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('selection preloads large artwork before audio or player opens', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('lazer-current-art-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final track = (await tester.runAsync(
      () => _cover(directory, 'selected', Colors.red),
    ))!;
    final catalog = _Catalog();
    final state = AppState(
      catalog: catalog,
      artworkSeedLoader: (_) async => null,
    );
    addTearDown(state.dispose);
    await tester.runAsync(() async {
      state.playQueue([track]);
      state.pause();
      expect(state.currentArtwork.providerFor(track)!.targetSize, 1024);
      expect(catalog.resolvingAudio.isCompleted, isFalse);
      expect(find.byType(NowPlayingPage), findsNothing);
      await state.currentArtwork.ready.timeout(const Duration(seconds: 10));
    });
    final provider = state.currentArtwork.providerFor(track)!;
    final sameAlbum = Track.fromJson({...track.toJson(), 'id': 'same-album'});
    state.currentArtwork.update(sameAlbum);
    expect(state.currentArtwork.providerFor(sameAlbum), same(provider));
    state.currentArtwork.update(track);

    // Opening and reopening must work with just the decoded in-memory image.
    File.fromUri(Uri.parse(track.coverUrl!)).deleteSync();
    for (var opening = 0; opening < 2; opening++) {
      await tester.pumpWidget(MaterialApp(home: NowPlayingPage(state: state)));
      final image = tester.widget<RawImage>(
        find.descendant(
          of: find.byKey(const ValueKey('now-playing-cover')),
          matching: find.byType(RawImage),
        ),
      );
      expect(
        image.image,
        isNotNull,
        reason: 'no placeholder on the first frame',
      );
      expect(image.image!.width, 1024);
      expect(
        tester
            .widget<Image>(
              find.descendant(
                of: find.byKey(const ValueKey('now-playing-cover')),
                matching: find.byType(Image),
              ),
            )
            .image,
        provider,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('rapid selection retains only the latest large decode', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('lazer-art-race-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final tracks = (await tester.runAsync(
      () async => [
        await _cover(directory, 'first', Colors.red),
        await _cover(directory, 'second', Colors.blue),
        await _cover(directory, 'third', Colors.green),
      ],
    ))!;
    final state = AppState(
      catalog: _Catalog(),
      artworkSeedLoader: (_) async => null,
    );
    addTearDown(state.dispose);
    late ImageProvider first, second, third;
    await tester.runAsync(() async {
      state.playQueue(tracks);
      state.pause();
      first = state.currentArtwork.providerFor(tracks.first)!;
      state.next();
      second = state.currentArtwork.providerFor(tracks[1])!;
      state.playTrackAt(2);
      state.pause();
      third = state.currentArtwork.providerFor(tracks[2])!;
      await state.currentArtwork.ready.timeout(const Duration(seconds: 10));
    });
    final cache = PaintingBinding.instance.imageCache;
    for (final old in [first, second]) {
      final status = cache.statusForKey(old);
      expect(status.pending, isFalse);
      expect(status.live, isFalse);
      expect(status.keepAlive, isFalse);
    }
    expect(cache.statusForKey(third).live, isTrue);
    expect(state.currentArtwork.providerFor(tracks.first), isNull);
    state.currentArtwork.update(null);
    expect(cache.statusForKey(third).live, isFalse);
    expect(cache.statusForKey(third).keepAlive, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed and absent covers release their current cache owner', (
    tester,
  ) async {
    final cache = CurrentArtworkCache();
    final track = Track(
      id: 'missing',
      title: 'Missing',
      artist: '',
      album: '',
      duration: Duration.zero,
      coverSeed: 1,
      coverUrl: File(
        '${Directory.systemTemp.path}/lazer-absent-cover.png',
      ).uri.toString(),
    );
    await tester.runAsync(() async {
      cache.update(track);
      await cache.ready.timeout(const Duration(seconds: 10));
    });
    final failed = cache.providerFor(track)!;
    cache.update(null);
    expect(cache.providerFor(track), isNull);
    expect(
      PaintingBinding.instance.imageCache.statusForKey(failed).live,
      isFalse,
    );
    cache.dispose();
    cache.update(track);
    expect(cache.providerFor(track), isNull);
    expect(tester.takeException(), isNull);
  });
}
