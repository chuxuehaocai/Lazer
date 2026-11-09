import 'dart:async';

import 'package:flutter/material.dart';

import '../animation/apple_modal.dart';
import '../l10n/app_localizations.dart';
import '../theme/apple_design.dart';
import '../widgets/spring_buttons.dart';
import 'podcast_feed.dart';
import 'remote_source.dart';

/// Glyph that identifies a protocol in every list and editor.
IconData networkKindIcon(NetworkSourceKind kind) => switch (kind) {
  NetworkSourceKind.webdav => Icons.cloud_queue_rounded,
  NetworkSourceKind.smb => Icons.folder_shared_rounded,
  NetworkSourceKind.sftp => Icons.terminal_rounded,
  NetworkSourceKind.ftp => Icons.dns_rounded,
};

/// The sentence an error carries, translated at the render site. State layers
/// keep the Chinese source string; this is where it becomes interface text.
String networkErrorSentence(BuildContext context, Object? error) {
  if (error == null) return '';
  if (error is RemoteFailure) {
    final String detail = error.diagnostic;
    final String message = context.tr(error.message);
    return detail.isEmpty ? message : '$message（$detail）';
  }
  if (error is PodcastFeedException) {
    final String message = context.tr(error.message);
    return error.detail == null || error.detail!.isEmpty
        ? message
        : '$message（${error.detail}）';
  }
  if (error is String) return context.tr(error);
  return context.tr('操作失败，请稍后重试。');
}

/// A compact, translatable error row used under a source or a form.
class NetworkErrorText extends StatelessWidget {
  const NetworkErrorText({super.key, required this.error, this.padding});

  final Object? error;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    if (error == null) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: padding ?? const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            Icons.error_outline_rounded,
            size: 15,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              networkErrorSentence(context, error),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A labelled text field that matches the app's grouped forms.
class NetworkField extends StatelessWidget {
  const NetworkField({
    super.key,
    required this.label,
    required this.controller,
    this.hint,
    this.obscure = false,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
    this.autofocus = false,
    this.enabled = true,
    this.fieldKey,
  });

  final String label;
  final TextEditingController controller;
  final String? hint;
  final bool obscure;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final bool enabled;
  final Key? fieldKey;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            context.tr(label),
            style: theme.textTheme.labelMedium?.copyWith(
              color: apple.secondaryLabel,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 5),
          TextField(
            key: fieldKey,
            controller: controller,
            enabled: enabled,
            obscureText: obscure,
            keyboardType: keyboardType,
            textInputAction: textInputAction,
            autofocus: autofocus,
            onSubmitted: onSubmitted,
            style: theme.textTheme.bodyMedium?.copyWith(color: apple.label),
            decoration: InputDecoration(
              hintText: hint == null ? null : context.tr(hint!),
              isDense: true,
              filled: true,
              fillColor: apple.fill,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 11,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: apple.separator, width: .5),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: apple.separator, width: .5),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: apple.accent, width: 1.4),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A back chevron for pages that are pushed on top of the shell.
class NetworkBackButton extends StatelessWidget {
  const NetworkBackButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: IconButton(
        tooltip: context.tr('返回'),
        onPressed: onPressed,
        style: IconButton.styleFrom(
          backgroundColor: apple.fill,
          minimumSize: const Size(38, 38),
        ),
        icon: Icon(Icons.chevron_left_rounded, color: apple.label, size: 24),
      ),
    );
  }
}

/// One prompt with a single text field: used for a feed address, a playlist
/// address and a station URL.
Future<String?> showNetworkTextPrompt(
  BuildContext context, {
  required String title,
  required String label,
  String? hint,
  String initialValue = '',
  String confirmLabel = '保存',
  bool obscure = false,
  String? description,
}) {
  final TextEditingController controller = TextEditingController(
    text: initialValue,
  );
  return showAppleDialog<String>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: Text(context.tr(title)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (description != null) ...<Widget>[
              Text(
                context.tr(description),
                style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                  color: AppleSemanticColors.of(dialogContext).secondaryLabel,
                ),
              ),
              const SizedBox(height: 12),
            ],
            NetworkField(
              label: label,
              hint: hint,
              controller: controller,
              obscure: obscure,
              autofocus: true,
              onSubmitted: (String value) =>
                  Navigator.of(dialogContext).pop(value.trim()),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        SpringTextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const TrText('取消'),
        ),
        SpringFilledButton(
          onPressed: () =>
              Navigator.of(dialogContext).pop(controller.text.trim()),
          child: TrText(confirmLabel),
        ),
      ],
    ),
  ).whenComplete(controller.dispose);
}

/// Shows a translated snack bar for a network action.
void showNetworkMessage(
  BuildContext context,
  String message, {
  bool error = false,
}) {
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final ThemeData theme = Theme.of(context);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(context.tr(message)),
        backgroundColor: error ? theme.colorScheme.errorContainer : null,
        // The text stays readable on both the light and the error surface.
        duration: const Duration(seconds: 4),
      ),
    );
}

/// A row that shows a small spinner where its label normally sits.
class NetworkProgressLabel extends StatelessWidget {
  const NetworkProgressLabel({super.key, this.size = 14});

  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: const CircularProgressIndicator(strokeWidth: 2),
  );
}

/// Reports long work (a scan, a feed refresh) without blocking the page.
class NetworkBusyBanner extends StatelessWidget {
  const NetworkBusyBanner({
    super.key,
    required this.message,
    this.detail,
    this.onCancel,
  });

  final String message;
  final String? detail;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 10),
      child: Row(
        children: <Widget>[
          const SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  context.tr(message),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: apple.secondaryLabel,
                  ),
                ),
                if (detail != null && detail!.isNotEmpty)
                  Text(
                    detail!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: apple.tertiaryLabel,
                    ),
                  ),
              ],
            ),
          ),
          if (onCancel != null)
            SpringTextButton(
              onPressed: onCancel,
              child: const TrText('取消'),
            ),
        ],
      ),
    );
  }
}

/// The standard `MM-dd HH:mm` stamp the network lists show.
String formatNetworkDate(BuildContext context, DateTime? value) {
  if (value == null) return '';
  final DateTime local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
