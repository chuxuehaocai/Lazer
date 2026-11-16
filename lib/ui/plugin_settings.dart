import 'dart:async';

import 'package:flutter/material.dart';

import '../animation/apple_modal.dart';
import '../l10n/app_localizations.dart';
import '../plugins/plugin_extensions.dart';
import '../state/app_state.dart';
import '../theme/apple_design.dart';
import '../widgets/settings_choice.dart';
import '../widgets/settings_row.dart';
import '../widgets/spring_buttons.dart';
import '../widgets/apple_ui.dart';

/// Renders the bounded settings controls registered by enabled Lua plugins.
///
/// Lua supplies data only; this widget owns the Flutter controls and routes
/// changes back through [PluginManager], so a plugin cannot construct widgets
/// or reach application state directly.
class LuaPluginSettingsSection extends StatelessWidget {
  const LuaPluginSettingsSection({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final settings = state.pluginManager.pluginSettings;
    if (settings.isEmpty) return const SizedBox.shrink();
    final grouped = <String, List<LuaPluginSetting>>{};
    for (final setting in settings) {
      grouped
          .putIfAbsent(setting.pluginId, () => <LuaPluginSetting>[])
          .add(setting);
    }
    final apple = AppleSemanticColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 22, 12, 7),
          child: Text(
            context.tr('插件设置'),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: apple.secondaryLabel,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        for (final group in grouped.values) ...<Widget>[
          AppleGroupedCard(
            margin: EdgeInsets.zero,
            child: Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.extension_rounded, color: apple.accent),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          group.first.pluginName,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
                for (final setting in group)
                  _LuaPluginSettingRow(state: state, setting: setting),
              ],
            ),
          ),
          if (grouped.values.last != group) const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _LuaPluginSettingRow extends StatelessWidget {
  const _LuaPluginSettingRow({required this.state, required this.setting});

  final AppState state;
  final LuaPluginSetting setting;

  Future<void> _set(BuildContext context, Object? value) async {
    try {
      await state.pluginManager.setPluginSetting(
        setting.pluginId,
        setting.id,
        value,
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(context.tr('$error'))));
    }
  }

  Future<void> _invoke(BuildContext context) async {
    try {
      await state.pluginManager.invokePluginSetting(
        setting.pluginId,
        setting.id,
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(context.tr('$error'))));
    }
  }

  Future<void> _editText(BuildContext context) async {
    final controller = TextEditingController(
      text: setting.value is String ? setting.value as String : '',
    );
    final value = await showAppleDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.tr(setting.title)),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 2048,
          decoration: InputDecoration(hintText: context.tr('输入内容')),
          onSubmitted: (text) => Navigator.of(dialogContext).pop(text),
        ),
        actions: <Widget>[
          SpringTextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const TrText('取消'),
          ),
          SpringFilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const TrText('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!context.mounted || value == null) return;
    await _set(context, value);
  }

  Widget _control(BuildContext context) {
    final enabled = setting.enabled;
    switch (setting.type) {
      case LuaPluginSettingType.toggle:
        return Switch(
          key: ValueKey('lua-setting-${setting.pluginId}-${setting.id}'),
          value: setting.value == true,
          onChanged: enabled
              ? (value) => unawaited(_set(context, value))
              : null,
        );
      case LuaPluginSettingType.select:
        final selected =
            setting.value is String &&
                setting.options.any((option) => option.value == setting.value)
            ? setting.value as String
            : setting.options.firstOrNull?.value;
        return SettingsChoice<String>(
          key: ValueKey('lua-setting-${setting.pluginId}-${setting.id}'),
          value: selected,
          items: <DropdownMenuItem<String>>[
            for (final option in setting.options)
              DropdownMenuItem<String>(
                value: option.value,
                child: Text(option.label),
              ),
          ],
          onChanged: !enabled
              ? null
              : (value) {
                  if (value != null) unawaited(_set(context, value));
                },
          hint: Text(context.tr('请选择')),
        );
      case LuaPluginSettingType.text:
        final value = setting.value is String ? setting.value as String : '';
        return SpringOutlinedButton(
          key: ValueKey('lua-setting-${setting.pluginId}-${setting.id}'),
          onPressed: enabled ? () => unawaited(_editText(context)) : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 210),
            child: Text(
              value.isEmpty ? context.tr('未设置') : value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
      case LuaPluginSettingType.number:
        final value = setting.value is num
            ? (setting.value as num)
                  .toDouble()
                  .clamp(setting.min, setting.max)
                  .toDouble()
            : setting.min;
        final divisions = ((setting.max - setting.min) / setting.step)
            .round()
            .clamp(1, 2000);
        return SizedBox(
          width: 250,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(
                width: 48,
                child: Text(
                  _formatNumber(value),
                  textAlign: TextAlign.end,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              Expanded(
                child: Slider(
                  key: ValueKey(
                    'lua-setting-${setting.pluginId}-${setting.id}',
                  ),
                  min: setting.min,
                  max: setting.max,
                  divisions: divisions,
                  value: value,
                  onChanged: !enabled
                      ? null
                      : (next) => unawaited(_set(context, next)),
                ),
              ),
            ],
          ),
        );
      case LuaPluginSettingType.action:
        return SpringOutlinedButton(
          key: ValueKey('lua-setting-${setting.pluginId}-${setting.id}'),
          onPressed: enabled ? () => unawaited(_invoke(context)) : null,
          child: const TrText('执行'),
        );
    }
  }

  @override
  Widget build(BuildContext context) => SettingsRow(
    key: ValueKey('lua-setting-row-${setting.pluginId}-${setting.id}'),
    label: setting.title,
    subtitle: setting.subtitle,
    trailing: _control(context),
    expandControl: setting.type == LuaPluginSettingType.select,
  );
}

String _formatNumber(double value) {
  if (value == value.roundToDouble()) return value.toInt().toString();
  return value.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
}
