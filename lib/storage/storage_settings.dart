import 'dart:io';

import 'package:flutter/material.dart';

import '../animation/apple_modal.dart';
import '../l10n/app_localizations.dart';
import '../widgets/apple_ui.dart';
import '../widgets/spring_buttons.dart';
import 'all_files_access.dart';
import 'app_storage.dart';

class StorageSettings extends StatefulWidget {
  const StorageSettings({
    super.key,
    this.storage,
    this.access = const AllFilesAccess(),
  });
  final AppStorage? storage;
  final AllFilesAccess access;

  @override
  State<StorageSettings> createState() => _StorageSettingsState();
}

class _StorageSettingsState extends State<StorageSettings>
    with WidgetsBindingObserver {
  AppStorage get storage => widget.storage ?? AppStorage.shared;
  bool _granted = false, _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  Future<void> _refresh() async {
    final granted = await widget.access.hasAccess();
    if (mounted) setState(() => _granted = granted);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<bool> _grant() async {
    final granted =
        await widget.access.hasAccess() || await widget.access.requestAccess();
    if (mounted) setState(() => _granted = granted);
    return granted;
  }

  Future<void> _change() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (!await _grant() || !mounted) return;
      final selected = await showAppleDialog<String>(
        context: context,
        builder: (_) => _DataDirectoryDialog(
          initialPath: storage.requestedRoot ?? '/sdcard/Lazer',
        ),
      );
      if (selected == null || selected.isEmpty) return;
      await storage.schedule(selected);
    } on FileSystemException catch (_) {
      if (mounted) _message();
    } on FormatException catch (_) {
      if (mounted) _message();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message() => ScaffoldMessenger.of(
    context,
  ).showSnackBar(const SnackBar(content: TrText('无法使用该文件夹，请检查路径和所有文件访问权限。')));

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppleGroupedCard(
    margin: EdgeInsets.zero,
    child: Column(
      children: [
        AppleListTile(
          title: context.tr('所有文件访问权限'),
          subtitle: context.tr(
            _granted ? '已授权，可访问共享存储文件夹' : '允许访问 /sdcard 下的音乐与数据文件夹',
          ),
          trailing: SpringTextButton(
            key: const ValueKey('grant-all-files-access'),
            onPressed: _busy ? null : _grant,
            child: TrText(_granted ? '已授权' : '授权'),
          ),
        ),
        AppleListTile(
          title: context.tr('数据保存路径'),
          subtitle: storage.requestedRoot ?? context.tr('应用默认目录'),
          trailing: Wrap(
            children: [
              if (storage.requestedRoot != null)
                SpringTextButton(
                  key: const ValueKey('reset-data-directory'),
                  onPressed: _busy
                      ? null
                      : () async {
                          await storage.schedule(null);
                          if (mounted) setState(() {});
                        },
                  child: const TrText('恢复默认'),
                ),
              SpringTextButton(
                key: const ValueKey('change-data-directory'),
                onPressed: _busy ? null : _change,
                child: const TrText('更改'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: TrText(
            storage.error != null
                ? storage.usingDefaultFallback
                      ? '数据目录不可用，暂用应用默认目录。请检查权限和可用空间。'
                      : '数据迁移失败，仍使用原目录。请检查权限和可用空间。'
                : storage.requiresRestart
                ? '重启应用后生效，已有数据将迁移到新目录。'
                : '保存缓存、歌词、导入的字体和本地音乐索引。',
          ),
        ),
      ],
    ),
  );
}

class _DataDirectoryDialog extends StatefulWidget {
  const _DataDirectoryDialog({required this.initialPath});
  final String initialPath;

  @override
  State<_DataDirectoryDialog> createState() => _DataDirectoryDialogState();
}

class _DataDirectoryDialogState extends State<_DataDirectoryDialog> {
  late final _controller = TextEditingController(text: widget.initialPath);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const TrText('数据保存路径'),
    content: SizedBox(
      width: 420,
      child: TextField(
        key: const ValueKey('data-directory-input'),
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          hintText: '/sdcard/Lazer',
          labelText: context.tr('文件夹绝对路径'),
        ),
      ),
    ),
    actions: [
      SpringTextButton(
        onPressed: () => Navigator.pop(context),
        child: const TrText('取消'),
      ),
      SpringFilledButton(
        key: const ValueKey('save-data-directory'),
        onPressed: () => Navigator.pop(context, _controller.text.trim()),
        child: const TrText('保存'),
      ),
    ],
  );
}
