import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const MethodChannel _updatesChannel = MethodChannel(
  'dev.naominet.lazer/updates',
);

@visibleForTesting
Future<Process> Function(
  String executable,
  List<String> arguments, {
  ProcessStartMode mode,
})
startExternalProcess = Process.start;

/// Opens an http(s) link in the system browser.
///
/// The app deliberately carries no `url_launcher` dependency: desktop shells
/// can hand the URL to the platform directly, and Android/iOS answer through
/// the same channel the TV and haptics bridges already use. Only http and
/// https are accepted, so a malformed release payload cannot ask the platform
/// to start an arbitrary scheme.
///
/// Returns false when no browser could be launched; callers then show the URL
/// itself instead of failing silently.
Future<bool> openExternalUrl(String raw) async {
  final Uri? uri = Uri.tryParse(raw.trim());
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
    return false;
  }
  if (kIsWeb) return false;
  if (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    try {
      return await _updatesChannel.invokeMethod<bool>(
            'openUrl',
            <String, Object>{'url': uri.toString()},
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }
  try {
    if (Platform.isWindows) {
      await startExternalProcess('rundll32', <String>[
        'url.dll,FileProtocolHandler',
        uri.toString(),
      ], mode: ProcessStartMode.detached);
    } else if (Platform.isMacOS) {
      await startExternalProcess('open', <String>[
        uri.toString(),
      ], mode: ProcessStartMode.detached);
    } else if (Platform.isLinux) {
      await startExternalProcess('xdg-open', <String>[
        uri.toString(),
      ], mode: ProcessStartMode.detached);
    } else {
      return false;
    }
    return true;
  } catch (_) {
    return false;
  }
}
