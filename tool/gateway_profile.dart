// Synthetic large-response profile with in-memory HTTP; no network or user data.
// flutter run --profile -d windows -t tool/gateway_profile.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:lazer_nextgen/gateway/transport.dart';

class _Headers implements io.HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  set contentType(io.ContentType? value) {}
  @override
  void forEach(void Function(String, List<String>) action) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements io.HttpClientResponse {
  _Response(this.bytes);
  final List<int> bytes;
  @override
  int get statusCode => 200;
  @override
  final io.HttpHeaders headers = _Headers();
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements io.HttpClientRequest {
  _Request(this.bytes);
  final List<int> bytes;
  @override
  final io.HttpHeaders headers = _Headers();
  @override
  void write(Object? object) {}
  @override
  Future<io.HttpClientResponse> close() async => _Response(bytes);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements io.HttpClient {
  _Client(this.bytes);
  final List<int> bytes;
  @override
  Future<io.HttpClientRequest> postUrl(Uri url) async => _Request(bytes);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('Gateway profile'))),
    ),
  );
  final payload = utf8.encode(
    jsonEncode({
      'code': '200',
      'playlist': {
        'tracks': [
          for (var i = 0; i < 5000; i++)
            {
              'id': i,
              'name': 'Synthetic track $i',
              'artists': [
                {'id': i, 'name': 'Artist $i', 'avatarImgId_str': '$i'},
              ],
              'album': {'name': 'Album $i'},
            },
        ],
      },
    }),
  );
  final transport = NeteaseTransport(client: _Client(payload));
  final frames = <FrameTiming>[];
  bool recording = false;
  void onFrames(List<FrameTiming> timings) {
    if (recording) frames.addAll(timings);
  }

  SchedulerBinding.instance.addTimingsCallback(onFrames);
  await Future<void>.delayed(const Duration(seconds: 2));
  final ticker = Ticker((_) {})..start();
  recording = true;
  final latencies = <int>[];
  for (var i = 0; i < 20; i++) {
    final watch = Stopwatch()..start();
    final result = await transport.request('/playlist/detail', {'id': '1'});
    latencies.add(watch.elapsedMicroseconds);
    if ((result['playlist']['tracks'] as List).length != 5000 ||
        result['code'] != 200) {
      throw StateError('Bad response');
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }
  recording = false;
  ticker.dispose();
  SchedulerBinding.instance.removeTimingsCallback(onFrames);
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
    'response_bytes': payload.length,
    'requests': latencies.length,
    'frames': frames.length,
    'request_p50_ms': percentile(List.of(latencies), .5),
    'request_p95_ms': percentile(List.of(latencies), .95),
    'vsync_p99_ms': percentile(List.of(intervals), .99),
    'intervals_over_16_7ms': intervals.where((us) => us > 16667).length,
  };
  const path = String.fromEnvironment('PROFILE_OUTPUT');
  if (path.isNotEmpty) await io.File(path).writeAsString(jsonEncode(output));
  debugPrint('GATEWAY_PROFILE ${jsonEncode(output)}');
  io.exit(0);
}
