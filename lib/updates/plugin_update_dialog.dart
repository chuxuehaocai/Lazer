import 'package:flutter/material.dart';

import '../animation/apple_modal.dart';
import '../l10n/app_localizations.dart';
import '../plugins/plugin_market.dart';
import '../tv/tv_mode.dart';
import '../widgets/spring_buttons.dart';

enum PluginUpdateResult { later, skipped, updated }

/// Presents one available plugin update and performs its verified download.
///
/// The shell shows updates one at a time so two dialogs never stack. Returning
/// [PluginUpdateResult.skipped] lets the caller continue with the next plugin,
/// while [PluginUpdateResult.later] postpones the whole remaining queue.
Future<PluginUpdateResult> showPluginUpdateDialog(
  BuildContext context, {
  required PluginMarket market,
  required MarketPlugin plugin,
  required String installedVersion,
}) async {
  return await showAppleDialog<PluginUpdateResult>(
        context: context,
        builder: (BuildContext context) => _PluginUpdateDialog(
          market: market,
          plugin: plugin,
          installedVersion: installedVersion,
        ),
      ) ??
      PluginUpdateResult.later;
}

class _PluginUpdateDialog extends StatelessWidget {
  const _PluginUpdateDialog({
    required this.market,
    required this.plugin,
    required this.installedVersion,
  });

  final PluginMarket market;
  final MarketPlugin plugin;
  final String installedVersion;

  Future<void> _skip(BuildContext context) async {
    await market.skipUpdate(plugin);
    if (context.mounted) {
      Navigator.of(context).pop(PluginUpdateResult.skipped);
    }
  }

  Future<void> _update(BuildContext context) async {
    final bool installed = await market.install(plugin);
    if (installed && context.mounted) {
      Navigator.of(context).pop(PluginUpdateResult.updated);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: market,
      builder: (BuildContext context, Widget? child) {
        final ThemeData theme = Theme.of(context);
        final ColorScheme scheme = theme.colorScheme;
        final String locale = Localizations.localeOf(context).toLanguageTag();
        final String name = plugin.localized(plugin.name, locale).trim();
        final String summary = plugin.localized(plugin.summary, locale).trim();
        final bool downloading = market.installing == plugin.id;
        final String? error = market.error;
        return AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
          contentPadding: const EdgeInsets.fromLTRB(24, 14, 24, 8),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          title: Row(
            children: <Widget>[
              Icon(Icons.extension_rounded, color: scheme.primary),
              const SizedBox(width: 12),
              Expanded(child: Text(context.tr('发现插件更新'))),
            ],
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  name.isEmpty ? plugin.id : name,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  context.tr('插件当前版本 $installedVersion，最新版本 ${plugin.version}'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (summary.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 14),
                  Text(
                    summary,
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
                  ),
                ],
                if (downloading) ...<Widget>[
                  const SizedBox(height: 18),
                  Text(context.tr('下载')),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: market.progress),
                ],
                if (error != null && !downloading) ...<Widget>[
                  const SizedBox(height: 14),
                  Text(
                    context.tr(error),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: <Widget>[
            SpringTextButton(
              onPressed: downloading
                  ? null
                  : () => Navigator.of(context).pop(PluginUpdateResult.later),
              child: const TrText('稍后'),
            ),
            SpringTextButton(
              onPressed: downloading ? null : () => _skip(context),
              child: const TrText('跳过此版本'),
            ),
            if (downloading)
              SpringTextButton(
                onPressed: market.cancelDownload,
                child: const TrText('取消下载'),
              )
            else
              SpringFilledButton(
                autofocus: TvScope.isActive(context),
                onPressed: () => _update(context),
                child: const TrText('更新'),
              ),
          ],
        );
      },
    );
  }
}
