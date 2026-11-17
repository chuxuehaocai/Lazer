// Read-only output discovery for a HiFi test machine. Does not open a playback
// stream, change the default device, or write endpoint/software volume.
//
// dart tool/native_device_check.dart [--device <name fragment>] [--output <json>]
// Can also be compiled beside the bundled engine with `dart compile exe`.
import 'dart:convert';
import 'dart:io';

import 'package:lazer_nextgen/audio/native/lazer_audio_abi.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_devices.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_library.dart';

String? _option(List<String> arguments, String key) {
  final index = arguments.indexOf(key);
  if (index < 0) return null;
  if (index + 1 == arguments.length || arguments[index + 1].startsWith('--')) {
    throw ArgumentError('Missing value for $key');
  }
  return arguments[index + 1];
}

void main(List<String> arguments) {
  try {
    if (arguments.contains('--help')) {
      stdout.writeln(
        'native-device-check [--device <name fragment>] [--output <json>]\n'
        'Enumerates devices and queries exclusive PCM formats; no playback or '
        'volume changes.',
      );
      return;
    }
    final filter = _option(arguments, '--device')?.toLowerCase();
    final output = _option(arguments, '--output');
    final loaded = LazerAudioLoader.load(reload: true);
    if (!loaded.supportsStreaming) {
      throw StateError(
        loaded.reason ?? 'Native engine/reader bridge unavailable',
      );
    }
    final api = loaded.api!;
    if (api.abiVersion() != lazerAudioAbiVersion) {
      throw StateError('Unexpected native ABI ${api.abiVersion()}');
    }
    final errors = <String>[];
    final devices = enumerateOutputDevices(api, onError: errors.add)
        .where(
          (device) =>
              filter == null ||
              device.displayName.toLowerCase().contains(filter),
        )
        .toList();
    final candidates = [
      for (final rate in [
        44100,
        48000,
        88200,
        96000,
        176400,
        192000,
        352800,
        384000,
        705600,
        768000,
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
      for (final rate in [44100, 48000, 96000, 192000, 384000])
        LazerPcmFormatProbe(
          sampleRate: rate,
          channels: 2,
          containerBits: 32,
          validBits: 24,
          status: 0,
          nativeStatus: 0,
        ),
    ];
    final formats = <String, List<LazerPcmFormatProbe>>{};
    for (final device in devices.where((device) => device.isActive)) {
      if (api.probePcmFormats == null) continue;
      final results = probeExclusivePcmFormats(api, device.token, candidates);
      formats[device.token] = results;
      if (results.length != candidates.length ||
          results.any((result) => result.status != 0 && result.status != 1)) {
        errors.add('Exclusive PCM query failed for ${device.displayName}');
      }
    }
    final report = <String, Object?>{
      'timeUtc': DateTime.now().toUtc().toIso8601String(),
      'scope':
          'OS device enumeration and exclusive PCM format queries only; '
          'no playback, volume writes, or default endpoint changes. '
          'Reported formats do not establish physical DAC fidelity or DSD support.',
      'abi': api.abiVersion(),
      'build': api.buildInformation(),
      'readerBridge': loaded.bridge != null,
      'catalog': outputDeviceCatalogKind(api),
      'filter': filter,
      'errors': errors,
      'devices': [
        for (final device in devices)
          {
            'name': device.displayName,
            'token': device.token,
            'active': device.isActive,
            'default': device.isDefault,
            'hardwareVolume': device.hasHardwareVolume,
            'exclusivePcmFormats': [
              for (final format
                  in formats[device.token] ?? <LazerPcmFormatProbe>[])
                {
                  'sampleRate': format.sampleRate,
                  'channels': format.channels,
                  'containerBits': format.containerBits,
                  'validBits': format.validBits,
                  'supported': format.isSupported,
                  'status': format.status,
                  'hresult': format.nativeStatus,
                },
            ],
          },
      ],
    };
    final json = const JsonEncoder.withIndent('  ').convert(report);
    stdout.writeln(json);
    if (output != null) {
      final file = File(output);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('$json\n');
    }
    if (errors.isNotEmpty || !devices.any((device) => device.isActive)) {
      exitCode = 1;
    }
  } catch (error) {
    stderr.writeln('Device check failed: $error');
    exitCode = 1;
  }
}
