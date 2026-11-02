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
  final controller = StillAliveAudio(volume: .15);
  final second = StillAliveAudio(volume: .15);
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
    result['error'] = controller.error;
    if (!controller.playing ||
        playedUntil - startedAt < const Duration(seconds: 1) ||
        controller.position - resumedAt < const Duration(milliseconds: 200) ||
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
    result['closedPlaying'] = controller.playing;
    controller.dispose();
  }
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
