import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Small bridge for the native home-screen widgets. The widget only displays
/// the device-local all-time play count, so it never needs the account session.
class SystemWidgetsBridge {
  static const MethodChannel _channel = MethodChannel(
    'dev.naominet.lazer/system_widgets',
  );

  static Future<void> updatePlayCount(int count) async {
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod<void>('updatePlayCount', <String, Object?>{
        'count': count,
      });
    } on MissingPluginException {
      // Native widgets are optional on desktop and on older app installs.
    } on PlatformException {
      // A widget update must never affect playback or statistics persistence.
    } catch (_) {
      // Tests and early startup can invoke this before the Flutter binding has
      // a binary messenger. Widgets remain optional in that phase.
    }
  }
}
