// i18n:data — tray menu labels are interface keys.
// ignore_for_file: deprecated_member_use, implementation_imports

import 'dart:async';
import 'dart:io' show Directory, File, Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart' show Locale, WidgetsBinding;
import 'package:tray_manager/src/menu.dart';
import 'package:tray_manager/src/tray_listener.dart';
import 'package:tray_manager/src/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../data/models.dart';
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
  bool _menuStale = false;
  Object? _menuSignature;

  @visibleForTesting
  static Object menuSignature(AppState state) {
    final track = state.current;
    return (track?.title, track?.artist, state.playing, state.language);
  }

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
    _menuSignature = menuSignature(state);
    await _updateMenu();
  }

  void _onStateChanged() {
    final AppState? state = _state;
    if (state == null) return;
    final Object signature = menuSignature(state);
    if (signature == _menuSignature) return;
    _menuSignature = signature;
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

  /// 托盘右键菜单。
  ///
  /// 每一项的动作只挂在 `key` 上，**不带 `onClick`**：tray_manager 的
  /// `_onMenuItemClicked` 先调 `menuItem.onClick`，再遍历所有 `TrayListener`
  /// 调 `onTrayMenuItemClick`。两处都接的话一次点击会执行两遍 —— 菜单里的
  /// 「暂停」于是先 `pause()` 再 `play()`，歌曲接着放；「下一首」一口气跳两首。
  /// 这就是「右键菜单里按暂停，歌不会停」的原因。
  ///
  /// 派发点只有 [onTrayMenuItemClick] 一处，见
  /// `test/app_system_tray_signature_test.dart` 里的不变式用例。
  @visibleForTesting
  static Menu buildContextMenu({
    required String playPauseLabel,
    required String previousLabel,
    required String nextLabel,
    required String showWindowLabel,
    required String exitAppLabel,
    required String trackLabel,
  }) => Menu(
    items: <MenuItem>[
      MenuItem(key: 'track_info', label: trackLabel, disabled: true),
      MenuItem.separator(),
      MenuItem(key: 'toggle_play', label: playPauseLabel),
      MenuItem(key: 'previous', label: previousLabel),
      MenuItem(key: 'next', label: nextLabel),
      MenuItem.separator(),
      MenuItem(key: 'show_window', label: showWindowLabel),
      MenuItem.separator(),
      MenuItem(key: 'exit_app', label: exitAppLabel),
    ],
  );

  Future<void> _updateMenu() async {
    if (!kSupportsSystemTray || !_initialized) return;
    if (_updating) {
      _menuStale = true;
      return;
    }
    _updating = true;
    try {
      final AppState? state = _state;
      if (state == null) return;

      final Track? track = state.current;
      final bool isPlaying = state.playing;
      final AppLocalizations l10n = await _getLocalizations();

      final Menu menu = buildContextMenu(
        playPauseLabel: l10n.text(isPlaying ? '暂停' : '播放'),
        previousLabel: l10n.text('上一首'),
        nextLabel: l10n.text('下一首'),
        showWindowLabel: l10n.text('显示主界面'),
        exitAppLabel: l10n.text('退出 Lazer'),
        trackLabel: track != null
            ? '${track.title} · ${track.artist}'
            : l10n.text('暂未播放歌曲'),
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
      if (_menuStale) {
        _menuStale = false;
        unawaited(_updateMenu());
      }
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

  /// 真正关窗口之前要先做完的事（现在用来先收掉悬浮歌词那个子窗口）。
  ///
  /// 主窗口先没的话，desktop_multi_window 的子引擎会被一起拽掉，
  /// 那时它还在跑 ticker / 收发 channel，Windows 上就是一次 access violation
  /// 弹窗（「指令引用了 … 内存」）。所以退出顺序是：先关子窗口，再关自己。
  static Future<void> Function()? beforeExit;

  static Future<void> exitApp() async {
    try {
      await beforeExit?.call().timeout(const Duration(seconds: 3));
    } catch (_) {}
    try {
      await instance._state?.flushPersistence().timeout(
        const Duration(seconds: 2),
      );
    } catch (_) {}
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

  /// Runs one tray menu click.
  ///
  /// The single dispatch point: see [buildContextMenu] for why the items carry
  /// no `onClick` of their own. Keeping the mapping here also makes 「菜单里的
  /// 暂停真的暂停」a plain unit test instead of a manual tray exercise.
  @visibleForTesting
  static bool dispatchMenuKey(AppState state, String? key) {
    switch (key) {
      case 'toggle_play':
        state.togglePlay();
        return true;
      case 'previous':
        state.previous();
        return true;
      case 'next':
        state.next();
        return true;
      case 'show_window':
        unawaited(showWindow());
        return true;
      case 'exit_app':
        unawaited(exitApp());
        return true;
    }
    return false;
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final state = _state;
    if (state == null) return;
    dispatchMenuKey(state, menuItem.key);
  }

  Future<void> dispose() async {
    _state?.removeListener(_onStateChanged);
    _state = null;
    _menuSignature = null;
    _menuStale = false;
    if (_initialized) {
      TrayManager.instance.removeListener(this);
      try {
        await TrayManager.instance.destroy();
      } catch (_) {}
      _initialized = false;
    }
  }
}
