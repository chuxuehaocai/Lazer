import 'dart:async';

import 'package:flutter/services.dart';

/// A USB candidate, not proof of an opened direct-output session. The native
/// backend verifies its descriptors, clock and exclusive interface claims.
class AndroidUsbAudioDevice {
  const AndroidUsbAudioDevice({
    required this.id,
    required this.name,
    required this.vendorId,
    required this.productId,
    required this.hasPermission,
  });

  final String id;
  final String name;
  final int vendorId;
  final int productId;
  final bool hasPermission;

  factory AndroidUsbAudioDevice.fromMap(Map<Object?, Object?> map) =>
      AndroidUsbAudioDevice(
        id: map['id'] as String,
        name: map['name'] as String,
        vendorId: map['vendorId'] as int,
        productId: map['productId'] as int,
        hasPermission: map['hasPermission'] as bool? ?? false,
      );
}

/// Owns the Android permission/connection bridge. Persistent device settings use
/// `android-usb:<deviceName>`; ephemeral FD tokens must never be saved. Resolve
/// immediately before passing settings to the native engine. PCM never crosses
/// this channel: the native render thread writes directly through libusb.
class AndroidUsbAudio {
  AndroidUsbAudio({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('dev.naominet.lazer/usb_audio') {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'detached' && call.arguments is String) {
        _detached.add(call.arguments as String);
      }
    });
  }

  static final instance = AndroidUsbAudio();
  static bool isUsbDeviceId(String? id) =>
      id?.startsWith('android-usb:') ?? false;

  final MethodChannel _channel;
  final _detached = StreamController<String>.broadcast();
  Stream<String> get detachedDevices => _detached.stream;

  Future<List<AndroidUsbAudioDevice>> listDevices() async {
    final devices = await _channel.invokeListMethod<Object?>('listDevices');
    return [
      for (final device in devices ?? const <Object?>[])
        AndroidUsbAudioDevice.fromMap(device as Map<Object?, Object?>),
    ];
  }

  Future<String> resolveDeviceId(String deviceId) async {
    if (deviceId.startsWith('android-usb-fd:')) {
      throw StateError(
        'USB connection tokens cannot be reused as device settings',
      );
    }
    if (!isUsbDeviceId(deviceId)) return deviceId;
    final token = await _channel.invokeMethod<String>('openDevice', {
      'id': deviceId,
    });
    if (token == null || !RegExp(r'^android-usb-fd:[0-9]+$').hasMatch(token)) {
      throw StateError('Android USB did not return a live connection');
    }
    return token;
  }

  /// Call after the native engine has closed the device. A subsequent resolve
  /// opens a fresh connection, requesting permission only when Android requires it.
  Future<void> releaseDevice(String deviceId) =>
      _channel.invokeMethod<void>('closeDevice', {'id': deviceId});

  Future<void> closeConnections() => _channel.invokeMethod<void>('closeAll');
}
