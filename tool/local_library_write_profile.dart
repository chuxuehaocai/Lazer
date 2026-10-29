// Synthetic local manifest write profile; uses only a temporary directory.
// flutter run --profile -d windows -t tool/local_library_write_profile.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/local/local_library.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(home: Scaffold(body: Text('Local library profile'))),
  );
  final directory = await io.Directory.systemTemp.createTemp(
    'lazer-local-profile-',
  );
  try {
    final records = <Map<String, dynamic>>[
      for (var i = 0; i < 5000; i++)
        LocalTrack(
          track: Track(
            id: '$i',
            title: 'Synthetic $i',
            artist: 'Artist',
            album: 'Album',
            duration: const Duration(minutes: 3),
            coverSeed: i,
          ),
          path: '${directory.path}/synthetic-$i.mp3',
          source: LocalTrackSource.scan,
          modifiedAt: DateTime.fromMillisecondsSinceEpoch(0),
          addedAt: DateTime.fromMillisecondsSinceEpoch(i),
        ).toJson(),
    ];
    final file = io.File('${directory.path}/local_library.json');
    await file.writeAsString(
      jsonEncode({'version': 1, 'tracks': records, 'scanRoots': <String>[]}),
    );
    final frames = <FrameTiming>[];
    var recording = false;
    void onFrames(List<FrameTiming> timings) {
      if (recording) frames.addAll(timings);
    }

    SchedulerBinding.instance.addTimingsCallback(onFrames);
    await Future<void>.delayed(const Duration(seconds: 2));
    final ticker = Ticker((_) {})..start();
    final library = LocalLibrary(
      supportDirectory: () async => directory,
      documentsDirectory: () async => directory,
      fileExists: (_) async => true,
    );
    await library.load();
    while (library.verifying) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    final latencies = <int>[];
    recording = true;
    for (var i = 0; i < 12; i++) {
      final watch = Stopwatch()..start();
      await library.addScanRoot('${directory.path}/root-$i');
      latencies.add(watch.elapsedMicroseconds);
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    final saved = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if ((saved['tracks'] as List).length != 5000 ||
        (saved['scanRoots'] as List).length != 12) {
      throw StateError('Invalid manifest');
    }
    library.dispose();
    recording = false;
    ticker.dispose();
    SchedulerBinding.instance.removeTimingsCallback(onFrames);
    double percentile(List<int> values, double p) {
      values.sort();
      return values.isEmpty
          ? 0
          : values[((values.length - 1) * p).ceil()] / 1000;
    }

    final intervals = <int>[
      for (var i = 1; i < frames.length; i++)
        frames[i].timestampInMicroseconds(ui.FramePhase.vsyncStart) -
            frames[i - 1].timestampInMicroseconds(ui.FramePhase.vsyncStart),
    ];
    final result = {
      'bytes': await file.length(),
      'writes': latencies.length,
      'frames': frames.length,
      'write_p95_ms': percentile(latencies, .95),
      'vsync_p99_ms': percentile(intervals, .99),
      'intervals_over_16_7ms': intervals.where((us) => us > 16667).length,
    };
    const path = String.fromEnvironment('PROFILE_OUTPUT');
    if (path.isNotEmpty) await io.File(path).writeAsString(jsonEncode(result));
    debugPrint('LOCAL_WRITE_PROFILE ${jsonEncode(result)}');
  } finally {
    await directory.delete(recursive: true);
  }
  io.exit(0);
}
