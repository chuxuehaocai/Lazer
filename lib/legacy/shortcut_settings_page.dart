import 'dart:async';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../state/media_shortcuts.dart';
import '../widgets/apple_ui.dart';
import '../widgets/settings_detail.dart';
import '../widgets/shortcut_recorder_dialog.dart';

class ShortcutSettingsPage extends StatelessWidget {
  const ShortcutSettingsPage({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => ShortcutSettingsView(state: state);
}

class ShortcutSettingsView extends StatelessWidget {
  const ShortcutSettingsView({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state,
    builder: (context, _) {
      final customised = MediaShortcutAction.values.any(
        (action) =>
            state.mediaShortcuts[action] != kDefaultMediaShortcuts[action],
      );
      return SettingsDetailScaffold(
        title: '快捷键设置',
        actions: [
          TextButton(
            key: const ValueKey('media-shortcut-reset'),
            onPressed: customised
                ? () => unawaited(state.resetMediaShortcuts())
                : null,
            child: const TrText('恢复默认'),
          ),
        ],
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: TrText('在应用内用键盘控制播放；在文本框中输入时快捷键不会触发'),
                ),
                AppleGroupedCard(
                  child: Column(
                    children: [
                      for (final action in MediaShortcutAction.values)
                        AppleListTile(
                          title: context.tr(action.label),
                          subtitle: context.tr(action.detail),
                          trailing: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: (MediaQuery.sizeOf(context).width * .45)
                                  .clamp(100, 300),
                            ),
                            child: OutlinedButton(
                              key: ValueKey('media-shortcut-${action.name}'),
                              onPressed: () => unawaited(
                                _editMediaShortcut(context, state, action),
                              ),
                              child: Text(
                                state.mediaShortcutFor(action)?.label ??
                                    context.tr('未设置'),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

Future<void> _editMediaShortcut(
  BuildContext context,
  AppState state,
  MediaShortcutAction action,
) async {
  final ShortcutSelection? selection = await showShortcutRecorderDialog(
    context,
    action: action,
    current: state.mediaShortcutFor(action),
    conflict: (MediaShortcutBinding binding) => mediaShortcutConflict(
      state.mediaShortcuts,
      action: action,
      binding: binding,
    ),
  );
  if (selection == null) return;
  if (selection.cleared) {
    await state.setMediaShortcut(action, null);
    return;
  }
  final MediaShortcutBinding? binding = selection.binding;
  if (binding == null) return;
  if (mediaShortcutConflict(
        state.mediaShortcuts,
        action: action,
        binding: binding,
      ) !=
      null) {
    return;
  }
  await state.setMediaShortcut(action, binding);
}
