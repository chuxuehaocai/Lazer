import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../diagnostics/app_log.dart';
import '../diagnostics/console_session.dart';
import '../widgets/spring_buttons.dart';
import '../widgets/accessible_controls.dart';
import '../theme/apple_design.dart';
import '../diagnostics/export_logs.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../widgets/build_safe_state.dart';
import '../widgets/settings_detail.dart';

class DeveloperConsolePage extends StatelessWidget {
  const DeveloperConsolePage({super.key, required this.state});
  final AppState state;
  @override
  Widget build(BuildContext context) => DeveloperConsoleView(state: state);
}

class DeveloperConsoleView extends StatefulWidget {
  const DeveloperConsoleView({super.key, required this.state}) : session = null;
  const DeveloperConsoleView.remote({super.key, required this.session})
    : state = null;
  final AppState? state;
  final ConsoleSession? session;
  @override
  State<DeveloperConsoleView> createState() => _DeveloperConsoleViewState();
}

class _DeveloperConsoleViewState extends State<DeveloperConsoleView>
    with BuildSafeState<DeveloperConsoleView> {
  final _input = TextEditingController();
  final _filter = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  late final ConsoleSession _console =
      widget.session ?? LocalConsoleSession(widget.state!);
  int _historyIndex = 0;
  String _draft = '';
  bool _showLogs = false;

  @override
  void initState() {
    super.initState();
    _console.addListener(_changed);
    _filter.addListener(_changed);
    _historyIndex = _console.history.length;
  }

  void _changed() {
    if (!mounted) return;
    final follow =
        !_scroll.hasClients ||
        _scroll.position.maxScrollExtent - _scroll.offset < 60;
    setState(() {});
    if (follow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  Future<void> _run([String? command]) async {
    if (_console.busy || !_console.enabled) return;
    final text = command ?? _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    _draft = '';
    await _console.execute(text);
    if (!mounted) return;
    _historyIndex = _console.history.length;
    _focus.requestFocus();
  }

  Future<void> _export() async {
    final report = await _console.report();
    if (mounted) await exportLogText(context, report);
  }

  void _history(int direction) {
    final history = _console.history;
    if (history.isEmpty) return;
    if (_historyIndex == history.length) _draft = _input.text;
    _historyIndex = (_historyIndex + direction).clamp(0, history.length);
    _input.text = _historyIndex == history.length
        ? _draft
        : history[_historyIndex];
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
  }

  @override
  void dispose() {
    _console.removeListener(_changed);
    if (widget.session == null) _console.dispose();
    _input.dispose();
    _filter.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _console.enabled;
    final mono = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace');
    final filter = _filter.text.toLowerCase();
    final logLines = _showLogs
        ? _console.logs
              .split('\n')
              .where((line) => line.toLowerCase().contains(filter))
              .toList()
        : const <String>[];
    final entries = _console.entries;
    return SettingsDetailScaffold(
      title: 'Lua 开发者控制台',
      child: !enabled
          ? Center(child: Text(context.tr('开发者控制台已关闭。请在设置中启用。')))
          : SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.all(
                  SettingsDetailHost.isEmbedded(context) ? 32 : 20,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        ChoiceChip(
                          label: Text(context.tr('控制台')),
                          selected: !_showLogs,
                          onSelected: (_) => setState(() => _showLogs = false),
                        ),
                        ChoiceChip(
                          label: Text(context.tr('实时日志')),
                          selected: _showLogs,
                          onSelected: (_) => setState(() => _showLogs = true),
                        ),
                        SpringTextButton(
                          onPressed: _console.busy
                              ? null
                              : () => unawaited(_run('/help')),
                          child: Text(context.tr('指令帮助')),
                        ),
                        AccessibleIconButton(
                          tooltip: context.tr('复制'),
                          icon: const Icon(Icons.copy_rounded),
                          onPressed: () => Clipboard.setData(
                            ClipboardData(
                              text: AppLog.redact(
                                _showLogs
                                    ? logLines.join('\n')
                                    : entries
                                          .map(
                                            (entry) =>
                                                '${entry.input ? "> " : ""}${context.tr(entry.text)}',
                                          )
                                          .join('\n'),
                              ),
                            ),
                          ),
                        ),
                        SpringTextButton(
                          onPressed: () => unawaited(_export()),
                          child: Text(context.tr('导出日志')),
                        ),
                        AccessibleIconButton(
                          tooltip: context.tr('清空'),
                          icon: const Icon(Icons.delete_sweep_outlined),
                          onPressed: _console.busy
                              ? null
                              : () {
                                  if (_showLogs) {
                                    unawaited(_console.clearLogs());
                                  } else {
                                    unawaited(_run('/clear'));
                                  }
                                },
                        ),
                      ],
                    ),
                    if (_showLogs)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: TextField(
                          controller: _filter,
                          decoration: InputDecoration(
                            labelText: context.tr('筛选日志'),
                            prefixIcon: const Icon(Icons.search_rounded),
                          ),
                        ),
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          context.tr(
                            '输入 Lua 或 /help；Enter 执行，Shift+Enter 换行，↑↓ 浏览历史。',
                          ),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    Expanded(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: AppleSemanticColors.of(
                            context,
                          ).secondaryGroupedBackground,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Theme.of(context).dividerColor,
                          ),
                        ),
                        child: entries.isEmpty && !_showLogs
                            ? Center(
                                child: Text(
                                  context.tr('输入 /help 查看指令，或尝试 1 + 2。'),
                                ),
                              )
                            : ListView.builder(
                                controller: _scroll,
                                padding: const EdgeInsets.all(12),
                                itemCount: _showLogs
                                    ? logLines.length
                                    : entries.length,
                                itemBuilder: (context, index) {
                                  final entry = _showLogs
                                      ? null
                                      : entries[index];
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: SelectableText(
                                      _showLogs
                                          ? logLines[index]
                                          : '${entry!.input ? "> " : ""}${context.tr(entry.text)}',
                                      style: mono?.copyWith(
                                        color: entry?.error == true
                                            ? Theme.of(
                                                context,
                                              ).colorScheme.error
                                            : entry?.input == true
                                            ? Theme.of(
                                                context,
                                              ).colorScheme.primary
                                            : null,
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                    ),
                    if (!_showLogs) ...[
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: CallbackShortcuts(
                              bindings: {
                                const SingleActivator(
                                  LogicalKeyboardKey.enter,
                                ): () =>
                                    unawaited(_run()),
                                const SingleActivator(
                                  LogicalKeyboardKey.arrowUp,
                                ): () =>
                                    _history(-1),
                                const SingleActivator(
                                  LogicalKeyboardKey.arrowDown,
                                ): () =>
                                    _history(1),
                              },
                              child: TextField(
                                key: const ValueKey('developer-console-input'),
                                controller: _input,
                                focusNode: _focus,
                                enabled: !_console.busy,
                                minLines: 1,
                                maxLines: 4,
                                style: mono,
                                decoration: InputDecoration(
                                  hintText: context.tr('输入 Lua 或指令'),
                                  border: const OutlineInputBorder(),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton.filled(
                            key: const ValueKey('developer-console-run'),
                            tooltip: context.tr('执行'),
                            onPressed: _console.busy
                                ? null
                                : () => unawaited(_run()),
                            icon: _console.busy
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.play_arrow_rounded),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
    );
  }
}
