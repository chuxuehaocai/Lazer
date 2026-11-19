// Bridges the HiFi settings to the native engine.
//
// One place applies the user's choices, so the settings page, the persistence layer
// and the engine cannot drift apart: `apply()` pushes device policy and the EQ into
// the engine, `refreshDevices()` re-reads the platform catalog, and the reported
// format comes from the engine's own snapshot rather than from what was requested.
//
// Everything here reports honestly: a device that refused exclusive mode, a
// bit-perfect request the endpoint cannot honour, or a DSD mode without a DSD source
// are shown as they are, never as "supported".
// i18n:data — the fallback reason below is an interface key; the HiFi settings
// page renders it through `context.tr`.
library;

import '../state/build_safe_notifier.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../state/hifi_settings.dart';
import 'android_usb_audio.dart';
import 'native/audio_path_log.dart';
import 'native/engine_metrics.dart';
import 'native/lazer_audio_devices.dart';
import 'native/lazer_audio_engine.dart';
import 'native/lazer_audio_library.dart';
import 'native/lazer_audio_worker.dart';
import 'native/output_path_state.dart';

/// What the settings page needs to draw itself.
class HifiStatus {
  const HifiStatus({
    required this.nativeAvailable,
    required this.nativeReason,
    required this.engineDescription,
    this.catalogKind,
    this.streamInfo,
  });

  final bool nativeAvailable;

  /// Why the native engine is not in use, when it is not.
  final String? nativeReason;

  /// `native (lazer-audio)` or `just_audio (reason)`.
  final String engineDescription;

  /// `windows-endpoints` / `utf8-output`, or null when the host has no catalog.
  final String? catalogKind;

  /// The format the engine actually negotiated for the current source.
  final LazerStreamInfo? streamInfo;
}

/// Owns the HiFi settings for the running app.
class HifiController extends ChangeNotifier with BuildSafeNotifier {
  HifiController(
    HifiSettings settings, {
    required this.engine,
    required this.persist,
    this.catalogApi,
    AndroidUsbAudio? androidUsb,
  }) : _settings = defaultTargetPlatform == TargetPlatform.iOS
           ? settings.forIosOutput()
           : settings,
       _androidUsb =
           androidUsb ?? (Platform.isAndroid ? AndroidUsbAudio.instance : null);

  /// Persists a snapshot of the settings; injected so tests can observe writes.
  final Future<void> Function(HifiSettings settings) persist;

  /// The engine in use, when it is the native one.
  final NativeAudioEngine? engine;

  /// The loaded library, for the platform catalogs. Independent of [engine] so the
  /// device list still works while the native engine is not driving playback.
  final LazerAudioApi? catalogApi;
  final AndroidUsbAudio? _androidUsb;
  StreamSubscription<String>? _usbDetachSubscription;
  bool _disposed = false;
  int _catalogGeneration = 0;

  HifiSettings _settings;
  List<LazerOutputDevice> _devices = const <LazerOutputDevice>[];
  String? _deviceError;
  LazerStreamInfo? _streamInfo;
  bool _busy = false;
  double? _endpointVolume;
  StreamSubscription<LazerStreamInfo?>? _streamSubscription;
  Object? _lastApplyError;
  Object? _lastDspApplyError;
  bool _dspDeferredUntilNextStream = false;
  Timer? _persistTimer;
  HifiSettings? _pendingPersist;
  Future<void> _persistQueue = Future<void>.value();

  HifiSettings get settings => _settings;
  List<LazerOutputDevice> get devices => _devices;
  String? get deviceError => _deviceError;
  LazerStreamInfo? get streamInfo => _streamInfo ?? _streamInfoFromEngine;
  bool get busy => _busy;
  double? get endpointVolume => _endpointVolume;

  /// Why the last apply failed, for an inline error row.
  Object? get lastApplyError => _lastApplyError;

  /// DSP was queued for the next output session because the running strict
  /// stream cannot accept processing. This is not an apply failure.
  bool get dspDeferredUntilNextStream => _dspDeferredUntilNextStream;

  bool get nativeAvailable => engine != null;
  bool get usesIosSystemRoute => defaultTargetPlatform == TargetPlatform.iOS;
  bool get usesAndroidUsbDevices => _androidUsb != null;
  bool get supportsAndroidUsb =>
      usesAndroidUsbDevices && (catalogApi?.supportsAndroidUsb ?? false);
  bool get supportsDevices =>
      !usesIosSystemRoute &&
      (supportsAndroidUsb ||
          (catalogApi != null && outputDeviceCatalogKind(catalogApi!) != null));
  bool get supportsExclusiveMode => usesAndroidUsbDevices
      ? supportsAndroidUsb &&
            AndroidUsbAudio.isUsbDeviceId(_settings.outputToken)
      : !usesIosSystemRoute &&
            (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
  bool get supportsDoP =>
      !usesIosSystemRoute &&
      (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
  // A capability to request strict output, not a claim about the connected DAC.
  bool get supportsBitPerfect => !usesIosSystemRoute && supportsExclusiveMode;
  bool get supportsNativeDsd => !usesIosSystemRoute && Platform.isLinux;

  /// Shared with AppState so controls and the applied DSP see the same policy.
  HifiSettings normalizeSettings(HifiSettings settings) =>
      usesIosSystemRoute ? settings.forIosOutput() : settings;

  /// Whether the vendored engine can enforce the selected DSD rate policy.
  bool get supportsDsdRatePolicy => _settings.dsdRatePolicy.isSupported;

  /// Whether the selected normalisation mode is available in this engine.
  bool get supportsVolumeNormalization =>
      _settings.volumeNormalization.isSupported;

  /// The selected device, or null for the system default.
  LazerOutputDevice? get selectedDevice {
    if (!_settings.hasOutputSelection) return null;
    final String token = _settings.outputToken!;
    for (final LazerOutputDevice device in _devices) {
      if (device.token == token) return device;
    }
    return null;
  }

  /// The default endpoint, used for the endpoint-volume row.
  LazerOutputDevice? get defaultDevice {
    if (usesAndroidUsbDevices) return null;
    for (final LazerOutputDevice device in _devices) {
      if (device.isDefault) return device;
    }
    return _devices.isEmpty ? null : _devices.first;
  }

  String? get _nativeReason => !_settings.preferNativeEngine
      ? '已选择系统音频引擎'
      : LazerAudioLoader.load().reason;

  HifiStatus get status => HifiStatus(
    nativeAvailable: nativeAvailable,
    nativeReason: nativeAvailable ? null : _nativeReason,
    engineDescription: nativeAvailable
        ? 'native (lazer-audio)'
        : 'just_audio${_nativeReason == null ? '' : ' ($_nativeReason)'}',
    catalogKind: supportsAndroidUsb
        ? 'android-usb-uac2'
        : catalogApi == null
        ? null
        : outputDeviceCatalogKind(catalogApi!),
    streamInfo: streamInfo,
  );

  LazerStreamInfo? get _streamInfoFromEngine => engine?.streamInfo;

  /// The live output path with the bit-perfect verdict derived from its three
  /// conditions, or null before a stream is opened.
  OutputPathState? get outputPath => streamInfo?.outputPath;

  LazerEngineMetrics? _metrics;

  /// Ring occupancy and starvation counters of the current session.
  ///
  /// A synchronous, allocation-free snapshot read — the same call [position]
  /// already makes while the app ticks — so the diagnostics panel can read it
  /// during a build. The underrun transition is recorded once as an `audio.path`
  /// line, which is what makes a starvation episode visible after the fact
  /// without logging every frame count.
  LazerEngineMetrics? readMetrics() {
    final LazerEngineMetrics? next = engine?.readMetrics();
    if (next == null) return _metrics;
    final LazerEngineMetrics? previous = _metrics;
    _metrics = next;
    if (previous == null ||
        previous.underrunActive != next.underrunActive ||
        (next.underrunFrames > 0 && previous.underrunFrames == 0)) {
      logAudioPathEvent('metrics', <String, Object?>{
        'ring_fill': next.ringFillFrames,
        'ring_capacity': next.ringCapacityFrames,
        'underrun_active': next.underrunActive ? 1 : 0,
        'underrun_frames': next.underrunFrames,
      });
    }
    return next;
  }

  /// Starts following the engine's negotiated format.
  void attach() {
    if (_disposed) return;
    _usbDetachSubscription ??= _androidUsb?.detachedDevices.listen((_) {
      unawaited(refreshDevices());
    });
    final NativeAudioEngine? native = engine;
    if (native == null) return;
    _streamInfo = native.streamInfo;
    _streamSubscription ??= native.streamInfoStream.listen((
      LazerStreamInfo? info,
    ) {
      _streamInfo = info;
      if (info != null &&
          _dspDeferredUntilNextStream &&
          !native.hasPendingDspSettings) {
        _dspDeferredUntilNextStream = false;
      }
      // A strict output can refuse DSP until the next source is opened. The
      // engine replays that saved request before opening, so a new snapshot
      // with no pending DSP confirms recovery without resending settings here.
      if (info != null &&
          _lastDspApplyError != null &&
          identical(_lastApplyError, _lastDspApplyError) &&
          !native.hasPendingDspSettings) {
        _lastApplyError = null;
        _lastDspApplyError = null;
      }
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _catalogGeneration++;
    unawaited(_usbDetachSubscription?.cancel());
    _usbDetachSubscription = null;
    unawaited(_streamSubscription?.cancel());
    _streamSubscription = null;
    _persistTimer?.cancel();
    _flushPendingPersistence();
    super.dispose();
  }

  /// Replaces the settings and applies only the parts that changed.
  ///
  /// Slider movement can produce many updates per second. Those updates should
  /// touch the DSP once, not also resend the output-device policy and query the
  /// endpoint volume on every detent. Preference writes are coalesced separately.
  /// [forceApply] restores the complete request at startup, even if this
  /// controller was constructed with the same saved settings before attaching.
  Future<void> update(HifiSettings next, {bool forceApply = false}) async {
    next = normalizeSettings(next);
    if (_disposed) return;
    if (next == _settings) {
      if (forceApply || _lastApplyError != null) await apply();
      return;
    }
    final HifiSettings previous = _settings;
    // A previous partial apply may have changed output but refused DSP (or the
    // reverse). Retry both before clearing its error, even when this edit only
    // changes a buffer size or another unrelated preference.
    final bool retry = forceApply || _lastApplyError != null;
    final bool outputChanged = retry || !_sameOutputSettings(previous, next);
    final bool endpointChanged = previous.outputToken != next.outputToken;
    final bool dspChanged = retry || !_sameDspSettings(previous, next);
    _settings = next;
    _schedulePersistence(next);
    notifyListeners();
    bool applyingDsp = false;
    bool deferredDsp = false;
    try {
      if (outputChanged) {
        final NativeAudioEngine? native = engine;
        if (native != null) {
          await native.setDeviceSettings(_toDeviceSettings());
          if (endpointChanged) await refreshEndpointVolume();
        }
      }
      if (dspChanged) {
        applyingDsp = true;
        deferredDsp = await _applyDspSettings();
      }
      if (_disposed || !identical(_settings, next)) return;
      _lastApplyError = null;
      _lastDspApplyError = null;
      _dspDeferredUntilNextStream = deferredDsp;
    } catch (error) {
      if (_disposed || !identical(_settings, next)) return;
      _lastApplyError = error;
      _lastDspApplyError = applyingDsp ? error : null;
      _dspDeferredUntilNextStream = false;
      debugPrint('hifi: applying settings failed: $error');
    }
    notifyListeners();
  }

  /// Pushes the current settings into the engine.
  Future<void> apply() async {
    if (_disposed) return;
    final HifiSettings snapshot = _settings;
    bool applyingDsp = false;
    bool deferredDsp = false;
    try {
      await _applyOutputSettings(refreshVolume: true);
      applyingDsp = true;
      deferredDsp = await _applyDspSettings();
      if (_disposed || !identical(_settings, snapshot)) return;
      _lastApplyError = null;
      _lastDspApplyError = null;
      _dspDeferredUntilNextStream = deferredDsp;
    } catch (error) {
      if (_disposed || !identical(_settings, snapshot)) return;
      _lastApplyError = error;
      _lastDspApplyError = applyingDsp ? error : null;
      _dspDeferredUntilNextStream = false;
      debugPrint('hifi: applying settings failed: $error');
    }
    notifyListeners();
  }

  Future<void> _applyOutputSettings({required bool refreshVolume}) async {
    final NativeAudioEngine? native = engine;
    if (native == null) return;
    await native.setDeviceSettings(_toDeviceSettings());
    if (refreshVolume) await refreshEndpointVolume();
  }

  Future<bool> _applyDspSettings() async {
    final NativeAudioEngine? native = engine;
    if (native == null) return false;
    final LazerDspRequest dsp = _settings.toDspRequest();
    try {
      await native.setEqualizer(
        preampDb: dsp.preampDb,
        limiterEnabled: dsp.limiterEnabled,
        limiterThresholdDb: dsp.limiterThresholdDb,
        bands: <LazerEqBandSettings>[
          for (final HifiEqBandMessage band in dsp.bands)
            LazerEqBandSettings(
              kind: band.kind,
              frequencyHz: band.frequencyHz,
              gainDb: band.gainDb,
              q: band.q,
              enabled: band.enabled != 0,
            ),
        ],
        stageOrder: dsp.stageOrder,
        crossfeed: LazerCrossfeedSettings(
          enabled: dsp.crossfeedEnabled,
          strength: dsp.crossfeedStrength,
          algorithm: dsp.crossfeedAlgorithm,
          delayMs: dsp.crossfeedDelayMs,
          cutoffHz: dsp.crossfeedCutoffHz,
        ),
      );
      return false;
    } catch (_) {
      final OutputPathState? path = native.streamInfo?.outputPath;
      // The output policy is reopened on the next source. Asking the running
      // strict stream to install processing now is expected to be refused; the
      // engine has already retained the request and replays it at that boundary.
      if (!_settings.directOutputRequested &&
          path != null &&
          path.live &&
          (path.bitPerfect || path.isDsdPath) &&
          native.hasPendingDspSettings) {
        return true;
      }
      rethrow;
    }
  }

  bool _sameOutputSettings(HifiSettings first, HifiSettings second) {
    final LazerOutputRequest a = first.toOutputRequest();
    final LazerOutputRequest b = second.toOutputRequest();
    return a.token == b.token &&
        a.exclusive == b.exclusive &&
        a.bitPerfect == b.bitPerfect &&
        a.resampleMode == b.resampleMode &&
        a.targetSampleRate == b.targetSampleRate &&
        a.bufferMillis == b.bufferMillis &&
        a.dsdOutputMode == b.dsdOutputMode &&
        listEquals(
          a.dsdOutputMode.fallbackChain,
          b.dsdOutputMode.fallbackChain,
        );
  }

  bool _sameDspSettings(HifiSettings first, HifiSettings second) {
    final LazerDspRequest a = first.toDspRequest();
    final LazerDspRequest b = second.toDspRequest();
    if (a.preampDb != b.preampDb ||
        a.limiterEnabled != b.limiterEnabled ||
        a.limiterThresholdDb != b.limiterThresholdDb ||
        a.crossfeedEnabled != b.crossfeedEnabled ||
        a.crossfeedStrength != b.crossfeedStrength ||
        a.crossfeedAlgorithm != b.crossfeedAlgorithm ||
        a.crossfeedDelayMs != b.crossfeedDelayMs ||
        a.crossfeedCutoffHz != b.crossfeedCutoffHz ||
        !listEquals(a.stageOrder, b.stageOrder) ||
        a.bands.length != b.bands.length) {
      return false;
    }
    for (int index = 0; index < a.bands.length; index++) {
      final HifiEqBandMessage x = a.bands[index];
      final HifiEqBandMessage y = b.bands[index];
      if (x.kind != y.kind ||
          x.frequencyHz != y.frequencyHz ||
          x.gainDb != y.gainDb ||
          x.q != y.q ||
          x.enabled != y.enabled) {
        return false;
      }
    }
    return true;
  }

  void _schedulePersistence(HifiSettings settings) {
    _pendingPersist = settings;
    _persistTimer?.cancel();
    _persistTimer = Timer(
      const Duration(milliseconds: 180),
      _flushPendingPersistence,
    );
  }

  void _flushPendingPersistence() {
    _persistTimer = null;
    final HifiSettings? snapshot = _pendingPersist;
    _pendingPersist = null;
    if (snapshot == null) return;
    _persistQueue = _persistQueue.then((_) => persist(snapshot)).catchError((
      Object error,
    ) {
      debugPrint('hifi: persisting settings failed: $error');
    });
  }

  /// The engine-side settings, derived in one place (`HifiSettings`) so the page,
  /// the persistence layer and this controller cannot disagree about what a
  /// setting means.
  LazerDeviceSettings _toDeviceSettings() {
    final LazerOutputRequest request = _settings.toOutputRequest();
    return LazerDeviceSettings(
      exclusive: request.exclusive,
      bitPerfect: request.bitPerfect,
      resampleMode: request.resampleMode,
      targetSampleRate: request.targetSampleRate,
      bufferMillis: request.bufferMillis,
      dsdOutputMode: request.dsdOutputMode.nativeValue,
      dsdFallbackChain: <int>[
        for (final HifiDsdOutputMode mode
            in request.dsdOutputMode.fallbackChain)
          mode.nativeValue,
      ],
      deviceToken: request.token,
    );
  }

  /// Re-reads the platform's output devices.
  Future<void> refreshDevices() async {
    if (_disposed) return;
    if (usesIosSystemRoute) {
      // iOS chooses outputs through AVAudioSession and Control Center. A desktop
      // catalog (or a saved UID) must not appear as a selectable iOS endpoint.
      _devices = const <LazerOutputDevice>[];
      _deviceError = null;
      _endpointVolume = null;
      notifyListeners();
      return;
    }
    final usb = _androidUsb;
    if (usb != null) {
      final generation = ++_catalogGeneration;
      _busy = true;
      notifyListeners();
      try {
        final candidates = await usb.listDevices();
        if (_disposed || generation != _catalogGeneration) return;
        _devices = [
          for (final device in candidates)
            LazerOutputDevice(
              token: device.id,
              identityKey: device.id,
              identityIsEphemeral: true,
              displayName: device.name,
            ),
        ];
        _deviceError = null;
        _endpointVolume = null;
      } catch (error) {
        if (_disposed || generation != _catalogGeneration) return;
        _devices = const [];
        _deviceError = '$error';
      } finally {
        if (!_disposed && generation == _catalogGeneration) {
          _busy = false;
          logAudioPathEvent('device_catalog', <String, Object?>{
            'kind': 'android-usb-uac2',
            'count': _devices.length,
            'error': _deviceError,
          });
          notifyListeners();
        }
      }
      return;
    }
    final LazerAudioApi? api = catalogApi;
    if (api == null) {
      _devices = const <LazerOutputDevice>[];
      _deviceError = 'this host has no device catalog';
      logAudioPathEvent('device_catalog', <String, Object?>{
        'kind': null,
        'count': 0,
        'default': null,
        'error': _deviceError,
      });
      notifyListeners();
      return;
    }
    _busy = true;
    notifyListeners();
    try {
      _deviceError = null;
      _devices = enumerateOutputDevices(
        api,
        onError: (String message) => _deviceError = message,
      );
      await refreshEndpointVolume();
    } catch (error) {
      _deviceError = '$error';
    } finally {
      _busy = false;
      // The catalog record: which namespace answered, how many endpoints it
      // found, and which one playback would default to.
      logAudioPathEvent('device_catalog', <String, Object?>{
        'kind': outputDeviceCatalogKind(api),
        'count': _devices.length,
        'default': defaultDevice?.displayName,
        'error': _deviceError,
      });
      if (!_disposed) notifyListeners();
    }
  }

  /// Reads the endpoint master volume of the selected (or default) endpoint.
  Future<void> refreshEndpointVolume() async {
    final LazerAudioApi? api = catalogApi;
    final LazerOutputDevice? device = selectedDevice ?? defaultDevice;
    if (api == null || device == null || !device.hasHardwareVolume) {
      _endpointVolume = null;
      return;
    }
    _endpointVolume = readEndpointVolume(api, device.token);
  }

  /// Writes the endpoint master volume.
  ///
  /// This is the OS endpoint control: it affects other applications using the same
  /// endpoint, and it is not a claim about the DAC's own volume or USB `SET_CUR`.
  Future<bool> setEndpointVolume(double volume) async {
    final LazerAudioApi? api = catalogApi;
    final LazerOutputDevice? device = selectedDevice ?? defaultDevice;
    if (api == null || device == null) return false;
    final bool written = writeEndpointVolume(api, device.token, volume);
    if (written) {
      _endpointVolume = readEndpointVolume(api, device.token) ?? volume;
      notifyListeners();
    }
    return written;
  }

  /// Asks the engine which exact PCM layouts the selected endpoint accepts in
  /// exclusive mode. Empty when the host has no probe (non-Windows).
  List<LazerPcmFormatProbe> probeExclusiveFormats() {
    final LazerAudioApi? api = catalogApi;
    final LazerOutputDevice? device = selectedDevice ?? defaultDevice;
    if (api == null || device == null) return const <LazerPcmFormatProbe>[];
    return probeExclusivePcmFormats(api, device.token, <LazerPcmFormatProbe>[
      for (final int rate in <int>[44100, 48000, 88200, 96000, 176400, 192000])
        for (final int bits in <int>[16, 24, 32])
          LazerPcmFormatProbe(
            sampleRate: rate,
            channels: 2,
            containerBits: bits,
            validBits: bits,
            status: 0,
            nativeStatus: 0,
          ),
    ]).where((LazerPcmFormatProbe probe) => probe.isSupported).toList();
  }
}
