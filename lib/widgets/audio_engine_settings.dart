import 'spring_buttons.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../audio/native/imported_engine.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import 'apple_ui.dart';
import 'settings_choice.dart';
import 'settings_row.dart';

class AudioEngineSettings extends StatefulWidget {
  const AudioEngineSettings({super.key, required this.state});
  final AppState state;

  @override
  State<AudioEngineSettings> createState() => _AudioEngineSettingsState();
}

class _AudioEngineSettingsState extends State<AudioEngineSettings> {
  bool _importing = false;
  String? _error;

  Future<void> _import() async {
    setState(() {
      _importing = true;
      _error = null;
    });
    try {
      final String? path = await importAudioEngine();
      if (path != null) {
        await widget.state.setImportedEnginePath(path);
        await widget.state.setHifiSettings(
          widget.state.hifiSettings.copyWith(preferNativeEngine: true),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) => AppleGroupedCard(
    margin: const EdgeInsets.only(bottom: SettingsSpacing.groupGap),
    child: Column(
      children: [
        SettingsRow(
          label: '音频引擎', // i18n:key
          subtitle: '切换引擎或导入后，下次启动应用时生效', // i18n:key
          expandControl: true,
          trailing: SettingsChoice<bool>(
            key: const ValueKey('audio-engine-choice'),
            value: widget.state.hifiSettings.preferNativeEngine,
            items: const [
              DropdownMenuItem(value: true, child: TrText('Audio Engine')),
              DropdownMenuItem(value: false, child: TrText('系统音频引擎')),
            ],
            onChanged: (value) {
              if (value != null) {
                unawaited(
                  widget.state.setHifiSettings(
                    widget.state.hifiSettings.copyWith(
                      preferNativeEngine: value,
                    ),
                  ),
                );
              }
            },
          ),
        ),
        AppleListTile(
          padding: SettingsSpacing.rowPadding,
          minHeight: SettingsSpacing.rowMinHeight,
          title: context.tr('导入 Audio Engine'),
          subtitle: context.tr(
            widget.state.importedEnginePath == null
                ? '使用应用内置引擎，可导入当前平台的引擎和依赖库'
                : '已选择导入的引擎',
          ),
          trailing: SpringTextButton(
            key: const ValueKey('import-audio-engine'),
            onPressed: _importing ? null : _import,
            child: TrText(_importing ? '导入中' : '选择文件'),
          ),
        ),
        if (widget.state.importedEnginePath != null)
          AppleListTile(
            padding: SettingsSpacing.rowPadding,
            minHeight: SettingsSpacing.rowMinHeight,
            title: context.tr('恢复内置引擎'),
            onTap: () => unawaited(widget.state.setImportedEnginePath(null)),
            trailing: const Icon(Icons.chevron_right_rounded),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    ),
  );
}
