// i18n:data — console messages are translated by the console view.
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../plugins/lua_plugin_runtime.dart';
import '../plugins/plugin_manifest.dart';
import '../state/app_state.dart';
import 'app_log.dart';

class ConsoleEntry {
  const ConsoleEntry(this.text, {this.input = false, this.error = false});
  final String text;
  final bool input, error;
}

/// Created lazily by AppState; the Lua isolate starts only for a Lua command.
class DeveloperConsole extends ChangeNotifier {
  DeveloperConsole(this.state);
  final AppState state;
  final List<ConsoleEntry> _entries = [];
  final List<String> _history = [];
  List<ConsoleEntry> get entries => List.unmodifiable(_entries);
  List<String> get history => List.unmodifiable(_history);
  LuaPluginRuntime? _runtime;
  bool busy = false;
  bool _disposed = false;
  int _generation = 0;

  static const help = '''/help — 指令帮助
/status — 播放状态
/queue — 播放队列（最多 100 首）
/plugins — 已安装的 Lua 插件
/play /pause /next /previous /stop — 播放控制
/seek <seconds> — 跳转到指定秒数
/volume <0-100> — 设置音量
/logs [text] — 查看最近日志，可按文本筛选
/clear — 清空控制台
/reset — 重置 Lua 会话
Lua: 1 + 2 · print("hello") · x = 42 · return x''';

  void _append(String text, {bool input = false, bool error = false}) {
    if (_disposed) return;
    final safe = AppLog.redact(text);
    _entries.add(
      ConsoleEntry(
        safe.length > 32768 ? safe.substring(0, 32768) : safe,
        input: input,
        error: error,
      ),
    );
    var characters = _entries.fold<int>(0, (n, entry) => n + entry.text.length);
    while (_entries.length > 300 || characters > 128 * 1024) {
      characters -= _entries.removeAt(0).text.length;
    }
    notifyListeners();
  }

  Future<void> execute(String input) async {
    if (_disposed || !state.developerConsoleEnabled || busy) return;
    final source = input.trim();
    if (source.isEmpty) return;
    if (source.length > 16 * 1024) {
      _append('Lua 输入不能超过 16 KiB。', error: true);
      return;
    }
    final generation = _generation;
    busy = true;
    if (_history.isEmpty || _history.last != source) {
      _history.add(source);
      if (_history.length > 100) _history.removeAt(0);
    }
    _append(source, input: true);
    final clock = Stopwatch()..start();
    // Record command names, never arbitrary Lua source or arguments.
    AppLog.shared.event('console', 'execute', {
      'kind': source.startsWith('/')
          ? source.split(RegExp(r'\s+')).first
          : 'lua',
    });
    try {
      final output = source.startsWith('/')
          ? await _command(source)
          : (await (_runtime ??= _newRuntime()).evaluate(source)).join('\n');
      if (generation == _generation && state.developerConsoleEnabled) {
        if (output.isNotEmpty) _append(output);
        AppLog.shared.event('console', 'completed', {
          'elapsed_ms': clock.elapsedMilliseconds,
        });
      }
    } catch (error) {
      if (generation == _generation && state.developerConsoleEnabled) {
        _append('$error', error: true);
        AppLog.shared.event('console', 'failed', {
          'elapsed_ms': clock.elapsedMilliseconds,
        });
        // Discard a failed VM so a timeout or a damaged stack cannot poison
        // subsequent commands. The transcript remains available for inspection.
        _runtime?.close();
        _runtime = null;
      }
    } finally {
      if (!_disposed && generation == _generation) {
        busy = false;
        notifyListeners();
      }
    }
  }

  LuaPluginRuntime _newRuntime() => LuaPluginRuntime(
    manifest: PluginManifest.fromJson({
      'id': 'lazer.console',
      'name': 'Developer Console',
      'version': '1.0.0',
      'apiVersion': 1,
      'provider': 'console',
    }),
    sources: const {
      'main.lua': 'host = nil; coroutine = nil; return {call=function() end}',
    },
    dataDirectory: '',
    timeout: const Duration(seconds: 3),
  );

  Future<String> _command(String source) async {
    final parts = source.split(RegExp(r'\s+'));
    final name = parts.first.toLowerCase();
    final numeric = name == '/seek' || name == '/volume';
    if (name != '/logs' && parts.length != (numeric ? 2 : 1)) {
      throw ArgumentError('指令参数无效，请输入 /help。');
    }
    switch (name) {
      case '/help':
        return help;
      case '/status':
        return const JsonEncoder.withIndent('  ').convert({
          'provider': state.musicProvider.id,
          'engine': state.audioEngine?.runtimeType.toString() ?? 'none',
          'playing': state.playing,
          'ready': state.audioReady,
          'track': state.current?.title,
          'track_id': state.current?.id,
          'position_seconds': state.precisePosition.inMilliseconds / 1000,
          'volume': (state.volume * 100).round(),
          'queue_length': state.queueLength,
          'queue_index': state.queueIndex,
          'error': state.playbackError,
        });
      case '/queue':
        return state.queue.isEmpty
            ? '播放队列为空。'
            : [
                for (var i = 0; i < state.queue.length && i < 100; i++)
                  '${i == state.queueIndex ? ">" : " "} ${i + 1}. ${state.queue[i].title} (${state.queue[i].id})',
              ].join('\n');
      case '/plugins':
        return state.pluginManager.plugins.isEmpty
            ? '尚未安装插件。'
            : [
                for (final plugin in state.pluginManager.plugins)
                  '${plugin.manifest.id} ${plugin.manifest.version} enabled=${plugin.enabled} running=${plugin.runtime != null}${plugin.error == null ? "" : " error=${plugin.error}"}',
              ].join('\n');
      case '/play':
        state.play();
      case '/pause':
        state.pause();
      case '/next':
        state.next();
      case '/previous':
        state.previous();
      case '/stop':
        state.stop();
      case '/seek':
        final seconds = double.tryParse(parts[1]);
        if (seconds == null ||
            !seconds.isFinite ||
            seconds < 0 ||
            seconds > 2147483) {
          throw ArgumentError('用法：/seek <seconds>（非负秒数）');
        }
        await state.seekTo(Duration(milliseconds: (seconds * 1000).round()));
      case '/volume':
        final percent = double.tryParse(parts[1]);
        if (percent == null ||
            !percent.isFinite ||
            percent < 0 ||
            percent > 100) {
          throw ArgumentError('用法：/volume <0-100>');
        }
        await state.setVolume(percent / 100);
      case '/logs':
        final filter = parts.skip(1).join(' ').toLowerCase();
        final lines = AppLog.shared
            .snapshot()
            .split('\n')
            .where((line) => line.toLowerCase().contains(filter))
            .toList();
        return lines
            .skip(lines.length > 100 ? lines.length - 100 : 0)
            .join('\n');
      case '/clear':
        _entries.clear();
        return '';
      case '/reset':
        _runtime?.close();
        _runtime = null;
        return 'Lua 会话已重置。';
      default:
        throw ArgumentError('未知指令，请输入 /help。');
    }
    return '指令已执行。';
  }

  /// Invalidates pending output and releases the VM immediately on disable.
  void disable() {
    _generation++;
    _runtime?.close();
    _runtime = null;
    busy = false;
    _history.clear();
    _entries.clear();
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    disable();
    super.dispose();
  }
}
