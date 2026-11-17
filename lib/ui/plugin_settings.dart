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
import '../widgets/settings_detail.dart';
import '../widgets/text_input_dialog.dart';

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
    final pages = state.pluginManager.pluginPages;
    if (settings.isEmpty && pages.isEmpty) return const SizedBox.shrink();
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
        if (settings.isNotEmpty) ...<Widget>[
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
        if (pages.isNotEmpty) ...<Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 22, 12, 7),
            child: Text(
              context.tr('插件页面'),
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: apple.secondaryLabel,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          AppleGroupedCard(
            margin: EdgeInsets.zero,
            child: Column(
              children: <Widget>[
                for (var i = 0; i < pages.length; i++) ...<Widget>[
                  if (i > 0) Divider(height: 1, color: apple.separator),
                  _LuaPluginPageTile(state: state, page: pages[i]),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _LuaPluginPageTile extends StatelessWidget {
  const _LuaPluginPageTile({required this.state, required this.page});

  final AppState state;
  final LuaPluginPage page;

  @override
  Widget build(BuildContext context) => AppleListTile(
    key: ValueKey('lua-plugin-page-${page.pluginId}-${page.id}'),
    padding: SettingsSpacing.rowPadding,
    minHeight: SettingsSpacing.rowMinHeight,
    leading: AppleIconTile(
      icon: luaPluginIcon(page.icon),
      color: AppleSemanticColors.of(context).accent,
    ),
    title: context.tr(page.title),
    subtitle: page.subtitle.isEmpty
        ? context.tr(page.pluginName)
        : '${context.tr(page.pluginName)} · ${context.tr(page.subtitle)}',
    trailing: const Icon(Icons.chevron_right_rounded),
    onTap: () => SettingsDetailHost.open(
      context,
      page: (_) => LuaPluginPageView(
        state: state,
        pluginId: page.pluginId,
        pageId: page.id,
      ),
      view: (_) => LuaPluginPageView(
        state: state,
        pluginId: page.pluginId,
        pageId: page.id,
      ),
    ),
  );
}

/// Flutter-owned rendering for a Lua page description.
///
/// The page geometry comes from [LuaPluginPageLayout]: spacing, inset, width,
/// alignment and flow are all data the plugin supplied, and this widget turns
/// them into host-owned Flutter widgets.
class LuaPluginPageView extends StatelessWidget {
  const LuaPluginPageView({
    super.key,
    required this.state,
    required this.pluginId,
    required this.pageId,
  });

  final AppState state;
  final String pluginId;
  final String pageId;

  LuaPluginPage? _page() => state.pluginManager.pluginPages
      .where((page) => page.pluginId == pluginId && page.id == pageId)
      .firstOrNull;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state.pluginManager,
    builder: (context, _) {
      final page = _page();
      if (page == null) {
        return SettingsDetailScaffold(
          title: context.tr('插件页面'),
          child: const Center(child: CircularProgressIndicator()),
        );
      }
      final layout = page.layout;
      return SettingsDetailScaffold(
        title: context.tr(page.title),
        child: LayoutBuilder(
          builder: (context, constraints) => ListView(
            padding: EdgeInsets.fromLTRB(layout.inset, 8, layout.inset, 32),
            children: <Widget>[
              if (layout.header && page.subtitle.isNotEmpty)
                ApplePageTitle(
                  title: page.title,
                  subtitle: page.subtitle,
                  padding: const EdgeInsets.fromLTRB(0, 4, 0, 18),
                ),
              _frame(page, layout, constraints.maxWidth - layout.inset * 2),
            ],
          ),
        ),
      );
    },
  );

  /// Wraps the element surface in the page's width and alignment rules.
  Widget _frame(LuaPluginPage page, LuaPluginPageLayout layout, double room) {
    final surface = layout.card
        ? AppleGroupedCard(
            margin: EdgeInsets.zero,
            child: _surface(page, layout),
          )
        : _surface(page, layout);
    if (layout.maxWidth <= 0 || layout.maxWidth >= room) return surface;
    return Align(
      alignment: switch (layout.align) {
        LuaPluginPageAlign.start => Alignment.topLeft,
        LuaPluginPageAlign.end => Alignment.topRight,
        LuaPluginPageAlign.center ||
        LuaPluginPageAlign.stretch => Alignment.topCenter,
      },
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: layout.maxWidth),
        child: surface,
      ),
    );
  }

  Widget _surface(LuaPluginPage page, LuaPluginPageLayout layout) {
    switch (layout.direction) {
      case LuaPluginPageDirection.vertical:
        final children = <Widget>[];
        for (var i = 0; i < page.elements.length; i++) {
          final element = page.elements[i];
          final gap = (i == 0 ? 0.0 : layout.gap) + element.gap;
          if (gap > 0) children.add(SizedBox(height: gap));
          children.add(
            _LuaPluginPageElementView(state: state, element: element),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        );
      case LuaPluginPageDirection.horizontal:
        final children = <Widget>[];
        for (var i = 0; i < page.elements.length; i++) {
          final element = page.elements[i];
          final gap = (i == 0 ? 0.0 : layout.gap) + element.gap;
          if (gap > 0) children.add(SizedBox(width: gap));
          children.add(
            Expanded(
              child: _LuaPluginPageElementView(state: state, element: element),
            ),
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        );
      case LuaPluginPageDirection.grid:
        final columns = layout.columns;
        return LayoutBuilder(
          builder: (context, constraints) {
            final gap = layout.gap * (columns - 1);
            final width = (constraints.maxWidth - gap) / columns;
            return Wrap(
              spacing: layout.gap,
              runSpacing: layout.gap,
              children: <Widget>[
                for (final element in page.elements)
                  SizedBox(
                    width: width > 0 ? width : constraints.maxWidth,
                    child: _LuaPluginPageElementView(
                      state: state,
                      element: element,
                    ),
                  ),
              ],
            );
          },
        );
    }
  }
}

class _LuaPluginPageElementView extends StatelessWidget {
  const _LuaPluginPageElementView({required this.state, required this.element});

  final AppState state;
  final LuaPluginPageElement element;

  Future<void> _event(BuildContext context, Object? value) async {
    try {
      await state.pluginManager.invokePluginPageEvent(
        element.pluginId,
        element.pageId,
        element.id!,
        value,
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(context.tr('$error'))));
    }
  }

  Future<void> _editText(BuildContext context) async {
    final value = await showAppleDialog<String>(
      context: context,
      builder: (_) => AppTextInputDialog(
        title: context.tr(element.title),
        initialValue: element.value is String ? element.value as String : '',
        maxLines: element.maxLines,
        maxLength: 2048,
        hintText: element.placeholder.isEmpty
            ? context.tr('输入内容')
            : context.tr(element.placeholder),
      ),
    );
    if (!context.mounted || value == null) return;
    await _event(context, value);
  }

  Widget _control(BuildContext context) {
    switch (element.type) {
      case LuaPluginPageElementType.text:
        return Padding(
          padding: SettingsSpacing.rowPadding,
          child: Text(
            context.tr(element.text),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        );
      case LuaPluginPageElementType.section:
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
          child: Text(
            context.tr(element.title),
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
        );
      case LuaPluginPageElementType.divider:
        return Divider(
          height: 1,
          color: AppleSemanticColors.of(context).separator,
        );
      case LuaPluginPageElementType.spacer:
        return const SizedBox(height: 12);
      case LuaPluginPageElementType.button:
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: SpringFilledButton.icon(
            onPressed: element.enabled
                ? () => unawaited(_event(context, null))
                : null,
            icon: Icon(luaPluginIcon(element.icon)),
            label: Text(context.tr(element.title)),
          ),
        );
      case LuaPluginPageElementType.toggle:
        return SettingsRow(
          label: element.title,
          subtitle: element.subtitle,
          trailing: Switch(
            value: element.value == true,
            onChanged: element.enabled
                ? (value) => unawaited(_event(context, value))
                : null,
          ),
        );
      case LuaPluginPageElementType.select:
        final selected =
            element.value is String &&
                element.options.any((option) => option.value == element.value)
            ? element.value as String
            : element.options.first.value;
        return SettingsRow(
          label: element.title,
          subtitle: element.subtitle,
          expandControl: true,
          trailing: SettingsChoice<String>(
            value: selected,
            items: [
              for (final option in element.options)
                DropdownMenuItem<String>(
                  value: option.value,
                  child: Text(context.tr(option.label)),
                ),
            ],
            onChanged: element.enabled
                ? (value) {
                    if (value != null) unawaited(_event(context, value));
                  }
                : null,
          ),
        );
      case LuaPluginPageElementType.slider:
        final value = element.value is num
            ? (element.value as num)
                  .toDouble()
                  .clamp(element.min, element.max)
                  .toDouble()
            : element.min;
        final divisions = ((element.max - element.min) / element.step)
            .round()
            .clamp(1, 2000);
        return SettingsRow(
          label: element.title,
          subtitle: element.subtitle,
          trailing: SizedBox(
            width: 250,
            child: Slider(
              value: value,
              min: element.min,
              max: element.max,
              divisions: divisions,
              label: _formatNumber(value),
              onChanged: element.enabled
                  ? (next) => unawaited(_event(context, next))
                  : null,
            ),
          ),
        );
      case LuaPluginPageElementType.textField:
        final value = element.value is String ? element.value as String : '';
        return SettingsRow(
          label: element.title,
          subtitle: element.subtitle,
          trailing: SpringOutlinedButton(
            onPressed: element.enabled
                ? () => unawaited(_editText(context))
                : null,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 210),
              child: Text(
                value.isEmpty ? context.tr('未设置') : value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final control = _control(context);
    if (element.padding <= 0) return control;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: element.padding),
      child: control,
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
    final value = await showAppleDialog<String>(
      context: context,
      builder: (_) => AppTextInputDialog(
        title: context.tr(setting.title),
        initialValue: setting.value is String ? setting.value as String : '',
        maxLength: 2048,
        hintText: context.tr('输入内容'),
      ),
    );
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
