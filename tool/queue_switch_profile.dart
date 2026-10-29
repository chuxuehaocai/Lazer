// Reproducible large-queue track-switch profile, with fake audio and storage.
// flutter run --profile -d windows -t tool/queue_switch_profile.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/legacy/legacy_shell.dart';
import 'package:lazer_nextgen/lyrics/imported_lyrics_store.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Engine implements AudioEngine {
  @override
  bool get active => true;
  @override
  Duration get position => Duration.zero;
  @override
  Duration? get duration => const Duration(minutes: 3);
  @override
  Stream<void> get completed => const Stream.empty();
  @override
  Future<void> setUrl(String url) async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> stop() async {}
  @override
  void dispose() {}
}

class _Gateway extends NeteaseGateway {
  @override
  Future<List<GatewaySong>> songDetails(List<int> ids) async => [];
}

class _Catalog extends Catalog {
  _Catalog() : super(gateway: _Gateway());
  @override
  HomeFeed? get home =>
      const HomeFeed(featuredTracks: [], quick: [], playlists: [], albums: []);
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => 'fake:${track.id}';
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async =>
      const GatewayLyrics(lrc: '[00:00.00]Profile lyric');
}

class _Lyrics extends ImportedLyricsStore {
  @override
  Future<String?> read(Track track) async => null;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // This benchmark is a test harness and must not touch the user's settings.
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues({});
  final state = AppState(
    catalog: _Catalog(),
    audioEngine: _Engine(),
    importedLyrics: _Lyrics(),
  );
  const bool dynamicBackdrop = bool.fromEnvironment('PROFILE_DYNAMIC_BACKDROP');
  if (!dynamicBackdrop) {
    await state.setLegacyBackground(LegacyBackgroundMode.off);
  }
  final tracks = List<Track>.generate(
    5000,
    (i) => Track(
      id: '${i + 1}',
      title: 'Synthetic song $i',
      artist: 'Artist',
      album: 'Album',
      duration: const Duration(minutes: 3),
      coverSeed: i,
    ),
  );
  state.playQueue(tracks);
  runApp(MaterialApp(home: LegacyShell(state: state)));
  final frames = <FrameTiming>[];
  bool recording = false;
  void onFrames(List<FrameTiming> timings) {
    if (recording) frames.addAll(timings);
  }

  SchedulerBinding.instance.addTimingsCallback(onFrames);
  await Future<void>.delayed(const Duration(seconds: 3));
  // Keep vsync active while switching so intervals expose UI-thread stalls.
  final ticker = Ticker((_) {})..start();
  recording = true;
  final switchTimes = <int>[];
  for (int i = 1; i <= 40; i++) {
    final watch = Stopwatch()..start();
    state.playTrackAt(i);
    switchTimes.add(watch.elapsedMicroseconds);
    await Future<void>.delayed(const Duration(milliseconds: 125));
  }
  recording = false;
  ticker.dispose();
  await Future<void>.delayed(const Duration(seconds: 2));
  final prefs = await SharedPreferences.getInstance();
  final saved =
      jsonDecode(prefs.getString('lazer_playback_queue_v1')!)
          as Map<String, dynamic>;
  SchedulerBinding.instance.removeTimingsCallback(onFrames);
  double percentile(List<int> values, double fraction) {
    values.sort();
    return values.isEmpty
        ? 0
        : values[((values.length - 1) * fraction).ceil()] / 1000;
  }

  double p95(List<int> values) => percentile(values, .95);

  final intervals = <int>[
    for (var i = 1; i < frames.length; i++)
      frames[i].timestampInMicroseconds(ui.FramePhase.vsyncStart) -
          frames[i - 1].timestampInMicroseconds(ui.FramePhase.vsyncStart),
  ];
  final output = {
    'dynamic_backdrop': dynamicBackdrop,
    'frames': frames.length,
    'build_p95_ms': p95(
      frames.map((f) => f.buildDuration.inMicroseconds).toList(),
    ),
    'raster_p95_ms': p95(
      frames.map((f) => f.rasterDuration.inMicroseconds).toList(),
    ),
    'switch_call_p95_ms': p95(switchTimes),
    'vsync_interval_p95_ms': p95(List<int>.of(intervals)),
    'vsync_interval_p99_ms': percentile(intervals, .99),
    'intervals_over_16_7ms': intervals.where((us) => us > 16667).length,
    'saved_index': saved['index'],
    'saved_tracks': (saved['tracks'] as List).length,
  };
  const path = String.fromEnvironment('PROFILE_OUTPUT');
  if (path.isNotEmpty) await File(path).writeAsString(jsonEncode(output));
  debugPrint('QUEUE_PROFILE ${jsonEncode(output)}');
  state.dispose();
  exit(0);
}
