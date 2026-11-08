import 'dart:async';

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../theme/apple_design.dart';
import '../tv/tv_mode.dart';
import '../utils/byte_format.dart';
import '../widgets/apple_ui.dart';
import '../widgets/build_safe_state.dart';
import '../widgets/spring_buttons.dart';
import '../ui/widgets.dart';
import 'network_source.dart';
import 'network_sources_controller.dart';
import 'network_widgets.dart';
import 'remote_source.dart';

/// Folder browser for one network source: folders first, then the files this
/// app can play. Tapping a song queues the whole folder from that point.
class NetworkBrowsePage extends StatefulWidget {
  const NetworkBrowsePage({
    super.key,
    required this.state,
    required this.controller,
    required this.sourceId,
    this.initialPath,
  });

  final AppState state;
  final NetworkSourcesController controller;
  final String sourceId;
  final String? initialPath;

  @override
  State<NetworkBrowsePage> createState() => _NetworkBrowsePageState();
}

class _NetworkBrowsePageState extends State<NetworkBrowsePage>
    with BuildSafeState<NetworkBrowsePage> {
  late String _path;
  RemoteListing? _listing;
  Object? _error;
  bool _loading = false;
  int _request = 0;

  NetworkSourcesController get network => widget.controller;

  NetworkSource? get _source => network.sourceById(widget.sourceId);

  @override
  void initState() {
    super.initState();
    _path = widget.initialPath ?? _source?.rootPath ?? '/';
    unawaited(_load());
  }

  Future<void> _load() async {
    final int request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final RemoteListing listing = await network.list(widget.sourceId, _path);
      if (!mounted || request != _request) return;
      setState(() {
        _listing = listing;
        _path = listing.path;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  void _openFolder(String path) {
    setState(() => _path = path);
    unawaited(_load());
  }

  void _up() {
    final String parent = remoteParent(_path);
    if (parent == _path) return;
    _openFolder(parent);
  }

  List<RemoteEntry> get _folders => <RemoteEntry>[
    for (final RemoteEntry entry in _listing?.entries ?? const <RemoteEntry>[])
      if (entry.isDirectory) entry,
  ]..sort(byFolderThenName);

  List<RemoteEntry> get _audio => <RemoteEntry>[
    for (final RemoteEntry entry in _listing?.entries ?? const <RemoteEntry>[])
      if (entry.isAudio) entry,
  ]..sort(byFolderThenName);

  Future<void> _playAll() async {
    final List<RemoteEntry> audio = _audio;
    if (audio.isEmpty) return;
    try {
      final List<Track> tracks = await network.indexFolder(
        widget.sourceId,
        audio,
      );
      if (!mounted) return;
      widget.state.playQueue(tracks);
    } catch (error) {
      if (!mounted) return;
      showNetworkMessage(
        context,
        networkErrorSentence(context, error),
        error: true,
      );
    }
  }

  Future<void> _play(int index) async {
    try {
      final List<Track> tracks = await network.indexFolder(
        widget.sourceId,
        _audio,
      );
      if (!mounted) return;
      widget.state.playQueue(tracks, startIndex: index);
    } catch (error) {
      if (!mounted) return;
      showNetworkMessage(
        context,
        networkErrorSentence(context, error),
        error: true,
      );
    }
  }

  Future<void> _scanHere() async {
    if (network.scanning) return;
    try {
      final result = await network.scan(widget.sourceId, _path);
      if (!mounted) return;
      showNetworkMessage(
        context,
        result.cancelled
            ? '扫描已取消，已索引 ${result.added} 首'
            : '已索引 ${result.added} 首，更新 ${result.updated} 首',
      );
    } catch (error) {
      if (!mounted) return;
      showNetworkMessage(
        context,
        networkErrorSentence(context, error),
        error: true,
      );
    }
  }

  Future<void> _showFileMenu(RemoteEntry entry, Offset position) async {
    final RenderBox? overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final String? action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(position, position),
        Offset.zero & overlay.size,
      ),
      color: AppleSemanticColors.of(context).tertiaryBackground,
      surfaceTintColor: Colors.transparent,
      elevation: 18,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: <PopupMenuEntry<String>>[
        const PopupMenuItem<String>(value: 'play', child: TrText('播放')),
        const PopupMenuItem<String>(
          value: 'play-folder',
          child: TrText('播放这个文件夹'),
        ),
      ],
    );
    if (!mounted || action == null) return;
    if (action == 'play') {
      final int index = _audio.indexWhere(
        (RemoteEntry e) => e.path == entry.path,
      );
      if (index >= 0) unawaited(_play(index));
    } else if (action == 'play-folder') {
      unawaited(_playAll());
    }
  }

  @override
  Widget build(BuildContext context) {
    final double inset = pageInset(context);
    final NetworkSource? source = _source;
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final List<RemoteEntry> folders = _folders;
    final List<RemoteEntry> audio = _audio;
    return AnimatedBuilder(
      animation: network,
      builder: (BuildContext context, Widget? child) {
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 980),
            child: CustomScrollView(
              slivers: <Widget>[
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(inset, 8, inset, 0),
                  sliver: SliverToBoxAdapter(
                    child: ApplePageTitle(
                      title: source?.displayName ?? '网络源',
                      subtitle: source == null
                          ? null
                          : '${source.address} · ${remoteDisplayPath(_path)}',
                      padding: const EdgeInsets.fromLTRB(0, 12, 0, 12),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          if (_path != (source?.rootPath ?? '/'))
                            IconButton(
                              key: const ValueKey<String>('network-browse-up'),
                              tooltip: context.tr('上一级'),
                              onPressed: _up,
                              icon: Icon(
                                Icons.arrow_upward_rounded,
                                size: 20,
                                color: apple.secondaryLabel,
                              ),
                            ),
                          IconButton(
                            key: const ValueKey<String>(
                              'network-browse-reload',
                            ),
                            tooltip: context.tr('刷新'),
                            onPressed: _loading ? null : _load,
                            icon: _loading
                                ? const NetworkProgressLabel(size: 18)
                                : Icon(
                                    Icons.refresh_rounded,
                                    size: 20,
                                    color: apple.secondaryLabel,
                                  ),
                          ),
                          NetworkBackButton(
                            onPressed: () => Navigator.of(context).maybePop(),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.symmetric(horizontal: inset),
                  sliver: SliverToBoxAdapter(
                    child: Row(
                      children: <Widget>[
                        if (audio.isNotEmpty)
                          SpringFilledButton.tonalIcon(
                            key: const ValueKey<String>(
                              'network-browse-play-all',
                            ),
                            onPressed: () => unawaited(_playAll()),
                            icon: const Icon(
                              Icons.play_arrow_rounded,
                              size: 19,
                            ),
                            label: const TrText('播放全部'),
                          ),
                        const SizedBox(width: 8),
                        SpringOutlinedButton.icon(
                          key: const ValueKey<String>('network-browse-scan'),
                          onPressed: network.scanning
                              ? null
                              : () => unawaited(_scanHere()),
                          icon: const Icon(
                            Icons.manage_search_rounded,
                            size: 18,
                          ),
                          label: const TrText('扫描此文件夹'),
                        ),
                      ],
                    ),
                  ),
                ),
                if (network.scanning)
                  SliverPadding(
                    padding: const EdgeInsets.only(top: 12),
                    sliver: SliverToBoxAdapter(
                      child: NetworkBusyBanner(
                        message: '正在扫描网络存储…',
                        detail:
                            '${network.scanningFolder ?? ''} · ${network.scanningFiles} 首',
                        onCancel: network.cancelScan,
                      ),
                    ),
                  ),
                if (_loading && _listing == null)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_error != null)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: AppleEmptyState(
                      message: networkErrorSentence(context, _error),
                      icon: Icons.cloud_off_rounded,
                      action: SpringFilledButton(
                        onPressed: _load,
                        child: const TrText('重试'),
                      ),
                    ),
                  )
                else ...<Widget>[
                  if (folders.isNotEmpty)
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(inset, 16, inset, 0),
                      sliver: SliverToBoxAdapter(
                        child: AppleGroupedCard(
                          margin: EdgeInsets.zero,
                          child: Column(
                            children: <Widget>[
                              for (int i = 0; i < folders.length; i++)
                                Column(
                                  children: <Widget>[
                                    if (i > 0)
                                      Container(
                                        height: .5,
                                        color: apple.separator,
                                      ),
                                    AppleListTile(
                                      key: ValueKey<String>(
                                        'network-folder-${folders[i].path}',
                                      ),
                                      leading: AppleIconTile(
                                        icon: Icons.folder_rounded,
                                        color: apple.accent,
                                      ),
                                      title: folders[i].name,
                                      subtitle: context.tr('文件夹'),
                                      showChevron: true,
                                      onTap: () => _openFolder(folders[i].path),
                                      trailing: TextButton(
                                        key: ValueKey<String>(
                                          'network-folder-scan-${folders[i].path}',
                                        ),
                                        onPressed: network.scanning
                                            ? null
                                            : () => unawaited(
                                                _scanFolder(folders[i]),
                                              ),
                                        child: const TrText('扫描'),
                                      ),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (audio.isNotEmpty)
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(inset, 22, inset, 6),
                      sliver: SliverToBoxAdapter(
                        child: AppSectionHeader(
                          title: '歌曲',
                          subtitle: audio.isEmpty
                              ? null
                              : context.tr('${audio.length} 首'),
                        ),
                      ),
                    ),
                  SliverPadding(
                    padding: EdgeInsets.symmetric(horizontal: inset),
                    sliver: SliverList.builder(
                      itemCount: audio.length,
                      itemBuilder: (BuildContext context, int i) {
                        return _NetworkFileRow(
                          key: ValueKey<String>(
                            'network-file-${audio[i].path}',
                          ),
                          entry: audio[i],
                          onTap: () => unawaited(_play(i)),
                          onMenu: (Offset position) =>
                              unawaited(_showFileMenu(audio[i], position)),
                        );
                      },
                    ),
                  ),
                  if (folders.isEmpty && audio.isEmpty)
                    SliverToBoxAdapter(
                      child: AppleEmptyState(
                        message: '这个文件夹里没有音频文件。',
                        icon: Icons.folder_off_rounded,
                        action: SpringOutlinedButton(
                          onPressed: _load,
                          child: const TrText('刷新'),
                        ),
                      ),
                    ),
                ],
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 40 + MediaQuery.paddingOf(context).bottom,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _scanFolder(RemoteEntry entry) async {
    if (network.scanning) return;
    try {
      final result = await network.scan(widget.sourceId, entry.path);
      if (!mounted) return;
      showNetworkMessage(
        context,
        result.cancelled
            ? '扫描已取消，已索引 ${result.added} 首'
            : '已索引 ${result.added} 首，更新 ${result.updated} 首',
      );
    } catch (error) {
      if (!mounted) return;
      showNetworkMessage(
        context,
        networkErrorSentence(context, error),
        error: true,
      );
    }
  }
}

/// One file row: the title follows the same `Artist - Title` rule the library
/// uses, and the second line says what the file is and how big it is.
class _NetworkFileRow extends StatefulWidget {
  const _NetworkFileRow({
    super.key,
    required this.entry,
    required this.onTap,
    required this.onMenu,
  });

  final RemoteEntry entry;
  final VoidCallback onTap;
  final ValueChanged<Offset>? onMenu;

  @override
  State<_NetworkFileRow> createState() => _NetworkFileRowState();
}

class _NetworkFileRowState extends State<_NetworkFileRow>
    with BuildSafeState<_NetworkFileRow> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final String name = widget.entry.name;
    final String base = name.contains('.')
        ? name.substring(0, name.lastIndexOf('.'))
        : name;
    String title = base;
    String artist = '';
    final int separator = base.indexOf(' - ');
    if (separator > 0) {
      artist = base.substring(0, separator).trim();
      title = base.substring(separator + 3).trim();
    } else if (base.contains('-') && !RegExp(r'^\d+-\d+$').hasMatch(base)) {
      final int dash = base.indexOf('-');
      if (dash > 0) {
        artist = base.substring(0, dash).trim();
        title = base.substring(dash + 1).trim();
      }
    }
    if (title.trim().isEmpty) title = name;
    final String size = widget.entry.size == null
        ? ''
        : formatBytes(widget.entry.size!);
    final String detail = <String>[
      if (artist.isNotEmpty) artist,
      if (widget.entry.isPlaylist) context.tr('播放列表'),
      if (size.isNotEmpty) size,
    ].join(' · ');
    return TvTapTarget(
      borderRadius: BorderRadius.circular(8),
      onTap: widget.onTap,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onSecondaryTapDown: widget.onMenu == null
              ? null
              : (TapDownDetails details) =>
                    widget.onMenu!(details.globalPosition),
          onLongPress: widget.onMenu == null
              ? null
              : () {
                  final RenderBox? box =
                      context.findRenderObject() as RenderBox?;
                  widget.onMenu!(
                    box?.localToGlobal(box.size.center(Offset.zero)) ??
                        Offset.zero,
                  );
                },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            margin: const EdgeInsets.symmetric(vertical: 1),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              color: _hovering ? apple.fill : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  widget.entry.isPlaylist
                      ? Icons.queue_music_rounded
                      : Icons.music_note_rounded,
                  size: 19,
                  color: apple.secondaryLabel,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: apple.label,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (detail.isNotEmpty)
                        Text(
                          detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: apple.secondaryLabel,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.play_arrow_rounded,
                  size: 19,
                  color: _hovering ? apple.accent : apple.tertiaryLabel,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
