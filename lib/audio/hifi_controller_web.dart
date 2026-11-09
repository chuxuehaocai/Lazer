import 'dart:async';

import 'package:flutter/foundation.dart';

import '../state/build_safe_notifier.dart';
import '../state/hifi_settings.dart';

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
  final String? nativeReason;
  final String engineDescription;
  final String? catalogKind;
  final Object? streamInfo;
}

/// Browser stand-in for the native HiFi controller.
///
/// The web build has no FFmpeg/WASAPI session, so the capabilities are all
/// false and the settings snapshot is still persisted by the app.
class HifiController extends ChangeNotifier with BuildSafeNotifier {
  HifiController(
    this._settings, {
    this.engine,
    this.catalogApi,
    required this.persist,
  });

  final Future<void> Function(HifiSettings settings) persist;
  final Object? engine;
  final Object? catalogApi;

  HifiSettings _settings;

  HifiSettings get settings => _settings;
  List<Object> get devices => const <Object>[];
  Object? get selectedDevice => null;
  Object? get defaultDevice => null;
  Object? get streamInfo => null;
  bool get busy => false;
  double? get endpointVolume => null;
  Object? get lastApplyError => null;
  bool get nativeAvailable => false;
  bool get supportsDevices => false;
  bool get supportsExclusiveMode => false;
  bool get supportsDoP => false;
  bool get supportsNativeDsd => false;
  bool get supportsDsdRatePolicy => false;
  bool get supportsVolumeNormalization => false;

  HifiStatus get status => const HifiStatus(
    nativeAvailable: false,
    nativeReason: '浏览器没有原生音频引擎',
    engineDescription: 'just_audio (web)',
  );

  Object? readMetrics() => null;

  void attach() {}

  Future<void> update(HifiSettings next) async {
    _settings = next;
    notifyListeners();
    await persist(next);
  }

  Future<void> apply() async {}
  Future<void> refreshDevices() async {}
  Future<void> refreshEndpointVolume() async {}
  Future<bool> setEndpointVolume(double volume) async => false;
  List<Object> probeExclusiveFormats() => const <Object>[];
}
