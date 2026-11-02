// Offline native-window resource probe; no account, playback or user settings.
// flutter run --release --no-pub -d windows -t tool/resource_usage_profile.dart
//   --dart-define=PROFILE_OUTPUT=build/reports/resource-usage/current.json
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:ui' show FramePhase;

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:lazer_nextgen/ui/background.dart';
import 'package:window_manager/window_manager.dart';

typedef _ProcessTimesNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<Uint64>,
      Pointer<Uint64>,
      Pointer<Uint64>,
      Pointer<Uint64>,
    );
typedef _ProcessTimes =
    int Function(
      Pointer<Void>,
      Pointer<Uint64>,
      Pointer<Uint64>,
      Pointer<Uint64>,
      Pointer<Uint64>,
    );

class _LifecycleLog with WidgetsBindingObserver {
  final events = <Map<String, Object?>>[];

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    events.add({
      'time_utc': DateTime.now().toUtc().toIso8601String(),
      'state': state.name,
    });
  }
}

// CPU time includes all threads of this process, in units of one CPU core.
// Windows FILETIME values are 100 ns; the probe never opens another process.
Duration? _cpuTime() {
  if (!Platform.isWindows) return null;
  final kernel = DynamicLibrary.open('kernel32.dll');
  final process = kernel
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'GetCurrentProcess',
      )();
  final read = kernel.lookupFunction<_ProcessTimesNative, _ProcessTimes>(
    'GetProcessTimes',
  );
  final times = calloc<Uint64>(4);
  try {
    if (read(process, times, times + 1, times + 2, times + 3) == 0) {
      throw StateError('GetProcessTimes failed');
    }
    return Duration(microseconds: (times[2] + times[3]) ~/ 10);
  } finally {
    calloc.free(times);
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final desktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  final lifecycle = _LifecycleLog();
  WidgetsBinding.instance.addObserver(lifecycle);
  if (desktop) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1280, 720),
        title: 'Lazer resource probe',
        alwaysOnTop: true,
      ),
    );
    await windowManager.show();
    await windowManager.focus();
  }
  final stage = ValueNotifier<(double?, bool)>((30, true));
  runApp(
    MaterialApp(
      home: Scaffold(
        body: ValueListenableBuilder<(double?, bool)>(
          valueListenable: stage,
          builder: (_, value, _) => AlbumFlowBackground(
            colors: const [Color(0xff245889), Color(0xffb5487a)],
            frameRate: value.$1,
            animated: value.$2,
          ),
        ),
      ),
    ),
  );
  var count = 0;
  var recording = false;
  int? firstVsync, lastVsync;
  SchedulerBinding.instance.addPersistentFrameCallback((_) {
    if (recording) {
      count++;
      final timestamp =
          SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
      firstVsync ??= timestamp;
      lastVsync = timestamp;
    }
  });
  final timings = <FrameTiming>[];
  void onTimings(List<FrameTiming> batch) {
    timings.addAll(batch);
  }

  SchedulerBinding.instance.addTimingsCallback(onTimings);
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final results = <String, Object?>{
    'schema_version': 2,
    'time_utc': DateTime.now().toUtc().toIso8601String(),
    'platform': Platform.operatingSystem,
    'renderer': const String.fromEnvironment(
      'PROFILE_RENDERER',
      defaultValue: 'unified-current',
    ),
    'process_id': pid,
    'refresh_hz': view.display.refreshRate,
    'requested_window': '1280x720',
    'logical_view_width': view.physicalSize.width / view.devicePixelRatio,
    'logical_view_height': view.physicalSize.height / view.devicePixelRatio,
    'device_pixel_ratio': view.devicePixelRatio,
    'cpu_units': 'one core = 100%',
    'gpu_busy_measured': false,
    'frame_count_kind':
        'Flutter persistent frame callbacks, not GPU utilization',
    'samples_complete': false,
  };
  const definedOutput = String.fromEnvironment('PROFILE_OUTPUT');
  final output = Platform.environment['PROFILE_OUTPUT'] ?? definedOutput;
  Future<void> save() async {
    if (output.isEmpty) return;
    final file = File(output);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(results));
  }

  final requestedStages = Platform.environment['PROFILE_STAGES']
      ?.split(',')
      .map((name) => name.trim())
      .toSet();
  final stages =
      <(String, double?, bool)>[
            ('10fps', 10, true),
            ('30fps', 30, true),
            ('display_vsync', null, true),
            ('static', 30, false),
          ]
          .where(
            (stage) =>
                requestedStages == null || requestedStages.contains(stage.$1),
          )
          .toList();
  if (stages.isEmpty) throw ArgumentError('PROFILE_STAGES selected no stages');
  results['stages'] = stages.map((stage) => stage.$1).toList();
  for (final (name, fps, animated) in stages) {
    if (desktop) {
      if (await windowManager.isMinimized()) await windowManager.restore();
      await windowManager.show();
      await windowManager.focus();
    }
    stage.value = (fps, animated);
    await Future<void>.delayed(const Duration(seconds: 2));
    final lifecycleBefore = WidgetsBinding.instance.lifecycleState?.name;
    final eventStart = lifecycle.events.length;
    final visibleBefore = desktop ? await windowManager.isVisible() : null;
    final minimizedBefore = desktop ? await windowManager.isMinimized() : null;
    count = 0;
    firstVsync = lastVsync = null;
    timings.clear();
    final rssBefore = ProcessInfo.currentRss;
    final rssSamples = <int>[rssBefore];
    final rssSampler = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => rssSamples.add(ProcessInfo.currentRss),
    );
    final cpuBefore = _cpuTime();
    final sampleStarted = DateTime.now().toUtc().toIso8601String();
    final wall = Stopwatch()..start();
    recording = true;
    await Future<void>.delayed(const Duration(seconds: 5));
    recording = false;
    wall.stop();
    final cpuAfter = _cpuTime();
    rssSampler.cancel();
    final rssAfter = ProcessInfo.currentRss;
    rssSamples.add(rssAfter);
    final lifecycleAfter = WidgetsBinding.instance.lifecycleState?.name;
    final changes = lifecycle.events.sublist(eventStart);
    final visibleAfter = desktop ? await windowManager.isVisible() : null;
    final minimizedAfter = desktop ? await windowManager.isMinimized() : null;
    final sampleEnded = DateTime.now().toUtc().toIso8601String();
    // Release-mode timing reports arrive in batches. Drain them after stopping
    // CPU/RSS sampling and keep only vsyncs actually counted in this stage.
    await Future<void>.delayed(const Duration(seconds: 1));
    final stageTimings = timings.where((frame) {
      final timestamp = frame.timestampInMicroseconds(FramePhase.vsyncStart);
      return firstVsync != null &&
          timestamp >= firstVsync! &&
          timestamp <= lastVsync!;
    }).toList();
    final invalidReasons = <String>[
      // Some Windows runners do not report an initial lifecycle state.
      // Native visibility plus active frame delivery are still observable;
      // a reported inactive/hidden state must never count as an optimization.
      if ((lifecycleBefore != null && lifecycleBefore != 'resumed') ||
          (lifecycleAfter != null && lifecycleAfter != 'resumed'))
        'lifecycle_not_resumed',
      if (changes.any((event) => event['state'] != 'resumed'))
        'lifecycle_changed_while_sampling',
      if (desktop && (visibleBefore != true || visibleAfter != true))
        'window_not_visible',
      if (desktop && (minimizedBefore != false || minimizedAfter != false))
        'window_minimized',
      if (animated && count == 0) 'animated_stage_delivered_no_frames',
    ];
    double p95(Iterable<int> values) {
      final sorted = values.toList()..sort();
      return sorted.isEmpty
          ? 0
          : sorted[((sorted.length - 1) * .95).ceil()] / 1000;
    }

    results[name] = {
      'valid': invalidReasons.isEmpty,
      'invalid_reasons': invalidReasons,
      'warnings': [
        if (lifecycleBefore == null || lifecycleAfter == null)
          'initial_lifecycle_not_reported_by_platform',
      ],
      'lifecycle_before': lifecycleBefore,
      'lifecycle_after': lifecycleAfter,
      'lifecycle_changes': changes,
      'visible_before': visibleBefore,
      'visible_after': visibleAfter,
      'minimized_before': minimizedBefore,
      'minimized_after': minimizedAfter,
      'sample_started_utc': sampleStarted,
      'sample_ended_utc': sampleEnded,
      'wall_ms': wall.elapsedMicroseconds / 1000,
      'scheduled_frames': count,
      'scheduled_frames_per_second': count * 1000000 / wall.elapsedMicroseconds,
      'timing_samples': stageTimings.length,
      'cpu_ms': cpuBefore == null
          ? null
          : (cpuAfter! - cpuBefore).inMicroseconds / 1000,
      'cpu_one_core_percent': cpuBefore == null
          ? null
          : (cpuAfter! - cpuBefore).inMicroseconds *
                100 /
                wall.elapsedMicroseconds,
      'rss_before_bytes': rssBefore,
      'rss_bytes': rssAfter,
      'rss_sample_min_bytes': rssSamples.reduce((a, b) => a < b ? a : b),
      'rss_sample_max_bytes': rssSamples.reduce((a, b) => a > b ? a : b),
      'process_peak_rss_bytes': ProcessInfo.maxRss,
      'build_p95_ms': p95(
        stageTimings.map((frame) => frame.buildDuration.inMicroseconds),
      ),
      'raster_p95_ms': p95(
        stageTimings.map((frame) => frame.rasterDuration.inMicroseconds),
      ),
    };
    await save();
  }
  SchedulerBinding.instance.removeTimingsCallback(onTimings);
  results['samples_complete'] = true;
  results['valid'] = stages.every(
    (stage) => (results[stage.$1]! as Map)['valid'] == true,
  );
  results['lifecycle_events'] = lifecycle.events;
  await save();
  final encoded = jsonEncode(results);
  debugPrint('RESOURCE_USAGE_PROFILE $encoded');
  runApp(const SizedBox.shrink());
  await SchedulerBinding.instance.endOfFrame;
  stage.dispose();
  WidgetsBinding.instance.removeObserver(lifecycle);
  exit(results['valid'] == true ? 0 : 2);
}
