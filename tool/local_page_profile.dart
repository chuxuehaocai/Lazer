// Synthetic local library page rebuild profile, without user files or settings.
import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/local/local_library.dart';
import 'package:lazer_nextgen/local/local_music_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';

class FakeLibrary extends LocalLibrary {
  final entries = List<LocalTrack>.generate(
    5000,
    (i) => LocalTrack(
      track: Track(
        id: '$i',
        title: 'Song $i',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(minutes: 3),
        coverSeed: i,
      ),
      path: '/synthetic/$i.mp3',
      source: LocalTrackSource.scan,
      modifiedAt: DateTime.fromMillisecondsSinceEpoch(0),
      addedAt: DateTime.fromMillisecondsSinceEpoch((i * 7919) % 5000),
    ),
  );
  @override
  List<LocalTrack> get tracks => List<LocalTrack>.unmodifiable(entries);
  @override
  Future<void> refreshMissing() async {}
  void reportUnchanged() => notifyListeners();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final library = FakeLibrary();
  final state = AppState(localLibrary: library);
  runApp(
    MaterialApp(
      home: Scaffold(body: LocalMusicPage(state: state)),
    ),
  );
  await Future<void>.delayed(const Duration(seconds: 2));
  final frames = <FrameTiming>[];
  var recording = true;
  void onFrames(List<FrameTiming> timings) {
    if (recording) frames.addAll(timings);
  }

  SchedulerBinding.instance.addTimingsCallback(onFrames);
  final ticker = Ticker((_) {})..start();
  for (var i = 0; i < 40; i++) {
    library.reportUnchanged();
    await Future<void>.delayed(const Duration(milliseconds: 125));
  }
  recording = false;
  ticker.dispose();
  SchedulerBinding.instance.removeTimingsCallback(onFrames);
  double percentile(List<int> values, double p) {
    values.sort();
    return values.isEmpty ? 0 : values[((values.length - 1) * p).ceil()] / 1000;
  }

  final builds = [
    for (final frame in frames) frame.buildDuration.inMicroseconds,
  ];
  final intervals = <int>[
    for (var i = 1; i < frames.length; i++)
      frames[i].timestampInMicroseconds(ui.FramePhase.vsyncStart) -
          frames[i - 1].timestampInMicroseconds(ui.FramePhase.vsyncStart),
  ];
  final result = {
    'frames': frames.length,
    'build_p95_ms': percentile(builds, .95),
    'build_p99_ms': percentile(builds, .99),
    'vsync_p99_ms': percentile(intervals, .99),
    'intervals_over_16_7ms': intervals.where((us) => us > 16667).length,
  };
  const path = String.fromEnvironment('PROFILE_OUTPUT');
  if (path.isNotEmpty) await io.File(path).writeAsString(jsonEncode(result));
  debugPrint('LOCAL_PAGE_PROFILE ${jsonEncode(result)}');
  state.dispose();
  io.exit(0);
}
