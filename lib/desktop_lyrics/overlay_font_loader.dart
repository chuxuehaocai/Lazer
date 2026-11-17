import 'dart:io';
import 'package:flutter/services.dart';

import 'overlay_protocol.dart';

const int kOverlayMaximumFontBytes = 64 * 1024 * 1024;

/// Registers a custom family once per overlay engine and shares in-flight I/O.
class OverlayFontLoader {
  OverlayFontLoader({Future<void> Function(String, ByteData)? register})
    : _register = register ?? _registerFont;
  static final shared = OverlayFontLoader();
  final Map<(String, String), Future<void>> _loads = {};
  final Future<void> Function(String, ByteData) _register;
  int _reservedBytes = 0;

  Future<void> load(String family, String path) {
    final key = (family, path);
    final existing = _loads[key];
    if (existing != null) return existing;
    if (_loads.length >= kOverlayCustomFontLimit) {
      return Future<void>.error(
        StateError('Overlay custom font session limit reached'),
      );
    }
    return _loads.putIfAbsent(key, () async {
      var reserved = 0;
      try {
        final file = File(path);
        final length = await file.length();
        if (length > kOverlayMaximumFontBytes) {
          throw StateError('Overlay font exceeds 64 MiB limit');
        }
        if (_reservedBytes + length > kOverlayMaximumFontBytes) {
          throw StateError('Overlay custom font byte budget reached');
        }
        _reservedBytes += length;
        reserved = length;
        final handle = await file.open();
        final bytes = await (() async {
          try {
            final buffer = Uint8List(length);
            var offset = 0;
            while (offset < length) {
              final count = await handle.readInto(buffer, offset, length);
              if (count == 0) break;
              offset += count;
            }
            return Uint8List.sublistView(buffer, 0, offset);
          } finally {
            await handle.close();
          }
        })();
        if (bytes.length > kOverlayMaximumFontBytes) {
          throw StateError('Overlay font exceeds 64 MiB limit');
        }
        await _register(family, ByteData.sublistView(bytes));
      } catch (_) {
        // Failed registrations can be retried after the file becomes available.
        _loads.remove(key);
        _reservedBytes -= reserved;
        rethrow;
      }
    });
  }

  static Future<void> _registerFont(String family, ByteData bytes) async {
    final loader = FontLoader(family)..addFont(Future.value(bytes));
    await loader.load();
  }
}
