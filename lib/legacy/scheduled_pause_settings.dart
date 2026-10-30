import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../state/scheduled_pause.dart';
import '../widgets/apple_ui.dart';
import '../widgets/settings_detail.dart';

class ScheduledPauseSettingsPage extends StatelessWidget {
  const ScheduledPauseSettingsPage({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state,
    builder: (context, _) => SettingsDetailScaffold(
      title: '定时关闭',
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              AppleGroupedCard(
                child: AppleListTile(
                  title: context.tr('启用定时关闭'),
                  subtitle: context.tr(
                    state.scheduledPauseActive ? '当前处于暂停时段' : '到达指定时段后自动暂停播放',
                  ),
                  trailing: Switch(
                    key: const ValueKey('scheduled-pause-enabled'),
                    value: state.scheduledPause.enabled,
                    onChanged: (value) => unawaited(
                      state.setScheduledPause(
                        state.scheduledPause.copyWith(enabled: value),
                      ),
                    ),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: TrText('每日重复，按本地时间执行。时段内保持暂停，结束后不会自动播放。'),
              ),
              if (state.scheduledPause.windows.isEmpty)
                const AppleEmptyState(
                  message: '还没有暂停时段',
                  icon: Icons.bedtime_outlined,
                ),
              for (final window in state.scheduledPause.windows)
                AppleGroupedCard(
                  key: ValueKey('pause-window-${window.id}'),
                  child: Column(
                    children: [
                      AppleListTile(
                        title:
                            '${_time(window.startMinute)} - ${_time(window.endMinute)}',
                        subtitle: context.tr(
                          window.endMinute < window.startMinute
                              ? '每天 · 跨午夜'
                              : '每天',
                        ),
                        onTap: () => unawaited(_edit(context, window)),
                        trailing: Switch(
                          key: ValueKey('pause-window-enabled-${window.id}'),
                          value: window.enabled,
                          onChanged: (value) =>
                              unawaited(_save(window.copyWith(enabled: value))),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: () =>
                                  unawaited(_edit(context, window)),
                              child: const TrText('编辑'),
                            ),
                            TextButton(
                              key: ValueKey('pause-window-delete-${window.id}'),
                              onPressed: () => unawaited(
                                state.setScheduledPause(
                                  state.scheduledPause.copyWith(
                                    windows: state.scheduledPause.windows
                                        .where((item) => item.id != window.id)
                                        .toList(),
                                  ),
                                ),
                              ),
                              child: const TrText('删除'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  key: const ValueKey('add-pause-window'),
                  onPressed: () => unawaited(_edit(context, null)),
                  icon: const Icon(Icons.add_rounded),
                  label: const TrText('添加暂停时段'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Future<void> _save(PauseWindow window) => state.setScheduledPause(
    state.scheduledPause.copyWith(
      windows: [
        for (final item in state.scheduledPause.windows)
          item.id == window.id ? window : item,
      ],
    ),
  );

  Future<void> _edit(BuildContext context, PauseWindow? current) async {
    final result = await showDialog<PauseWindow>(
      context: context,
      builder: (_) => _PauseWindowDialog(window: current),
    );
    if (result == null) return;
    if (current != null) {
      await _save(result);
    } else {
      await state.setScheduledPause(
        state.scheduledPause.copyWith(
          windows: [...state.scheduledPause.windows, result],
        ),
      );
    }
  }
}

String _time(int minute) =>
    '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';

class _PauseWindowDialog extends StatefulWidget {
  const _PauseWindowDialog({this.window});
  final PauseWindow? window;
  @override
  State<_PauseWindowDialog> createState() => _PauseWindowDialogState();
}

class _PauseWindowDialogState extends State<_PauseWindowDialog> {
  late final _start = TextEditingController(
    text: _time(widget.window?.startMinute ?? 23 * 60),
  );
  late final _end = TextEditingController(
    text: _time(widget.window?.endMinute ?? 7 * 60),
  );
  final _form = GlobalKey<FormState>();

  int? _parse(String? text) {
    final match = RegExp(
      r'^([01]?\d|2[0-3]):([0-5]\d)$',
    ).firstMatch(text?.trim() ?? '');
    return match == null
        ? null
        : int.parse(match[1]!) * 60 + int.parse(match[2]!);
  }

  @override
  void dispose() {
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: TrText(widget.window == null ? '添加暂停时段' : '编辑暂停时段'),
    content: SizedBox(
      width: 360,
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (controller, label, key) in [
              (_start, '开始时间', 'pause-window-start'),
              (_end, '结束时间', 'pause-window-end'),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TextFormField(
                  key: ValueKey(key),
                  controller: controller,
                  keyboardType: TextInputType.datetime,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9:]')),
                    LengthLimitingTextInputFormatter(5),
                  ],
                  decoration: InputDecoration(
                    labelText: context.tr(label),
                    hintText: 'HH:mm',
                  ),
                  validator: (value) {
                    final minute = _parse(value);
                    if (minute == null) {
                      return context.tr('请输入有效的24小时制时间，例如23:30');
                    }
                    if (controller == _end && minute == _parse(_start.text)) {
                      return context.tr('开始时间和结束时间不能相同');
                    }
                    return null;
                  },
                ),
              ),
            const TrText('结束时间早于开始时间时，时段会延续到次日。'),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const TrText('取消'),
      ),
      FilledButton(
        key: const ValueKey('save-pause-window'),
        onPressed: () {
          if (!_form.currentState!.validate()) return;
          Navigator.pop(
            context,
            PauseWindow(
              id:
                  widget.window?.id ??
                  DateTime.now().microsecondsSinceEpoch.toString(),
              startMinute: _parse(_start.text)!,
              endMinute: _parse(_end.text)!,
              enabled: widget.window?.enabled ?? true,
            ),
          );
        },
        child: const TrText('保存'),
      ),
    ],
  );
}
