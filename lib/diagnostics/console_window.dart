import 'dart:async';
import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:window_manager/window_manager.dart';

import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../theme/apple_design.dart';
import '../theme/font_preferences.dart';
import '../theme/imported_font.dart';
import '../ui/developer_console_page.dart';
import 'app_log.dart';
import 'console_session.dart';
import 'developer_console.dart';

const _hostChannel = WindowMethodChannel(
  'lazer/console/host',
  mode: ChannelMode.unidirectional,
);

bool get supportsConsoleWindow =>
    !kIsWeb &&
    {
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    }.contains(defaultTargetPlatform);

/// Only the main engine owns AppState and the Lua VM. The window is a client.
class ConsoleWindowController {
  ConsoleWindowController(this.state) {
    instance = this;
    _session = LocalConsoleSession(state)..addListener(_changed);
  }
  static ConsoleWindowController? instance;
  final AppState state;
  late final LocalConsoleSession _session;
  int _revision = 0;
  WindowController? _window;
  Future<void>? _opening;
  bool _disposed = false;

  void _changed() => _revision++;

  Future<void> open() =>
      _opening ??= _open().whenComplete(() => _opening = null);

  Future<void> _open() async {
    if (_disposed || !state.developerConsoleEnabled) return;
    await _hostChannel.setMethodCallHandler(_handle);
    final existing = _window;
    if (existing != null) {
      try {
        await _windowChannel(existing.windowId).invokeMethod<void>('show');
        return;
      } on WindowChannelException {
        _window = null;
      }
    }
    _window = await WindowController.create(
      WindowConfiguration(
        arguments: jsonEncode({'kind': 'developer_console'}),
        hiddenAtLaunch: true,
      ),
    );
    AppLog.shared.event('console', 'window_opened');
  }

  Future<dynamic> _handle(MethodCall call) async {
    if (_disposed) return null;
    if (call.method == 'snapshot') {
      if (call.arguments == _revision) return null;
      return {
        'revision': _revision,
        'enabled': _session.enabled,
        'busy': _session.busy,
        'entries': [
          for (final entry in _session.entries)
            {'text': entry.text, 'input': entry.input, 'error': entry.error},
        ],
        'history': _session.history,
        'logs': _session.logs,
        'theme': state.themeMode.name,
        'accent': state.accentSeed?.toARGB32(),
        'fonts': state.fontPreferences.encode(),
        'locale': state.language.locale?.toLanguageTag(),
      };
    }
    // Recheck the setting in the owner engine for every command.
    if (!_session.enabled) return null;
    switch (call.method) {
      case 'execute':
        if (call.arguments is String) {
          await _session.execute(call.arguments as String);
        }
      case 'clearLogs':
        await _session.clearLogs();
      case 'report':
        return _session.report();
    }
    _revision++;
    return null;
  }

  void dispose() {
    _disposed = true;
    if (instance == this) instance = null;
    _session.dispose();
    if (supportsConsoleWindow) {
      unawaited(_hostChannel.setMethodCallHandler(null));
      final window = _window;
      if (window != null) {
        unawaited(
          _windowChannel(
            window.windowId,
          ).invokeMethod<void>('close').catchError((Object _) {}),
        );
      }
    }
  }
}

WindowMethodChannel _windowChannel(String id) => WindowMethodChannel(
  'lazer/console/window/$id',
  mode: ChannelMode.unidirectional,
);

bool isConsoleWindow(List<String> args) {
  if (args.length < 3 || args.first != 'multi_window') return false;
  try {
    final data = jsonDecode(args[2]);
    return data is Map && data['kind'] == 'developer_console';
  } on FormatException {
    return false;
  }
}

Future<void> runConsoleWindow(String id) async {
  await windowManager.ensureInitialized();
  await _windowChannel(id).setMethodCallHandler((call) async {
    if (call.method == 'close') await windowManager.close();
    if (call.method == 'show') {
      await windowManager.show();
      await windowManager.focus();
    }
    return null;
  });
  runApp(const _ConsoleWindowApp());
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      title: 'Lazer · Lua 开发者控制台',
      size: Size(1000, 700),
      minimumSize: Size(480, 360),
      center: true,
    ),
  );
  await windowManager.show();
  await windowManager.focus();
}

class RemoteConsoleSession extends ConsoleSession {
  Timer? _timer;
  bool _polling = false, _disposed = false;
  int _revision = -1;
  Map<dynamic, dynamic> _snapshot = {};
  ThemeMode get themeMode => ThemeMode.values.firstWhere(
    (mode) => mode.name == _snapshot['theme'],
    orElse: () => ThemeMode.system,
  );
  Color? get accent =>
      _snapshot['accent'] is int ? Color(_snapshot['accent'] as int) : null;
  FontPreferences get fonts =>
      FontPreferences.decode(_snapshot['fonts'] as String?);
  Locale? get locale {
    final tag = _snapshot['locale'] as String?;
    if (tag == null) return null;
    final parts = tag.split('-');
    return Locale.fromSubtags(
      languageCode: parts.first,
      scriptCode: parts.skip(1).where((part) => part.length == 4).firstOrNull,
      countryCode: parts
          .skip(1)
          .where((part) => part.length == 2 || part.length == 3)
          .firstOrNull,
    );
  }

  @override
  bool get enabled => _snapshot['enabled'] == true;
  @override
  bool get busy => _snapshot['busy'] == true || _executing;
  bool _executing = false;
  @override
  List<ConsoleEntry> entries = [];
  @override
  List<String> history = [];
  @override
  String get logs => _snapshot['logs'] as String? ?? '';

  void start() {
    unawaited(refresh());
    _timer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => unawaited(refresh()),
    );
  }

  Future<void> refresh() async {
    if (_disposed || _polling) return;
    _polling = true;
    try {
      final data = await _hostChannel.invokeMethod<dynamic>(
        'snapshot',
        _revision,
      );
      if (_disposed || data is! Map) return;
      final previousFont = _snapshot['fonts'];
      _snapshot = data;
      if (previousFont != data['fonts']) {
        try {
          await ImportedFont.load(fonts.family);
        } catch (error) {
          AppLog.shared.record('console font: $error');
        }
        if (_disposed) return;
      }
      _revision = data['revision'] as int;
      entries = [
        for (final entry in data['entries'] as List)
          ConsoleEntry(
            entry['text'] as String,
            input: entry['input'] == true,
            error: entry['error'] == true,
          ),
      ];
      history = List<String>.from(data['history'] as List);
      notifyListeners();
    } on WindowChannelException {
      if (!_disposed) {
        _snapshot = {..._snapshot, 'enabled': false};
        notifyListeners();
      }
    } finally {
      _polling = false;
    }
  }

  @override
  Future<void> execute(String input) async {
    if (!enabled || busy) return;
    _executing = true;
    notifyListeners();
    try {
      await _hostChannel.invokeMethod<void>('execute', input);
    } on WindowChannelException {
      _snapshot = {..._snapshot, 'enabled': false};
    } finally {
      _executing = false;
      if (!_disposed) {
        notifyListeners();
        await refresh();
      }
    }
  }

  @override
  Future<void> clearLogs() async {
    await _hostChannel.invokeMethod<void>('clearLogs');
    await refresh();
  }

  @override
  Future<String> report() async =>
      await _hostChannel.invokeMethod<String>('report') ?? logs;
  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

class _ConsoleWindowApp extends StatefulWidget {
  const _ConsoleWindowApp();
  @override
  State<_ConsoleWindowApp> createState() => _ConsoleWindowAppState();
}

class _ConsoleWindowAppState extends State<_ConsoleWindowApp> {
  final _session = RemoteConsoleSession();
  @override
  void initState() {
    super.initState();
    _session.start();
  }

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _session,
    child: DeveloperConsoleView.remote(session: _session),
    builder: (context, child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppleTheme(
        seedAccent: _session.accent,
        fonts: _session.fonts,
      ),
      darkTheme: buildAppleTheme(
        brightness: Brightness.dark,
        seedAccent: _session.accent,
        fonts: _session.fonts,
      ),
      themeMode: _session.themeMode,
      locale: _session.locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: child,
    ),
  );
}
