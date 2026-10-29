// Synthetic catalogue conversion benchmark; fake network and cache only.
// flutter run --profile -d windows -t tool/catalog_profile.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:lazer_nextgen/cache/disk_cache.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';

class _Cache extends DiskCache {
  _Cache({this.value});
  CachedJson? value;
  @override
  Future<CachedJson?> readJson(String key) async => value;
  @override
  Future<void> writeJson(
    String key,
    Map<String, dynamic> data, {
    DateTime? savedAt,
  }) async {
    value = CachedJson(data, savedAt ?? DateTime.now());
  }
}

class _Gateway extends NeteaseGateway {
  @override
  Future<Map<String, dynamic>> playlistDetail(
    int id, {
    int subscriberLimit = 8,
  }) async => {
    'playlist': {
      'id': id,
      'name': 'Fixture',
      'trackCount': 5000,
      'trackIds': [
        for (int i = 1; i <= 5000; i++) {'id': i},
      ],
    },
  };
  @override
  Future<List<GatewaySong>> songDetails(List<int> ids) async => [
    for (final id in ids)
      GatewaySong(
        id: id,
        title: 'Song $id',
        artists: ['Artist $id'],
        albumName: 'Album',
        duration: const Duration(minutes: 3),
        albumId: 1,
      ),
  ];
}

Track track(int i) => Track(
  id: '$i',
  title: 'Song $i',
  artist: 'Artist $i',
  album: 'Album',
  duration: const Duration(minutes: 3),
  coverSeed: i,
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('Catalogue profile'))),
    ),
  );
  final data = {
    'tracks': [for (int i = 1; i <= 5000; i++) track(i).toJson()],
  };
  final frames = <FrameTiming>[];
  bool recording = false;
  void onFrames(List<FrameTiming> timings) {
    if (recording) frames.addAll(timings);
  }

  SchedulerBinding.instance.addTimingsCallback(onFrames);
  await Future<void>.delayed(const Duration(seconds: 2));
  final ticker = Ticker((_) {})..start();
  double percentile(List<int> values, double p) {
    values.sort();
    return values.isEmpty ? 0 : values[((values.length - 1) * p).ceil()] / 1000;
  }

  Future<Map<String, Object>> sample({required bool fromCache}) async {
    frames.clear();
    recording = true;
    final times = <int>[];
    for (int i = 0; i < 12; i++) {
      final cache = _Cache(
        value: fromCache ? CachedJson(data, DateTime.now()) : null,
      );
      final catalog = Catalog(gateway: _Gateway(), cache: cache);
      final watch = Stopwatch()..start();
      final tracks = await catalog.playlistTracks('12');
      times.add(watch.elapsedMicroseconds);
      if (tracks.length != 5000 || tracks.last.id != '5000') {
        throw StateError('Bad playlist');
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    recording = false;
    final intervals = <int>[
      for (var i = 1; i < frames.length; i++)
        frames[i].timestampInMicroseconds(ui.FramePhase.vsyncStart) -
            frames[i - 1].timestampInMicroseconds(ui.FramePhase.vsyncStart),
    ];
    return {
      'frames': frames.length,
      'latency_p95_ms': percentile(times, .95),
      'vsync_p99_ms': percentile(intervals, .99),
      'intervals_over_16_7ms': intervals.where((v) => v > 16667).length,
    };
  }

  final result = {
    'cold_memory_cache': await sample(fromCache: true),
    'fake_network': await sample(fromCache: false),
  };
  ticker.dispose();
  SchedulerBinding.instance.removeTimingsCallback(onFrames);
  const path = String.fromEnvironment('PROFILE_OUTPUT');
  if (path.isNotEmpty) await io.File(path).writeAsString(jsonEncode(result));
  debugPrint('CATALOG_PROFILE ${jsonEncode(result)}');
  io.exit(0);
}
