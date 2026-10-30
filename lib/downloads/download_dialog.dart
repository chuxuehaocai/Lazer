import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../data/audio_quality.dart';
import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../lyrics/lyrics_import.dart';
import '../state/app_state.dart';
import '../theme/apple_design.dart';
import 'download_manager.dart';
import 'download_queue_sheet.dart';

class DownloadRequest {
  const DownloadRequest({
    required this.quality,
    required this.directory,
    this.folderName,
  });

  final AudioQuality quality;
  final String directory;
  final String? folderName;
}

/// Asks for the quality and destination of a download. Returns null when the
/// user cancels. [folderName] is offered as an optional album/playlist folder.
Future<DownloadRequest?> showDownloadDialog(
  BuildContext context,
  AppState state, {
  required List<Track> tracks,
  String? folderName,
}) {
  if (tracks.isEmpty) return Future<DownloadRequest?>.value(null);
  return showDialog<DownloadRequest>(
    context: context,
    builder: (BuildContext context) =>
        _DownloadDialog(state: state, tracks: tracks, folderName: folderName),
  );
}

/// Right-click / long-press menu for a track row.
Future<void> showTrackActions(
  BuildContext context,
  AppState state,
  Track track,
  Offset globalPosition,
) async {
  final bool downloadable = track.isServiceTrack;
  final RenderBox? overlay =
      Overlay.of(context).context.findRenderObject() as RenderBox?;
  final bool hasImportedLyrics = await state.importedLyrics.has(track);
  if (!context.mounted || overlay == null) return;
  final String? action = await showMenu<String>(
    context: context,
    position: RelativeRect.fromRect(
      Rect.fromPoints(globalPosition, globalPosition),
      Offset.zero & overlay.size,
    ),
    items: <PopupMenuEntry<String>>[
      if (downloadable)
        PopupMenuItem<String>(value: 'download', child: TrText('下载歌曲')),
      if (!downloadable)
        PopupMenuItem<String>(
          value: 'download',
          enabled: false,
          child: TrText('本地歌曲无需下载'),
        ),
      const PopupMenuDivider(),
      PopupMenuItem<String>(value: 'import-lyrics', child: TrText('导入歌词…')),
      if (hasImportedLyrics)
        PopupMenuItem<String>(value: 'remove-lyrics', child: TrText('移除导入歌词')),
    ],
  );
  if (!context.mounted) return;
  switch (action) {
    case 'download':
      if (downloadable) {
        await downloadTracks(context, state, <Track>[track]);
      }
    case 'import-lyrics':
      await pickAndImportLyrics(context, state, track: track);
    case 'remove-lyrics':
      await removeImportedLyrics(context, state, track);
  }
}

/// Opens the download dialog, queues the tracks and offers the queue in a
/// snack bar action.
Future<void> downloadTracks(
  BuildContext context,
  AppState state,
  List<Track> tracks, {
  String? folderName,
}) async {
  final List<Track> downloadable = tracks
      .where((Track track) => track.isServiceTrack)
      .toList();
  if (downloadable.isEmpty) return;
  final DownloadRequest? request = await showDownloadDialog(
    context,
    state,
    tracks: downloadable,
    folderName: folderName,
  );
  if (request == null || !context.mounted) return;
  state.downloadManager.enqueue(
    downloadable,
    quality: request.quality,
    directory: request.directory,
    folderName: request.folderName,
  );
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(
      content: Text(
        context.tr(
          downloadable.length == 1
              ? '已加入下载队列'
              : '已加入 ${downloadable.length} 首歌曲',
        ),
      ),
      action: SnackBarAction(
        label: context.tr('查看'),
        onPressed: () => showDownloadQueueSheet(context, state),
      ),
    ),
  );
}

class _DownloadDialog extends StatefulWidget {
  const _DownloadDialog({
    required this.state,
    required this.tracks,
    this.folderName,
  });

  final AppState state;
  final List<Track> tracks;
  final String? folderName;

  @override
  State<_DownloadDialog> createState() => _DownloadDialogState();
}

class _DownloadDialogState extends State<_DownloadDialog> {
  late AudioQuality _quality = widget.state.downloadQuality;
  String? _directory;
  late bool _createFolder =
      widget.folderName != null && widget.folderName!.trim().isNotEmpty;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _directory = widget.state.downloadDirectory;
    _resolveDefaultDirectory();
  }

  bool get _canPickDirectory =>
      !kIsWeb && defaultTargetPlatform != TargetPlatform.iOS;

  Future<void> _resolveDefaultDirectory() async {
    final String? remembered = widget.state.downloadDirectory;
    if (remembered != null && remembered.trim().isNotEmpty) {
      _directory = remembered;
      return;
    }
    final String? fallback = await defaultDownloadDirectory();
    if (!mounted) return;
    setState(() => _directory ??= fallback);
  }

  Future<void> _pickDirectory() async {
    try {
      final String? picked = await getDirectoryPath(
        confirmButtonText: context.tr('选择'),
      );
      if (picked == null || !mounted) return;
      setState(() {
        _directory = picked;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '无法打开目录选择器'); // i18n:key
    }
  }

  Future<void> _confirm() async {
    final String? directory = _directory;
    if (directory == null || directory.trim().isEmpty) {
      setState(() => _error = '请选择保存目录'); // i18n:key
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Directory(directory).create(recursive: true);
      final File probe = File(
        '$directory${Platform.pathSeparator}.lazer_write_test',
      );
      await probe.writeAsString('ok');
      await probe.delete();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '这个目录不可写，请换一个位置'; // i18n:key
      });
      return;
    }
    await widget.state.setDownloadQuality(_quality);
    await widget.state.setDownloadDirectory(directory);
    if (!mounted) return;
    Navigator.of(context).pop(
      DownloadRequest(
        quality: _quality,
        directory: directory,
        folderName: _createFolder ? widget.folderName : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final Duration total = widget.tracks.fold<Duration>(
      Duration.zero,
      (Duration sum, Track track) => sum + track.duration,
    );
    final int estimate = _quality.estimatedBytes(total);
    return AlertDialog(
      title: TrText(
        widget.tracks.length == 1 ? '下载歌曲' : '下载 ${widget.tracks.length} 首歌曲',
      ),
      content: SizedBox(
        width: 430,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                context.tr('下载音质'),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: apple.secondaryLabel,
                ),
              ),
              const SizedBox(height: 4),
              RadioGroup<AudioQuality>(
                groupValue: _quality,
                onChanged: (AudioQuality? value) {
                  if (_busy || value == null) return;
                  setState(() => _quality = value);
                },
                child: Column(
                  children: <Widget>[
                    for (final AudioQuality quality in AudioQuality.values)
                      RadioListTile<AudioQuality>(
                        key: ValueKey<String>(
                          'download-quality-${quality.name}',
                        ),
                        value: quality,
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(
                          '${context.tr(widget.state.audioQualityLabel(quality))}  ${context.tr(widget.state.audioQualityBitrate(quality))}',
                        ),
                        subtitle: Text(
                          context.tr(widget.state.audioQualityDetail(quality)),
                        ),
                      ),
                  ],
                ),
              ),
              Divider(height: 18, color: apple.separator),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          context.tr('保存到'),
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: apple.secondaryLabel,
                          ),
                        ),
                        Text(
                          _directory ?? context.tr('正在准备目录…'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  if (_canPickDirectory)
                    TextButton(
                      onPressed: _busy ? null : _pickDirectory,
                      child: TrText('选择…'),
                    ),
                ],
              ),
              if (widget.folderName != null &&
                  widget.folderName!.trim().isNotEmpty)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _createFolder,
                  title: Text(
                    context.tr('创建「${widget.folderName!.trim()}」文件夹'),
                  ),
                  onChanged: _busy
                      ? null
                      : (bool value) => setState(() => _createFolder = value),
                ),
              if (total > Duration.zero)
                Text(
                  context.tr(
                    '预计占用 ${formatBytes(estimate)}（按 ${_quality.bitrateLabel} 估算）',
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: apple.secondaryLabel,
                  ),
                ),
              if (_quality.requiresVip)
                Text(
                  context.tr('无损音质需要黑胶会员；无权限时会自动降级。'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: apple.secondaryLabel,
                  ),
                ),
              if (_error != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  context.tr(_error!),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: TrText('取消'),
        ),
        FilledButton(
          key: const ValueKey<String>('download-confirm'),
          onPressed: _busy ? null : _confirm,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : TrText('下载'),
        ),
      ],
    );
  }
}

/// Default destination: the user's Downloads directory on desktop, an app
/// Documents sub-folder on mobile (iOS has no directory picker).
Future<String?> defaultDownloadDirectory() async {
  try {
    if (!kIsWeb &&
        defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      final Directory? downloads = await getDownloadsDirectory();
      if (downloads != null) return downloads.path;
    }
    final Directory documents = await getApplicationDocumentsDirectory();
    return '${documents.path}${Platform.pathSeparator}Lazer Downloads';
  } catch (_) {
    return null;
  }
}
