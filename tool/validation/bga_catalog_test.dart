import 'dart:convert';
import 'package:lazer_nextgen/plugins/plugin_manager.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
// Explicit network validation, separate from the deterministic CI suite:
// flutter test --no-pub tool/validation/bga_catalog_test.dart
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/ui/background.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/utils/media_requests.dart';

class _Network extends HttpOverrides {
  final List<String> requests = [];
  final Map<String, Duration> delays = {};
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _Client(super.createHttpClient(context), requests, delays);
}

class _Client implements HttpClient {
  _Client(this.client, this.requests, this.delays);
  final HttpClient client;
  final List<String> requests;
  final Map<String, Duration> delays;
  @override
  set autoUncompress(bool value) => client.autoUncompress = value;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requests.add(url.toString());
    if (delays[url.path] case final delay?) await Future<void>.delayed(delay);
    return client.getUrl(url);
  }

  @override
  void close({bool force = false}) => client.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<Uint8List> _get(Uri uri) async {
  final client = HttpClient();
  try {
    final request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 15));
    MediaRequestRules.headers(uri.toString()).forEach(request.headers.set);
    final response = await request.close().timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }
    final bytes = BytesBuilder();
    await for (final chunk in response) {
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  } finally {
    client.close(force: true);
  }
}

Future<List<Color>> _mesh(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  try {
    final data = await frame.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    return albumMeshColorsFromPixels(
      data!.buffer.asUint8List(),
      frame.image.width,
      frame.image.height,
    );
  } finally {
    frame.image.dispose();
    codec.dispose();
  }
}

void main() {
  testWidgets('real catalogue covers update cold and warm BGA caches', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('lazer-bga-live-');
    final previous = HttpOverrides.current;
    final network = _Network();
    HttpOverrides.global = network;
    addTearDown(() {
      HttpOverrides.global = previous;
      root.deleteSync(recursive: true);
    });
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => root.path,
    );
    final tracks = <Track>[];
    final meshes = <String, List<Color>>{};
    await tester.runAsync(() async {
      const zip=String.fromEnvironment('LAZER_TEST_PLUGIN_ZIP');
      const cookie=String.fromEnvironment('LAZER_TEST_COOKIE_FILE');
      final app=AppState(pluginManager:PluginManager(rootDirectory:Directory('${root.path}/plugins')));
      addTearDown(app.dispose);
      await app.pluginManager.importZip(await File(zip).readAsBytes());
      if (cookie.isNotEmpty) await app.signInWithCookie(await File(cookie).readAsString());
      final results=await app.search(const String.fromEnvironment('LAZER_TEST_QUERY',defaultValue:'音乐'));
      for (var track in results.tracks.take(6)) {
        if (track.coverUrl==null) {
          final id=MusicId.tryParse(track.id)!;
          track=app.catalog.trackFromMusicSong(await app.catalog.connections.resolve(id).song(id));
        }
        tracks.add(track);
        meshes[track.id]=await _mesh(await _get(Uri.parse(albumPaletteArtworkUrl(track.coverUrl)!)));
      }
      expect(tracks,isNotEmpty);
    });
    var current = tracks.first;
    late StateSetter update;
    final playerBoundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Row(
              children: [
                Expanded(
                  child: RepaintBoundary(
                    key: playerBoundary,
                    child: AlbumBlurFlow(
                      track: current,
                      mode: AppBackgroundMode.nowPlayingDynamic,
                      pageColor: Colors.black,
                      animationsEnabled: true,
                    ),
                  ),
                ),
                Expanded(
                  child: AppAlbumBackdrop(
                    track: current,
                    mode: AppBackgroundMode.nowPlayingDynamic,
                    uiAlpha: 0,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
    final samples = <Map<String, Object>>[];
    final hashes = <String>[];
    Future<void> ready(Track track, String phase) async {
      final clock = Stopwatch()..start();
      for (var frame = 0; frame < 1500; frame++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
        final backgrounds = tester.widgetList<AlbumFlowBackground>(
          find.byType(AlbumFlowBackground),
        );
        if (backgrounds.length == 2 &&
            backgrounds.every(
              (canvas) => listEquals(canvas.colors, meshes[track.id]),
            )) {
          await tester.pump(const Duration(seconds: 1));
          samples.add({
            'id': track.id,
            'phase': phase,
            'milliseconds': clock.elapsedMilliseconds,
          });
          return;
        }
      }
      fail(
        'Both backgrounds did not receive catalogue cover ${track.id} during $phase',
      );
    }

    final coldRequests = network.requests.length;
    for (final track in tracks.take(3)) {
      update(() => current = track);
      await tester.pump();
      await ready(track, 'cold');
      await tester.runAsync(() async {
        final image =
            await (playerBoundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        hashes.add(sha256.convert(data!.buffer.asUint8List()).toString());
        image.dispose();
      });
    }
    expect(network.requests.length, greaterThan(coldRequests));
    expect(
      hashes.toSet().length,
      3,
      reason: 'real painted pixels must change across covers',
    );
    final beforeWarm = network.requests.length;
    for (final track in tracks.take(3).toList().reversed) {
      update(() => current = track);
      await tester.pump();
      await ready(track, 'warm');
    }
    expect(
      network.requests.length,
      beforeWarm,
      reason: 'warm palette/cache hits must not re-download',
    );
    final warmRequests = network.requests.length - beforeWarm;
    // Three still-uncached real covers arrive out of order. Delay the first
    // requests at the network boundary, keeping the actual CDN/cache/decoder.
    network.delays[Uri.parse(tracks[3].coverUrl!).path] = const Duration(
      milliseconds: 1800,
    );
    network.delays[Uri.parse(tracks[4].coverUrl!).path] = const Duration(
      milliseconds: 900,
    );
    update(() => current = tracks[3]);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    update(() => current = tracks[4]);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    update(() => current = tracks.last);
    await tester.pump();
    await ready(tracks.last, 'rapid-final');
    final completed = <String, AlbumCoverPalette?>{};
    for (final track in tracks.skip(3)) {
      albumPaletteForCover(
        track.coverUrl,
      ).then((palette) => completed[track.id] = palette);
    }
    // Continue both widget time and real IO. Awaiting a request created by a
    // widget inside runAsync alone would leave its fake-zone delay unadvanced.
    for (var frame = 0; frame < 1500 && completed.length < 3; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(completed.length, 3);
    for (final track in tracks.skip(3)) {
      expect(listEquals(completed[track.id]?.mesh, meshes[track.id]), isTrue);
    }
    expect(
      tester
          .widgetList<AlbumFlowBackground>(find.byType(AlbumFlowBackground))
          .every((canvas) => listEquals(canvas.colors, meshes[tracks.last.id])),
      isTrue,
      reason: 'late previous CDN results must not replace the final song',
    );
    final cached = Directory('${root.path}/lazer_cache_v1/artwork');
    expect(cached.existsSync(), isTrue);
    final files = cached.listSync().whereType<File>().length;
    expect(files, greaterThanOrEqualTo(6));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      final report = {
        'covers': samples,
        'coldCoverRequests': network.requests.length - coldRequests,
        'warmCoverRequests': warmRequests,
        'coldRaceCovers': 3,
        'diskFiles': files,
        'distinctPixelHashes': hashes.toSet().length,
      };
      await File(
        'build/reports/bga-real-catalog.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    });
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 4)));
}
