// Run on a real desktop GPU, without accounts, audio or network fixtures:
// flutter run -d windows --profile -t tool/benchmarks/player_open.dart
// Results: build/benchmarks/player-open.json
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'package:lazer_nextgen/accessibility/lazer_binding.dart';
import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/audio/system_media_handler.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/lyrics/lyric_document.dart';
import 'package:lazer_nextgen/main.dart' show LazerApp;
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/playback_queue_store.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/ui/player_bar.dart';
import 'package:lazer_nextgen/updates/update_checker.dart';
import 'package:lazer_nextgen/widgets/window_frame.dart';

class _UnusedAudio implements AudioEngine {
  @override
  void dispose() {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('The rendering benchmark must not play audio');
}

class _BenchmarkState extends AppState {
  _BenchmarkState(String cover)
    : super(
        queueStore: PlaybackQueueStore(
          read: () async => null,
          write: (_) async {},
        ),
        updateChecker: UpdateChecker(
          fetch: (_) async => http.Response('[]', 200),
        ),
      ) {
    themeMode = ThemeMode.dark;
    layoutStyle = AppLayoutStyle.desktop;
    autoDpiScale = false;
    _tracks = List.generate(
      48,
      (i) => Track(
        id: 'render-benchmark-$i',
        title: 'Evening light $i',
        artist: 'Synthetic artist',
        album: 'Render benchmark',
        coverUrl: cover,
        coverSeed: i,
        duration: const Duration(minutes: 5),
      ),
    );
    lyrics = List.generate(
      120,
      (i) => LyricLine(
        Duration(seconds: i * 2),
        'A quiet melody across the evening sky',
        translation: 'A second line for layout and blur measurement',
        words: List.generate(
          8,
          (word) => LyricWord(
            Duration(milliseconds: i * 2000 + word * 200),
            const Duration(milliseconds: 200),
            [
              'A ',
              'quiet ',
              'melody ',
              'across ',
              'the ',
              'evening ',
              'sky ',
              '',
            ][word],
          ),
        ),
      ),
    );
  }
  late final List<Track> _tracks;
  int _index = 0;
  bool _playing = true;
  Duration _position = const Duration(seconds: 98);
  @override
  Future<void> bootstrap() async {}
  @override
  Future<void> flushPersistence() async {}
  @override
  Future<void> ensureCurrentLyrics({bool force = false}) async {}
  @override
  Track get current => _tracks[_index];
  @override
  List<Track> get queue => _tracks;
  @override
  List<Track> get recentTracks => _tracks;
  @override
  bool get playing => _playing;
  @override
  Duration get precisePosition => _position;
  @override
  Duration get position => precisePosition;
  @override
  void togglePlay() {
    _playing = !_playing;
    notifyListeners();
  }

  @override
  Future<void> next() async {
    _index = (_index + 1) % _tracks.length;
    notifyListeners();
  }

  @override
  Future<void> previous() async {
    _index = (_index - 1) % _tracks.length;
    notifyListeners();
  }

  @override
  void seek(double fraction) {
    _position = Duration(milliseconds: (300000 * fraction).round());
    notifyListeners();
  }

  @override
  HomeFeed get home => HomeFeed(
    featuredTracks: _tracks,
    quick: _tracks,
    daily: _tracks,
    playlists: const [],
    albums: const [],
  );
}

T _widget<T extends Widget>() {
  T? result;
  void visit(Element element) {
    if (element.widget is T) result ??= element.widget as T;
    if (result == null) element.visitChildren(visit);
  }

  visit(WidgetsBinding.instance.rootElement!);
  if (result == null) throw StateError('No mounted $T in the production tree');
  return result!;
}

Future<String> _cover(Directory output) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 600, 600),
    Paint()
      ..shader = ui.Gradient.linear(Offset.zero, const Offset(600, 600), [
        const Color(0xffd49b79),
        const Color(0xff355c91),
      ]),
  );
  for (var i = 0; i < 9; i++) {
    canvas.drawCircle(
      Offset(i * 65.0, i * 45.0),
      160,
      Paint()..color = Colors.white.withValues(alpha: .08),
    );
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(600, 600);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File('${output.path}/cover.png');
  await file.writeAsBytes(bytes!.buffer.asUint8List());
  image.dispose();
  picture.dispose();
  return file.uri.toString();
}

Map<String, Object> _summary(List<FrameTiming> frames, double refresh) {
  final build =
      frames.map((f) => f.buildDuration.inMicroseconds / 1000).toList()..sort();
  final raster =
      frames.map((f) => f.rasterDuration.inMicroseconds / 1000).toList()
        ..sort();
  double p95(List<double> values) => values[((values.length - 1) * .95).ceil()];
  final budget = 1000 / refresh;
  return {
    'frames': frames.length,
    'budgetMs': budget,
    'buildP95Ms': p95(build),
    'buildWorstMs': build.last,
    'rasterP95Ms': p95(raster),
    'rasterWorstMs': raster.last,
    'framesOverBudget': frames
        .where(
          (f) =>
              f.buildDuration.inMicroseconds / 1000 > budget ||
              f.rasterDuration.inMicroseconds / 1000 > budget,
        )
        .length,
  };
}

Future<void> main() async {
  LazerWidgetsBinding();
  // This executable is an isolated rendering test, never a user session.
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues({});
  final requestedWidth = double.tryParse(
    Platform.environment['LAZER_BENCHMARK_WIDTH'] ?? '',
  );
  final width = requestedWidth != null && requestedWidth.isFinite
      ? requestedWidth.clamp(320.0, 2560.0)
      : 1280.0;
  final windowSize = Size(width, 800);
  final output = await Directory(
    'build/benchmarks',
  ).absolute.create(recursive: true);
  final state = _BenchmarkState(await _cover(output));
  await state.setIndependentPlayback(true);
  await initWindowFrame();
  await windowManager.setSize(windowSize);
  final media = SystemMediaController(state);
  runApp(LazerApp(state: state, audio: _UnusedAudio(), media: media));
  if (Platform.environment['LAZER_UI_REVIEW'] == '1') {
    await windowManager.setTitle('Lazer - Mobile UI review');
    return;
  }
  await Future<void>.delayed(const Duration(seconds: 3));
  final refresh = WidgetsBinding
      .instance
      .platformDispatcher
      .views
      .first
      .display
      .refreshRate;
  final samples = <Map<String, Object>>[];
  final frames = <FrameTiming>[];
  var capture = false;
  void timings(List<FrameTiming> batch) {
    if (capture) frames.addAll(batch);
  }

  SchedulerBinding.instance.addTimingsCallback(timings);
  try {
    for (final mode in AppBackgroundMode.values.where(
      (mode) => [
        'nowPlayingDynamic',
        'nowPlayingStatic',
        'windowsMica',
      ].contains(mode.name),
    )) {
      await state.setAppBackground(mode);
      await state.setPlayerBackground(mode);
      await Future<void>.delayed(const Duration(seconds: 1));
      for (var attempt = 0; attempt < 4; attempt++) {
        frames.clear();
        capture = true;
        if (useCompactLayout(
          state.uiMode,
          width,
          layoutStyle: state.layoutStyle,
        )) {
          Element? cover;
          void findCover(Element element) {
            if (element.widget.key == const ValueKey('bottom-track-cover')) {
              cover = element;
            }
            if (cover == null) element.visitChildren(findCover);
          }

          findCover(WidgetsBinding.instance.rootElement!);
          if (cover == null) throw StateError('No mobile player entry');
          // Use the production entry callback; the phone has no hidden bar.
          final entry = cover!.widget as Semantics;
          entry.properties.onTap!();
        } else {
          _widget<AppPlayerBar>().onOpen();
        }
        await Future<void>.delayed(const Duration(milliseconds: 1600));
        capture = false;
        if (frames.isEmpty) {
          throw StateError('Engine supplied no frame timings');
        }
        samples.add({
          'mode': mode.name,
          'attempt': attempt,
          'cold': attempt == 0,
          ..._summary(frames, refresh > 0 ? refresh : 60),
        });
        _widget<NowPlayingPage>().onClose?.call();
        await Future<void>.delayed(const Duration(milliseconds: 1400));
      }
    }
    final report = {
      'buildMode': kProfileMode
          ? 'profile'
          : kReleaseMode
          ? 'release'
          : 'debug',
      'operatingSystem': Platform.operatingSystemVersion,
      'refreshRate': refresh,
      'logicalSize': [windowSize.width, windowSize.height],
      'note':
          'Synthetic local artwork and word-timed lyrics; no audio/network. '
          'Cold = first open for each background mode. Includes entry and 1.6s tail.',
      'samples': samples,
    };
    await File(
      '${output.path}/player-open-${width.round()}.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    debugPrint(jsonEncode(report));
  } finally {
    SchedulerBinding.instance.removeTimingsCallback(timings);
    await windowManager.destroy();
  }
}
