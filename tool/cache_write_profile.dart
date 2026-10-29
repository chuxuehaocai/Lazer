// Synthetic large-cache write profile. No disk, network or user data.
// flutter run --profile -d windows -t tool/cache_write_profile.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:lazer_nextgen/cache/disk_cache.dart';

class _MemoryCache extends DiskCache {
  List<int>? lastBytes;
  @override
  Future<io.File?> put(
    CacheBucket bucket,
    String key,
    Stream<List<int>> Function() source, {
    String extension = 'bin',
    int? expectedLength,
    int? maxBytes,
  }) async {
    final result = <int>[];
    await for (final chunk in source()) {
      result.addAll(chunk);
    }
    lastBytes = result;
    return null;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('Cache profile'))),
    ),
  );
  final data = <String, dynamic>{
    'tracks': [
      for (var i = 0; i < 5000; i++)
        {
          'id': '$i',
          'title': 'Synthetic track $i',
          'artist': 'Artist $i',
          'artists': [
            {'id': i, 'name': 'Artist $i'},
          ],
          'album': 'Album $i',
          'durationMs': 180000,
        },
    ],
  };
  final cache = _MemoryCache();
  final frames = <FrameTiming>[];
  bool recording = false;
  void onFrames(List<FrameTiming> timings) {
    if (recording) frames.addAll(timings);
  }

  SchedulerBinding.instance.addTimingsCallback(onFrames);
  await Future<void>.delayed(const Duration(seconds: 2));
  final ticker = Ticker((_) {})..start();
  recording = true;
  final synchronous = <int>[];
  final total = <int>[];
  for (var i = 0; i < 20; i++) {
    final watch = Stopwatch()..start();
    final write = cache.writeJson('profile', data);
    synchronous.add(watch.elapsedMicroseconds);
    await write;
    total.add(watch.elapsedMicroseconds);
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }
  recording = false;
  ticker.dispose();
  SchedulerBinding.instance.removeTimingsCallback(onFrames);
  final saved =
      jsonDecode(utf8.decode(cache.lastBytes!)) as Map<String, dynamic>;
  if ((saved['data']['tracks'] as List).length != 5000) {
    throw StateError('Invalid cache');
  }
  double percentile(List<int> values, double p) {
    values.sort();
    return values.isEmpty ? 0 : values[((values.length - 1) * p).ceil()] / 1000;
  }

  final intervals = <int>[
    for (var i = 1; i < frames.length; i++)
      frames[i].timestampInMicroseconds(ui.FramePhase.vsyncStart) -
          frames[i - 1].timestampInMicroseconds(ui.FramePhase.vsyncStart),
  ];
  final output = {
    'bytes': cache.lastBytes!.length,
    'writes': total.length,
    'frames': frames.length,
    'call_p95_ms': percentile(synchronous, .95),
    'total_p95_ms': percentile(total, .95),
    'vsync_p99_ms': percentile(intervals, .99),
    'intervals_over_16_7ms': intervals.where((us) => us > 16667).length,
  };
  const path = String.fromEnvironment('PROFILE_OUTPUT');
  if (path.isNotEmpty) await io.File(path).writeAsString(jsonEncode(output));
  debugPrint('CACHE_PROFILE ${jsonEncode(output)}');
  io.exit(0);
}
