import '../widgets/spring_buttons.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import '../animation/apple_modal.dart';
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
                  title: context.tr('启用定时停止'),
                  subtitle: context.tr('到达指定时间点后自动暂停播放'),
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
                child: TrText('每日重复，按本地时间到点暂停当前播放。暂停后由你手动继续。'),
              ),
              if (state.scheduledPause.points.isEmpty)
                const AppleEmptyState(
                  message: '还没有暂停时间点',
                  icon: Icons.bedtime_outlined,
                ),
              for (final point in state.scheduledPause.points)
                AppleGroupedCard(
                  key: ValueKey('pause-point-${point.id}'),
                  child: Column(
                    children: [
                      AppleListTile(
                        title: _time(point.minute),
                        subtitle: context.tr('每天 · 到点暂停'),
                        onTap: () => unawaited(_edit(context, point)),
                        trailing: Switch(
                          key: ValueKey('pause-point-enabled-${point.id}'),
                          value: point.enabled,
                          onChanged: (value) =>
                              unawaited(_save(point.copyWith(enabled: value))),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            SpringTextButton(
                              onPressed: () => unawaited(_edit(context, point)),
                              child: const TrText('编辑'),
                            ),
                            SpringTextButton(
                              key: ValueKey('pause-point-delete-${point.id}'),
                              onPressed: () => unawaited(
                                state.setScheduledPause(
                                  state.scheduledPause.copyWith(
                                    points: state.scheduledPause.points
                                        .where((item) => item.id != point.id)
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
                child: SpringFilledButton.icon(
                  key: const ValueKey('add-pause-point'),
                  onPressed: () => unawaited(_edit(context, null)),
                  icon: const Icon(Icons.add_rounded),
                  label: const TrText('添加暂停时间点'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Future<void> _save(PausePoint point) => state.setScheduledPause(
    state.scheduledPause.copyWith(
      points: [
        for (final item in state.scheduledPause.points)
          item.id == point.id ? point : item,
      ],
    ),
  );

  Future<void> _edit(BuildContext context, PausePoint? current) async {
    final result = await showAppleDialog<PausePoint>(
      context: context,
      builder: (_) => _PausePointDialog(point: current),
    );
    if (result == null) return;
    if (current != null) {
      await _save(result);
    } else {
      await state.setScheduledPause(
        state.scheduledPause.copyWith(
          points: [...state.scheduledPause.points, result],
        ),
      );
    }
  }
}

String _time(int minute) =>
    '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';

class _PausePointDialog extends StatefulWidget {
  const _PausePointDialog({this.point});
  final PausePoint? point;
  @override
  State<_PausePointDialog> createState() => _PausePointDialogState();
}

class _PausePointDialogState extends State<_PausePointDialog> {
  late final _at = TextEditingController(
    text: _time(widget.point?.minute ?? 23 * 60),
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
    _at.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: TrText(widget.point == null ? '添加暂停时间点' : '编辑暂停时间点'),
    content: SizedBox(
      width: 360,
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TextFormField(
                key: const ValueKey('pause-point-time'),
                controller: _at,
                keyboardType: TextInputType.datetime,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9:]')),
                  LengthLimitingTextInputFormatter(5),
                ],
                decoration: InputDecoration(
                  labelText: context.tr('暂停时间'),
                  hintText: 'HH:mm',
                ),
                validator: (value) => _parse(value) == null
                    ? context.tr('请输入有效的24小时制时间，例如23:30')
                    : null,
              ),
            ),
            const TrText('每天到达该时间后暂停当前歌曲，之后由你手动继续。'),
          ],
        ),
      ),
    ),
    actions: [
      SpringTextButton(
        onPressed: () => Navigator.pop(context),
        child: const TrText('取消'),
      ),
      SpringFilledButton(
        key: const ValueKey('save-pause-point'),
        onPressed: () {
          if (!_form.currentState!.validate()) return;
          Navigator.pop(
            context,
            PausePoint(
              id:
                  widget.point?.id ??
                  DateTime.now().microsecondsSinceEpoch.toString(),
              minute: _parse(_at.text)!,
              enabled: widget.point?.enabled ?? true,
            ),
          );
        },
        child: const TrText('保存'),
      ),
    ],
  );
}
