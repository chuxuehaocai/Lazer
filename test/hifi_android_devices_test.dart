import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/android_usb_audio.dart';
import 'package:lazer_nextgen/audio/hifi_controller_io.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_library_io.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_abi.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_engine.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_worker.dart';
import 'package:lazer_nextgen/audio/native/audio_stream_cache.dart';
import 'package:lazer_nextgen/state/hifi_settings.dart';

class _CatalogApi extends LazerAudioApi {
  _CatalogApi(this.usbSupported) : super(DynamicLibrary.process());
  final bool usbSupported;
  @override
  bool get supportsAndroidUsb => usbSupported;

  @override
  String Function(Pointer<Void>) get lastError =>
      (_) => 'USB test refusal';
}

class _UnusedBridge implements LazerAudioBridgeApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('This test must not open a reader');
}

class _DeviceWorker implements LazerAudioWorker {
  _DeviceWorker(this.events);
  final List<String> events;
  final devices = <List<Object?>>[];
  final closed = Completer<void>();
  int deviceStatus = lazerAudioOk;

  @override
  Future<Object?> call(int op, List<Object?> params) async {
    events.add(LazerWorkerOp.describe(op));
    if (op == LazerWorkerOp.setDevice) {
      devices.add(List<Object?>.of(params));
      return deviceStatus;
    }
    return lazerAudioOk;
  }

  @override
  Future<void> close() async => closed.complete();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/hifi-usb-catalog');
  const nativeChannel = MethodChannel('dev.naominet.lazer/usb_audio');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late AndroidUsbAudio usb;
  late HifiController hifi;
  const id = 'android-usb:/dev/bus/usb/001/002';
  Map<String, Object> device(String token) => {
    'id': token,
    'name': 'USB DAC',
    'vendorId': 1,
    'productId': 2,
    'hasPermission': false,
  };

  setUp(() {
    usb = AndroidUsbAudio(channel: channel);
    hifi = HifiController(
      const HifiSettings(outputToken: id, outputName: 'USB DAC'),
      engine: null,
      persist: (_) async {},
      catalogApi: _CatalogApi(true),
      androidUsb: usb,
    );
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    channel.setMethodCallHandler(null);
    messenger.setMockMethodCallHandler(nativeChannel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'USB catalog preserves requested route without opening permission',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return [device(id)];
      });
      await hifi.refreshDevices();
      expect(calls, ['listDevices']);
      expect(hifi.supportsDevices, isTrue);
      expect(hifi.supportsExclusiveMode, isTrue);
      expect(hifi.selectedDevice?.token, id);
      expect(hifi.selectedDevice?.identityIsEphemeral, isTrue);
      expect(hifi.defaultDevice, isNull);
      expect(hifi.status.catalogKind, 'android-usb-uac2');
      hifi.dispose();
    },
  );

  test(
    'disconnected saved route is retained and never becomes system default',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async => []);
      await hifi.refreshDevices();
      expect(hifi.settings.outputToken, id);
      expect(hifi.selectedDevice, isNull);
      expect(hifi.defaultDevice, isNull);
      hifi.dispose();
    },
  );

  test('old native library cannot advertise USB exclusive capability', () {
    hifi.dispose();
    hifi = HifiController(
      const HifiSettings(outputToken: id),
      engine: null,
      persist: (_) async {},
      catalogApi: _CatalogApi(false),
      androidUsb: usb,
    );
    expect(hifi.supportsAndroidUsb, isFalse);
    expect(hifi.supportsExclusiveMode, isFalse);
    hifi.dispose();
  });

  test(
    'latest enumeration wins when two refreshes finish out of order',
    () async {
      final first = Completer<Object?>();
      final second = Completer<Object?>();
      var calls = 0;
      messenger.setMockMethodCallHandler(
        channel,
        (_) => ++calls == 1 ? first.future : second.future,
      );
      final older = hifi.refreshDevices();
      final newer = hifi.refreshDevices();
      second.complete([device('android-usb:new')]);
      await newer;
      first.complete([device('android-usb:old')]);
      await older;
      expect(hifi.devices.single.token, 'android-usb:new');
      expect(hifi.busy, isFalse);
      hifi.dispose();
    },
  );

  test('desktop refresh does not notify after controller disposal', () async {
    hifi.dispose();
    hifi = HifiController(
      const HifiSettings(),
      engine: null,
      persist: (_) async {},
      catalogApi: _CatalogApi(false),
    );
    var notifications = 0;
    hifi.addListener(() => ++notifications);
    final pending = hifi.refreshDevices();
    hifi.dispose();
    await pending;
    expect(notifications, 1);
  });

  test(
    'late enumeration after disposal does not notify or replace state',
    () async {
      final reply = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (_) => reply.future);
      final pending = hifi.refreshDevices();
      hifi.dispose();
      reply.complete([device(id)]);
      await pending;
      expect(hifi.devices, isEmpty);
    },
  );

  test('USB capability remains optional for older imported libraries', () {
    expect(
      requiredEngineSymbols,
      isNot(contains('lazer_audio_android_usb_backend_version')),
    );
    expect(LazerAudioApi(DynamicLibrary.process()).supportsAndroidUsb, isFalse);
  });

  Future<(NativeAudioEngine, _DeviceWorker)> nativeEngine({
    bool supported = true,
    required List<String> events,
  }) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final directory = await Directory.systemTemp.createTemp('hifi-usb');
    addTearDown(() => directory.delete(recursive: true));
    final worker = _DeviceWorker(events);
    final native = NativeAudioEngine.forTesting(
      api: _CatalogApi(supported),
      bridge: _UnusedBridge(),
      worker: worker,
      cache: AudioStreamCache(() async => directory),
    );
    addTearDown(() async {
      native.dispose();
      await worker.closed.future;
    });
    return (native, worker);
  }

  test(
    'native USB selection sends only live descriptors and surfaces refusal',
    () async {
      final events = <String>[];
      final (native, worker) = await nativeEngine(events: events);
      messenger.setMockMethodCallHandler(nativeChannel, (call) async {
        events.add('usb:${call.method}');
        return call.method == 'openDevice' ? 'android-usb-fd:42' : null;
      });
      await native.setDeviceSettings(
        const LazerDeviceSettings(deviceToken: id),
      );
      expect(worker.devices.single.last, 'android-usb-fd:42');
      worker.deviceStatus = lazerAudioErrorUnsupported;
      await expectLater(
        native.setDeviceSettings(const LazerDeviceSettings(deviceToken: id)),
        throwsStateError,
      );
      native.dispose();
      await worker.closed.future;
      expect(
        events.indexOf('destroy'),
        lessThan(events.indexOf('usb:closeAll')),
      );
    },
  );

  test('an engine without USB support never requests permission', () async {
    final events = <String>[];
    final (native, worker) = await nativeEngine(
      supported: false,
      events: events,
    );
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      events.add('usb:${call.method}');
      return 'android-usb-fd:42';
    });
    await expectLater(
      native.setDeviceSettings(const LazerDeviceSettings(deviceToken: id)),
      throwsUnsupportedError,
    );
    expect(worker.devices, isEmpty);
    expect(events, isEmpty);
  });

  test(
    'permission arriving after native destruction releases its connection',
    () async {
      final events = <String>[];
      final (native, worker) = await nativeEngine(events: events);
      final opened = Completer<void>();
      final permission = Completer<String?>();
      messenger.setMockMethodCallHandler(nativeChannel, (call) async {
        events.add('usb:${call.method}');
        if (call.method == 'openDevice') {
          opened.complete();
          return permission.future;
        }
        return null;
      });
      final pending = native.setDeviceSettings(
        const LazerDeviceSettings(deviceToken: id),
      );
      final rejected = expectLater(pending, throwsStateError);
      await opened.future;
      native.dispose();
      await worker.closed.future;
      permission.complete('android-usb-fd:42');
      await rejected;
      expect(worker.devices, isEmpty);
      expect(
        events,
        containsAllInOrder([
          'usb:openDevice',
          'stop',
          'destroy',
          'usb:closeDevice',
        ]),
      );
    },
  );
}
