// Pure-Dart motion benchmark; no account, network, audio or Flutter runner.
// dart run tool/lyric_motion_profile.dart
import 'dart:convert';
import 'dart:io';

import 'package:lazer_nextgen/lyrics/word_motion.dart';

void main(List<String> arguments) {
  const iterations = 200000;
  final results = <String, Object>{};
  var checksum = 0.0;
  for (final mode in ['ordinary', 'emphasized', 'held']) {
    double sample(int i) {
      final elapsed = (i % 4000).toDouble();
      final motion = mode == 'ordinary'
          ? LyricWordMotion.ordinary(elapsed, 1800)
          : LyricWordMotion.emphasized(
              elapsed,
              1800,
              i % 8,
              8,
              last: i.isEven,
              holdFloat: mode == 'held',
            );
      return motion.scale + motion.xEm + motion.yEm + motion.glow;
    }

    for (var i = 0; i < 20000; i++) {
      checksum += sample(i);
    }
    final times = <int>[];
    for (var round = 0; round < 7; round++) {
      final watch = Stopwatch()..start();
      for (var i = 0; i < iterations; i++) {
        checksum += sample(i);
      }
      times.add(watch.elapsedMicroseconds);
    }
    times.sort();
    results[mode] = {
      'calls': iterations,
      'median_ms': times[times.length ~/ 2] / 1000,
      'p95_ms': times.last / 1000,
    };
  }
  results['checksum'] = checksum;
  final output = jsonEncode(results);
  stdout.writeln(output);
  if (arguments.isNotEmpty) File(arguments.first).writeAsStringSync(output);
}
