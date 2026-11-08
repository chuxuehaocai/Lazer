import 'dart:async';

import 'package:flutter/material.dart';

import '../animation/apple_modal.dart';
import '../animation/view_transitions.dart';
import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../tv/tv_mode.dart';
import '../theme/apple_design.dart';
import '../ui/widgets.dart';
import '../widgets/apple_ui.dart';
import '../widgets/build_safe_state.dart';
import '../widgets/interaction_feedback.dart';
import '../widgets/spring_buttons.dart';
import 'network_browse_page.dart';
import 'network_library.dart';
import 'network_source.dart';
import 'network_source_editor.dart';
import 'network_sources_controller.dart';
import 'network_widgets.dart';
import 'podcast_feed.dart';
import 'podcast_pages.dart';
import 'radio_pages.dart';
import 'radio_station.dart';
import 'remote_source.dart';

/// 音乐库 → 网络源: the row that opens NAS shares, internet radio and podcast
/// subscriptions. Kept above the playlists (and available to guests) like
/// 本地音乐, because none of it needs an account.
class NetworkSourcesCard extends StatelessWidget {
  const NetworkSourcesCard({
    super.key,
    required this.state,
    required this.onOpen,
  });

  final AppState state;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final NetworkSourcesController network = state.networkSources;
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return AnimatedBuilder(
      animation: network,
      builder: (BuildContext context, Widget? child) {
        final int sources = network.sources.length;
        final int stations = network.stations.length;
        final int podcasts = network.podcasts.length;
        final String subtitle;
        if (sources == 0 && stations == 0 && podcasts == 0) {
          subtitle = context.tr('WebDAV、SMB、SFTP、FTP，以及网络电台与播客');
        } else {
          subtitle = <String>[
            if (sources > 0) context.tr('$sources 个存储'),
            if (stations > 0) context.tr('$stations 个电台'),
            if (podcasts > 0) context.tr('$podcasts 个播客'),
          ].join(' · ');
        }
        return AppleGroupedCard(
          margin: EdgeInsets.zero,
          child: AppleListTile(
            key: const ValueKey<String>('open-network-sources'),
            title: context.tr('网络源'),
            subtitle: subtitle,
            leading: AppleIconTile(
              icon: Icons.lan_rounded,
              color: apple.accent,
            ),
            showChevron: true,
            onTap: onOpen,
          ),
        );
      },
    );
  }
}

/// Opens the 网络源 hub on top of the shell.
Future<void> openNetworkSourcesPage(BuildContext context, AppState state) =>
    Navigator.of(context).push<void>(
      ApplePageRoute<void>(
        settings: const RouteSettings(name: '/network-sources'),
        builder: (_) => NetworkSourcesPage(state: state),
      ),
    );

enum _NetworkTab { storage, radio, podcast, indexed }

/// The 网络源 page: storage, radio and podcasts in three lists that share one
/// header, so the library has a single door for everything off-machine.
class NetworkSourcesPage extends StatefulWidget {
  const NetworkSourcesPage({
    super.key,
    required this.state,
    this.controller,
    this.onBack,
  });

  final AppState state;
  final NetworkSourcesController? controller;
  final VoidCallback? onBack;

  @override
  State<NetworkSourcesPage> createState() => _NetworkSourcesPageState();
}

class _NetworkSourcesPageState extends State<NetworkSourcesPage>
    with BuildSafeState<NetworkSourcesPage> {
  _NetworkTab _tab = _NetworkTab.storage;
  bool _busy = false;
  String? _busyMessage;

  NetworkSourcesController get network =>
      widget.controller ?? widget.state.networkSources;

  @override
  void initState() {
    super.initState();
    unawaited(network.load());
  }

  Future<void> _withBusy(String message, Future<void> Function() body) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _busyMessage = message;
    });
    try {
      await body();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The editor reports its own progress, so the page does not put a second
  /// spinner behind the dialog.
  Future<void> _addSource() async {
    final bool saved = await showNetworkSourceEditor(
      context,
      controller: network,
    );
    if (saved && mounted) showNetworkMessage(context, '已添加网络源');
  }

  Future<void> _editSource(NetworkSource source) async {
    final bool saved = await showNetworkSourceEditor(
      context,
      controller: network,
      source: source,
    );
    if (saved && mounted) showNetworkMessage(context, '已保存网络源');
  }

  Future<void> _removeSource(NetworkSource source) async {
    final bool? confirmed = await showAppleDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const TrText('移除网络源？'),
        content: Text(
          context.tr('「${source.displayName}」和它索引的歌曲会从这个列表移除，服务器上的文件不受影响。'),
        ),
        actions: <Widget>[
          SpringTextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const TrText('取消'),
          ),
          SpringFilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const TrText('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await network.removeSource(source.id);
    if (mounted) showNetworkMessage(context, '已移除网络源');
  }

  Future<void> _scanSource(NetworkSource source) async {
    if (network.scanning) return;
    await _withBusy('正在扫描网络源…', () async {
      try {
        final result = await network.scan(source.id, source.rootPath);
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
    });
  }

  void _browse(NetworkSource source) {
    Navigator.of(context).push<void>(
      ApplePageRoute<void>(
        settings: const RouteSettings(name: '/network-browse'),
        builder: (_) => NetworkBrowsePage(
          state: widget.state,
          controller: network,
          sourceId: source.id,
        ),
      ),
    );
  }

  Future<void> _addStation() async {
    final RadioStationDraft? draft = await showRadioStationDialog(
      context,
      controller: network,
    );
    if (draft == null || !mounted) return;
    await network.addStation(
      name: draft.name,
      url: draft.url,
      genre: draft.genre,
    );
    if (mounted) showNetworkMessage(context, '已添加电台');
  }

  Future<void> _editStation(RadioStation station) async {
    final RadioStationDraft? draft = await showRadioStationDialog(
      context,
      controller: network,
      station: station,
    );
    if (draft == null || !mounted) return;
    await network.updateStation(
      station.id,
      name: draft.name,
      url: draft.url,
      genre: draft.genre,
    );
    if (mounted) showNetworkMessage(context, '已保存电台');
  }

  Future<void> _removeStation(RadioStation station) async {
    final bool? confirmed = await showAppleDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const TrText('移除这个电台？'),
        content: Text(context.tr('「${station.name}」会从网络电台列表移除。')),
        actions: <Widget>[
          SpringTextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const TrText('取消'),
          ),
          SpringFilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const TrText('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await network.removeStation(station.id);
    if (mounted) showNetworkMessage(context, '已移除电台');
  }

  void _playStation(RadioStation station) {
    widget.state.playQueue(<Track>[station.toTrack()]);
  }

  Future<void> _importPlaylist() async {
    final String? url = await showNetworkTextPrompt(
      context,
      title: '导入电台列表',
      label: 'M3U / PLS 地址',
      hint: 'https://example.com/radio.m3u',
      description: '支持 M3U、M3U8、PLS、ASX 与 XSPF 列表，一次把里面的电台都加进来。',
      confirmLabel: '导入',
    );
    if (url == null || url.isEmpty || !mounted) return;
    final Uri? uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      showNetworkMessage(context, '请填写以 http 或 https 开头的地址。', error: true);
      return;
    }
    await _withBusy('正在导入电台…', () async {
      try {
        final int added = await network.importRadioPlaylist(uri);
        if (!mounted) return;
        showNetworkMessage(
          context,
          added == 0 ? '列表里的电台都已经在列表里了' : '已导入 $added 个电台',
        );
      } catch (error) {
        if (!mounted) return;
        showNetworkMessage(
          context,
          networkErrorSentence(context, error),
          error: true,
        );
      }
    });
  }

  Future<void> _subscribe() async {
    final String? url = await showNetworkTextPrompt(
      context,
      title: '订阅播客',
      label: 'RSS 地址',
      hint: 'https://example.com/podcast.xml',
      description: '支持 RSS 2.0 与 Atom，包括 iTunes 时长和 Podcast 2.0 的附件。',
      confirmLabel: '订阅',
    );
    if (url == null || url.isEmpty || !mounted) return;
    await _withBusy('正在获取播客…', () async {
      try {
        final PodcastSubscription subscription = await network.subscribe(url);
        if (!mounted) return;
        showNetworkMessage(context, '已订阅「${subscription.displayTitle}」');
        _openPodcast(subscription);
      } catch (error) {
        if (!mounted) return;
        showNetworkMessage(
          context,
          networkErrorSentence(context, error),
          error: true,
        );
      }
    });
  }

  Future<void> _refreshPodcast(PodcastSubscription podcast) =>
      _withBusy('正在刷新播客…', () async {
        try {
          final PodcastSubscription refreshed = await network.refreshPodcast(
            podcast.id,
          );
          if (!mounted) return;
          showNetworkMessage(
            context,
            '「${refreshed.displayTitle}」已更新，共 ${refreshed.episodes.length} 集',
          );
        } catch (error) {
          if (!mounted) return;
          showNetworkMessage(
            context,
            networkErrorSentence(context, error),
            error: true,
          );
        }
      });

  Future<void> _refreshAllPodcasts() => _withBusy('正在刷新全部播客…', () async {
    final ({int refreshed, int failed}) result = await network
        .refreshAllPodcasts();
    if (!mounted) return;
    if (result.failed == 0) {
      showNetworkMessage(context, '已刷新 ${result.refreshed} 个播客');
      return;
    }
    showNetworkMessage(
      context,
      '已刷新 ${result.refreshed} 个播客，${result.failed} 个失败',
      error: true,
    );
  });

  Future<void> _unsubscribe(PodcastSubscription podcast) async {
    final bool? confirmed = await showAppleDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const TrText('取消订阅？'),
        content: Text(
          context.tr('「${podcast.displayTitle}」会取消订阅，本地的收听进度也会删除。'),
        ),
        actions: <Widget>[
          SpringTextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const TrText('取消'),
          ),
          SpringFilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const TrText('取消订阅'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await network.unsubscribe(podcast.id);
    if (mounted) showNetworkMessage(context, '已取消订阅');
  }

  void _openPodcast(PodcastSubscription podcast) {
    Navigator.of(context).push<void>(
      ApplePageRoute<void>(
        settings: const RouteSettings(name: '/network-podcast'),
        builder: (_) => PodcastEpisodesPage(
          state: widget.state,
          controller: network,
          podcastId: podcast.id,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final double inset = pageInset(context);
    return AnimatedBuilder(
      animation: network,
      builder: (BuildContext context, Widget? child) {
        final List<NetworkSource> sources = network.sources;
        final List<RadioStation> stations = network.stations;
        final List<PodcastSubscription> podcasts = network.podcasts;
        final int totalStorage = network.entries.length;
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 980),
            child: CustomScrollView(
              slivers: <Widget>[
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(inset, 8, inset, 0),
                  sliver: SliverToBoxAdapter(
                    child: ApplePageTitle(
                      title: '网络源',
                      subtitle: _subtitle(
                        context,
                        sources.length,
                        stations.length,
                        podcasts.length,
                        totalStorage,
                      ),
                      padding: const EdgeInsets.fromLTRB(0, 12, 0, 14),
                      trailing: NetworkBackButton(
                        onPressed:
                            widget.onBack ??
                            () => Navigator.of(context).maybePop(),
                      ),
                    ),
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.symmetric(horizontal: inset),
                  sliver: SliverToBoxAdapter(child: _tabBar(context)),
                ),
                if (network.scanning)
                  SliverPadding(
                    padding: EdgeInsets.only(top: 12),
                    sliver: SliverToBoxAdapter(
                      child: NetworkBusyBanner(
                        message: '正在扫描网络存储…',
                        detail:
                            '${network.scanningFolder ?? ''} · ${network.scanningFiles} 首',
                        onCancel: network.cancelScan,
                      ),
                    ),
                  )
                else if (_busy)
                  SliverPadding(
                    padding: EdgeInsets.only(top: 12),
                    sliver: SliverToBoxAdapter(
                      child: NetworkBusyBanner(
                        message: _busyMessage ?? '正在处理…',
                      ),
                    ),
                  ),
                ..._bodySlivers(
                  context,
                  inset,
                  sources,
                  stations,
                  podcasts,
                  totalStorage,
                ),
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

  List<Widget> _bodySlivers(
    BuildContext context,
    double inset,
    List<NetworkSource> sources,
    List<RadioStation> stations,
    List<PodcastSubscription> podcasts,
    int totalStorage,
  ) {
    if (_tab == _NetworkTab.indexed) return _indexedSlivers(context, inset);
    return <Widget>[
      SliverPadding(
        padding: EdgeInsets.fromLTRB(inset, 16, inset, 0),
        sliver: SliverToBoxAdapter(
          child: switch (_tab) {
            _NetworkTab.radio => _radioSection(context, stations),
            _NetworkTab.podcast => _podcastSection(context, podcasts),
            _ => _storageSection(context, sources, totalStorage),
          },
        ),
      ),
    ];
  }

  /// Every file the app has indexed from a network source. This is the reason
  /// 扫描到资料库 exists: it is the playable list, built lazily like the local
  /// library's rows.
  List<Widget> _indexedSlivers(BuildContext context, double inset) {
    final List<Track> tracks = network.libraryTracks;
    if (tracks.isEmpty) {
      return <Widget>[
        SliverPadding(
          padding: EdgeInsets.fromLTRB(inset, 16, inset, 0),
          sliver: SliverToBoxAdapter(
            child: AppleEmptyState(
              message: '还没有索引网络歌曲。在源里播放一个文件夹，或点「扫描到资料库」。',
              icon: Icons.library_music_rounded,
              action: SpringFilledButton(
                onPressed: () => setState(() => _tab = _NetworkTab.storage),
                child: const TrText('去扫描'),
              ),
            ),
          ),
        ),
      ];
    }
    return <Widget>[
      SliverPadding(
        padding: EdgeInsets.fromLTRB(inset, 16, inset, 6),
        sliver: SliverToBoxAdapter(
          child: AppSectionHeader(
            title: '已索引的歌曲',
            subtitle: context.tr('${tracks.length} 首'),
            trailing: SpringFilledButton.tonalIcon(
              key: const ValueKey<String>('network-indexed-play-all'),
              onPressed: () => widget.state.playQueue(tracks),
              icon: const Icon(Icons.play_arrow_rounded, size: 19),
              label: const TrText('播放全部'),
            ),
          ),
        ),
      ),
      SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: inset),
        sliver: SliverList.builder(
          itemCount: tracks.length,
          itemBuilder: (BuildContext context, int index) {
            final Track track = tracks[index];
            return AppTrackRow(
              key: ValueKey<String>('network-indexed-row-$index'),
              track: track,
              index: index,
              onTap: () => widget.state.playQueue(tracks, startIndex: index),
              onMenuRequested: (Offset position) =>
                  unawaited(_showIndexedMenu(tracks, index, position)),
            );
          },
        ),
      ),
    ];
  }

  Future<void> _showIndexedMenu(
    List<Track> tracks,
    int index,
    Offset position,
  ) async {
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
        const PopupMenuItem<String>(value: 'remove', child: TrText('从索引移除')),
      ],
    );
    if (!mounted || action == null) return;
    if (action == 'play') {
      widget.state.playQueue(tracks, startIndex: index);
      return;
    }
    final NetworkTrackEntry? entry = network.entryForTrackId(tracks[index].id);
    if (entry == null) return;
    final NetworkSource? source = network.sourceById(entry.sourceId);
    await network.removeEntry(entry.id);
    if (!mounted) return;
    showNetworkMessage(
      context,
      source == null ? '已从索引移除' : '已从「${source.displayName}」的索引移除',
    );
  }

  String _subtitle(
    BuildContext context,
    int sources,
    int stations,
    int podcasts,
    int tracks,
  ) {
    final List<String> parts = <String>[
      if (sources > 0) context.tr('$sources 个存储'),
      if (tracks > 0) context.tr('$tracks 首已索引'),
      if (stations > 0) context.tr('$stations 个电台'),
      if (podcasts > 0) context.tr('$podcasts 个播客'),
    ];
    return parts.isEmpty ? context.tr('NAS、网络电台与播客都在这里') : parts.join(' · ');
  }

  Widget _tabBar(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final (_NetworkTab tab, IconData icon) entry
            in const <(_NetworkTab, IconData)>[
              (_NetworkTab.storage, Icons.cloud_queue_rounded),
              (_NetworkTab.radio, Icons.radio_rounded),
              (_NetworkTab.podcast, Icons.podcasts_rounded),
              (_NetworkTab.indexed, Icons.library_music_rounded),
            ])
          TvTapTarget(
            key: ValueKey<String>('network-tab-${entry.$1.name}'),
            borderRadius: BorderRadius.circular(11),
            onTap: () => setState(() => _tab = entry.$1),
            child: SpringPress(
              pressedScale: .97,
              builder: (BuildContext context, WidgetStatesController states) =>
                  GestureDetector(
                    onTap: () => setState(() => _tab = entry.$1),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 9,
                      ),
                      decoration: BoxDecoration(
                        color: _tab == entry.$1
                            ? apple.accentSoft
                            : apple.secondaryGroupedBackground,
                        borderRadius: BorderRadius.circular(11),
                        border: Border.all(color: apple.separator, width: .5),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(
                            entry.$2,
                            size: 17,
                            color: _tab == entry.$1
                                ? apple.accent
                                : apple.secondaryLabel,
                          ),
                          const SizedBox(width: 7),
                          Text(
                            switch (entry.$1) {
                              _NetworkTab.storage => context.tr('网络存储'),
                              _NetworkTab.radio => context.tr('网络电台'),
                              _NetworkTab.podcast => context.tr('播客'),
                              _NetworkTab.indexed => context.tr('已索引'),
                            },
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: _tab == entry.$1
                                      ? apple.accent
                                      : apple.label,
                                  fontWeight: _tab == entry.$1
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ),
            ),
          ),
      ],
    );
  }

  Widget _storageSection(
    BuildContext context,
    List<NetworkSource> sources,
    int indexedTracks,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppSectionHeader(
          title: '网络存储',
          subtitle: indexedTracks > 0
              ? context.tr('$indexedTracks 首已索引')
              : null,
          trailing: SpringFilledButton.icon(
            key: const ValueKey<String>('network-add-source'),
            onPressed: _busy ? null : () => unawaited(_addSource()),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const TrText('添加'),
          ),
        ),
        const SizedBox(height: 12),
        AppleGroupedCard(
          margin: EdgeInsets.zero,
          child: Column(
            children: <Widget>[
              if (sources.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 22,
                  ),
                  child: Text(
                    context.tr('还没有网络存储。添加一个 NAS 地址后，就能直接播放里面的音乐。'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppleSemanticColors.of(context).secondaryLabel,
                    ),
                  ),
                )
              else
                for (int i = 0; i < sources.length; i++)
                  _sectionRow(
                    context,
                    showDivider: i > 0,
                    child: _sourceRow(context, sources[i]),
                  ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sourceRow(BuildContext context, NetworkSource source) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final int tracks = network.countFor(source.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppleListTile(
          key: ValueKey<String>('network-source-row-${source.id}'),
          leading: AppleIconTile(
            icon: networkKindIcon(source.kind),
            color: apple.accent,
          ),
          title: source.displayName,
          subtitle: <String>[
            networkSourceKindLabel(source.kind),
            source.address,
            source.locationLabel,
            if (tracks > 0) context.tr('$tracks 首'),
          ].join(' · '),
          onTap: () => _browse(source),
          trailing: PopupMenuButton<String>(
            key: ValueKey<String>('network-source-menu-${source.id}'),
            tooltip: context.tr('更多操作'),
            icon: const Icon(Icons.more_horiz_rounded, size: 20),
            onSelected: (String action) {
              switch (action) {
                case 'browse':
                  _browse(source);
                case 'scan':
                  unawaited(_scanSource(source));
                case 'edit':
                  unawaited(_editSource(source));
                case 'remove':
                  unawaited(_removeSource(source));
              }
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              const PopupMenuItem<String>(value: 'browse', child: TrText('浏览')),
              const PopupMenuItem<String>(
                value: 'scan',
                child: TrText('扫描到资料库'),
              ),
              const PopupMenuItem<String>(value: 'edit', child: TrText('编辑')),
              const PopupMenuItem<String>(value: 'remove', child: TrText('移除')),
            ],
          ),
        ),
        if (source.lastError != null) NetworkErrorText(error: source.lastError),
      ],
    );
  }

  Widget _radioSection(BuildContext context, List<RadioStation> stations) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppSectionHeader(
          title: '网络电台',
          subtitle: stations.isEmpty
              ? null
              : context.tr('共 ${stations.length} 个'),
          trailing: _SectionActions(
            keyPrefix: 'network-radio',
            actions: <_SectionAction>[
              _SectionAction(
                id: 'network-import-playlist',
                label: '导入列表',
                icon: Icons.playlist_add_rounded,
                onPressed: _busy ? null : _importPlaylist,
              ),
              _SectionAction(
                id: 'network-add-station',
                label: '添加',
                icon: Icons.add_rounded,
                onPressed: _busy ? null : _addStation,
                filled: true,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        AppleGroupedCard(
          margin: EdgeInsets.zero,
          child: Column(
            children: <Widget>[
              if (stations.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 22,
                  ),
                  child: Text(
                    context.tr('还没有电台。添加一个流地址，或导入 M3U / PLS 列表。'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppleSemanticColors.of(context).secondaryLabel,
                    ),
                  ),
                )
              else
                for (int i = 0; i < stations.length; i++)
                  _sectionRow(
                    context,
                    showDivider: i > 0,
                    child: _stationRow(context, stations[i]),
                  ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _stationRow(BuildContext context, RadioStation station) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final String host = Uri.tryParse(station.url)?.host ?? station.url;
    return AppleListTile(
      key: ValueKey<String>('network-radio-row-${station.id}'),
      leading: AppleIconTile(icon: Icons.radio_rounded, color: apple.accent),
      title: station.name,
      subtitle: <String>[
        if (station.displayGenre.isNotEmpty) station.displayGenre,
        host,
      ].join(' · '),
      onTap: () => _playStation(station),
      trailing: PopupMenuButton<String>(
        key: ValueKey<String>('network-radio-menu-${station.id}'),
        tooltip: context.tr('更多操作'),
        icon: const Icon(Icons.more_horiz_rounded, size: 20),
        onSelected: (String action) {
          switch (action) {
            case 'play':
              _playStation(station);
            case 'edit':
              unawaited(_editStation(station));
            case 'remove':
              unawaited(_removeStation(station));
          }
        },
        itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
          const PopupMenuItem<String>(value: 'play', child: TrText('播放')),
          const PopupMenuItem<String>(value: 'edit', child: TrText('编辑')),
          const PopupMenuItem<String>(value: 'remove', child: TrText('移除')),
        ],
      ),
    );
  }

  Widget _podcastSection(
    BuildContext context,
    List<PodcastSubscription> podcasts,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppSectionHeader(
          title: '播客',
          subtitle: podcasts.isEmpty
              ? null
              : context.tr('共 ${podcasts.length} 个'),
          trailing: _SectionActions(
            keyPrefix: 'network-podcast',
            actions: <_SectionAction>[
              _SectionAction(
                id: 'network-refresh-podcasts',
                label: '刷新全部',
                icon: Icons.sync_rounded,
                onPressed: _busy || podcasts.isEmpty
                    ? null
                    : _refreshAllPodcasts,
              ),
              _SectionAction(
                id: 'network-subscribe-podcast',
                label: '订阅',
                icon: Icons.add_rounded,
                onPressed: _busy ? null : _subscribe,
                filled: true,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        AppleGroupedCard(
          margin: EdgeInsets.zero,
          child: Column(
            children: <Widget>[
              if (podcasts.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 22,
                  ),
                  child: Text(
                    context.tr('还没有播客订阅。粘贴一个 RSS 地址就能开始。'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppleSemanticColors.of(context).secondaryLabel,
                    ),
                  ),
                )
              else
                for (int i = 0; i < podcasts.length; i++)
                  _sectionRow(
                    context,
                    showDivider: i > 0,
                    child: _podcastRow(context, podcasts[i]),
                  ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _podcastRow(BuildContext context, PodcastSubscription podcast) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final PodcastEpisode? resume = podcast.continueEpisode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppleListTile(
          key: ValueKey<String>('network-podcast-row-${podcast.id}'),
          leading: AppleIconTile(
            icon: Icons.podcasts_rounded,
            color: apple.accent,
          ),
          title: podcast.displayTitle,
          subtitle: <String>[
            context.tr('${podcast.episodes.length} 集'),
            if (podcast.unplayedCount > 0)
              context.tr('${podcast.unplayedCount} 集未听'),
            if (resume != null) context.tr('上次听到 ${resume.title}'),
          ].join(' · '),
          onTap: () => _openPodcast(podcast),
          trailing: PopupMenuButton<String>(
            key: ValueKey<String>('network-podcast-menu-${podcast.id}'),
            tooltip: context.tr('更多操作'),
            icon: const Icon(Icons.more_horiz_rounded, size: 20),
            onSelected: (String action) {
              switch (action) {
                case 'open':
                  _openPodcast(podcast);
                case 'refresh':
                  unawaited(_refreshPodcast(podcast));
                case 'unsubscribe':
                  unawaited(_unsubscribe(podcast));
              }
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              const PopupMenuItem<String>(value: 'open', child: TrText('查看节目')),
              const PopupMenuItem<String>(
                value: 'refresh',
                child: TrText('刷新'),
              ),
              const PopupMenuItem<String>(
                value: 'unsubscribe',
                child: TrText('取消订阅'),
              ),
            ],
          ),
        ),
        if (podcast.error != null) NetworkErrorText(error: podcast.error),
      ],
    );
  }

  /// One row plus the hairline that separates it from the previous one.
  Widget _sectionRow(
    BuildContext context, {
    required bool showDivider,
    required Widget child,
  }) => Column(
    children: <Widget>[
      if (showDivider)
        Container(height: .5, color: AppleSemanticColors.of(context).separator),
      child,
    ],
  );
}

/// One action in a section header.
class _SectionAction {
  const _SectionAction({
    required this.id,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.filled = false,
  });

  final String id;
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool filled;
}

/// Section-header actions that fold into one menu on a phone.
///
/// Two labelled buttons next to a section title overflow at 390 dp with large
/// text; below ~520 dp the same actions live behind a single menu.
class _SectionActions extends StatelessWidget {
  const _SectionActions({required this.actions, required this.keyPrefix});

  final List<_SectionAction> actions;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final bool narrow = MediaQuery.sizeOf(context).width < 520;
    if (narrow) {
      final List<_SectionAction> enabled = <_SectionAction>[
        for (final _SectionAction action in actions)
          if (action.onPressed != null) action,
      ];
      if (enabled.isEmpty) return const SizedBox.shrink();
      return PopupMenuButton<_SectionAction>(
        key: ValueKey<String>('$keyPrefix-actions'),
        tooltip: context.tr('更多操作'),
        icon: const Icon(Icons.more_horiz_rounded, size: 20),
        onSelected: (_SectionAction action) => action.onPressed?.call(),
        itemBuilder: (BuildContext context) => <PopupMenuEntry<_SectionAction>>[
          for (final _SectionAction action in enabled)
            PopupMenuItem<_SectionAction>(
              value: action,
              child: TrText(action.label),
            ),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < actions.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: 6),
          if (actions[i].filled)
            SpringFilledButton.icon(
              key: ValueKey<String>(actions[i].id),
              onPressed: actions[i].onPressed,
              icon: Icon(actions[i].icon, size: 18),
              label: TrText(actions[i].label),
            )
          else
            SpringTextButton.icon(
              key: ValueKey<String>(actions[i].id),
              onPressed: actions[i].onPressed,
              icon: Icon(actions[i].icon, size: 18),
              label: TrText(actions[i].label),
            ),
        ],
      ],
    );
  }
}
