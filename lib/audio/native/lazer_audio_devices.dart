// Output-device discovery for the native engine.
//
// The engine exposes two different catalogs and they are not interchangeable:
//
//   * Windows: `lazer_audio_device_catalog_*` — `wchar_t` strings, Windows render
//     endpoints, plus per-endpoint hardware-volume flags and an exact exclusive PCM
//     format probe.
//   * Linux / macOS: `lazer_audio_output_device_catalog_*` — UTF-8 strings, ALSA
//     `hw:` PCMs or CoreAudio devices by stable UID.
//
// Both report *platform* state. Neither proves the format a DAC locks to, and the
// Windows hardware-volume flags describe the OS endpoint, not USB `SET_CUR`.
//
// Flutter-free so `tool/native_device_check.dart` can run it with plain Dart.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'lazer_audio_abi.dart';
import 'lazer_audio_library.dart';

/// One selectable output endpoint.
class LazerOutputDevice {
  const LazerOutputDevice({
    required this.token,
    required this.identityKey,
    required this.displayName,
    this.isDefault = false,
    this.isActive = true,
    this.identityIsEphemeral = false,
    this.endpointState,
    this.defaultRoleMask,
    this.hardwareVolumeFlags,
    this.volumeQueryHresult,
  });

  /// What `LazerDeviceSettings.deviceToken` carries: an endpoint id on Windows, an
  /// ALSA `hw:` token or a CoreAudio UID elsewhere.
  final String token;

  /// Stable-looking identity to re-resolve after a driver update. On Windows this is
  /// `PKEY_AudioEndpoint_StableId` when available and the endpoint id otherwise, so
  /// it is only as stable as the platform reports.
  final String identityKey;

  final String displayName;
  final bool isDefault;
  final bool isActive;

  /// True when [identityKey] fell back to a volatile value (ALSA card index).
  final bool identityIsEphemeral;

  /// `DEVICE_STATE_*` mask (Windows only).
  final int? endpointState;

  /// `LazerAudioDeviceDefaultRole` bitmask (Windows only).
  final int? defaultRoleMask;

  /// `ENDPOINT_HARDWARE_SUPPORT_*` bits; null when not queried or unsupported.
  final int? hardwareVolumeFlags;

  final int? volumeQueryHresult;

  /// Whether Windows reports this endpoint as owning the console/multimedia role.
  bool get isWindowsDefaultRole =>
      (defaultRoleMask ?? 0) & 0x3 != 0;

  /// Whether the endpoint advertises hardware volume control for the software slider.
  bool get hasHardwareVolume => (hardwareVolumeFlags ?? 0) & 0x1 != 0;

  @override
  String toString() =>
      'LazerOutputDevice($displayName, token=$token, default=$isDefault)';
}

/// Result of one exclusive-format query.
class LazerPcmFormatProbe {
  const LazerPcmFormatProbe({
    required this.sampleRate,
    required this.channels,
    required this.containerBits,
    required this.validBits,
    required this.status,
    required this.nativeStatus,
  });

  final int sampleRate;
  final int channels;
  final int containerBits;
  final int validBits;

  /// 0 supported, 1 unsupported, 2 error (see `LazerAudioPcmFormatProbeStatus`).
  final int status;

  /// The raw `IAudioClient::IsFormatSupported` HRESULT.
  final int nativeStatus;

  bool get isSupported => status == 0;

  @override
  String toString() =>
      '$sampleRate Hz/${validBits}of$containerBits-bit/${channels}ch '
      '${status == 0 ? 'supported' : status == 1 ? 'unsupported' : 'error'}';
}

/// How this host exposes devices, or null when the engine has no catalog here.
String? outputDeviceCatalogKind(LazerAudioApi api) {
  if (api.deviceCatalogCreate != null) return 'windows-endpoints';
  if (api.outputDeviceCatalogCreate != null) return 'utf8-output';
  return null;
}

/// Enumerates the output devices the engine can open.
///
/// Returns an empty list when the platform has no catalog or the catalog had no
/// entries; [error] is filled with the native failure text when one occurred.
List<LazerOutputDevice> enumerateOutputDevices(
  LazerAudioApi api, {
  void Function(String message)? onError,
}) {
  final Pointer<Pointer<Void>> out = calloc<Pointer<Void>>();
  try {
    if (api.deviceCatalogCreate != null) {
      return _enumerateWindows(api, out, onError);
    }
    if (api.outputDeviceCatalogCreate != null) {
      return _enumerateUtf8(api, out, onError);
    }
    onError?.call('this host has no output device catalog');
    return <LazerOutputDevice>[];
  } finally {
    calloc.free(out);
  }
}

List<LazerOutputDevice> _enumerateWindows(
  LazerAudioApi api,
  Pointer<Pointer<Void>> out,
  void Function(String message)? onError,
) {
  final int created = api.deviceCatalogCreate!(out);
  if (created != lazerAudioOk || out.value == nullptr) {
    onError?.call('device catalog create failed ($created)');
    return <LazerOutputDevice>[];
  }
  final Pointer<Void> catalog = out.value;
  final Pointer<Uint32> count = calloc<Uint32>();
  final Pointer<LazerAudioDeviceInfo> info = calloc<LazerAudioDeviceInfo>();
  final Pointer<Uint32> idChars = calloc<Uint32>();
  final Pointer<Uint32> identityChars = calloc<Uint32>();
  final Pointer<Uint32> nameChars = calloc<Uint32>();
  try {
    if (api.deviceCatalogCount!(catalog, count) != lazerAudioOk) {
      onError?.call('device catalog count failed');
      return <LazerOutputDevice>[];
    }
    final List<LazerOutputDevice> devices = <LazerOutputDevice>[];
    for (int index = 0; index < count.value; index++) {
      info.ref.structSize = sizeOf<LazerAudioDeviceInfo>();
      // First pass: ask for the required UTF-16 code-unit counts.
      api.deviceCatalogGet!(
        catalog,
        index,
        info,
        nullptr,
        0,
        idChars,
        nullptr,
        0,
        identityChars,
        nullptr,
        0,
        nameChars,
      );
      final Pointer<Uint16> id = calloc<Uint16>(idChars.value);
      final Pointer<Uint16> identity = calloc<Uint16>(identityChars.value);
      final Pointer<Uint16> name = calloc<Uint16>(nameChars.value);
      final int status = api.deviceCatalogGet!(
        catalog,
        index,
        info,
        id,
        idChars.value,
        idChars,
        identity,
        identityChars.value,
        identityChars,
        name,
        nameChars.value,
        nameChars,
      );
      if (status == lazerAudioOk) {
        devices.add(
          LazerOutputDevice(
            token: _wideToString(id),
            identityKey: _wideToString(identity),
            displayName: _wideToString(name),
            isDefault: info.ref.defaultRoleMask & 0x3 != 0,
            isActive: info.ref.endpointState & 0x1 != 0,
            endpointState: info.ref.endpointState,
            defaultRoleMask: info.ref.defaultRoleMask,
            hardwareVolumeFlags: info.ref.endpointVolumeQueryHresult == 0
                ? info.ref.endpointVolumeHardwareSupportFlags
                : null,
            volumeQueryHresult: info.ref.endpointVolumeQueryHresult,
          ),
        );
      } else {
        onError?.call('device $index read failed ($status)');
      }
      calloc.free(id);
      calloc.free(identity);
      calloc.free(name);
    }
    return devices;
  } finally {
    calloc.free(count);
    calloc.free(info);
    calloc.free(idChars);
    calloc.free(identityChars);
    calloc.free(nameChars);
    api.deviceCatalogDestroy!(catalog);
  }
}

List<LazerOutputDevice> _enumerateUtf8(
  LazerAudioApi api,
  Pointer<Pointer<Void>> out,
  void Function(String message)? onError,
) {
  final int created = api.outputDeviceCatalogCreate!(out);
  if (created != lazerAudioOk || out.value == nullptr) {
    onError?.call('output device catalog create failed ($created)');
    return <LazerOutputDevice>[];
  }
  final Pointer<Void> catalog = out.value;
  final Pointer<Uint32> count = calloc<Uint32>();
  final Pointer<LazerAudioOutputDeviceInfo> info =
      calloc<LazerAudioOutputDeviceInfo>();
  final Pointer<Uint32> tokenBytes = calloc<Uint32>();
  final Pointer<Uint32> identityBytes = calloc<Uint32>();
  final Pointer<Uint32> nameBytes = calloc<Uint32>();
  try {
    if (api.outputDeviceCatalogCount!(catalog, count) != lazerAudioOk) {
      onError?.call('output device catalog count failed');
      return <LazerOutputDevice>[];
    }
    final List<LazerOutputDevice> devices = <LazerOutputDevice>[];
    for (int index = 0; index < count.value; index++) {
      info.ref.structSize = sizeOf<LazerAudioOutputDeviceInfo>();
      api.outputDeviceCatalogGet!(
        catalog,
        index,
        info,
        nullptr,
        0,
        tokenBytes,
        nullptr,
        0,
        identityBytes,
        nullptr,
        0,
        nameBytes,
      );
      final Pointer<Uint8> token = calloc<Uint8>(tokenBytes.value);
      final Pointer<Uint8> identity = calloc<Uint8>(identityBytes.value);
      final Pointer<Uint8> name = calloc<Uint8>(nameBytes.value);
      final int status = api.outputDeviceCatalogGet!(
        catalog,
        index,
        info,
        token,
        tokenBytes.value,
        tokenBytes,
        identity,
        identityBytes.value,
        identityBytes,
        name,
        nameBytes.value,
        nameBytes,
      );
      if (status == lazerAudioOk) {
        devices.add(
          LazerOutputDevice(
            token: lazerReadCString(token),
            identityKey: lazerReadCString(identity),
            displayName: lazerReadCString(name),
            isDefault:
                info.ref.flags & lazerAudioOutputDeviceFlagDefault != 0,
            isActive: info.ref.flags & lazerAudioOutputDeviceFlagActive != 0,
            identityIsEphemeral:
                info.ref.flags & lazerAudioOutputDeviceFlagIdentityEphemeral != 0,
          ),
        );
      } else {
        onError?.call('output device $index read failed ($status)');
      }
      calloc.free(token);
      calloc.free(identity);
      calloc.free(name);
    }
    return devices;
  } finally {
    calloc.free(count);
    calloc.free(info);
    calloc.free(tokenBytes);
    calloc.free(identityBytes);
    calloc.free(nameBytes);
    api.outputDeviceCatalogDestroy!(catalog);
  }
}

/// Asks a Windows endpoint which exact PCM layouts it accepts in exclusive mode.
///
/// This is the same query the engine's own negotiation uses; a supported answer is
/// necessary but not sufficient for bit-perfect output, and nothing here reads back
/// from the DAC.
List<LazerPcmFormatProbe> probeExclusivePcmFormats(
  LazerAudioApi api,
  String deviceToken,
  List<LazerPcmFormatProbe> candidates,
) {
  final int Function(
    Pointer<Uint16>,
    Pointer<LazerAudioPcmFormatCandidate>,
    int,
    Pointer<LazerAudioPcmFormatProbeResult>,
  )?
  probe = api.probePcmFormats;
  if (probe == null || candidates.isEmpty) return const <LazerPcmFormatProbe>[];
  final Pointer<LazerAudioPcmFormatCandidate> input =
      calloc<LazerAudioPcmFormatCandidate>(candidates.length);
  final Pointer<LazerAudioPcmFormatProbeResult> results =
      calloc<LazerAudioPcmFormatProbeResult>(candidates.length);
  final Pointer<Uint16> token = deviceToken.toNativeUtf16().cast<Uint16>();
  try {
    for (int index = 0; index < candidates.length; index++) {
      final LazerPcmFormatProbe candidate = candidates[index];
      input[index]
        ..sampleRate = candidate.sampleRate
        ..channels = candidate.channels
        ..containerBits = candidate.containerBits
        ..validBits = candidate.validBits
        ..reserved = 0;
    }
    final int status = probe(token, input, candidates.length, results);
    if (status != lazerAudioOk) return const <LazerPcmFormatProbe>[];
    return <LazerPcmFormatProbe>[
      for (int index = 0; index < candidates.length; index++)
        LazerPcmFormatProbe(
          sampleRate: candidates[index].sampleRate,
          channels: candidates[index].channels,
          containerBits: candidates[index].containerBits,
          validBits: candidates[index].validBits,
          status: results[index].status,
          nativeStatus: results[index].nativeStatus,
        ),
    ];
  } finally {
    calloc.free(input);
    calloc.free(results);
    calloc.free(token);
  }
}

/// Reads a Windows endpoint's master-volume scalar.
///
/// Returns null when the endpoint does not advertise hardware volume; the engine
/// returns `Unsupported` rather than falling back to software gain.
double? readEndpointVolume(LazerAudioApi api, String deviceToken) {
  final int Function(
    Pointer<Uint16>,
    Pointer<Float>,
    Pointer<Uint32>,
    Pointer<Int32>,
  )?
  get = api.endpointVolumeGet;
  if (get == null) return null;
  final Pointer<Float> scalar = calloc<Float>();
  final Pointer<Uint32> flags = calloc<Uint32>();
  final Pointer<Int32> hresult = calloc<Int32>();
  final Pointer<Uint16> token = deviceToken.toNativeUtf16().cast<Uint16>();
  try {
    final int status = get(token, scalar, flags, hresult);
    if (status != lazerAudioOk) return null;
    return scalar.value;
  } finally {
    calloc.free(scalar);
    calloc.free(flags);
    calloc.free(hresult);
    calloc.free(token);
  }
}

/// Writes a Windows endpoint's master-volume scalar; returns whether it stuck.
bool writeEndpointVolume(
  LazerAudioApi api,
  String deviceToken,
  double volume,
) {
  final int Function(
    Pointer<Uint16>,
    double,
    Pointer<Uint32>,
    Pointer<Int32>,
  )?
  set = api.endpointVolumeSet;
  if (set == null) return false;
  final Pointer<Uint32> flags = calloc<Uint32>();
  final Pointer<Int32> hresult = calloc<Int32>();
  final Pointer<Uint16> token = deviceToken.toNativeUtf16().cast<Uint16>();
  try {
    return set(token, volume.clamp(0, 1), flags, hresult) == lazerAudioOk;
  } finally {
    calloc.free(flags);
    calloc.free(hresult);
    calloc.free(token);
  }
}

String _wideToString(Pointer<Uint16> buffer, {int maxUnits = 4096}) {
  if (buffer == nullptr) return '';
  final List<int> units = <int>[];
  for (int index = 0; index < maxUnits; index++) {
    final int unit = buffer[index];
    if (unit == 0) break;
    units.add(unit);
  }
  return String.fromCharCodes(units);
}
