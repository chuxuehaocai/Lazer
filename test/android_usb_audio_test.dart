import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/android_usb_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/android-usb-audio');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late AndroidUsbAudio usb;
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    usb = AndroidUsbAudio(channel: channel);
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    channel.setMethodCallHandler(null);
  });

  test(
    'device catalog returns candidates and resolves permission at open time',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'listDevices') {
          return [
            {
              'id': 'android-usb:/dev/bus/usb/001/002',
              'name': 'Test DAC',
              'vendorId': 1,
              'productId': 2,
              'hasPermission': false,
            },
          ];
        }
        return 'android-usb-fd:42';
      });
      final devices = await usb.listDevices();
      expect(devices.single.name, 'Test DAC');
      expect(devices.single.hasPermission, isFalse);
      expect(await usb.resolveDeviceId(devices.single.id), 'android-usb-fd:42');
      expect(calls.last.arguments, {'id': devices.single.id});
    },
  );

  test('permission rejection propagates without a default route', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      throw PlatformException(code: 'usb_permission_denied');
    });
    await expectLater(
      usb.resolveDeviceId('android-usb:device'),
      throwsA(isA<PlatformException>()),
    );
    expect(calls, hasLength(1));
  });

  test('stale and malformed descriptor tokens are rejected', () async {
    await expectLater(
      usb.resolveDeviceId('android-usb-fd:42'),
      throwsStateError,
    );
    for (final response in <String?>[
      null,
      '42',
      'android-usb-fd:-1',
      'android-usb-fd:',
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => response);
      await expectLater(
        usb.resolveDeviceId('android-usb:device'),
        throwsStateError,
      );
    }
  });

  test(
    'system routes do not request USB access and close is explicit',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      expect(await usb.resolveDeviceId(''), '');
      expect(calls, isEmpty);
      await usb.releaseDevice('android-usb:device');
      await usb.closeConnections();
      expect(calls.map((c) => c.method), ['closeDevice', 'closeAll']);
    },
  );
}
