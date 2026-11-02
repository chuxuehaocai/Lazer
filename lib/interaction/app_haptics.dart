import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Semantic actions only. Each UI control calls this after recognizing a tap.
class AppHaptics {
  AppHaptics({DateTime Function()? now}) : _now = now ?? DateTime.now;
  static const channel = MethodChannel('dev.naominet.lazer/haptics');
  final DateTime Function() _now;
  DateTime? _last;

  Future<void> pulse({
    required bool enabled,
    required double intensity,
    bool detent = false,
    bool boundary = false,
  }) async {
    if (!enabled || intensity <= 0 || kIsWeb) return;
    final platform = defaultTargetPlatform;
    if (platform != TargetPlatform.iOS && platform != TargetPlatform.android) {
      return;
    }
    final now = _now();
    if (!boundary &&
        _last != null &&
        now.difference(_last!) < Duration(milliseconds: detent ? 35 : 60)) {
      return;
    }
    _last = now;
    final Map<String, Object> impact = <String, Object>{
      'intensity': (intensity * (detent && !boundary ? .55 : 1)).clamp(
        0.0,
        1.0,
      ),
      'kind': boundary
          ? 'boundary'
          : detent
          ? 'detent'
          : 'tap',
    };
    try {
      // Both mobile hosts implement this channel: iOS through impact
      // generators, Android through VibrationEffect. Flutter's own
      // HapticFeedback maps a tap to CLOCK_TICK there, which many devices do
      // not implement and which cannot follow the intensity slider.
      await channel.invokeMethod<void>('impact', impact);
    } on MissingPluginException {
      // Hosts without the native channel (tests, desktop tooling) fall back
      // to the framework's view haptics.
      try {
        await (platform == TargetPlatform.iOS
            ? HapticFeedback.lightImpact()
            : HapticFeedback.selectionClick());
      } on MissingPluginException {
        // Haptics are optional on hosts without a platform implementation.
      } on PlatformException {
        // A device-level failure must never prevent the recognized action.
      }
    } on PlatformException {
      // Device haptics are optional and must never prevent an action.
    }
  }
}

/// Quantized seek feedback: repeat ticks require movement to another notch,
/// so a held thumb or a 100 ms playback update cannot keep vibrating.
class SeekDetents {
  int? _notch;
  bool active = false;
  void begin(double value) {
    active = true;
    _notch = (value.clamp(0, 1) * 100).round();
  }

  bool update(double value) {
    if (!active) return false;
    final next = (value.clamp(0, 1) * 100).round();
    if (next == _notch) return false;
    _notch = next;
    return true;
  }

  void end() {
    active = false;
    _notch = null;
  }
}

/// Quantized detents for setting sliders over any [min, max] range. A repeat
/// tick requires crossing another division (1/100 of the range when the bar
/// is undivided), so a held thumb or a keyboard auto-repeat cannot keep
/// vibrating the way a raw onChanged stream would.
class SliderDetents {
  SliderDetents({required this.min, required this.max, this.steps});
  final double min;
  final double max;
  final int? steps;
  int? _notch;
  bool active = false;

  int _notchOf(double value) {
    final span = max - min;
    final t = span > 0 ? (value.clamp(min, max) - min) / span : 0.0;
    return (t * (steps ?? 100)).round();
  }

  void begin(double value) {
    active = true;
    _notch = _notchOf(value);
  }

  bool update(double value) {
    if (!active) return false;
    final next = _notchOf(value);
    if (next == _notch) return false;
    _notch = next;
    return true;
  }

  void end() {
    active = false;
    _notch = null;
  }
}
