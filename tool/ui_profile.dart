// Synthetic profile-mode benchmark. It uses no account, network or music files.
// Run: flutter run --profile -d windows -t tool/ui_profile.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:lazer_nextgen/data/lyrics.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/widgets/lyric_viewport.dart';
import 'package:lazer_nextgen/widgets/playback_queue_view.dart';

const _track = Track(
  id: '1',
  title: 'Profile track',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 5),
  coverSeed: 1,
);

class _ProfileState extends AppState {
  _ProfileState() {
    lyrics = [
      for (int i = 0; i < 200; i++)
        LyricLine(
          Duration(seconds: i * 2),
          'A representative lyric line $i',
          words: [
            LyricWord(
              Duration(seconds: i * 2),
              const Duration(seconds: 2),
              'A representative lyric line $i',
            ),
          ],
        ),
    ];
  }
  final entries = List<Track>.generate(
    5000,
    (i) => Track(
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
  Duration get precisePosition => const Duration(seconds: 1);
  @override
  List<Track> get queue => List<Track>.unmodifiable(entries);
}

Map<String, Object> _summarize(List<FrameTiming> frames) {
  List<int> sorted(Iterable<int> values) => values.toList()..sort();
  double ms(int us) => us / 1000;
  double percentile(List<int> values, double p) =>
      values.isEmpty ? 0 : ms(values[((values.length - 1) * p).ceil()]);
  final build = sorted(frames.map((f) => f.buildDuration.inMicroseconds));
  final raster = sorted(frames.map((f) => f.rasterDuration.inMicroseconds));
  return {
    'frames': frames.length,
    'build_p50_ms': percentile(build, .5),
    'build_p95_ms': percentile(build, .95),
    'raster_p50_ms': percentile(raster, .5),
    'raster_p95_ms': percentile(raster, .95),
  };
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final state = _ProfileState();
  final mode = ValueNotifier<int>(0);
  final queueKey = GlobalKey();
  runApp(
    MaterialApp(
      home: Scaffold(
        body: ValueListenableBuilder<int>(
          valueListenable: mode,
          builder: (_, value, _) => value == 0
              ? LyricViewport(state: state)
              : PlaybackQueueView(key: queueKey, state: state),
        ),
      ),
    ),
  );
  unawaited(() async {
    final samples = <FrameTiming>[];
    bool recording = false;
    void onFrames(List<FrameTiming> frames) {
      if (recording) samples.addAll(frames);
    }

    SchedulerBinding.instance.addTimingsCallback(onFrames);
    await Future<void>.delayed(const Duration(seconds: 3));
    recording = true;
    await Future<void>.delayed(const Duration(seconds: 5));
    recording = false;
    final lyrics = _summarize(samples);
    samples.clear();
    mode.value = 1;
    await Future<void>.delayed(const Duration(seconds: 2));
    ScrollableState? scroll;
    void findScroll(Element element) {
      if (element is StatefulElement && element.state is ScrollableState) {
        scroll = element.state as ScrollableState;
      }
      if (scroll == null) element.visitChildren(findScroll);
    }

    queueKey.currentContext!.visitChildElements(findScroll);
    if (scroll == null) throw StateError('Queue scrollable not found');
    recording = true;
    for (int i = 0; i < 4; i++) {
      await scroll!.position.animateTo(
        (i + 1) * 4000,
        duration: const Duration(milliseconds: 1200),
        curve: Curves.linear,
      );
    }
    recording = false;
    final queue = _summarize(samples);
    SchedulerBinding.instance.removeTimingsCallback(onFrames);
    final output = {'lyrics': lyrics, 'queue_scroll': queue};
    const path = String.fromEnvironment('PROFILE_OUTPUT');
    if (path.isNotEmpty) await File(path).writeAsString(jsonEncode(output));
    debugPrint('UI_PROFILE ${jsonEncode(output)}');
    state.dispose();
    exit(0);
  }());
}
