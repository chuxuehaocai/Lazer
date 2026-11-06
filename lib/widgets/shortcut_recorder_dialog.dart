import 'build_safe_state.dart';
import 'spring_buttons.dart';
import 'package:flutter/material.dart';
import '../animation/apple_modal.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../state/media_shortcuts.dart';
import '../theme/apple_design.dart';

/// What the recorder returns. A null result means the dialog was dismissed.
class ShortcutSelection {
  const ShortcutSelection.set(MediaShortcutBinding this.binding)
    : cleared = false;

  const ShortcutSelection.clear() : binding = null, cleared = true;

  final MediaShortcutBinding? binding;
  final bool cleared;
}

/// Captures one key combination for [action] and validates it against the
/// combinations already used by the other media actions.
Future<ShortcutSelection?> showShortcutRecorderDialog(
  BuildContext context, {
  required MediaShortcutAction action,
  required MediaShortcutBinding? current,
  required MediaShortcutAction? Function(MediaShortcutBinding binding) conflict,
}) => showAppleDialog<ShortcutSelection>(
  context: context,
  builder: (BuildContext context) => _ShortcutRecorderDialog(
    action: action,
    current: current,
    conflict: conflict,
  ),
);

class _ShortcutRecorderDialog extends StatefulWidget {
  const _ShortcutRecorderDialog({
    required this.action,
    required this.current,
    required this.conflict,
  });

  final MediaShortcutAction action;
  final MediaShortcutBinding? current;
  final MediaShortcutAction? Function(MediaShortcutBinding binding) conflict;

  @override
  State<_ShortcutRecorderDialog> createState() =>
      _ShortcutRecorderDialogState();
}

class _ShortcutRecorderDialogState extends State<_ShortcutRecorderDialog>
    with BuildSafeState<_ShortcutRecorderDialog> {
  final FocusNode _focus = FocusNode(debugLabel: 'media-shortcut-recorder');
  MediaShortcutBinding? _candidate;
  MediaShortcutAction? _conflict;
  bool _listening = true;

  @override
  void initState() {
    super.initState();
    // The global listener would otherwise fire an old binding while the new
    // one is being recorded.
    MediaShortcutRecorder.begin();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    MediaShortcutRecorder.end();
    _focus.dispose();
    super.dispose();
  }

  void _listenAgain() {
    setState(() {
      _candidate = null;
      _conflict = null;
      _listening = true;
    });
    _focus.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || !_listening) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.tab) {
      // Escape closes the dialog; Tab keeps the buttons reachable.
      return KeyEventResult.ignored;
    }
    if (isMediaShortcutModifierKey(key)) return KeyEventResult.handled;

    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    final MediaShortcutBinding binding = MediaShortcutBinding(
      key,
      control: keyboard.isControlPressed,
      alt: keyboard.isAltPressed,
      shift: keyboard.isShiftPressed,
      meta: keyboard.isMetaPressed,
    );
    setState(() {
      _candidate = binding;
      _conflict = widget.conflict(binding);
      _listening = false;
    });
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final MediaShortcutBinding? candidate = _candidate;
    final bool canSave = candidate != null && !_listening && _conflict == null;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: AlertDialog(
        title: const TrText('设置快捷键'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                context.tr(widget.action.label),
                style: theme.textTheme.titleMedium?.copyWith(
                  color: apple.label,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                context.tr(widget.action.detail),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: apple.secondaryLabel,
                ),
              ),
              const SizedBox(height: 18),
              Container(
                key: const ValueKey<String>('shortcut-recorder-target'),
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 16,
                ),
                decoration: BoxDecoration(
                  color: apple.secondaryFill,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _listening
                        ? Theme.of(context).colorScheme.primary
                        : apple.separator,
                  ),
                ),
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.keyboard_rounded,
                      size: 20,
                      color: apple.secondaryLabel,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _listening
                            ? context.tr('请按下新的快捷键…')
                            : (candidate?.label ?? context.tr('未设置')),
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: _listening
                              ? apple.secondaryLabel
                              : apple.label,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_conflict != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  context.tr('已用于「${context.tr(_conflict!.label)}」'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
              if (!_listening && candidate != null) ...<Widget>[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: SpringTextButton.icon(
                    key: const ValueKey<String>('shortcut-record-again'),
                    onPressed: _listenAgain,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const TrText('重新录入'),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: <Widget>[
          if (widget.current != null)
            SpringTextButton(
              key: const ValueKey<String>('shortcut-clear'),
              onPressed: () =>
                  Navigator.of(context).pop(const ShortcutSelection.clear()),
              child: const TrText('清除'),
            ),
          SpringTextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const TrText('取消'),
          ),
          SpringFilledButton(
            key: const ValueKey<String>('shortcut-save'),
            onPressed: canSave
                ? () => Navigator.of(
                    context,
                  ).pop(ShortcutSelection.set(candidate))
                : null,
            child: const TrText('保存'),
          ),
        ],
      ),
    );
  }
}
