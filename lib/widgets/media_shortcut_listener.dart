import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../state/app_state.dart';
import '../state/media_shortcuts.dart';

/// Handles globally configured media shortcuts after the focused control.
///
/// The focus manager keeps the handler available across navigator routes while
/// letting buttons, sliders and menus consume their own keys first. Text fields
/// are skipped, and a recorder dialog suspends it while capturing a combination.
class MediaShortcutListener extends StatefulWidget {
  const MediaShortcutListener({
    super.key,
    required this.state,
    required this.child,
  });

  final AppState state;
  final Widget child;

  @override
  State<MediaShortcutListener> createState() => _MediaShortcutListenerState();
}

class _MediaShortcutListenerState extends State<MediaShortcutListener> {
  @override
  void initState() {
    super.initState();
    FocusManager.instance.addLateKeyEventHandler(_handleKey);
  }

  @override
  void dispose() {
    FocusManager.instance.removeLateKeyEventHandler(_handleKey);
    super.dispose();
  }

  KeyEventResult _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent || event.synthesized) {
      return KeyEventResult.ignored;
    }
    if (MediaShortcutRecorder.active || _isEditingText()) {
      return KeyEventResult.ignored;
    }

    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    final MediaShortcutBinding pressed = MediaShortcutBinding(
      event.logicalKey,
      control: keyboard.isControlPressed,
      alt: keyboard.isAltPressed,
      shift: keyboard.isShiftPressed,
      meta: keyboard.isMetaPressed,
    );
    final MediaShortcutAction? action = mediaShortcutActionFor(
      widget.state.mediaShortcuts,
      pressed,
    );
    if (action == null) return KeyEventResult.ignored;
    _perform(action);
    return KeyEventResult.handled;
  }

  void _perform(MediaShortcutAction action) {
    final AppState state = widget.state;
    switch (action) {
      case MediaShortcutAction.playPause:
        state.togglePlay();
      case MediaShortcutAction.previousTrack:
        state.previous();
      case MediaShortcutAction.nextTrack:
        state.next();
      case MediaShortcutAction.seekBackward:
        state.seekBy(const Duration(seconds: -5));
      case MediaShortcutAction.seekForward:
        state.seekBy(const Duration(seconds: 5));
      case MediaShortcutAction.volumeDown:
        unawaited(state.adjustVolume(-0.05));
      case MediaShortcutAction.volumeUp:
        unawaited(state.adjustVolume(0.05));
      case MediaShortcutAction.mute:
        unawaited(state.toggleMute());
    }
  }

  bool _isEditingText() {
    final BuildContext? context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    if (context.widget is EditableText) return true;
    return context.findAncestorStateOfType<EditableTextState>() != null;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
