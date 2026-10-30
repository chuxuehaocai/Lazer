// Offline profile-mode probe for lyric rendering and retained memory.
// flutter run --profile -d windows -t tool/rendering_profile.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:lazer_nextgen/data/lyrics.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/widgets/lyric_viewport.dart';
import 'package:lazer_nextgen/widgets/timed_lyric_text.dart';

class _State extends AppState {
  _State() {
    lyrics = <LyricLine>[
      for (var line = 0; line < 300; line++)
        LyricLine(
          Duration(seconds: line * 4),
          'A representative lyric with several animated words',
          translation: 'A translated lyric line',
          words: <LyricWord>[
            for (final (index, word) in <String>[
              'A ',
              'representative ',
              'lyric ',
              'with ',
              'several ',
              'animated ',
              'words',
            ].indexed)
              LyricWord(
                Duration(milliseconds: line * 4000 + index * 500),
                Duration(milliseconds: index == 1 ? 1500 : 500),
                word,
              ),
          ],
        ),
    ];
  }

  final Stopwatch clock = Stopwatch();

  @override
  Track? get current => const Track(
    id: 'render-profile',
    title: 'Synthetic rendering profile',
    artist: 'Synthetic artist',
    album: 'Synthetic album',
    duration: Duration(minutes: 20),
    coverSeed: 1,
  );
  @override
  bool get playing => true;
  @override
  Duration get precisePosition => clock.elapsed;
}

Map<String, Object> _summary(List<FrameTiming> frames) {
  double percentile(Iterable<int> samples, double p) {
    final sorted = samples.toList()..sort();
    return sorted.isEmpty ? 0 : sorted[((sorted.length - 1) * p).ceil()] / 1000;
  }

  final intervals = [
    for (var i = 1; i < frames.length; i++)
      frames[i].timestampInMicroseconds(ui.FramePhase.vsyncStart) -
          frames[i - 1].timestampInMicroseconds(ui.FramePhase.vsyncStart),
  ];
  return {
    'frames': frames.length,
    'build_p50_ms': percentile(
      frames.map((f) => f.buildDuration.inMicroseconds),
      .5,
    ),
    'build_p95_ms': percentile(
      frames.map((f) => f.buildDuration.inMicroseconds),
      .95,
    ),
    'raster_p50_ms': percentile(
      frames.map((f) => f.rasterDuration.inMicroseconds),
      .5,
    ),
    'raster_p95_ms': percentile(
      frames.map((f) => f.rasterDuration.inMicroseconds),
      .95,
    ),
    'vsync_p95_ms': percentile(intervals, .95),
    'intervals_over_16_7ms': intervals.where((us) => us > 16667).length,
  };
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = _State();
  final mode = ValueNotifier(0);
  final repaint = ValueNotifier(0);
  final rows = List<LyricLine>.generate(16, (i) => state.lyrics[i]);
  runApp(
    MaterialApp(
      home: Scaffold(
        backgroundColor: const Color(0xff243142),
        body: ValueListenableBuilder<int>(
          valueListenable: mode,
          builder: (_, value, _) => value == 0
              ? Center(
                  child: SizedBox(
                    width: 680,
                    child: LyricViewport(state: state),
                  ),
                )
              : Column(
                  children: [
                    for (var i = 0; i < rows.length; i++)
                      SizedBox(
                        width: 760,
                        height: 36,
                        child: TimedLyricText(
                          key: ValueKey((value, i)),
                          line: rows[i],
                          style: const TextStyle(
                            fontSize: 18,
                            color: Colors.white,
                          ),
                          active: i == 0,
                          position: () => state.precisePosition,
                          repaint: repaint,
                        ),
                      ),
                  ],
                ),
        ),
      ),
    ),
  );
  await Future<void>.delayed(const Duration(seconds: 2));
  state.clock.start();
  final frames = <FrameTiming>[];
  void onFrames(List<FrameTiming> timings) => frames.addAll(timings);
  SchedulerBinding.instance.addTimingsCallback(onFrames);
  await Future<void>.delayed(const Duration(seconds: 8));
  SchedulerBinding.instance.removeTimingsCallback(onFrames);
  final result = <String, Object>{
    'active_lyrics': _summary(frames),
    'active_rss_bytes': ProcessInfo.currentRss,
  };
  // Repeatedly open a page of word-timed rows to include layout bursts and
  // off-focus paragraphs, rather than only sampling a warmed single row.
  frames.clear();
  SchedulerBinding.instance.addTimingsCallback(onFrames);
  for (var i = 1; i <= 20; i++) {
    mode.value = i;
    repaint.value++;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  SchedulerBinding.instance.removeTimingsCallback(onFrames);
  result['row_layout_bursts'] = _summary(frames);
  result['row_layout_rss_bytes'] = ProcessInfo.currentRss;
  result['peak_rss_bytes'] = ProcessInfo.maxRss;
  const output = String.fromEnvironment('PROFILE_OUTPUT');
  final encoded = jsonEncode(result);
  if (output.isNotEmpty) await File(output).writeAsString(encoded);
  debugPrint('RENDERING_PROFILE $encoded');
  await SchedulerBinding.instance.endOfFrame;
  runApp(const SizedBox.shrink());
  await Future<void>.delayed(const Duration(milliseconds: 100));
  state.dispose();
  repaint.dispose();
  mode.dispose();
  exit(0);
}
