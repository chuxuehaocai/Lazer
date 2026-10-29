import 'dart:async';

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../legacy/legacy_widgets.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../theme/apple_design.dart';
import '../utils/byte_format.dart';
import '../widgets/apple_ui.dart';
import 'local_library.dart';
import 'local_music_import.dart';
import 'local_music_scan.dart';

/// Runs one import pass and reports it in a snack bar.
///
/// Shared by the library entry and the local-music page so both surfaces pick,
/// probe, index and report the same way.
Future<LocalImportResult?> runLocalImport(
  BuildContext context,
  AppState state,
  LocalMusicImporter importer,
) async {
  try {
    final LocalImportResult result = await importer.importInto(
      state.localLibrary,
    );
    if (context.mounted) showLocalImportResult(context, result);
    return result;
  } on LocalImportException catch (error) {
    if (context.mounted) _showLocalMessage(context, error.message);
  } catch (_) {
    if (context.mounted) _showLocalMessage(context, '导入失败，请重试。');
  }
  return null;
}

/// Snack-bar copy for a finished import pass.
void showLocalImportResult(BuildContext context, LocalImportResult result) {
  final List<String> parts = <String>[
    if (result.added > 0) context.tr('已导入 ${result.added} 首'),
    if (result.skipped > 0) context.tr('${result.skipped} 首已在资料库'),
    if (result.failed > 0) context.tr('${result.failed} 个文件读取失败'),
  ];
  _showLocalMessage(context, parts.isEmpty ? '没有选择音频文件' : parts.join(' · '));
}

void _showLocalMessage(BuildContext context, String message) {
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(context.tr(message))));
}

/// The 音乐库 block that adds local files: one row into the library, one row
/// that opens the file chooser directly. Both stay available to guests, so
/// importing never depends on an account.
class LocalMusicCard extends StatefulWidget {
  const LocalMusicCard({
    super.key,
    required this.state,
    required this.onOpen,
    this.importer = const LocalMusicImporter(),
  });

  final AppState state;
  final VoidCallback onOpen;
  final LocalMusicImporter importer;

  @override
  State<LocalMusicCard> createState() => _LocalMusicCardState();
}

class _LocalMusicCardState extends State<LocalMusicCard> {
  bool _busy = false;

  Future<void> _import() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await runLocalImport(context, widget.state, widget.importer);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scan() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await scanSystemMusic(context, widget.state);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return AnimatedBuilder(
      animation: widget.state.localLibrary,
      builder: (BuildContext context, Widget? child) {
        final LocalLibrary library = widget.state.localLibrary;
        final int count = library.availableCount;
        return AppleGroupedCard(
          margin: EdgeInsets.zero,
          child: Column(
            children: <Widget>[
              AppleListTile(
                key: const ValueKey<String>('open-local-music'),
                title: context.tr('本地音乐'),
                subtitle: count == 0
                    ? context.tr('导入本机的 MP3、FLAC、M4A 或 WAV')
                    : context.tr(
                        '$count 首 · ${formatBytes(library.totalBytes)}',
                      ),
                leading: AppleIconTile(
                  icon: Icons.library_music_rounded,
                  color: apple.accent,
                ),
                showChevron: true,
                onTap: widget.onOpen,
              ),
              Container(height: .5, color: apple.separator),
              AppleListTile(
                key: const ValueKey<String>('import-local-music'),
                title: context.tr('导入本地音乐'),
                subtitle: context.tr('只记录文件路径，不复制也不改动原文件'),
                leading: AppleIconTile(
                  icon: Icons.file_open_rounded,
                  color: apple.accent,
                ),
                trailing: _busy
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        context.tr('导入'),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: apple.accent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                onTap: _busy ? null : () => unawaited(_import()),
              ),
              Container(height: .5, color: apple.separator),
              AppleListTile(
                key: const ValueKey<String>('scan-local-music'),
                title: context.tr('扫描本机音乐'),
                subtitle: context.tr('搜索系统音乐文件夹，自动读取歌曲信息'),
                leading: AppleIconTile(
                  icon: Icons.manage_search_rounded,
                  color: apple.accent,
                ),
                trailing: _busy
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        context.tr('扫描'),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: apple.accent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                onTap: _busy ? null : () => unawaited(_scan()),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Everything the local library holds: play a file, re-import, or drop the
/// record when the file moved away. The originals are never deleted from here.
class LocalMusicPage extends StatefulWidget {
  const LocalMusicPage({
    super.key,
    required this.state,
    this.importer = const LocalMusicImporter(),
  });

  final AppState state;
  final LocalMusicImporter importer;

  @override
  State<LocalMusicPage> createState() => _LocalMusicPageState();
}

class _LocalPageTracks {
  const _LocalPageTracks(this.playable, this.missing, this.bytes);
  final List<LocalTrack> playable;
  final List<LocalTrack> missing;
  final int bytes;
}

class _LocalMusicPageState extends State<LocalMusicPage> {
  bool _busy = false;
  LocalLibrary? _cachedLibrary;
  int? _cachedRevision;
  _LocalPageTracks? _cachedTracks;

  AppState get state => widget.state;

  _LocalPageTracks _tracksFor(LocalLibrary library) {
    final int revision = library.tracksRevision;
    if (identical(_cachedLibrary, library) && _cachedRevision == revision) {
      return _cachedTracks!;
    }
    final playable = <LocalTrack>[];
    final missing = <LocalTrack>[];
    var bytes = 0;
    for (final entry in library.tracks) {
      if (entry.missing) {
        missing.add(entry);
      } else {
        playable.add(entry);
        bytes += entry.bytes ?? 0;
      }
    }
    playable.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    _cachedLibrary = library;
    _cachedRevision = revision;
    return _cachedTracks = _LocalPageTracks(playable, missing, bytes);
  }

  @override
  void initState() {
    super.initState();
    // Files move while the app runs; re-check the index when the page opens.
    // After the frame, not during it: the check reports through the library,
    // and a report raised while this page mounts would mark the page it is
    // replacing as needing to build mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(state.localLibrary.refreshMissing());
    });
  }

  Future<void> _import() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await runLocalImport(context, state, widget.importer);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scanSystem() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await scanSystemMusic(context, state);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickFolder() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await pickMusicFolder(context, state);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _playAll(List<LocalTrack> playable) {
    if (playable.isEmpty) return;
    state.playQueue(<Track>[
      for (final LocalTrack entry in playable) entry.track,
    ]);
  }

  Future<void> _showRowMenu(
    BuildContext rowContext,
    List<LocalTrack> playable,
    int index,
    Offset position,
  ) async {
    final RenderBox? overlay =
        Overlay.of(rowContext).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final AppleSemanticColors apple = AppleSemanticColors.of(rowContext);
    final String? action = await showMenu<String>(
      context: rowContext,
      position: RelativeRect.fromRect(
        Rect.fromPoints(position, position),
        Offset.zero & overlay.size,
      ),
      color: apple.tertiaryBackground,
      surfaceTintColor: Colors.transparent,
      elevation: 18,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(value: 'play', child: TrText('播放')),
        if (playable[index].isDownload)
          PopupMenuItem<String>(value: 'delete-file', child: TrText('删除下载文件')),
        PopupMenuItem<String>(value: 'remove', child: TrText('从资料库移除')),
      ],
    );
    if (!mounted || action == null) return;
    if (action == 'play') {
      state.playQueue(<Track>[
        for (final LocalTrack entry in playable) entry.track,
      ], startIndex: index);
      return;
    }
    final LocalTrack entry = playable[index];
    if (action == 'delete-file') {
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: TrText('删除下载文件？'),
          content: Text(context.tr('「${entry.track.title}」的文件会从磁盘删除，无法恢复。')),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: TrText('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: TrText('删除'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      await state.localLibrary.remove(entry, deleteFile: true);
      if (!mounted) return;
      _showLocalMessage(context, '已删除下载文件');
      return;
    }
    await state.localLibrary.remove(entry);
    if (!mounted) return;
    _showLocalMessage(
      context,
      entry.isDownload ? '已从资料库移除，文件仍保留在下载目录' : '已从资料库移除，原文件仍在原处',
    );
  }

  @override
  Widget build(BuildContext context) {
    final double inset = _contentInset(context);
    return AnimatedBuilder(
      animation: state.localLibrary,
      builder: (BuildContext context, Widget? child) {
        final data = _tracksFor(state.localLibrary);
        final List<LocalTrack> playable = data.playable;
        final List<LocalTrack> missing = data.missing;
        final int bytes = data.bytes;
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: CustomScrollView(
              slivers: <Widget>[
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(inset, 8, inset, 0),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        ApplePageTitle(
                          title: '本地音乐',
                          subtitle: _subtitle(
                            context,
                            playable.length,
                            bytes,
                            missing.length,
                          ),
                          padding: const EdgeInsets.fromLTRB(0, 12, 0, 10),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              if (playable.isNotEmpty)
                                FilledButton.tonalIcon(
                                  key: const ValueKey<String>(
                                    'local-music-play-all',
                                  ),
                                  onPressed: () => _playAll(playable),
                                  icon: const Icon(
                                    Icons.play_arrow_rounded,
                                    size: 19,
                                  ),
                                  label: TrText('播放全部'),
                                ),
                              const SizedBox(width: 8),
                              FilledButton.icon(
                                key: const ValueKey<String>(
                                  'local-music-import',
                                ),
                                onPressed: _busy ? null : () => _import(),
                                icon: _busy
                                    ? const SizedBox.square(
                                        dimension: 15,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.add_rounded, size: 19),
                                label: TrText('导入'),
                              ),
                              const SizedBox(width: 4),
                              PopupMenuButton<String>(
                                key: const ValueKey<String>(
                                  'local-music-import-menu',
                                ),
                                enabled: !_busy,
                                tooltip: context.tr('更多导入方式'),
                                icon: const Icon(Icons.more_horiz_rounded),
                                onSelected: (String value) {
                                  if (value == 'scan') {
                                    unawaited(_scanSystem());
                                  } else if (value == 'folder') {
                                    unawaited(_pickFolder());
                                  }
                                },
                                itemBuilder: (BuildContext context) =>
                                    <PopupMenuEntry<String>>[
                                      PopupMenuItem<String>(
                                        value: 'scan',
                                        child: TrText('扫描系统音乐'),
                                      ),
                                      PopupMenuItem<String>(
                                        value: 'folder',
                                        child: TrText('选择文件夹…'),
                                      ),
                                    ],
                              ),
                            ],
                          ),
                        ),
                        if (playable.isEmpty && missing.isEmpty)
                          AppleEmptyState(
                            message: '还没有本地音乐。\n选几首存在这台设备上的歌吧。',
                            icon: Icons.folder_open_rounded,
                            action: Wrap(
                              spacing: 10,
                              runSpacing: 8,
                              alignment: WrapAlignment.center,
                              children: <Widget>[
                                FilledButton(
                                  key: const ValueKey<String>(
                                    'local-music-import-empty',
                                  ),
                                  onPressed: _busy ? null : () => _import(),
                                  child: TrText('导入本地音乐'),
                                ),
                                OutlinedButton.icon(
                                  key: const ValueKey<String>(
                                    'local-music-scan-empty',
                                  ),
                                  onPressed: _busy ? null : () => _scanSystem(),
                                  icon: const Icon(
                                    Icons.manage_search_rounded,
                                    size: 18,
                                  ),
                                  label: TrText('扫描本机音乐'),
                                ),
                              ],
                            ),
                          )
                        else if (playable.isNotEmpty)
                          LegacySectionHeader(
                            title: '歌曲',
                            subtitle: '${playable.length} 首',
                          ),
                        const SizedBox(height: 6),
                      ],
                    ),
                  ),
                ),
                if (playable.isNotEmpty)
                  SliverPadding(
                    padding: EdgeInsets.symmetric(horizontal: inset),
                    sliver: SliverList.builder(
                      itemCount: playable.length,
                      itemBuilder: (BuildContext context, int i) =>
                          LegacyTrackRow(
                            key: ValueKey<String>('local-track-row-$i'),
                            track: playable[i].track,
                            index: i,
                            current: state.current?.id == playable[i].id,
                            playing: state.playing,
                            onTap: () => state.playQueue(<Track>[
                              for (final LocalTrack entry in playable)
                                entry.track,
                            ], startIndex: i),
                            onMenuRequested: (Offset position) => unawaited(
                              _showRowMenu(context, playable, i, position),
                            ),
                          ),
                    ),
                  ),
                if (missing.isNotEmpty)
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(inset, 26, inset, 0),
                    sliver: SliverMainAxisGroup(
                      slivers: <Widget>[
                        SliverToBoxAdapter(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              LegacySectionHeader(
                                title: '文件已丢失',
                                subtitle: '${missing.length} 首',
                                trailing: TextButton(
                                  key: const ValueKey<String>(
                                    'local-music-clear-missing',
                                  ),
                                  onPressed: () => unawaited(
                                    state.localLibrary.clearMissing(),
                                  ),
                                  child: const TrText('清理记录'),
                                ),
                              ),
                              const SizedBox(height: 8),
                            ],
                          ),
                        ),
                        SliverList.builder(
                          itemCount: missing.length,
                          itemBuilder: (BuildContext context, int i) {
                            final LocalTrack entry = missing[i];
                            final apple = AppleSemanticColors.of(context);
                            return Container(
                              decoration: BoxDecoration(
                                color: apple.secondaryGroupedBackground,
                                border: Border(
                                  left: BorderSide(
                                    color: apple.separator,
                                    width: .5,
                                  ),
                                  right: BorderSide(
                                    color: apple.separator,
                                    width: .5,
                                  ),
                                  top: i == 0
                                      ? BorderSide(
                                          color: apple.separator,
                                          width: .5,
                                        )
                                      : BorderSide.none,
                                  bottom: i == missing.length - 1
                                      ? BorderSide(
                                          color: apple.separator,
                                          width: .5,
                                        )
                                      : BorderSide.none,
                                ),
                                borderRadius: BorderRadius.vertical(
                                  top: i == 0
                                      ? const Radius.circular(14)
                                      : Radius.zero,
                                  bottom: i == missing.length - 1
                                      ? const Radius.circular(14)
                                      : Radius.zero,
                                ),
                              ),
                              child: AppleListTile(
                                title: entry.track.title,
                                subtitle: entry.path,
                                leading: AppleIconTile(
                                  icon: Icons.error_outline_rounded,
                                  color: Theme.of(context).colorScheme.error,
                                ),
                                trailing: IconButton(
                                  tooltip: context.tr('从资料库移除'),
                                  onPressed: () => unawaited(
                                    state.localLibrary.remove(entry),
                                  ),
                                  icon: const Icon(
                                    Icons.delete_outline_rounded,
                                    size: 19,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                const SliverToBoxAdapter(child: SizedBox(height: 40)),
              ],
            ),
          ),
        );
      },
    );
  }

  String _subtitle(BuildContext context, int count, int bytes, int missing) {
    if (count == 0 && missing == 0) {
      return context.tr('从这台设备导入 MP3、FLAC、M4A 或 WAV');
    }
    final List<String> parts = <String>[
      context.tr('$count 首'),
      if (bytes > 0) formatBytes(bytes),
      if (missing > 0) context.tr('$missing 个文件已丢失'),
    ];
    return parts.join(' · ');
  }
}

/// Horizontal page margin that matches the rest of the shell: 16 pt on phones,
/// 24 pt in a window.
double _contentInset(BuildContext context) =>
    MediaQuery.sizeOf(context).width < 720 ? 16 : 24;
