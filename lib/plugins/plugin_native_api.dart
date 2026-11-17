import '../audio/audio_operation_queue.dart';
import 'plugin_manifest.dart';

/// Narrow native host API. Every callback stays on the Flutter isolate; no
/// pointers, platform channels, executable names or filesystem paths cross Lua.
class PluginNativeApi {
  PluginNativeApi({
    required this.platform,
    required this.audioStatusSupported,
    required this.audioDevicesSupported,
    required this.audioStatus,
    required this.audioDevices,
    required this.lyricsSupported,
    required this.desktopLyricsSupported,
    required this.lyricsStatus,
    required this.setFloatingLyrics,
    required this.setDesktopLyrics,
    required this.setLyricsLocked,
    required this.setLyricsLines,
  });

  final String platform;
  final bool Function() audioStatusSupported, audioDevicesSupported;
  final Map<String, Object?> Function() audioStatus, audioDevices, lyricsStatus;
  final bool lyricsSupported, desktopLyricsSupported;
  final Future<void> Function(bool) setFloatingLyrics,
      setDesktopLyrics,
      setLyricsLocked;
  final Future<void> Function(int) setLyricsLines;
  final _configuration = AudioOperationQueue(maximumPending: 1);
  bool _closed = false;

  static const _metadata = {
    'command',
    'op',
    'action',
    'operation',
    '_callerPluginId',
    '_assertDataAccess',
  };

  void close() {
    _closed = true;
    _configuration.cancelPending();
  }

  static Map<String, Object?> _error(String code, {bool supported = true}) => {
    'ok': false,
    'supported': supported,
    'error': {'code': code},
  };

  Future<Map<String, Object?>> dispatch(Map<String, dynamic> spec) async {
    final guard = spec['_assertDataAccess'];
    if (guard is! void Function()) {
      throw const PluginException('Native host access required', code: 403);
    }
    void assertAccess() {
      guard();
      if (_closed) {
        throw const PluginException('Native host is closed', code: 403);
      }
    }

    assertAccess();
    final command = spec['command'];
    if (command == 'native_capabilities') {
      return {
        'ok': true,
        'supported': true,
        'version': 1,
        'platform': platform,
        'operations': {
          'audio.status': {
            'supported': audioStatusSupported(),
            'permission': 'native_audio',
          },
          'audio.devices': {
            'supported': audioDevicesSupported(),
            'permission': 'native_audio',
          },
          'lyrics.status': {
            'supported': lyricsSupported,
            'permission': 'native_control',
          },
          'lyrics.configure': {
            'supported': lyricsSupported,
            'permission': 'native_control',
          },
        },
        'desktopLyrics': desktopLyricsSupported,
      };
    }
    if (command == 'native_audio.status' || command == 'native_audio.devices') {
      if (spec.keys.any((key) => !_metadata.contains(key))) {
        return _error('invalid_argument');
      }
      final status = command == 'native_audio.status';
      if (!(status ? audioStatusSupported() : audioDevicesSupported())) {
        return _error('unsupported_platform_or_engine', supported: false);
      }
      try {
        final data = (status ? audioStatus : audioDevices)();
        assertAccess();
        return {
          'ok': true,
          'supported': true,
          'platform': platform,
          'data': data,
        };
      } on PluginException {
        rethrow;
      } catch (_) {
        // Native error text can contain library paths or endpoint tokens.
        return _error('snapshot_unavailable');
      }
    }
    if (command == 'native_lyrics.status') {
      if (spec.keys.any((key) => !_metadata.contains(key))) {
        return _error('invalid_argument');
      }
      return lyricsSupported
          ? {'ok': true, 'supported': true, 'data': lyricsStatus()}
          : _error('unsupported_platform', supported: false);
    }
    if (command != 'native_lyrics.configure') {
      return _error('unsupported_operation', supported: false);
    }
    if (!lyricsSupported) {
      return _error('unsupported_platform', supported: false);
    }
    final mode = spec['mode'];
    final locked = spec['locked'];
    final lines = spec['lines'];
    if (spec.keys.any(
          (key) =>
              !_metadata.contains(key) &&
              !const {'mode', 'locked', 'lines'}.contains(key),
        ) ||
        (mode != null &&
            !const {'off', 'floating', 'desktop'}.contains(mode)) ||
        (locked != null && locked is! bool) ||
        (lines != null && (lines is! int || lines < 1 || lines > 5)) ||
        (mode == null && locked == null && lines == null)) {
      return _error('invalid_argument');
    }
    if (mode == 'desktop' && !desktopLyricsSupported) {
      return _error('unsupported_platform', supported: false);
    }
    return _configuration.run<Map<String, Object?>>(
      () async {
        // Waiting calls retain their own grant revision and VM epoch. Superseding
        // never completes an active call or releases its in-flight persistence.
        assertAccess();
        if (mode == 'off') {
          await setFloatingLyrics(false);
          assertAccess();
          await setDesktopLyrics(false);
        } else if (mode == 'floating') {
          await setFloatingLyrics(true);
        } else if (mode == 'desktop') {
          await setDesktopLyrics(true);
        }
        assertAccess();
        if (locked is bool) {
          await setLyricsLocked(locked);
          assertAccess();
        }
        if (lines is int) {
          await setLyricsLines(lines);
          assertAccess();
        }
        return {'ok': true, 'supported': true, 'data': lyricsStatus()};
      },
      key: 'lyrics',
      onSuperseded: () => _error('superseded'),
    );
  }
}
