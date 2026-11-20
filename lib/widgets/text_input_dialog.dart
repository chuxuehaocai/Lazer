import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'spring_buttons.dart';

/// Owns the editing resources until the dialog's exit animation unmounts it.
class AppTextInputDialog extends StatefulWidget {
  const AppTextInputDialog({
    super.key,
    required this.title,
    required this.initialValue,
    this.hintText,
    this.maxLines = 1,
    this.maxLength,
    this.labelText,
    this.description,
    this.obscureText = false,
    this.confirmLabel = '保存',
  });

  final String title;
  final String initialValue;
  final String? hintText;
  final int maxLines;
  final int? maxLength;
  final String? labelText;
  final String? description;
  final bool obscureText;
  final String confirmLabel;

  @override
  State<AppTextInputDialog> createState() => _AppTextInputDialogState();
}

class _AppTextInputDialogState extends State<AppTextInputDialog> {
  late final _controller = TextEditingController(text: widget.initialValue);
  bool _closing = false;

  void _close([String? value]) {
    if (_closing || ModalRoute.of(context)?.isCurrent != true) return;
    _closing = true;
    FocusManager.instance.primaryFocus?.unfocus(
      disposition: UnfocusDisposition.scope,
    );
    Navigator.of(context).pop(value);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(widget.title),
    content: SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.description != null) ...[
            Text(
              widget.description!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _controller,
            autofocus: true,
            obscureText: widget.obscureText,
            maxLines: widget.maxLines,
            maxLength: widget.maxLength,
            decoration: InputDecoration(
              hintText: widget.hintText,
              labelText: widget.labelText,
            ),
            onSubmitted: widget.maxLines == 1 ? _close : null,
          ),
        ],
      ),
    ),
    actions: [
      SpringTextButton(onPressed: _close, child: const TrText('取消')),
      SpringFilledButton(
        onPressed: () => _close(_controller.text),
        child: TrText(widget.confirmLabel),
      ),
    ],
  );
}
