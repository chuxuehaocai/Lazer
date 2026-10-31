// Field-by-field verification of the Dart mirror of `lazer_audio_api.h`.
//
// The expectations are the literal output of
// `native/lazer-audio-bridge/tools/abi_layout_probe.cpp` (compiled from the
// engine header by the C++ compiler). They exist because a wrong offset in
// `lib/audio/native/lazer_audio_abi.dart` is silent: the engine copies structs
// byte-for-byte, so a misplaced field shows up as a garbage position or no
// audio at all, never as a build error.
//
// `dart:ffi` has no `offsetOf`, so each field is written with a sentinel value
// and located by scanning the struct's raw bytes. Pointer, integer and double
// fields therefore all use the same mechanism.
//
// Two entry points use this:
//   * `test/audio/lazer_audio_abi_test.dart` (CI, `flutter test`)
//   * `tool/native_abi_check.dart` (plain `dart`, no Flutter toolchain needed)
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'package:lazer_nextgen/audio/native/lazer_audio_abi.dart';

/// One field expectation: where it should live and how to write a probe value.
class AbiField {
  const AbiField(this.name, this.offset, this.write, this.marker);

  final String name;
  final int offset;
  final void Function() write;
  final List<int> marker;
}

/// A struct expectation: its size and every field's offset.
class AbiStruct {
  const AbiStruct(this.name, this.size, this.fields);

  final String name;
  final int size;
  final List<AbiField> fields;
}

// Sentinel values chosen so each one is unlikely to appear by accident and can
// be recognised unambiguously in a byte scan.
const int _sentinel32 = 0x0A0B0C0D;
const int _sentinel64 = 0x1122334455667788;
const double _sentinelDouble = 91.5;

List<int> _int32Bytes(int value) =>
    (ByteData(4)..setInt32(0, value, Endian.host)).buffer.asUint8List().toList();

List<int> _uint32Bytes(int value) =>
    (ByteData(4)..setUint32(0, value, Endian.host)).buffer.asUint8List().toList();

List<int> _int64Bytes(int value) =>
    (ByteData(8)..setInt64(0, value, Endian.host)).buffer.asUint8List().toList();

List<int> _uint64Bytes(int value) =>
    (ByteData(8)..setUint64(0, value, Endian.host)).buffer.asUint8List().toList();

List<int> _doubleBytes(double value) =>
    (ByteData(8)..setFloat64(0, value, Endian.host)).buffer.asUint8List().toList();

final List<int> _pointerMarker = _int64Bytes(_sentinel64);
final List<int> _int32Marker = _int32Bytes(_sentinel32);
final List<int> _uint32Marker = _uint32Bytes(_sentinel32);
final List<int> _int64Marker = _int64Bytes(_sentinel64);
final List<int> _uint64Marker = _uint64Bytes(_sentinel64);
final List<int> _doubleMarker = _doubleBytes(_sentinelDouble);

/// Finds [marker] in the raw bytes after running [write], or -1.
int locate(Pointer<Uint8> base, int size, void Function() write, List<int> marker) {
  final Uint8List bytes = base.asTypedList(size);
  bytes.fillRange(0, bytes.length, 0);
  write();
  for (int start = 0; start + marker.length <= bytes.length; start++) {
    bool matches = true;
    for (int index = 0; index < marker.length; index++) {
      if (bytes[start + index] != marker[index]) {
        matches = false;
        break;
      }
    }
    if (matches) return start;
  }
  return -1;
}

/// Every struct the Dart side builds or reads, with the C compiler's layout.
List<AbiStruct> abiLayoutExpectations() => <AbiStruct>[
  AbiStruct('LazerAudioReader', sizeOf<LazerAudioReader>(), <AbiField>[
    AbiField(
      'read',
      0,
      () => _reader().ref.read = Pointer.fromAddress(_sentinel64),
      _pointerMarker,
    ),
    AbiField(
      'seek',
      8,
      () => _reader().ref.seek = Pointer.fromAddress(_sentinel64),
      _pointerMarker,
    ),
    AbiField(
      'length',
      16,
      () => _reader().ref.length = Pointer.fromAddress(_sentinel64),
      _pointerMarker,
    ),
    AbiField(
      'close',
      24,
      () => _reader().ref.close = Pointer.fromAddress(_sentinel64),
      _pointerMarker,
    ),
    AbiField(
      'context',
      32,
      () => _reader().ref.context = Pointer.fromAddress(_sentinel64),
      _pointerMarker,
    ),
    AbiField(
      'cancel',
      40,
      () => _reader().ref.cancel = Pointer.fromAddress(_sentinel64),
      _pointerMarker,
    ),
  ]),
  AbiStruct('LazerAudioOpenParams', sizeOf<LazerAudioOpenParams>(), <AbiField>[
    AbiField('structSize', 0, () => _openParams().ref.structSize = _sentinel32, _uint32Marker),
    AbiField(
      'startMillis',
      8,
      () => _openParams().ref.startMillis = _sentinel64,
      _int64Marker,
    ),
    AbiField(
      'durationHintMillis',
      16,
      () => _openParams().ref.durationHintMillis = _sentinel64,
      _int64Marker,
    ),
    AbiField(
      'cueStartFrame75',
      24,
      () => _openParams().ref.cueStartFrame75 = _sentinel64,
      _int64Marker,
    ),
    AbiField(
      'cueEndFrame75',
      32,
      () => _openParams().ref.cueEndFrame75 = _sentinel64,
      _int64Marker,
    ),
    AbiField(
      'replayGainDb',
      40,
      () => _openParams().ref.replayGainDb = _sentinelDouble,
      _doubleMarker,
    ),
  ]),
  AbiStruct('LazerAudioDeviceConfig', sizeOf<LazerAudioDeviceConfig>(), <AbiField>[
    AbiField(
      'deviceId',
      0,
      () => _deviceConfig().ref.deviceId = Pointer.fromAddress(_sentinel64),
      _pointerMarker,
    ),
    AbiField('exclusive', 8, () => _deviceConfig().ref.exclusive = _sentinel32, _int32Marker),
    AbiField(
      'resampleMode',
      12,
      () => _deviceConfig().ref.resampleMode = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'targetSampleRate',
      16,
      () => _deviceConfig().ref.targetSampleRate = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'bufferMillis',
      20,
      () => _deviceConfig().ref.bufferMillis = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'bitPerfect',
      24,
      () => _deviceConfig().ref.bitPerfect = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'dsdOutputMode',
      28,
      () => _deviceConfig().ref.dsdOutputMode = _sentinel32,
      _int32Marker,
    ),
  ]),
  AbiStruct('LazerAudioEventHandler', sizeOf<LazerAudioEventHandler>(), <AbiField>[]),
  AbiStruct('LazerAudioLogHandler', sizeOf<LazerAudioLogHandler>(), <AbiField>[]),
  AbiStruct('LazerAudioEngineConfig', sizeOf<LazerAudioEngineConfig>(), <AbiField>[
    AbiField(
      'abiVersion',
      0,
      () => _engineConfig().ref.abiVersion = _sentinel32,
      _uint32Marker,
    ),
    AbiField(
      'structSize',
      4,
      () => _engineConfig().ref.structSize = _sentinel32,
      _uint32Marker,
    ),
    AbiField(
      'device.exclusive',
      16,
      () => _engineConfig().ref.device.exclusive = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'device.dsdOutputMode',
      36,
      () => _engineConfig().ref.device.dsdOutputMode = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'events.context',
      48,
      () => _engineConfig().ref.events.context = Pointer.fromAddress(_sentinel64),
      _pointerMarker,
    ),
    AbiField(
      'log.context',
      64,
      () => _engineConfig().ref.log.context = Pointer.fromAddress(_sentinel64),
      _pointerMarker,
    ),
  ]),
  AbiStruct('LazerAudioSnapshot', sizeOf<LazerAudioSnapshot>(), <AbiField>[
    AbiField('state', 0, () => _snapshot().ref.state = _sentinel32, _int32Marker),
    AbiField('paused', 4, () => _snapshot().ref.paused = _sentinel32, _int32Marker),
    AbiField(
      'positionMillis',
      8,
      () => _snapshot().ref.positionMillis = _sentinel64,
      _int64Marker,
    ),
    AbiField(
      'durationMillis',
      16,
      () => _snapshot().ref.durationMillis = _sentinel64,
      _int64Marker,
    ),
    AbiField(
      'bufferedPercent',
      24,
      () => _snapshot().ref.bufferedPercent = _sentinel32,
      _int32Marker,
    ),
    AbiField('error', 28, () => _snapshot().ref.error = _sentinel32, _int32Marker),
    AbiField(
      'underrunActive',
      32,
      () => _snapshot().ref.underrunActive = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'underrunFrames',
      40,
      () => _snapshot().ref.underrunFrames = _sentinel64,
      _uint64Marker,
    ),
    AbiField(
      'terminalEvent',
      48,
      () => _snapshot().ref.terminalEvent = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'terminalDetail',
      52,
      () => _snapshot().ref.terminalDetail = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'terminalPositionMillis',
      56,
      () => _snapshot().ref.terminalPositionMillis = _sentinel64,
      _int64Marker,
    ),
    AbiField(
      'ringFillFrames',
      64,
      () => _snapshot().ref.ringFillFrames = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'ringCapacityFrames',
      68,
      () => _snapshot().ref.ringCapacityFrames = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'ringLowWatermarkFrames',
      72,
      () => _snapshot().ref.ringLowWatermarkFrames = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'ringHighWatermarkFrames',
      76,
      () => _snapshot().ref.ringHighWatermarkFrames = _sentinel32,
      _int32Marker,
    ),
  ]),
  AbiStruct('LazerAudioStreamInfo', sizeOf<LazerAudioStreamInfo>(), <AbiField>[
    AbiField('codec', 0, () => _streamInfo().ref.codec[0] = 0xAB, <int>[0xAB]),
    AbiField(
      'sourceSampleRate',
      64,
      () => _streamInfo().ref.sourceSampleRate = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'sourceChannels',
      68,
      () => _streamInfo().ref.sourceChannels = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'sourceBitsPerSample',
      72,
      () => _streamInfo().ref.sourceBitsPerSample = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'sourceBitrateKbps',
      76,
      () => _streamInfo().ref.sourceBitrateKbps = _sentinel32,
      _int32Marker,
    ),
    AbiField('lossless', 80, () => _streamInfo().ref.lossless = _sentinel32, _int32Marker),
    AbiField(
      'outputSampleRate',
      84,
      () => _streamInfo().ref.outputSampleRate = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'outputChannels',
      88,
      () => _streamInfo().ref.outputChannels = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'outputBitsPerSample',
      92,
      () => _streamInfo().ref.outputBitsPerSample = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'outputExclusive',
      96,
      () => _streamInfo().ref.outputExclusive = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'bitPerfectActive',
      100,
      () => _streamInfo().ref.bitPerfectActive = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'outputContainerBitsPerSample',
      104,
      () => _streamInfo().ref.outputContainerBitsPerSample = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'outputIsFloat',
      108,
      () => _streamInfo().ref.outputIsFloat = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'outputFormatInitialized',
      112,
      () => _streamInfo().ref.outputFormatInitialized = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'sourceFormatKind',
      116,
      () => _streamInfo().ref.sourceFormatKind = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'sourceDsdRateMultiplier',
      120,
      () => _streamInfo().ref.sourceDsdRateMultiplier = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'outputFormatSelection',
      124,
      () => _streamInfo().ref.outputFormatSelection = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'outputPeakMillidbfs',
      128,
      () => _streamInfo().ref.outputPeakMillidbfs = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'limiterGainReductionMillidb',
      132,
      () => _streamInfo().ref.limiterGainReductionMillidb = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'outputClippedSampleCount',
      136,
      () => _streamInfo().ref.outputClippedSampleCount = _sentinel64,
      _uint64Marker,
    ),
    AbiField(
      'outputTelemetryValid',
      144,
      () => _streamInfo().ref.outputTelemetryValid = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'outputFormatKind',
      148,
      () => _streamInfo().ref.outputFormatKind = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'outputDsdRateMultiplier',
      152,
      () => _streamInfo().ref.outputDsdRateMultiplier = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'outputCoreAudioMixabilityKnown',
      156,
      () => _streamInfo().ref.outputCoreAudioMixabilityKnown = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'outputCoreAudioNonMixable',
      160,
      () => _streamInfo().ref.outputCoreAudioNonMixable = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'outputDspActive',
      164,
      () => _streamInfo().ref.outputDspActive = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'outputFormatMatchesSource',
      168,
      () => _streamInfo().ref.outputFormatMatchesSource = _sentinel32,
      _int32Marker,
    ),
  ]),
  AbiStruct('LazerAudioEqBand', sizeOf<LazerAudioEqBand>(), <AbiField>[
    AbiField('kind', 0, () => _eqBand().ref.kind = _sentinel32, _int32Marker),
    AbiField(
      'frequencyHz',
      8,
      () => _eqBand().ref.frequencyHz = _sentinelDouble,
      _doubleMarker,
    ),
    AbiField('gainDb', 16, () => _eqBand().ref.gainDb = _sentinelDouble, _doubleMarker),
    AbiField('q', 24, () => _eqBand().ref.q = _sentinelDouble, _doubleMarker),
    AbiField('enabled', 32, () => _eqBand().ref.enabled = _sentinel32, _int32Marker),
  ]),
  AbiStruct('LazerAudioDspConfig', sizeOf<LazerAudioDspConfig>(), <AbiField>[
    AbiField('preampDb', 0, () => _dsp().ref.preampDb = _sentinelDouble, _doubleMarker),
    AbiField('bandCount', 8, () => _dsp().ref.bandCount = _sentinel32, _uint32Marker),
    AbiField(
      'bands',
      16,
      () => _dsp().ref.bands = Pointer.fromAddress(_sentinel64),
      _pointerMarker,
    ),
    AbiField(
      'limiterEnabled',
      24,
      () => _dsp().ref.limiterEnabled = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'limiterThresholdDb',
      32,
      () => _dsp().ref.limiterThresholdDb = _sentinelDouble,
      _doubleMarker,
    ),
    AbiField(
      'balanceChannels',
      40,
      () => _dsp().ref.balanceChannels = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'crossfeedEnabled',
      44,
      () => _dsp().ref.crossfeedEnabled = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'crossfeedStrength',
      48,
      () => _dsp().ref.crossfeedStrength = _sentinelDouble,
      _doubleMarker,
    ),
    AbiField(
      'crossfeedAlgorithm',
      56,
      () => _dsp().ref.crossfeedAlgorithm = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'crossfeedDelayMs',
      64,
      () => _dsp().ref.crossfeedDelayMs = _sentinelDouble,
      _doubleMarker,
    ),
    AbiField(
      'crossfeedCutoffHz',
      72,
      () => _dsp().ref.crossfeedCutoffHz = _sentinelDouble,
      _doubleMarker,
    ),
    AbiField(
      'stageCount',
      80,
      () => _dsp().ref.stageCount = _sentinel32,
      _uint32Marker,
    ),
    AbiField(
      'stageOrder',
      84,
      () => _dsp().ref.stageOrder[0] = _sentinel32,
      _int32Marker,
    ),
  ]),
  AbiStruct('LazerAudioOutputDeviceInfo', sizeOf<LazerAudioOutputDeviceInfo>(), <AbiField>[
    AbiField(
      'structSize',
      0,
      () => _outputDeviceInfo().ref.structSize = _sentinel32,
      _uint32Marker,
    ),
    AbiField('flags', 4, () => _outputDeviceInfo().ref.flags = _sentinel32, _uint32Marker),
  ]),
  AbiStruct('LazerAudioDeviceInfo', sizeOf<LazerAudioDeviceInfo>(), <AbiField>[
    AbiField(
      'structSize',
      0,
      () => _deviceInfo().ref.structSize = _sentinel32,
      _uint32Marker,
    ),
    AbiField(
      'endpointState',
      4,
      () => _deviceInfo().ref.endpointState = _sentinel32,
      _uint32Marker,
    ),
    AbiField(
      'defaultRoleMask',
      8,
      () => _deviceInfo().ref.defaultRoleMask = _sentinel32,
      _uint32Marker,
    ),
    AbiField(
      'identityKind',
      12,
      () => _deviceInfo().ref.identityKind = _sentinel32,
      _uint32Marker,
    ),
    AbiField(
      'endpointVolumeQueryHresult',
      16,
      () => _deviceInfo().ref.endpointVolumeQueryHresult = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'endpointVolumeHardwareSupportFlags',
      20,
      () => _deviceInfo().ref.endpointVolumeHardwareSupportFlags = _sentinel32,
      _uint32Marker,
    ),
  ]),
  AbiStruct('LazerAudioPcmFormatCandidate', sizeOf<LazerAudioPcmFormatCandidate>(), <AbiField>[
    AbiField(
      'sampleRate',
      0,
      () => _candidate().ref.sampleRate = _sentinel32,
      _uint32Marker,
    ),
    AbiField(
      'channels',
      4,
      () => _candidate().ref.channels = 0x7E5D,
      <int>[0x5D, 0x7E],
    ),
    AbiField('containerBits', 6, () => _candidate().ref.containerBits = 0x7E5D, <int>[
      0x5D,
      0x7E,
    ]),
    AbiField('validBits', 8, () => _candidate().ref.validBits = 0x7E5D, <int>[0x5D, 0x7E]),
    AbiField('reserved', 10, () => _candidate().ref.reserved = 0x7E5D, <int>[0x5D, 0x7E]),
  ]),
  AbiStruct('LazerAudioPcmFormatProbeResult', sizeOf<LazerAudioPcmFormatProbeResult>(), <AbiField>[
    AbiField(
      'status',
      0,
      () => _probeResult().ref.status = _sentinel32,
      _int32Marker,
    ),
    AbiField(
      'nativeStatus',
      4,
      () => _probeResult().ref.nativeStatus = _sentinel32,
      _int32Marker,
    ),
  ]),
];

/// The C compiler's `sizeof` for every struct, independent of the Dart mirror.
///
/// These are the numbers `abiLayoutExpectations` must reproduce; keeping them
/// separate means a wrong `sizeOf` in the mirror cannot "agree" with itself.
const Map<String, int> abiCStructSizes = <String, int>{
  'LazerAudioReader': 48,
  'LazerAudioOpenParams': 48,
  'LazerAudioDeviceConfig': 32,
  'LazerAudioEventHandler': 16,
  'LazerAudioLogHandler': 16,
  'LazerAudioEngineConfig': 72,
  'LazerAudioSnapshot': 80,
  'LazerAudioStreamInfo': 176,
  'LazerAudioEqBand': 40,
  'LazerAudioDspConfig': 120,
  'LazerAudioOutputDeviceInfo': 8,
  'LazerAudioDeviceInfo': 24,
  'LazerAudioPcmFormatCandidate': 12,
  'LazerAudioPcmFormatProbeResult': 8,
};

// One allocation per struct, reused by every field probe of that struct.
final Map<String, Pointer<Uint8>> _scratch = <String, Pointer<Uint8>>{};

Pointer<Uint8> _scratchFor(String key, int size) =>
    _scratch.putIfAbsent(key, () => calloc<Uint8>(size));

Pointer<LazerAudioReader> _reader() =>
    _scratchFor('LazerAudioReader', sizeOf<LazerAudioReader>()).cast<LazerAudioReader>();
Pointer<LazerAudioOpenParams> _openParams() =>
    _scratchFor('LazerAudioOpenParams', sizeOf<LazerAudioOpenParams>()).cast<LazerAudioOpenParams>();
Pointer<LazerAudioDeviceConfig> _deviceConfig() =>
    _scratchFor('LazerAudioDeviceConfig', sizeOf<LazerAudioDeviceConfig>()).cast<LazerAudioDeviceConfig>();
Pointer<LazerAudioEngineConfig> _engineConfig() =>
    _scratchFor('LazerAudioEngineConfig', sizeOf<LazerAudioEngineConfig>()).cast<LazerAudioEngineConfig>();
Pointer<LazerAudioSnapshot> _snapshot() =>
    _scratchFor('LazerAudioSnapshot', sizeOf<LazerAudioSnapshot>()).cast<LazerAudioSnapshot>();
Pointer<LazerAudioStreamInfo> _streamInfo() =>
    _scratchFor('LazerAudioStreamInfo', sizeOf<LazerAudioStreamInfo>()).cast<LazerAudioStreamInfo>();
Pointer<LazerAudioEqBand> _eqBand() =>
    _scratchFor('LazerAudioEqBand', sizeOf<LazerAudioEqBand>()).cast<LazerAudioEqBand>();
Pointer<LazerAudioDspConfig> _dsp() =>
    _scratchFor('LazerAudioDspConfig', sizeOf<LazerAudioDspConfig>()).cast<LazerAudioDspConfig>();
Pointer<LazerAudioOutputDeviceInfo> _outputDeviceInfo() =>
    _scratchFor('LazerAudioOutputDeviceInfo', sizeOf<LazerAudioOutputDeviceInfo>())
        .cast<LazerAudioOutputDeviceInfo>();
Pointer<LazerAudioDeviceInfo> _deviceInfo() =>
    _scratchFor('LazerAudioDeviceInfo', sizeOf<LazerAudioDeviceInfo>()).cast<LazerAudioDeviceInfo>();
Pointer<LazerAudioPcmFormatCandidate> _candidate() =>
    _scratchFor('LazerAudioPcmFormatCandidate', sizeOf<LazerAudioPcmFormatCandidate>())
        .cast<LazerAudioPcmFormatCandidate>();
Pointer<LazerAudioPcmFormatProbeResult> _probeResult() =>
    _scratchFor('LazerAudioPcmFormatProbeResult', sizeOf<LazerAudioPcmFormatProbeResult>())
        .cast<LazerAudioPcmFormatProbeResult>();

/// Runs every check and returns human-readable mismatches (empty when the mirror
/// matches the header).
List<String> verifyAbiLayout() {
  final List<String> problems = <String>[];
  for (final MapEntry<String, int> expected in abiCStructSizes.entries) {
    final AbiStruct? actual = abiLayoutExpectations()
        .where((AbiStruct structure) => structure.name == expected.key)
        .firstOrNull;
    if (actual == null) {
      problems.add('${expected.key}: missing from the layout table');
      continue;
    }
    if (actual.size != expected.value) {
      problems.add(
        '${expected.key}: size ${actual.size} != C sizeof ${expected.value}',
      );
    }
  }
  for (final AbiStruct structure in abiLayoutExpectations()) {
    final int expectedSize = abiCStructSizes[structure.name] ?? structure.size;
    final Pointer<Uint8> base = _scratchFor(structure.name, expectedSize);
    for (final AbiField field in structure.fields) {
      final int found = locate(base, expectedSize, field.write, field.marker);
      if (found != field.offset) {
        problems.add(
          '${structure.name}.${field.name}: offset $found != C offsetOf '
          '${field.offset}',
        );
      }
    }
  }
  return problems;
}

/// Frees the probe scratch memory; safe to call once at the end of a test run.
void disposeAbiLayoutProbes() {
  for (final Pointer<Uint8> pointer in _scratch.values) {
    calloc.free(pointer);
  }
  _scratch.clear();
}
