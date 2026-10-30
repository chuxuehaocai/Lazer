// Profile the real player route with a synthetic queue and timed lyrics.
// Run: flutter run --profile -d windows -t tool/player_lifecycle_profile.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:lazer_nextgen/data/lyrics.dart';
import 'package:lazer_nextgen/accessibility/lazer_binding.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/player/now_playing_route.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:window_manager/window_manager.dart';

const Track _track = Track(
  id: 'profile-track',
  title: 'Profile track',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 5),
  coverSeed: 1,
);

class _ProfileState extends AppState {
  _ProfileState() {
    const List<String> words = <String>[
      '春天的',
      '风',
      '吹过',
      '安静的',
      '湖面，',
      '我们',
      '沿着',
      '小路',
      '走向',
      '远方。',
    ];
    lyrics = <LyricLine>[
      for (int i = 0; i < 200; i++) _wordTimedLine(i, words),
    ];
  }

  static LyricLine _wordTimedLine(int index, List<String> words) {
    final Duration lineStart = Duration(seconds: index * 3);
    var offset = lineStart;
    final List<LyricWord> timedWords = <LyricWord>[
      for (int i = 0; i < words.length; i++)
        () {
          final Duration duration = Duration(milliseconds: i == 0 ? 1200 : 200);
          final LyricWord word = LyricWord(offset, duration, words[i]);
          offset += duration;
          return word;
        }(),
    ];
    return LyricLine(lineStart, words.join(), words: timedWords);
  }

  final List<Track> _queue = List<Track>.generate(
    5000,
    (int i) => Track(
      id: '$i',
      title: 'Profile song $i',
      artist: 'Artist',
      album: 'Album',
      duration: const Duration(minutes: 3),
      coverSeed: i,
    ),
  );

  @override
  Track? get current => _track;
  @override
  bool get playing => true;
  @override
  int get queueIndex => 0;
  @override
  Duration get precisePosition =>
      const Duration(seconds: 1) + _songClock.elapsed;
  @override
  List<Track> get queue => _queue;
  @override
  bool get currentLyricsSettled => true;
  @override
  Future<void> ensureCurrentLyrics({bool force = false}) async {}

  final Stopwatch _songClock = Stopwatch()..start();
}

Map<String, Object> _summarize(List<FrameTiming> frames) {
  List<int> sorted(Iterable<int> values) => values.toList()..sort();
  double ms(int us) => us / 1000;
  double percentile(List<int> values, double p) =>
      values.isEmpty ? 0 : ms(values[((values.length - 1) * p).ceil()]);
  final List<int> build = sorted(
    frames.map((FrameTiming frame) => frame.buildDuration.inMicroseconds),
  );
  final List<int> raster = sorted(
    frames.map((FrameTiming frame) => frame.rasterDuration.inMicroseconds),
  );
  final List<int> intervals = <int>[
    for (int i = 1; i < frames.length; i++)
      frames[i].timestampInMicroseconds(ui.FramePhase.vsyncStart) -
          frames[i - 1].timestampInMicroseconds(ui.FramePhase.vsyncStart),
  ];
  return <String, Object>{
    'frames': frames.length,
    'build_p50_ms': percentile(build, .5),
    'build_p95_ms': percentile(build, .95),
    'raster_p50_ms': percentile(raster, .5),
    'raster_p95_ms': percentile(raster, .95),
    'vsync_p95_ms': percentile(sorted(intervals), .95),
    'frames_over_16_7ms': intervals.where((int us) => us > 16667).length,
  };
}

Future<Map<String, Object>> _measure(
  Future<void> Function() start,
  Duration duration,
) async {
  final List<FrameTiming> frames = <FrameTiming>[];
  bool recording = true;
  void onFrames(List<FrameTiming> timings) {
    if (recording) frames.addAll(timings);
  }

  SchedulerBinding.instance.addTimingsCallback(onFrames);
  await start();
  await Future<void>.delayed(duration);
  recording = false;
  SchedulerBinding.instance.removeTimingsCallback(onFrames);
  return _summarize(frames);
}

Future<void> main() async {
  LazerWidgetsBinding();
  final semantics = WidgetsBinding.instance.ensureSemantics();
  await windowManager.ensureInitialized();
  await windowManager.setSize(const Size(1280, 800));
  final _ProfileState state = _ProfileState();
  final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();
  runApp(MaterialApp(navigatorKey: navigator, home: const SizedBox.shrink()));
  await Future<void>.delayed(const Duration(seconds: 2));

  final Map<String, Object> open = await _measure(() async {
    navigator.currentState!.push<void>(NowPlayingRoute(state: state));
  }, const Duration(milliseconds: 700));
  final Map<String, Object> active = await _measure(
    () async {},
    const Duration(seconds: 4),
  );
  state.lyricBlurEnabled = false;
  state.notifyListeners();
  final Map<String, Object> blurOff = await _measure(
    () async {},
    const Duration(seconds: 4),
  );
  final Map<String, Object> close = await _measure(() async {
    navigator.currentState!.pop();
  }, const Duration(milliseconds: 700));
  final Map<String, Object> output = <String, Object>{
    'open': open,
    'active_lyrics': active,
    'active_lyrics_blur_off': blurOff,
    'close': close,
  };
  debugPrint('PLAYER_LIFECYCLE_PROFILE ${jsonEncode(output)}');
  state.dispose();
  semantics.dispose();
  exit(0);
}
