import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../animation/apple_modal.dart';
import '../l10n/app_localizations.dart';
import '../plugins/plugin_manager.dart';
import '../state/app_state.dart';
import '../theme/apple_design.dart';
import '../widgets/accessible_controls.dart';
import '../widgets/apple_ui.dart';
import '../widgets/settings_detail.dart';
import '../widgets/spring_buttons.dart';
import '../widgets/build_safe_state.dart';
import '../plugins/plugin_package.dart';
import 'plugin_market_page.dart';
import '../theme/shape_scale.dart';

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
          // 两个命令都只留图标：胶囊是窗口自己的 chrome，塞两段文字进去会跟
          // 标题挤在一起。名字放语义标签里 —— 这里不能用 Tooltip：胶囊本身
          // 画在 overlay portal 里，再套一层 tooltip 会触发深度断言。
          AccessibleIconButton(
            key: const ValueKey('plugin-market-action'),
            semanticLabel: context.tr('插件市场'),
            icon: const Icon(Icons.storefront_rounded),
            iconSize: 20,
            visualDensity: VisualDensity.compact,
            onPressed: () => SettingsDetailHost.open(
              context,
              page: (_) => PluginMarketPage(state: widget.state),
              view: (_) => PluginMarketView(state: widget.state),
            ),
          ),
          AccessibleIconButton(
            key: const ValueKey('plugin-import-action'),
            semanticLabel: context.tr('导入 ZIP'),
            icon: const Icon(Icons.file_upload_outlined),
            iconSize: 20,
            visualDensity: VisualDensity.compact,
            onPressed: manager.busy || _picking ? null : _import,
          ),
        ],
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            20,
            8 + SettingsDetailScaffold.topInsetOf(context),
            20,
            32,
          ),
          children: [
            // The same air above the title as every settings category page:
            // 8 from the list plus 12 from the title itself.
            ApplePageTitle(
              title: '插件管理',
              subtitle: manager.plugins.isEmpty
                  ? '还没有导入插件'
                  : '${manager.plugins.length} 个插件已安装',
              padding: const EdgeInsets.fromLTRB(0, 12, 0, 18),
            ),
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
                          '插件以 ZIP 导入。每个插件运行在独立的 Lua 沙箱中，只能访问清单声明的网络域名、存储和文件沙箱。',
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
                  message: '还没有安装插件。先导入一个音乐平台插件。',
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

  });
  final InstalledPlugin plugin;
  final PluginManager manager;

  String _permissionSummary(BuildContext context) {
    final parts = <String>[];
    if (plugin.manifest.domains.isNotEmpty) {
      final count = plugin.manifest.domains.length;
      final unit = context.tr('个授权域名');
      parts.add('$count $unit');
    }
    if (plugin.manifest.socketDomains.isNotEmpty) {
      parts.add(context.tr('允许 Socket 连接'));
    }
    if (plugin.manifest.socketServerBindings.isNotEmpty) {
      parts.add(context.tr('允许 Socket 服务端'));
    }
    if (plugin.manifest.websocketDomains.isNotEmpty ||
        plugin.manifest.websocketServerBindings.isNotEmpty) {
      parts.add(context.tr('WebSocket 需授权'));
    }
    if (plugin.manifest.storage) {
      parts.add(context.tr('本地存储'));
    }
    if (plugin.manifest.dataPermissions.isNotEmpty) {
      parts.add(context.tr('隐私资料需授权'));
    }
    if (plugin.manifest.filesystem) {
      parts.add(context.tr('文件管理权限'));
    }
    if (plugin.manifest.appearance) {
      parts.add(context.tr('可更改界面配色'));
    }
    if (parts.isEmpty) {
      return context.tr('无需特殊权限');
    }
    return parts.join(' · ');
  }

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
              borderRadius: BorderRadius.circular(12 * AppleShape.scaleOf(context)),
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
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${_pluginKind(plugin)} · v${plugin.manifest.version}${plugin.error == null ? '' : ' · ${plugin.error}'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: plugin.error == null
                        ? apple.secondaryLabel
                        : Theme.of(context).colorScheme.error,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    _permissionSummary(context),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: apple.secondaryLabel,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: plugin.enabled,
            onChanged: manager.busy
                ? null
                : (value) =>
                      unawaited(manager.setEnabled(plugin.manifest.id, value)),
          ),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert_rounded, color: apple.secondaryLabel),
            onSelected: (value) async {
              if (value == 'info') {
                await _showPluginDetails(context, plugin, manager);
              } else if (value == 'remove') {
                await manager.uninstall(plugin.manifest.id);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'info',
                child: Row(
                  children: [
                    const Icon(Icons.info_outline_rounded, size: 18),
                    const SizedBox(width: 8),
                    Text(context.tr('详细信息')),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'remove',
                child: Row(
                  children: [
                    Icon(
                      Icons.delete_outline_rounded,
                      size: 18,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      context.tr('卸载'),
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

Future<void> _showPluginDetails(
  BuildContext context,
  InstalledPlugin plugin,
  PluginManager manager,
) {
  final bool wide = MediaQuery.sizeOf(context).width >= 700;
  if (wide) {
    return showAppleDialog<void>(
      context: context,
      builder: (BuildContext context) => Dialog(
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16 * AppleShape.scaleOf(context))),
        child: SizedBox(
          width: 480,
          child: _PluginDetailsSheet(plugin: plugin, manager: manager),
        ),
      ),
    );
  }
  return showAppleModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    showDragHandle: true,
    builder: (BuildContext context) => SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.75,
      child: _PluginDetailsSheet(plugin: plugin, manager: manager),
    ),
  );
}

class _PluginDetailsSheet extends StatefulWidget {
  const _PluginDetailsSheet({required this.plugin, required this.manager});

  final InstalledPlugin plugin;
  final PluginManager manager;

  @override
  State<_PluginDetailsSheet> createState() => _PluginDetailsSheetState();
}

/// 插件卡片副标题里的「类型」。
///
/// 以前这里直接印 `manifest.provider`，纯主题插件的 provider 是 `parchment`，
/// 看起来就像注册了一个叫 parchment 的音乐平台。只有真的挂上网关时才显示平台名，
/// 否则显示它实际提供的东西：主题 / 布局 / 插件。
String _pluginKind(InstalledPlugin plugin) {
  if (plugin.gateways.isNotEmpty) return plugin.manifest.provider;
  final List<String> parts = <String>[
    if (plugin.theme != null) '主题',
    if (plugin.layout != null) '布局',
  ];
  return parts.isEmpty ? '插件' : parts.join(' · ');
}

class _PluginDetailsSheetState extends State<_PluginDetailsSheet> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final apple = AppleSemanticColors.of(context);
    final manifest = widget.plugin.manifest;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: apple.accent.withValues(alpha: .13),
                  borderRadius: BorderRadius.circular(12 * AppleShape.scaleOf(context)),
                ),
                child: Icon(Icons.extension_rounded, color: apple.accent, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      manifest.name,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${manifest.id} · v${manifest.version} · ${_pluginKind(widget.plugin)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: apple.secondaryLabel,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Divider(height: 1, color: apple.separator),
          const SizedBox(height: 16),
          Expanded(
            child: ListView(
              children: [
                _sectionHeader(context, Icons.language_rounded, context.tr('网络访问权限'), apple),
                const SizedBox(height: 8),
                if (manifest.domains.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 12),
                    child: Text(
                      context.tr('无需访问外网'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: apple.secondaryLabel,
                      ),
                    ),
                  )
                else ...[
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 8),
                    child: Text(
                      context.tr('该插件仅限访问以下白名单网络域名：'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: apple.secondaryLabel,
                      ),
                    ),
                  ),
                  Container(
                    decoration: BoxDecoration(
                      color: apple.tertiaryFill,
                      borderRadius: BorderRadius.circular(10 * AppleShape.scaleOf(context)),
                      border: Border.all(color: apple.separator, width: .5),
                    ),
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final domain in manifest.domains)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(
                              children: [
                                Icon(Icons.circle, size: 5, color: apple.accent),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: SelectableText(
                                    domain,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: apple.label,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerRight,
                    child: SpringTextButton(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: manifest.domains.join('\n')));
                        ScaffoldMessenger.of(context)
                          ..hideCurrentSnackBar()
                          ..showSnackBar(
                            SnackBar(
                              content: Text(context.tr('已复制域名列表')),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                      },
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.copy_rounded, size: 14, color: apple.accent),
                          const SizedBox(width: 4),
                          const TrText('复制全部域名'),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        context.tr('允许网络访问'),
                        style: theme.textTheme.bodySmall?.copyWith(color: apple.label),
                      ),
                      Switch(
                        value: widget.plugin.networkGranted,
                        onChanged: widget.manager.busy
                            ? null
                            : (value) async {
                                await widget.manager.setNetworkPermission(manifest.id, value);
                                if (mounted) setState(() {});
                              },
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                if (manifest.socketDomains.isNotEmpty) ...[
                  _sectionHeader(context, Icons.link_rounded, context.tr('允许 Socket 连接'), apple),
                  const SizedBox(height: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: apple.tertiaryFill,
                      borderRadius: BorderRadius.circular(10 * AppleShape.scaleOf(context)),
                      border: Border.all(color: apple.separator, width: .5),
                    ),
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final host in manifest.socketDomains)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Text(
                              host,
                              style: theme.textTheme.bodyMedium?.copyWith(color: apple.label),
                            ),
                          ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              context.tr('允许 Socket 连接'),
                              style: theme.textTheme.bodySmall?.copyWith(color: apple.label),
                            ),
                            Switch(
                              value: widget.plugin.socketGranted,
                              onChanged: widget.manager.busy
                                  ? null
                                  : (value) async {
                                      await widget.manager.setSocketPermission(manifest.id, value);
                                      if (mounted) setState(() {});
                                    },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                if (manifest.socketServerBindings.isNotEmpty) ...[
                  _sectionHeader(context, Icons.dns_outlined, context.tr('允许 Socket 服务端'), apple),
                  const SizedBox(height: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: apple.tertiaryFill,
                      borderRadius: BorderRadius.circular(10 * AppleShape.scaleOf(context)),
                      border: Border.all(color: apple.separator, width: .5),
                    ),
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final binding in manifest.socketServerBindings)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Text(
                              binding,
                              style: theme.textTheme.bodyMedium?.copyWith(color: apple.label),
                            ),
                          ),
                        if (kIsWeb)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              context.tr('浏览器不支持 Socket 服务端。'),
                              style: theme.textTheme.bodySmall?.copyWith(color: apple.secondaryLabel),
                            ),
                          ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              context.tr('允许 Socket 服务端'),
                              style: theme.textTheme.bodySmall?.copyWith(color: apple.label),
                            ),
                            Switch(
                              key: ValueKey('socket-server-permission-${manifest.id}'),
                              value: widget.plugin.socketServerGranted,
                              onChanged: widget.manager.busy || kIsWeb
                                  ? null
                                  : (value) async {
                                      await widget.manager.setSocketServerPermission(manifest.id, value);
                                      if (mounted) setState(() {});
                                    },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                if (manifest.websocketDomains.isNotEmpty) ...[
                  _sectionHeader(context, Icons.swap_calls_rounded, context.tr('WebSocket 实时通信'), apple),
                  const SizedBox(height: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: apple.tertiaryFill,
                      borderRadius: BorderRadius.circular(10 * AppleShape.scaleOf(context)),
                      border: Border.all(color: apple.separator, width: .5),
                    ),
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final ws in manifest.websocketDomains)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Text(
                              ws,
                              style: theme.textTheme.bodyMedium?.copyWith(color: apple.label),
                            ),
                          ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              context.tr('允许 WebSocket 连接'),
                              style: theme.textTheme.bodySmall?.copyWith(color: apple.label),
                            ),
                            Switch(
                              value: widget.plugin.websocketGranted,
                              onChanged: widget.manager.busy
                                  ? null
                                  : (value) async {
                                      await widget.manager.setWebsocketPermission(manifest.id, value);
                                      if (mounted) setState(() {});
                                    },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                if (manifest.websocketServerBindings.isNotEmpty) ...[
                  _sectionHeader(context, Icons.dns_outlined, context.tr('WebSocket 服务端'), apple),
                  const SizedBox(height: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: apple.tertiaryFill,
                      borderRadius: BorderRadius.circular(10 * AppleShape.scaleOf(context)),
                      border: Border.all(color: apple.separator, width: .5),
                    ),
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final binding in manifest.websocketServerBindings)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Text(
                              binding,
                              style: theme.textTheme.bodyMedium?.copyWith(color: apple.label),
                            ),
                          ),
                        if (kIsWeb)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              context.tr('浏览器不支持 WebSocket 服务端。'),
                              style: theme.textTheme.bodySmall?.copyWith(color: apple.secondaryLabel),
                            ),
                          ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              context.tr('允许 WebSocket 服务端'),
                              style: theme.textTheme.bodySmall?.copyWith(color: apple.label),
                            ),
                            Switch(
                              key: ValueKey('websocket-server-permission-${manifest.id}'),
                              value: widget.plugin.websocketServerGranted,
                              onChanged: widget.manager.busy || kIsWeb
                                  ? null
                                  : (value) async {
                                      await widget.manager.setWebsocketServerPermission(manifest.id, value);
                                      if (mounted) setState(() {});
                                    },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                if (manifest.dataPermissions.isNotEmpty) ...[
                  _sectionHeader(context, Icons.privacy_tip_outlined, context.tr('隐私资料权限'), apple),
                  const SizedBox(height: 8),
                  for (final scope in manifest.dataPermissions)
                    SwitchListTile.adaptive(
                      key: ValueKey('data-permission-${manifest.id}-$scope'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(switch (scope) {
                        'library' => context.tr('歌单与音乐库'),
                        'profile' => context.tr('平台与账号资料'),
                        'history' => context.tr('播放记录与统计'),
                        'native_audio' => context.tr('原生音频诊断与设备摘要'),
                        'native_control' => context.tr('桌面与悬浮歌词控制'),
                        _ => scope,
                      }),
                      value: widget.plugin.dataAccess.granted.contains(scope),
                      onChanged: widget.manager.busy ? null : (value) async {
                        await widget.manager.setDataPermission(manifest.id, scope, value);
                        if (mounted) setState(() {});
                      },
                    ),
                  const SizedBox(height: 16),
                ],
                if (manifest.filesystem) ...[
                  _sectionHeader(context, Icons.folder_copy_outlined, context.tr('文件管理权限'), apple),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Text(
                      context.tr('允许插件在自己的文件沙箱中读写、列出和删除文件；不会访问沙箱外的路径。'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: apple.secondaryLabel,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        context.tr('允许文件管理'),
                        style: theme.textTheme.bodySmall?.copyWith(color: apple.label),
                      ),
                      Switch(
                        key: ValueKey('filesystem-permission-${manifest.id}'),
                        value: widget.plugin.filesystemGranted,
                        onChanged: widget.manager.busy
                            ? null
                            : (value) async {
                                await widget.manager.setFilesystemPermission(
                                  manifest.id,
                                  value,
                                );
                                if (mounted) setState(() {});
                              },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],
                _sectionHeader(context, Icons.folder_outlined, context.tr('本地数据存储'), apple),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Text(
                    manifest.storage
                        ? context.tr('拥有独立的本地数据存储沙箱（存储于 lua_plugin_data 目录）。')
                        : context.tr('不使用本地存储'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: apple.secondaryLabel,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SpringFilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const TrText('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, IconData icon, String title, AppleSemanticColors apple) {
    return Row(
      children: [
        Icon(icon, size: 16, color: apple.accent),
        const SizedBox(width: 6),
        Text(
          title,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
