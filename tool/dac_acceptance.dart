// Device-specific WASAPI acceptance. Run with the current native engine staged:
// dart tool/dac_acceptance.dart --device NICEHCK --output build/reports/dac.json
// Uses a -80 dBFS tone, leaves OS volume unchanged, and never changes the default
// endpoint. Software negotiation/telemetry cannot establish analog THD+N or prove
// the physical DAC's output bytes; those require external measurement.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_abi.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_devices.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_library.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_worker.dart';
import 'package:lazer_nextgen/audio/native/lazer_stream_info.dart';

String? _option(List<String> args, String key) {
  final index = args.indexOf(key);
  if (index < 0) return null;
  if (index + 1 >= args.length) throw ArgumentError('Missing value for $key');
  return args[index + 1];
}

Future<void> main(List<String> args) async {
  final match = _option(args, '--device');
  if (!Platform.isWindows || match == null || match.trim().isEmpty) {
    stderr.writeln('Requires Windows and --device <unique endpoint name>.');
    exitCode = 2;
    return;
  }
  final loaded = LazerAudioLoader.load(reload: true);
  final api = loaded.api;
  if (api == null) {
    throw StateError(loaded.reason ?? 'Native engine unavailable');
  }
  final devices = enumerateOutputDevices(api)
      .where(
        (d) =>
            d.isActive &&
            d.displayName.toLowerCase().contains(match.toLowerCase()),
      )
      .toList();
  if (devices.length != 1) {
    throw StateError(
      'Expected one endpoint matching $match, found ${devices.length}',
    );
  }
  final device = devices.single;
  final formats = probeExclusivePcmFormats(api, device.token, [
    for (final rate in [
      44100,
      48000,
      88200,
      96000,
      176400,
      192000,
      352800,
      384000,
    ])
      for (final bits in [16, 24, 32])
        LazerPcmFormatProbe(
          sampleRate: rate,
          channels: 2,
          containerBits: bits,
          validBits: bits,
          status: 0,
          nativeStatus: 0,
        ),
  ]);
  if (formats.isEmpty) {
    throw StateError('The engine has no WASAPI format probe');
  }
  final results = <Map<String, Object?>>[];
  final report = <String, Object?>{
    'timeUtc': DateTime.now().toUtc().toIso8601String(),
    'platform': Platform.operatingSystemVersion,
    'engineBuild': api.buildInformation(),
    'device': device.displayName,
    'deviceToken': device.token,
    'signal':
        '997 Hz, -80 dBFS PCM stereo; software volume 1.0; OS volume unchanged',
    'scope':
        'WASAPI negotiation and engine playback telemetry, not physical loopback or analog fidelity',
    'formats': [
      for (final f in formats)
        {
          'rate': f.sampleRate,
          'bits': f.validBits,
          'containerBits': f.containerBits,
          'status': f.status,
          'hresult': f.nativeStatus,
        },
    ],
    'playback': results,
    'completed': false,
    'expectedPlaybackFormats': formats.where((f) => f.isSupported).length,
  };
  final directory = await Directory(
    'build/reports/dac-fixtures',
  ).create(recursive: true);
  final worker = await LazerAudioWorker.spawn();
  var failures = 0;
  try {
    for (final format in formats.where((f) => f.isSupported)) {
      final file = await _fixture(
        directory,
        format.sampleRate,
        format.validBits,
      );
      final settings = LazerDeviceSettings(
        exclusive: true,
        bitPerfect: true,
        deviceToken: device.token,
      );
      final address =
          await worker.call(LazerWorkerOp.create, [
                ...settings.toDeviceMessage(),
                0,
                0,
                device.token,
              ])
              as int?;
      if (address == null || address == 0) {
        throw StateError('Engine create failed');
      }
      final engine = Pointer<Void>.fromAddress(address);
      final info = calloc<LazerAudioStreamInfo>();
      final snapshot = calloc<LazerAudioSnapshot>();
      final result = <String, Object?>{
        'rate': format.sampleRate,
        'bits': format.validBits,
      };
      results.add(result);
      try {
        final status =
            await worker.call(LazerWorkerOp.openFile, [
                  address,
                  file.path,
                  ...const LazerOpenSettings().toMessage(),
                ])
                as int;
        result['openStatus'] = status;
        if (status != lazerAudioOk) {
          result['error'] = api.lastError(engine);
          result['passed'] = false;
          failures++;
          continue;
        }
        final infoStatus = api.streamInfo(engine, info);
        if (infoStatus != lazerAudioOk) {
          throw StateError('Stream info failed: $infoStatus');
        }
        final stream = LazerStreamInfo.fromNative(info.ref);
        final play = await worker.call(LazerWorkerOp.play, [address]) as int;
        var clock = 0;
        var underruns = 0;
        final timer = Stopwatch()..start();
        while (timer.elapsedMilliseconds < 1800) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
          if (api.snapshot(engine, snapshot) != lazerAudioOk) {
            throw StateError('Snapshot failed');
          }
          clock = math.max(clock, snapshot.ref.positionMillis);
          underruns = math.max(underruns, snapshot.ref.underrunFrames);
        }
        final path = stream.outputPath;
        final passed =
            play == lazerAudioOk &&
            clock >= 1000 &&
            underruns == 0 &&
            path.bitPerfect &&
            path.agreesWithEngine &&
            stream.outputSampleRate == format.sampleRate &&
            stream.outputBitsPerSample == format.validBits &&
            stream.outputChannels == 2 &&
            !stream.outputIsFloat;
        result.addAll({
          'playStatus': play,
          'positionMillis': clock,
          'underrunFrames': underruns,
          'outputRate': stream.outputSampleRate,
          'outputBits': stream.outputBitsPerSample,
          'outputContainerBits': stream.outputContainerBitsPerSample,
          'exclusive': stream.outputExclusive,
          'dspActive': stream.dspActive,
          'formatMatchesSource': stream.formatMatchesSource,
          'engineReportsBitPerfect': stream.bitPerfectActive,
          'derivedBitPerfect': path.bitPerfect,
          'passed': passed,
        });
        if (!passed) failures++;
      } finally {
        await worker.call(LazerWorkerOp.stop, [address]);
        await worker.call(LazerWorkerOp.destroy, [address]);
        calloc.free(info);
        calloc.free(snapshot);
        stdout.writeln(jsonEncode(result));
      }
    }
    report['completed'] = true;
  } catch (error) {
    report['fatalError'] = '$error';
    failures++;
    rethrow;
  } finally {
    await worker.close();
    report['failures'] = failures;
    report['testedFormats'] = results.length;
    final output = File(_option(args, '--output') ?? 'build/reports/dac.json');
    await output.parent.create(recursive: true);
    await output.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(report)}\n',
    );
    stdout.writeln('Report: ${output.path}');
  }
  if (failures > 0 || results.isEmpty) exitCode = 1;
}

Future<File> _fixture(Directory directory, int rate, int bits) async {
  final frameBytes = 2 * (bits ~/ 8);
  final frames = rate * 4;
  final data = ByteData(44 + frames * frameBytes);
  void text(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      data.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  data.setUint32(4, data.lengthInBytes - 8, Endian.little);
  text(8, 'WAVEfmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 2, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * frameBytes, Endian.little);
  data.setUint16(32, frameBytes, Endian.little);
  data.setUint16(34, bits, Endian.little);
  text(36, 'data');
  data.setUint32(40, frames * frameBytes, Endian.little);
  final maximum = (1 << (bits - 1)) - 1;
  for (var frame = 0; frame < frames; frame++) {
    final sample =
        (math.sin(2 * math.pi * 997 * frame / rate) * maximum * 0.0001).round();
    for (var channel = 0; channel < 2; channel++) {
      final offset = 44 + frame * frameBytes + channel * (bits ~/ 8);
      for (var byte = 0; byte < bits ~/ 8; byte++) {
        data.setUint8(offset + byte, (sample >> (byte * 8)) & 0xff);
      }
    }
  }
  final file = File('${directory.path}/pcm_${rate}_$bits.wav');
  return file.writeAsBytes(data.buffer.asUint8List());
}
