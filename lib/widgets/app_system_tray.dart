// i18n:data — tray menu labels are interface keys.
// ignore_for_file: deprecated_member_use, implementation_imports

import 'dart:async';
import 'dart:io' show Directory, File, Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart' show Locale, WidgetsBinding;
import 'package:tray_manager/src/menu.dart';
import 'package:tray_manager/src/tray_listener.dart';
import 'package:tray_manager/src/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../l10n/app_language.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';

/// Whether system tray integration is active on the current platform.
/// Disabled on mobile/web and under test environments.
final bool kSupportsSystemTray =
    !kIsWeb &&
    (Platform.isWindows || Platform.isMacOS || Platform.isLinux) &&
    !Platform.environment.containsKey('FLUTTER_TEST');

/// Manages the desktop system tray icon, notification area presence, and
/// playback controls context menu.
class AppSystemTray with TrayListener {
  AppSystemTray._();

  static final AppSystemTray instance = AppSystemTray._();

  AppState? _state;
  bool _initialized = false;
  bool _updating = false;

  Future<void> initialize(AppState state) async {
    if (!kSupportsSystemTray || _initialized) return;
    _initialized = true;
    _state = state;
    TrayManager.instance.addListener(this);

    try {
      final String? iconPath = await _resolveIconPath();
      if (iconPath != null) {
        await TrayManager.instance.setIcon(iconPath);
      }
      await TrayManager.instance.setToolTip('Lazer');
    } catch (_) {}

    state.addListener(_onStateChanged);
    await _updateMenu();
  }

  void _onStateChanged() {
    unawaited(_updateMenu());
  }

  /// Path to a tray icon file the native layer can load.
  ///
  /// Source checkouts keep the Windows `.ico` next to the runner, but release
  /// bundles only ship declared assets, so fall back to writing the bundled
  /// bytes into a temporary file once.
  Future<String?> _resolveIconPath() async {
    final String asset = Platform.isWindows
        ? 'windows/runner/resources/app_icon.ico'
        : 'assets/app_icon.png';
    final File onDisk = File(asset);
    if (onDisk.existsSync()) return onDisk.absolute.path;
    try {
      final ByteData data = await rootBundle.load(asset);
      final Directory dir = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}lazer_tray',
      );
      await dir.create(recursive: true);
      final File file = File(
        '${dir.path}${Platform.pathSeparator}${asset.split('/').last}',
      );
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  Locale? _resolveLocale(AppLanguage? language) {
    if (language == null || language == AppLanguage.system) {
      return WidgetsBinding.instance.platformDispatcher.locale;
    }
    return language.locale;
  }

  Future<AppLocalizations> _getLocalizations() async {
    try {
      final locale = _resolveLocale(_state?.language);
      return await AppLocalizations.loadLocale(locale);
    } catch (_) {
      return AppLocalizations.fallback;
    }
  }

  Future<void> _updateMenu() async {
    if (!kSupportsSystemTray || !_initialized || _updating) return;
    _updating = true;
    try {
      final AppState? state = _state;
      if (state == null) return;

      final track = state.current;
      final bool isPlaying = state.playing;
      final l10n = await _getLocalizations();

      final String playPauseLabel = l10n.text(isPlaying ? '暂停' : '播放');
      final String prevLabel = l10n.text('上一首');
      final String nextLabel = l10n.text('下一首');
      final String showWindowLabel = l10n.text('显示主界面');
      final String exitAppLabel = l10n.text('退出 Lazer');
      final String noTrackLabel = l10n.text('暂未播放歌曲');

      final menu = Menu(
        items: <MenuItem>[
          MenuItem(
            key: 'track_info',
            label: track != null
                ? '${track.title} · ${track.artist}'
                : noTrackLabel,
            disabled: true,
          ),
          MenuItem.separator(),
          MenuItem(
            key: 'toggle_play',
            label: playPauseLabel,
            onClick: (_) => state.togglePlay(),
          ),
          MenuItem(
            key: 'previous',
            label: prevLabel,
            onClick: (_) => state.previous(),
          ),
          MenuItem(
            key: 'next',
            label: nextLabel,
            onClick: (_) => state.next(),
          ),
          MenuItem.separator(),
          MenuItem(
            key: 'show_window',
            label: showWindowLabel,
            onClick: (_) => unawaited(showWindow()),
          ),
          MenuItem.separator(),
          MenuItem(
            key: 'exit_app',
            label: exitAppLabel,
            onClick: (_) => unawaited(exitApp()),
          ),
        ],
      );

      await TrayManager.instance.setContextMenu(menu);
      if (track != null) {
        await TrayManager.instance.setToolTip('Lazer - ${track.title}');
      } else {
        await TrayManager.instance.setToolTip('Lazer');
      }
    } catch (_) {
    } finally {
      _updating = false;
    }
  }

  static Future<void> showWindow() async {
    try {
      final bool isVisible = await windowManager.isVisible();
      final bool isMinimized = await windowManager.isMinimized();
      if (!isVisible) {
        await windowManager.show();
      }
      if (isMinimized) {
        await windowManager.restore();
      }
      await windowManager.focus();
    } catch (_) {}
  }

  static Future<void> exitApp() async {
    try {
      if (kSupportsSystemTray) {
        await TrayManager.instance.destroy();
      }
      try {
        await windowManager.setPreventClose(false);
      } catch (_) {}
      try {
        await windowManager.close();
      } catch (_) {
        await windowManager.destroy();
      }
    } catch (_) {}
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(showWindow());
  }

  @override
  void onTrayIconMouseUp() {
    unawaited(showWindow());
  }

  @override
  void onTrayIconRightMouseDown() {}

  @override
  void onTrayIconRightMouseUp() {
    unawaited(TrayManager.instance.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final state = _state;
    if (state == null) return;
    switch (menuItem.key) {
      case 'toggle_play':
        state.togglePlay();
      case 'previous':
        state.previous();
      case 'next':
        state.next();
      case 'show_window':
        unawaited(showWindow());
      case 'exit_app':
        unawaited(exitApp());
    }
  }

  Future<void> dispose() async {
    _state?.removeListener(_onStateChanged);
    _state = null;
    if (_initialized) {
      TrayManager.instance.removeListener(this);
      try {
        await TrayManager.instance.destroy();
      } catch (_) {}
      _initialized = false;
    }
  }
}
