// End-to-end smoke test of the native engine through FFI, on a real host.
//
// This drives the same calls `NativeAudioEngine` makes — create, open, play,
// snapshot, seek, gapless queue, stop, DSP — but without the Flutter layer, so it
// runs with plain `dart` on a machine that has the engine binary and an output
// device:
//
//   dart tool/native_engine_smoke.dart
//   dart tool/native_engine_smoke.dart --file path/to/track.flac
//
// It needs `lazer-audio` + `lazer-audio-bridge` + FFmpeg's DLLs where
// `LazerAudioLoader` looks (next to the executable, the working directory, or
// `build/native-audio`), and a WAV/FLAC to play. Generated fixtures are used when
// `build/native-audio/testdata` exists.
//
// What it proves that the offline probes cannot: the Dart struct mirror is
// accepted by the real engine, the ABI version handshake works, the reader bridge
// feeds a live decoder, events arrive on a Dart listener from engine threads, and
// the transport actually moves.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_abi.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_devices.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_library.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_reader.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_worker.dart';
import 'package:lazer_nextgen/audio/native/lazer_stream_info.dart';
import 'package:lazer_nextgen/state/hifi_settings.dart';

int _failures = 0;

void _expect(String what, Object? actual, Object? expected) {
  final bool ok = '$actual' == '$expected';
  stdout.writeln(
    '${ok ? 'ok  ' : 'FAIL'} $what: $actual'
    '${ok ? '' : ' (expected $expected)'}',
  );
  if (!ok) _failures++;
}

void _expectTrue(String what, bool condition, [String? detail]) {
  stdout.writeln(
    '${condition ? 'ok  ' : 'FAIL'} $what${detail == null ? '' : ': $detail'}',
  );
  if (!condition) _failures++;
}

/// An engine event as delivered to the Dart listener.
class _Event {
  _Event(this.event, this.detail, this.positionMillis, this.at);
  final int event;
  final int detail;
  final int positionMillis;
  final Duration at;

  @override
  String toString() => 'event=$event detail=$detail pos=${positionMillis}ms';
}

Future<void> main(List<String> arguments) async {
  final LazerAudioAvailability availability = LazerAudioLoader.load();
  stdout.writeln(
    'library: ${availability.isAvailable ? 'loaded' : availability.reason}',
  );
  if (!availability.isAvailable) {
    stderr.writeln(
      'The native engine is not loadable; see docs/audio-engine.md.',
    );
    exit(2);
  }
  final LazerAudioApi api = availability.api!;
  _expect('ABI version', api.abiVersion(), lazerAudioAbiVersion);
  _expectTrue('reader bridge present', availability.bridge != null);
  final LazerAudioBridgeApi? bridge = availability.bridge;

  stdout.writeln('build: ${api.buildInformation().split('\n').first}');

  // ---- output devices -------------------------------------------------------
  final List<String> deviceErrors = <String>[];
  final List<LazerOutputDevice> devices = enumerateOutputDevices(
    api,
    onError: deviceErrors.add,
  );
  stdout.writeln('device catalog: ${outputDeviceCatalogKind(api)}');
  for (final String error in deviceErrors) {
    stdout.writeln('  device error: $error');
  }
  for (final LazerOutputDevice device in devices) {
    final String hardware = device.hardwareVolumeFlags == null
        ? ''
        : ' hwVolume=${device.hasHardwareVolume}'
              ' flags=0x${device.hardwareVolumeFlags!.toRadixString(16)}';
    stdout.writeln(
      '  ${device.isActive ? '' : '(inactive) '}${device.displayName}'
      '${device.isDefault ? ' [default]' : ''}$hardware',
    );
    stdout.writeln('      token=${device.token}');
    stdout.writeln('      identity=${device.identityKey}');
  }
  _expectTrue(
    'at least one output device',
    devices.isNotEmpty,
    '${devices.length}',
  );
  if (devices.isNotEmpty) {
    // The endpoint volume is per endpoint, so query the one that is actually the
    // default output rather than whichever happens to be listed first.
    final LazerOutputDevice first = devices.firstWhere(
      (LazerOutputDevice device) => device.isDefault,
      orElse: () => devices.first,
    );
    stdout.writeln('  volume probe on: ${first.displayName}');
    final double? volume = readEndpointVolume(api, first.token);
    stdout.writeln('  endpoint volume: ${volume ?? 'unavailable'}');
    if (volume != null) {
      // Round-trip at a value that is definitely not the current one, then restore.
      final bool written = writeEndpointVolume(api, first.token, 0.25);
      final double? readBack = readEndpointVolume(api, first.token);
      _expectTrue(
        'endpoint volume round-trip',
        written && readBack != null && (readBack - 0.25).abs() < 0.05,
        'wrote 0.25, read ${readBack?.toStringAsFixed(3)}',
      );
      writeEndpointVolume(api, first.token, volume);
      final double? restored = readEndpointVolume(api, first.token);
      _expectTrue(
        'endpoint volume restored',
        restored != null && (restored - volume).abs() < 0.05,
        'restored to ${restored?.toStringAsFixed(3)}',
      );
    }
    final List<LazerPcmFormatProbe> probes =
        probeExclusivePcmFormats(api, first.token, <LazerPcmFormatProbe>[
          const LazerPcmFormatProbe(
            sampleRate: 44100,
            channels: 2,
            containerBits: 16,
            validBits: 16,
            status: 0,
            nativeStatus: 0,
          ),
          const LazerPcmFormatProbe(
            sampleRate: 44100,
            channels: 2,
            containerBits: 24,
            validBits: 24,
            status: 0,
            nativeStatus: 0,
          ),
          const LazerPcmFormatProbe(
            sampleRate: 192000,
            channels: 2,
            containerBits: 24,
            validBits: 24,
            status: 0,
            nativeStatus: 0,
          ),
        ]);
    for (final LazerPcmFormatProbe probe in probes) {
      stdout.writeln('  exclusive query: $probe');
    }
  }

  // ---- engine ---------------------------------------------------------------
  final List<_Event> events = <_Event>[];
  final Stopwatch clock = Stopwatch()..start();
  final NativeCallable<LazerAudioEventNative> listener =
      NativeCallable<LazerAudioEventNative>.listener((
        Pointer<Void> context,
        int event,
        int detail,
        int positionMillis,
      ) {
        events.add(_Event(event, detail, positionMillis, clock.elapsed));
      });

  final LazerAudioWorker worker = await LazerAudioWorker.spawn();
  final Pointer<LazerAudioSnapshot> snapshot = calloc<LazerAudioSnapshot>();
  final Pointer<LazerAudioStreamInfo> streamInfo =
      calloc<LazerAudioStreamInfo>();
  int? address;

  /// Both helpers refresh the snapshot; reading the struct without another call
  /// would report whatever the previous sample left in it.
  bool refreshSnapshot() {
    if (address == null) return false;
    return api.snapshot(Pointer<Void>.fromAddress(address), snapshot) ==
        lazerAudioOk;
  }

  int snapshotState() => refreshSnapshot() ? snapshot.ref.state : -1;

  int snapshotPosition() =>
      refreshSnapshot() ? snapshot.ref.positionMillis : -1;

  try {
    final Object? created = await worker.call(LazerWorkerOp.create, <Object?>[
      ...const LazerDeviceSettings().toDeviceMessage(),
      listener.nativeFunction.address,
      0,
    ]);
    _expectTrue('engine created', created != null);
    if (created == null) {
      stderr.writeln('lazer_audio_create returned null');
      exit(2);
    }
    address = created as int;
    final Pointer<Void> engine = Pointer<Void>.fromAddress(address);

    await worker.call(LazerWorkerOp.setDevice, <Object?>[
      address,
      ...const LazerDeviceSettings().toDeviceMessage(),
      null,
    ]);
    await worker.call(LazerWorkerOp.setVolume, <Object?>[address, 0.4]);

    // ---- open a local file through the engine's own file reader -------------
    final String wavPath = _fixture(arguments, 'tone441.wav');
    _expectTrue('fixture exists', File(wavPath).existsSync(), wavPath);
    final int openStatus =
        await worker.call(LazerWorkerOp.openFile, <Object?>[
              address,
              wavPath,
              ...const LazerOpenSettings().toMessage(),
            ])
            as int;
    _expect('open local WAV', openStatus, lazerAudioOk);
    if (openStatus != lazerAudioOk) {
      stdout.writeln('  last error: ${api.lastError(engine)}');
    } else {
      api.streamInfo(engine, streamInfo);
      final LazerStreamInfo info = LazerStreamInfo.fromNative(streamInfo.ref);
      stdout.writeln('  stream: ${info.summary}');
      _expect('source codec', info.codec, 'pcm_s16le');
      _expect('source sample rate', info.sourceSampleRate, 44100);
      _expect('output format initialized', info.outputFormatInitialized, true);
      _expect('lossless', info.lossless, true);
      // Shared-mode WASAPI mixes to the endpoint format, so the engine must report
      // the endpoint's rate/depth rather than the source's, and must not claim
      // bit-perfect output.
      _expectTrue(
        'bit-perfect is not claimed in shared mode',
        !info.bitPerfectActive || info.outputExclusive,
        'bitPerfect=${info.bitPerfectActive} exclusive=${info.outputExclusive}',
      );
      _expectTrue(
        'output format is reported',
        info.outputSampleRate > 0 && info.outputBitsPerSample > 0,
        '${info.outputSampleRate} Hz/${info.outputBitsPerSample}-bit '
            'float=${info.outputIsFloat} selection=${info.outputFormatSelection}',
      );

      _expect('play', api.play(engine), lazerAudioOk);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      final int playing = snapshotState();
      final int position = snapshotPosition();
      _expectTrue(
        'state is playing',
        playing == lazerAudioStatePlaying,
        'state=$playing',
      );
      _expectTrue(
        'position advanced',
        position > 300,
        '${position}ms after ~900ms of playback',
      );
      api.streamInfo(engine, streamInfo);
      stdout.writeln(
        '  telemetry: peak=${streamInfo.ref.outputPeakMillidbfs}mBFS '
        'clipped=${streamInfo.ref.outputClippedSampleCount} '
        'valid=${streamInfo.ref.outputTelemetryValid}',
      );

      _expect('seek to 2s', api.seek(engine, 2000), lazerAudioOk);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final int afterSeek = snapshotPosition();
      _expectTrue(
        'position after seek is near 2s',
        afterSeek >= 1900 && afterSeek <= 2400,
        '${afterSeek}ms',
      );

      _expect('pause', api.pause(engine), lazerAudioOk);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      _expect('state after pause', snapshotState(), lazerAudioStatePaused);

      _expect('stop', api.stop(engine), lazerAudioOk);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      _expect('state after stop', snapshotState(), lazerAudioStateStopped);
    }

    // ---- exclusive + bit-perfect -------------------------------------------
    // The core promise of the engine: the decoded integer samples reach the device
    // untouched. On a shared-mode-only endpoint this must fail honestly rather than
    // silently falling back, which is what the assertions below pin down.
    // Bit-perfect bypasses the software volume, so the engine requires it at 100%
    // instead of quietly attenuating a stream it promised to leave untouched.
    await worker.call(LazerWorkerOp.setVolume, <Object?>[address, 1.0]);
    await worker.call(LazerWorkerOp.setDevice, <Object?>[
      address,
      ...const LazerDeviceSettings(
        exclusive: true,
        bitPerfect: true,
        bufferMillis: 240,
      ).toDeviceMessage(),
      null,
    ]);
    final int exclusiveOpen =
        await worker.call(LazerWorkerOp.openFile, <Object?>[
              address,
              _fixture(arguments, 'tone441.wav'),
              ...const LazerOpenSettings().toMessage(),
            ])
            as int;
    stdout.writeln('exclusive open status: $exclusiveOpen');
    if (exclusiveOpen == lazerAudioOk) {
      api.streamInfo(engine, streamInfo);
      final LazerStreamInfo info = LazerStreamInfo.fromNative(streamInfo.ref);
      stdout.writeln(
        '  exclusive stream: ${info.summary} '
        'exclusive=${info.outputExclusive} bitPerfect=${info.bitPerfectActive} '
        'selection=${info.outputFormatSelection}',
      );
      _expectTrue('exclusive session is exclusive', info.outputExclusive);
      _expectTrue(
        'bit-perfect reaches the source format',
        info.bitPerfectActive &&
            info.outputSampleRate == info.sourceSampleRate &&
            info.outputBitsPerSample == info.sourceBitsPerSample &&
            !info.outputIsFloat,
        '${info.outputSampleRate}/${info.outputBitsPerSample} float=${info.outputIsFloat}',
      );
      _expect('play exclusive', api.play(engine), lazerAudioOk);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      _expectTrue(
        'exclusive playback advanced',
        snapshotPosition() > 150,
        '${snapshotPosition()}ms',
      );
      api.stop(engine);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    } else {
      // No exclusive-capable endpoint here: the failure must be a clean error.
      _expectTrue(
        'shared-only endpoint rejects exclusive honestly',
        exclusiveOpen == lazerAudioErrorDevice ||
            exclusiveOpen == lazerAudioErrorUnsupported,
        'status=$exclusiveOpen error=${api.lastError(engine)}',
      );
    }
    // Back to the defaults for the remaining checks.
    await worker.call(LazerWorkerOp.setVolume, <Object?>[address, 0.4]);
    await worker.call(LazerWorkerOp.setDevice, <Object?>[
      address,
      ...const LazerDeviceSettings().toDeviceMessage(),
      null,
    ]);

    // ---- the settings layer actually drives the engine ---------------------
    // Same path the settings page takes: HifiSettings -> device message + DSP
    // message. This is what proves the page is not decorative.
    final HifiSettings eqSettings = HifiSettings(
      buffer: HifiBufferSize.medium,
      equalizer:
          const HifiEqualizerState(
            enabled: true,
            preampDb: 6,
            limiterEnabled: true,
          ).withPreset(
            hifiEqPresets.firstWhere((HifiEqPreset p) => p.id == 'bass'),
          ),
      // Crossfeed is on too, so this exercises both DSP stages in one session.
      crossfeed: const HifiCrossfeedState(
        enabled: true,
        strength: 0.5,
        algorithm: HifiCrossfeedAlgorithm.bauer,
      ),
    );
    final LazerOutputRequest request = eqSettings.toOutputRequest();
    await worker.call(LazerWorkerOp.setDevice, <Object?>[
      address,
      ...request.toDeviceMessage(),
      request.token,
    ]);
    final LazerDspRequest dsp = eqSettings.toDspRequest();
    final int dspStatus2 =
        await worker.call(LazerWorkerOp.setDsp, <Object?>[
              address,
              dsp.preampDb,
              dsp.limiterEnabled ? 1 : 0,
              dsp.limiterThresholdDb,
              <Object?>[
                for (final HifiEqBandMessage band in dsp.bands)
                  <Object?>[
                    band.kind,
                    band.frequencyHz,
                    band.gainDb,
                    band.q,
                    band.enabled,
                  ],
              ],
              dsp.toCrossfeedMessage(),
            ])
            as int;
    _expect('settings: apply device + DSP', dspStatus2, lazerAudioOk);
    _expect('settings: band count handed to the engine', dsp.bands.length, 10);
    _expect('settings: preamp handed to the engine', dsp.preampDb, -3.0);
    _expect('settings: crossfeed is enabled', dsp.crossfeedEnabled, true);
    _expect('settings: crossfeed algorithm value', dsp.crossfeedAlgorithm, 1);
    // Bauer fixes its own delay/cutoff, so the custom fields must follow the algorithm.
    _expect('settings: crossfeed delay', dsp.crossfeedDelayMs, 0.22);
    _expect('settings: crossfeed cutoff', dsp.crossfeedCutoffHz, 700.0);

    final int eqOpen =
        await worker.call(LazerWorkerOp.openFile, <Object?>[
              address,
              _fixture(arguments, 'tone441.wav'),
              ...const LazerOpenSettings().toMessage(),
            ])
            as int;
    _expect('settings: open with the EQ enabled', eqOpen, lazerAudioOk);
    if (eqOpen == lazerAudioOk) {
      api.play(engine);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      api.streamInfo(engine, streamInfo);
      final LazerStreamInfo info = LazerStreamInfo.fromNative(streamInfo.ref);
      stdout.writeln(
        '  EQ session: ${info.summary} peak=${info.peakMilliDbfs}mBFS '
        'limiter=${info.limiterGainReductionMilliDb}mB clipped=${info.clippedSampleCount} '
        'selection=${info.outputFormatSelection}',
      );
      // A +6 dB preamp with a bass preset must be processed audio, so the engine
      // reports telemetry and must not call it bit-perfect.
      _expectTrue(
        'settings: DSP telemetry is live while the EQ runs',
        info.telemetryValid,
      );
      _expectTrue(
        'settings: EQ output is not bit-perfect',
        !info.bitPerfectActive,
      );
      _expectTrue(
        'settings: the buffer choice reached the session',
        request.bufferMillis == 240,
        '${request.bufferMillis}ms',
      );
      api.stop(engine);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    // Bit-perfect must send no bands at all, which is the promise the page makes
    // when it greys the EQ switch out.
    final HifiSettings bitPerfectSettings = eqSettings.copyWith(
      exclusiveMode: true,
      bitPerfect: true,
    );
    _expect(
      'settings: bit-perfect sends no EQ bands',
      bitPerfectSettings.equalizer
          .toEngineMessage(eqActive: bitPerfectSettings.eqActive)
          .bands
          .length,
      0,
    );
    _expect(
      'settings: bit-perfect bypasses crossfeed too',
      bitPerfectSettings.toDspRequest().crossfeedEnabled,
      false,
    );

    // ---- network-style playback through the bridge reader -------------------
    if (bridge != null) {
      final String flacPath = _fixture(arguments, 'tone480.flac');
      final NativeStreamReader? reader = NativeStreamReader.create(
        bridge,
        path: flacPath,
        expectedBytes: File(flacPath).lengthSync(),
      );
      _expectTrue('bridge reader created', reader != null);
      if (reader != null) {
        // A static file is already "fully downloaded".
        reader.finish();
        final int status =
            await worker.call(LazerWorkerOp.openReader, <Object?>[
                  address,
                  reader.address,
                  ...const LazerOpenSettings().toMessage(),
                ])
                as int;
        _expect('open FLAC through the reader bridge', status, lazerAudioOk);
        if (status == lazerAudioOk) {
          api.streamInfo(engine, streamInfo);
          final LazerStreamInfo info = LazerStreamInfo.fromNative(
            streamInfo.ref,
          );
          stdout.writeln('  stream: ${info.summary}');
          _expect('bridge source codec', info.codec, 'flac');
          _expect('bridge source sample rate', info.sourceSampleRate, 48000);
          _expect('play through bridge', api.play(engine), lazerAudioOk);
          await Future<void>.delayed(const Duration(milliseconds: 600));
          _expectTrue(
            'bridge playback advanced',
            snapshotPosition() > 200,
            '${snapshotPosition()}ms',
          );
          api.stop(engine);
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        reader.release();
      }

      // ---- gapless: a queued successor crosses without reopening the device --
      final String first = _fixture(arguments, 'tone24.wav');
      final String second = _fixture(arguments, 'tone441_short.flac');
      final int firstStatus =
          await worker.call(LazerWorkerOp.openFile, <Object?>[
                address,
                first,
                ...const LazerOpenSettings(
                  durationHint: Duration(seconds: 1),
                ).toMessage(),
              ])
              as int;
      _expect('open first track', firstStatus, lazerAudioOk);
      if (firstStatus == lazerAudioOk) {
        final NativeStreamReader? successor = NativeStreamReader.create(
          bridge,
          path: second,
          expectedBytes: File(second).lengthSync(),
        );
        if (successor != null) {
          successor.finish();
          final int queued =
              await worker.call(LazerWorkerOp.queueReader, <Object?>[
                    address,
                    1,
                    successor.address,
                    ...const LazerOpenSettings().toMessage(),
                  ])
                  as int;
          _expect('queue successor', queued, lazerAudioOk);
          events.clear();
          api.play(engine);
          // Wait for the 1 s first track to run out, crossing into the second.
          await Future<void>.delayed(const Duration(milliseconds: 3000));
          final Iterable<_Event> changes = events.where(
            (_Event event) => event.event == lazerAudioEventTrackChanged,
          );
          _expectTrue(
            'TrackChanged fired at the boundary',
            changes.isNotEmpty,
            '${events.length} events: ${events.join(', ')}',
          );
          final Iterable<_Event> ended = events.where(
            (_Event event) => event.event == lazerAudioEventEnded,
          );
          _expectTrue(
            'Ended reported for the queue',
            ended.isNotEmpty,
            'end position=${ended.map((_Event e) => e.positionMillis).join(',')}',
          );
          api.stop(engine);
          await Future<void>.delayed(const Duration(milliseconds: 100));
          successor.release();
        }
      }
    }

    // ---- DSP: a preamp must be visible in the telemetry --------------------
    final int dspStatus =
        await worker.call(LazerWorkerOp.setDsp, <Object?>[
              address,
              6.0,
              1,
              -1.0,
              <Object?>[
                <Object?>[lazerAudioEqBandPeak, 1000.0, 3.0, 1.0, 1],
              ],
            ])
            as int;
    _expect('apply DSP', dspStatus, lazerAudioOk);

    // ---- teardown ----------------------------------------------------------
    await worker.call(LazerWorkerOp.stop, <Object?>[address]);
    await worker.call(LazerWorkerOp.destroy, <Object?>[address]);
    address = null;
  } finally {
    await worker.close();
    listener.close();
    calloc.free(snapshot);
    calloc.free(streamInfo);
    clock.stop();
  }

  stdout.writeln(
    _failures == 0
        ? 'engine smoke passed (${events.length} events observed)'
        : 'engine smoke failed ($_failures expectations)',
  );
  exit(_failures == 0 ? 0 : 1);
}

/// `--file` overrides the first fixture; otherwise a generated tone is used.
String _fixture(List<String> arguments, String name) {
  for (int index = 0; index < arguments.length; index++) {
    if (arguments[index] == '--file' && index + 1 < arguments.length) {
      return arguments[index + 1];
    }
  }
  return <String>[
    'build/native-audio/testdata',
    name,
  ].join(Platform.pathSeparator);
}
