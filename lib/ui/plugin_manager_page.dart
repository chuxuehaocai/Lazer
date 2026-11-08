import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../gateway/gateway.dart';
import '../plugins/plugin_manager.dart';
import '../state/app_state.dart';
import '../theme/apple_design.dart';
import '../widgets/apple_ui.dart';
import '../widgets/settings_detail.dart';
import '../widgets/spring_buttons.dart';
import '../widgets/build_safe_state.dart';
import '../plugins/plugin_package.dart';
import 'plugin_market_page.dart';

String _errorText(Object error) =>
    error is FormatException ? error.message : '$error';

class PluginManagerPage extends StatelessWidget {
  const PluginManagerPage({super.key, required this.state});
  final AppState state;
  @override
  Widget build(BuildContext context) => PluginManagerView(state: state);
}

class PluginManagerView extends StatefulWidget {
  const PluginManagerView({super.key, required this.state});
  final AppState state;
  @override
  State<PluginManagerView> createState() => _PluginManagerViewState();
}

class _PluginManagerViewState extends State<PluginManagerView>
    with BuildSafeState<PluginManagerView> {
  bool _picking = false;
  PluginManager get manager => widget.state.pluginManager;
  @override
  void initState() {
    super.initState();
    unawaited(manager.restore());
  }

  Future<void> _import() async {
    if (_picking || manager.busy) return;
    setState(() => _picking = true);
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          XTypeGroup(
            label: context.tr('Lazer 插件'),
            extensions: ['zip'],
            mimeTypes: ['application/zip', 'application/x-zip-compressed'],
            uniformTypeIdentifiers: ['public.zip-archive'],
          ),
        ],
      );
      if (file == null || !mounted) return;
      final int length = await file.length();
      if (!mounted) return;
      if (length > maxPluginArchiveBytes) {
        throw FormatException(context.tr('插件包不能超过 16 MB。'));
      }
      await manager.importZip(await file.readAsBytes());
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: TrText('插件已安装')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.tr(_errorText(error)))));
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final apple = AppleSemanticColors.of(context);
    return AnimatedBuilder(
      animation: Listenable.merge([manager, widget.state]),
      builder: (context, _) => SettingsDetailScaffold(
        title: context.tr('插件管理'),
        actions: [
          SpringTextButton(
            onPressed: () => SettingsDetailHost.open(
              context,
              page: (_) => PluginMarketPage(state: widget.state),
              view: (_) => PluginMarketView(state: widget.state),
            ),
            child: const TrText('插件市场'),
          ),
          SpringFilledButton(
            onPressed: manager.busy || _picking ? null : _import,
            child: TrText(_picking || manager.busy ? '正在导入…' : '导入 ZIP'),
          ),
        ],
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            AppleGroupedCard(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.extension_rounded, color: apple.accent),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        context.tr(
                          '插件以 ZIP 导入。每个插件运行在独立的 Lua 沙箱中，只能访问清单声明的网络域名和存储。',
                        ),
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            if (manager.plugins.isEmpty)
              const AppleGroupedCard(
                margin: EdgeInsets.zero,
                child: AppleEmptyState(
                  message: '还没有安装插件。导入一个音乐平台插件开始使用。',
                  icon: Icons.extension_off_rounded,
                ),
              )
            else
              AppleGroupedCard(
                margin: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (var i = 0; i < manager.plugins.length; i++) ...[
                      if (i > 0) Divider(height: 1, color: apple.separator),
                      _PluginRow(
                        plugin: manager.plugins[i],
                        manager: manager,
                        active: manager.gateways
                            .where(
                              (gateway) =>
                                  gateway.connectionId ==
                                  manager.plugins[i].manifest.id,
                            )
                            .any(
                              (gateway) =>
                                  GatewayRegistry.keyOf(gateway) ==
                                  widget.state.activeConnectionKey,
                            ),
                        onUse: () async {
                          final gateway = manager.gateways
                              .where(
                                (gateway) =>
                                    gateway.connectionId ==
                                    manager.plugins[i].manifest.id,
                              )
                              .firstOrNull;
                          if (gateway != null) {
                            await widget.state.selectMusicConnection(
                              GatewayRegistry.keyOf(gateway),
                            );
                          }
                        },
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PluginRow extends StatelessWidget {
  const _PluginRow({
    required this.plugin,
    required this.manager,
    required this.active,
    required this.onUse,
  });
  final InstalledPlugin plugin;
  final PluginManager manager;
  final bool active;
  final Future<void> Function() onUse;
  @override
  Widget build(BuildContext context) {
    final apple = AppleSemanticColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: apple.accent.withValues(alpha: .13),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.extension_rounded, color: apple.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  plugin.manifest.name,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${plugin.manifest.provider} · v${plugin.manifest.version}${plugin.error == null ? '' : ' · ${plugin.error}'}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: plugin.error == null
                        ? apple.secondaryLabel
                        : Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ),
          ),
          if (plugin.enabled && !active && plugin.error == null)
            SpringTextButton(
              onPressed: manager.busy ? null : () => unawaited(onUse()),
              child: const TrText('使用'),
            ),
          Switch(
            value: plugin.enabled,
            onChanged: manager.busy
                ? null
                : (value) =>
                      unawaited(manager.setEnabled(plugin.manifest.id, value)),
          ),
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'remove') {
                await manager.uninstall(plugin.manifest.id);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'remove', child: Text(context.tr('卸载'))),
            ],
          ),
        ],
      ),
    );
  }
}
