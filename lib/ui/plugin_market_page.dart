import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../plugins/plugin_market.dart';
import '../state/app_state.dart';
import '../updates/release_version.dart';
import '../diagnostics/build_info.dart';
import '../widgets/apple_ui.dart';
import '../widgets/build_safe_state.dart';
import '../widgets/settings_detail.dart';
import '../widgets/spring_buttons.dart';

String _errorText(Object error) =>
    error is FormatException ? error.message : '$error';

class PluginMarketPage extends StatelessWidget {
  const PluginMarketPage({super.key, required this.state});
  final AppState state;
  @override
  Widget build(BuildContext context) => PluginMarketView(state: state);
}

class PluginMarketView extends StatefulWidget {
  const PluginMarketView({super.key, required this.state, this.market});
  final AppState state;
  final PluginMarket? market;
  @override
  State<PluginMarketView> createState() => _PluginMarketViewState();
}

class _PluginMarketViewState extends State<PluginMarketView>
    with BuildSafeState<PluginMarketView> {
  late final market = widget.market ?? PluginMarket(widget.state.pluginManager);
  String _query = '';
  @override
  void initState() {
    super.initState();
    unawaited(market.restore());
  }

  @override
  void dispose() {
    if (widget.market == null) market.dispose();
    super.dispose();
  }

  Future<void> _editSource() async {
    var source = market.source;
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.tr('插件源')),
        content: TextFormField(
          initialValue: source,
          autofocus: true,
          onChanged: (value) => source = value,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: defaultPluginSource),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.tr('取消')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, source),
            child: Text(context.tr('保存')),
          ),
        ],
      ),
    );
    if (value == null || !mounted) return;
    try {
      await market.setSource(value);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.tr(_errorText(error)))));
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([market, widget.state.pluginManager]),
    builder: (context, _) {
      final locale = Localizations.localeOf(context).toLanguageTag();
      final entries = market.plugins
          .where(
            (plugin) =>
                '${plugin.localized(plugin.name, locale)} ${plugin.localized(plugin.summary, locale)} ${plugin.author} ${plugin.id}'
                    .toLowerCase()
                    .contains(_query.toLowerCase()),
          )
          .toList();
      return SettingsDetailScaffold(
        title: context.tr('插件市场'),
        actions: [
          IconButton(
            tooltip: context.tr('插件源'),
            onPressed: _editSource,
            icon: const Icon(Icons.dns_outlined),
          ),
          IconButton(
            tooltip: context.tr('刷新'),
            onPressed: market.loading ? null : market.refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            TextField(
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded),
                hintText: context.tr('搜索插件'),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
            if (market.loading) const LinearProgressIndicator(),
            if (market.error case final error?)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(context.tr(error)),
              ),
            if (!market.loading && entries.isEmpty)
              AppleEmptyState(
                message: market.plugins.isEmpty ? '插件源暂时没有可用插件' : '没有匹配的插件',
                icon: Icons.extension_outlined,
              ),
            for (final plugin in entries) ...[
              const SizedBox(height: 12),
              _entry(context, plugin, locale),
            ],
          ],
        ),
      );
    },
  );

  Widget _entry(BuildContext context, MarketPlugin plugin, String locale) {
    final installed = widget.state.pluginManager.plugins
        .where((entry) => entry.manifest.id == plugin.id)
        .firstOrNull;
    final incompatible = plugin.incompatibility(
      defaultTargetPlatform.name.toLowerCase(),
      BuildInfo.version,
    );
    final update =
        installed != null &&
        ReleaseVersion.parse(
              plugin.version,
            )!.compareTo(ReleaseVersion.parse(installed.manifest.version)!) >
            0;
    final downloading = market.installing == plugin.id;
    final busy = market.installing != null || widget.state.pluginManager.busy;
    return AppleGroupedCard(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              plugin.localized(plugin.name, locale),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text('${plugin.author} · v${plugin.version}'),
            const SizedBox(height: 8),
            Text(plugin.localized(plugin.summary, locale)),
            const SizedBox(height: 12),
            if (downloading) ...[
              LinearProgressIndicator(value: market.progress),
              SpringTextButton(
                onPressed: widget.state.pluginManager.busy
                    ? null
                    : market.cancelDownload,
                child: Text(context.tr('取消下载')),
              ),
            ] else
              SpringFilledButton(
                onPressed:
                    incompatible != null || busy || installed != null && !update
                    ? null
                    : () => market.install(plugin),
                child: Text(
                  context.tr(
                    incompatible ??
                        (installed == null
                            ? '安装'
                            : update
                            ? '更新'
                            : '已安装'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
