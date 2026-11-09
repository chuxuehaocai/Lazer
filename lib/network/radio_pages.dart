import 'package:flutter/material.dart';

import '../animation/apple_modal.dart';
import '../l10n/app_localizations.dart';
import '../widgets/spring_buttons.dart';
import 'network_sources_controller.dart';
import 'network_widgets.dart';
import 'radio_station.dart';

/// What the station editor collects.
class RadioStationDraft {
  const RadioStationDraft({
    required this.name,
    required this.url,
    this.genre = '',
  });

  final String name;
  final String url;
  final String genre;
}

/// Add/edit dialog for one internet radio station.
///
/// Returns null when dismissed; the caller persists the draft through
/// [NetworkSourcesController] so the URL check happens in one place.
Future<RadioStationDraft?> showRadioStationDialog(
  BuildContext context, {
  required NetworkSourcesController controller,
  RadioStation? station,
}) => showAppleDialog<RadioStationDraft>(
  context: context,
  builder: (BuildContext dialogContext) => _RadioStationDialog(
    controller: controller,
    station: station,
  ),
);

class _RadioStationDialog extends StatefulWidget {
  const _RadioStationDialog({required this.controller, this.station});

  final NetworkSourcesController controller;
  final RadioStation? station;

  @override
  State<_RadioStationDialog> createState() => _RadioStationDialogState();
}

class _RadioStationDialogState extends State<_RadioStationDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.station?.name ?? '',
  );
  late final TextEditingController _url = TextEditingController(
    text: widget.station?.url ?? '',
  );
  late final TextEditingController _genre = TextEditingController(
    text: widget.station?.genre ?? '',
  );
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _genre.dispose();
    super.dispose();
  }

  void _submit() {
    final String url = _url.text.trim();
    final Uri? parsed = Uri.tryParse(url);
    if (url.isEmpty ||
        parsed == null ||
        (parsed.scheme != 'http' && parsed.scheme != 'https')) {
      setState(
        () => _error = context.tr('请填写以 http 或 https 开头的流地址。'),
      );
      return;
    }
    String name = _name.text.trim();
    if (name.isEmpty) name = parsed.host;
    Navigator.of(context).pop(
      RadioStationDraft(
        name: name,
        url: url,
        genre: _genre.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        context.tr(widget.station == null ? '添加电台' : '编辑电台'),
      ),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              NetworkField(
                label: '名称',
                hint: '留空时使用域名',
                controller: _name,
                fieldKey: const ValueKey<String>('radio-field-name'),
              ),
              NetworkField(
                label: '流地址',
                hint: 'https://example.com/stream.mp3',
                controller: _url,
                keyboardType: TextInputType.url,
                fieldKey: const ValueKey<String>('radio-field-url'),
              ),
              NetworkField(
                label: '类型（可选）',
                hint: '爵士、新闻、古典…',
                controller: _genre,
                fieldKey: const ValueKey<String>('radio-field-genre'),
                onSubmitted: (String _) => _submit(),
              ),
              NetworkErrorText(error: _error, padding: EdgeInsets.zero),
            ],
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
      actions: <Widget>[
        SpringTextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const TrText('取消'),
        ),
        SpringFilledButton(
          key: const ValueKey<String>('radio-save'),
          onPressed: _submit,
          child: const TrText('保存'),
        ),
      ],
    );
  }
}
