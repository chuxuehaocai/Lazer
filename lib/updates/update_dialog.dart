import '../widgets/spring_buttons.dart';
import 'package:flutter/material.dart';
import '../animation/apple_modal.dart';

import '../diagnostics/build_info.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../tv/tv_mode.dart';
import 'open_external.dart';
import 'update_checker.dart';

/// The settings entry point: always checks, even for a skipped release.
Future<void> checkUpdatesFromSettings(
  BuildContext context,
  AppState state,
) async {
  final AppRelease? release = await state.checkForUpdates(manual: true);
  if (!context.mounted) return;
  if (state.updateError != null) {
    _notice(context, context.tr('检查更新失败，请稍后重试'));
    return;
  }
  if (release == null) {
    _notice(context, context.tr('已是最新版本'));
    return;
  }
  await showUpdateDialog(context, state, release);
}

/// Presents a new release. [state] remembers a skip so automatic checks stop
/// offering this exact version until a newer one is published.
///
/// The shell's automatic prompt and the settings button can both ask for the
/// same release. Only one dialog may exist at a time; a second request is a
/// no-op instead of stacking an identical card behind the first. The flag lives
/// on the state (not in a static) so a new session starts clean.
Future<void> showUpdateDialog(
  BuildContext context,
  AppState state,
  AppRelease release,
) async {
  final String version = release.version.normalized;
  if (state.updateDialogVersion == version) return;
  state.updateDialogVersion = version;
  try {
    final bool? skipped = await showAppleDialog<bool>(
      context: context,
      builder: (BuildContext context) =>
          _UpdateDialog(state: state, release: release),
    );
    if (skipped == true && context.mounted) {
      _notice(context, context.tr('已跳过 $version'));
    }
  } finally {
    if (state.updateDialogVersion == version) {
      state.updateDialogVersion = null;
    }
  }
}

/// Shows an already-translated message.
void _notice(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

class _UpdateDialog extends StatelessWidget {
  const _UpdateDialog({required this.state, required this.release});

  final AppState state;
  final AppRelease release;

  Future<void> _skip(BuildContext context) async {
    await state.skipUpdate(release);
    if (context.mounted) Navigator.of(context).pop(true);
  }

  Future<void> _open(BuildContext context) async {
    final bool opened = await openExternalUrl(release.url);
    if (!context.mounted) return;
    if (opened) {
      Navigator.of(context).pop(false);
      return;
    }
    _notice(context, context.tr('无法打开浏览器，请手动访问 ${release.url}'));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String notes = release.notes.trim();
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 14, 24, 8),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      title: Row(
        children: <Widget>[
          Icon(Icons.system_update_alt_rounded, color: scheme.primary),
          const SizedBox(width: 12),
          Expanded(child: Text(context.tr('发现新版本'))),
          if (release.prerelease)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: .14),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                context.tr('预发布版本'),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              release.name,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              context.tr(
                '当前版本 ${BuildInfo.version}，最新版本 ${release.version.normalized}',
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (notes.isNotEmpty) ...<Widget>[
              const SizedBox(height: 14),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withValues(alpha: .5),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      notes,
                      style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            SelectableText(
              release.url,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        SpringTextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const TrText('稍后'),
        ),
        SpringTextButton(
          onPressed: () => _skip(context),
          child: const TrText('跳过此版本'),
        ),
        SpringFilledButton(
          autofocus: TvScope.isActive(context),
          onPressed: () => _open(context),
          child: const TrText('前往下载'),
        ),
      ],
    );
  }
}
