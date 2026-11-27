import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Preference key for the Android status-bar visibility choice.
///
/// A missing value means "automatic": tablets hide the status bar by default,
/// while phones keep it visible. Once the listener changes the setting, the
/// stored boolean becomes the explicit choice.
const String androidImmersiveStatusBarPreferenceKey =
    'lazer_android_immersive_status_bar';

const MethodChannel _channel = MethodChannel('dev.naominet.lazer/system_ui');

/// Detects a tablet using Android's smallest-width resource bucket.
///
/// 600 dp is the Android large-screen boundary and remains stable across
/// rotation. Other platforms and unavailable channels report false.
Future<bool> detectAndroidTablet() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
  try {
    final bool? result = await _channel
        .invokeMethod<bool>('isTablet')
        .timeout(const Duration(milliseconds: 800));
    return result ?? false;
  } catch (_) {
    return false;
  }
}

/// Applies the status-bar-only immersive preference on Android.
///
/// The navigation bar stays available, so the setting does not trap users in
/// an edge-swipe-only navigation mode. Missing native support is harmless in
/// tests and on other platforms.
Future<void> applyAndroidStatusBarHidden(bool hidden) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    await _channel.invokeMethod<void>('setStatusBarHidden', <String, Object?>{
      'hidden': hidden,
    });
  } catch (_) {
    // Native UI state is best effort. The persisted preference remains useful
    // when the app is launched with a working Android activity.
  }
}
