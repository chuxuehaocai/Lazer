// Run on the desktop runner, not flutter test's mocked plugin environment:
// flutter run --no-pub --release -d windows -t tool/validation/still_alive_audio_probe.dart
// This verifies asset decoding, native progress and release, not human hearing.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lazer_nextgen/easter_egg/still_alive_audio.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('Still Alive audio validation'))),
    ),
  );
  final result = <String, Object?>{
    'probe': 'still_alive_audio',
    'asset': stillAliveAudioAsset,
    'platform': Platform.operatingSystem,
  };
  // ignore: invalid_use_of_visible_for_testing_member
  final backend = createStillAliveAudioBackend();
  final controller = StillAliveAudio(
    volume: .15,
    backendFactory: () => backend,
  );
  final second = StillAliveAudio(volume: .15);
  StillAliveAudioSnapshot? latest;
  final reports = <Map<String, Object?>>[];
  final subscription = backend.snapshots.listen((report) {
    latest = report;
    reports.add({
      'positionMs': report.position.inMilliseconds,
      'playing': report.playing,
      'status': report.status.name,
    });
  });

  Future<void> waitFor(
    bool Function() predicate,
    String description, [
    Duration timeout = const Duration(seconds: 8),
  ]) async {
    final watch = Stopwatch()..start();
    while (!predicate()) {
      if (controller.error != null) throw StateError(controller.error!);
      if (watch.elapsed >= timeout) {
        throw StateError('Timed out waiting for $description');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> verifyReplay(String name) async {
    await controller.restart().timeout(const Duration(seconds: 15));
    await waitFor(
      () =>
          latest?.status == StillAliveAudioStatus.ready &&
          latest!.playing &&
          latest!.position > const Duration(milliseconds: 300) &&
          latest!.position < const Duration(seconds: 3),
      '$name decoder progress',
    );
    result[name] = {
      'nativePositionMs': latest!.position.inMilliseconds,
      'status': latest!.status.name,
      'nativePlaying': latest!.playing,
      'playing': controller.playing,
      'positionMs': controller.position.inMilliseconds,
    };
    if (!controller.playing) throw StateError('$name did not restart');
  }

  var status = 1;
  try {
    await controller.load().timeout(const Duration(seconds: 30));
    result['ready'] = controller.ready;
    result['durationMs'] = controller.duration?.inMilliseconds;
    if (!controller.ready || controller.error != null) {
      throw StateError(controller.error ?? 'Audio did not become ready');
    }
    await controller.play().timeout(const Duration(seconds: 15));
    final startedAt = controller.position;
    await Future<void>.delayed(const Duration(seconds: 3));
    final playedUntil = controller.position;
    result['playing'] = controller.playing;
    result['advancedMs'] = (playedUntil - startedAt).inMilliseconds;
    await controller.pause();
    final pausedAt = controller.position;
    await Future<void>.delayed(const Duration(milliseconds: 350));
    result['pauseDriftMs'] = (controller.position - pausedAt).inMilliseconds;

    // Loading another egg must keep the existing player's platform registry.
    await second.load().timeout(const Duration(seconds: 30));
    result['secondReady'] = second.ready;
    await second.close();
    await controller.play().timeout(const Duration(seconds: 15));
    final resumedAt = controller.position;
    await Future<void>.delayed(const Duration(milliseconds: 700));
    result['resumedMs'] = (controller.position - resumedAt).inMilliseconds;
    await verifyReplay('midSongReplay');
    await verifyReplay('consecutiveReplay');

    // Let the real decoder reach EOF. UI clock advancement alone cannot prove
    // that the plugin cleared its completed state for the following pass.
    await backend.seek(
      controller.duration! - const Duration(milliseconds: 600),
    );
    await waitFor(
      () =>
          !controller.playing &&
          controller.position >= controller.duration! &&
          latest?.status == StillAliveAudioStatus.completed,
      'native completion',
    );
    result['nativeCompletion'] = {
      'positionMs': latest!.position.inMilliseconds,
      'playing': latest!.playing,
      'status': latest!.status.name,
    };
    await verifyReplay('completedReplay');

    await backend.seek(
      controller.duration! - const Duration(milliseconds: 600),
    );
    await waitFor(
      () =>
          !controller.playing &&
          latest?.status == StillAliveAudioStatus.completed,
      'second native completion',
    );
    await controller.pause();
    await verifyReplay('pausedCompletedReplay');

    final restarting = controller.restart();
    await controller.pause();
    await restarting;
    await Future<void>.delayed(const Duration(milliseconds: 350));
    result['concurrentPausePlaying'] = controller.playing;
    result['concurrentPauseNativePlaying'] = latest?.playing;
    if (controller.playing || latest?.playing == true) {
      throw StateError('A cancelled replay resumed after pause');
    }
    await verifyReplay('replayAfterConcurrentPause');
    result['error'] = controller.error;
    if (!controller.playing ||
        playedUntil - startedAt < const Duration(seconds: 1) ||
        (result['resumedMs'] as int) < 200 ||
        result['pauseDriftMs'] != 0 ||
        controller.error != null ||
        result['secondReady'] != true) {
      throw StateError('Decoder progress or lifecycle contract did not pass');
    }
    status = 0;
  } catch (error, stack) {
    result['failure'] = '$error';
    result['stack'] = '$stack';
  } finally {
    await second.close();
    second.dispose();
    await controller.close();
    await subscription.cancel();
    result['closedPlaying'] = controller.playing;
    controller.dispose();
  }
  if (status != 0) result['reports'] = reports;
  result['passed'] = status == 0;
  final text = const JsonEncoder.withIndent('  ').convert(result);
  // Windows GUI runners may have no attached console when launched directly.
  final report = File('build/reports/still-alive-audio-live.json');
  report.parent.createSync(recursive: true);
  report.writeAsStringSync(text);
  // ignore: avoid_print
  print(text);
  exit(status);
}
