import 'dart:async';

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../theme/apple_design.dart';
import '../tv/tv_mode.dart';
import '../ui/widgets.dart';
import '../widgets/apple_ui.dart';
import '../widgets/build_safe_state.dart';
import '../widgets/spring_buttons.dart';
import 'network_sources_controller.dart';
import 'network_widgets.dart';
import 'podcast_feed.dart';

/// One podcast's episodes, with the listener's resume point.
class PodcastEpisodesPage extends StatefulWidget {
  const PodcastEpisodesPage({
    super.key,
    required this.state,
    required this.controller,
    required this.podcastId,
  });

  final AppState state;
  final NetworkSourcesController controller;
  final String podcastId;

  @override
  State<PodcastEpisodesPage> createState() => _PodcastEpisodesPageState();
}

class _PodcastEpisodesPageState extends State<PodcastEpisodesPage>
    with BuildSafeState<PodcastEpisodesPage> {
  bool _refreshing = false;

  NetworkSourcesController get network => widget.controller;

  PodcastSubscription? get _podcast => network.podcastById(widget.podcastId);

  @override
  void initState() {
    super.initState();
    unawaited(network.load());
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await network.refreshPodcast(widget.podcastId);
      if (!mounted) return;
      showNetworkMessage(context, '已刷新节目列表');
    } catch (error) {
      if (!mounted) return;
      showNetworkMessage(
        context,
        networkErrorSentence(context, error),
        error: true,
      );
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  /// Plays [index] and, unless [restart], seeks to the saved resume point.
  Future<void> _play(int index, {bool restart = false}) async {
    final PodcastSubscription? podcast = _podcast;
    if (podcast == null || index < 0 || index >= podcast.episodes.length) {
      return;
    }
    final List<Track> tracks = <Track>[
      for (final PodcastEpisode episode in podcast.episodes)
        podcastTrack(podcast, episode),
    ];
    final PodcastEpisode episode = podcast.episodes[index];
    final PodcastProgress progress = podcast.progressOf(episode.id);
    widget.state.playQueue(tracks, startIndex: index);
    if (restart) {
      if (progress.started) await network.clearEpisodeProgress(episode.id);
      return;
    }
    if (progress.position > Duration.zero) {
      await widget.state.seekTo(progress.position);
    }
  }

  Future<void> _playContinue(PodcastSubscription podcast) async {
    final PodcastEpisode? episode = podcast.continueEpisode;
    if (episode == null) return;
    final int index = podcast.episodes.indexWhere(
      (PodcastEpisode entry) => entry.id == episode.id,
    );
    if (index < 0) return;
    await _play(index);
  }

  Future<void> _markEpisode(PodcastEpisode episode, bool played) async {
    await network.markEpisodePlayed(episode.id, played: played);
    if (!mounted) return;
    showNetworkMessage(context, played ? '已标记为已播放' : '已标记为未播放');
  }

  Future<void> _clearProgress(PodcastEpisode episode) async {
    await network.clearEpisodeProgress(episode.id);
    if (!mounted) return;
    showNetworkMessage(context, '已清除这一集的收听进度');
  }

  Future<void> _openMenu(PodcastEpisode episode, Offset position) async {
    final RenderBox? overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final PodcastProgress progress =
        _podcast?.progressOf(episode.id) ?? const PodcastProgress();
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
        const PopupMenuItem<String>(value: 'play', child: TrText('从上次位置播放')),
        const PopupMenuItem<String>(value: 'restart', child: TrText('从头播放')),
        PopupMenuItem<String>(
          value: 'mark-played',
          child: TrText(progress.played ? '标记为未播放' : '标记为已播放'),
        ),
        if (progress.started)
          const PopupMenuItem<String>(value: 'clear', child: TrText('清除收听进度')),
      ],
    );
    if (!mounted || action == null) return;
    final int index =
        _podcast?.episodes.indexWhere(
          (PodcastEpisode entry) => entry.id == episode.id,
        ) ??
        -1;
    switch (action) {
      case 'play':
        if (index >= 0) await _play(index);
      case 'restart':
        if (index >= 0) await _play(index, restart: true);
      case 'mark-played':
        await _markEpisode(episode, !progress.played);
      case 'clear':
        await _clearProgress(episode);
    }
  }

  @override
  Widget build(BuildContext context) {
    final double inset = pageInset(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final ThemeData theme = Theme.of(context);
    return AnimatedBuilder(
      animation: network,
      builder: (BuildContext context, Widget? child) {
        final PodcastSubscription? podcast = _podcast;
        if (podcast == null) {
          return Center(
            child: AppleEmptyState(
              message: '这个播客订阅已经不在了。',
              icon: Icons.podcasts_rounded,
              action: SpringFilledButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: const TrText('返回'),
              ),
            ),
          );
        }
        final PodcastEpisode? resume = podcast.continueEpisode;
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 980),
            child: CustomScrollView(
              slivers: <Widget>[
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(inset, 8, inset, 0),
                  sliver: SliverToBoxAdapter(
                    child: ApplePageTitle(
                      title: podcast.displayTitle,
                      subtitle: <String>[
                        if (podcast.author.trim().isNotEmpty) podcast.author,
                        context.tr('${podcast.episodes.length} 集'),
                        if (podcast.lastFetchedAt != null)
                          context.tr(
                            '更新于 ${formatNetworkDate(context, podcast.lastFetchedAt)}',
                          ),
                      ].join(' · '),
                      padding: const EdgeInsets.fromLTRB(0, 12, 0, 12),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          IconButton(
                            key: const ValueKey<String>('podcast-refresh'),
                            tooltip: context.tr('刷新'),
                            onPressed: _refreshing ? null : _refresh,
                            icon: _refreshing
                                ? const NetworkProgressLabel(size: 18)
                                : Icon(
                                    Icons.sync_rounded,
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
                if (podcast.description.trim().isNotEmpty)
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(inset, 0, inset, 8),
                    sliver: SliverToBoxAdapter(
                      child: Text(
                        podcast.description,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: apple.secondaryLabel,
                        ),
                      ),
                    ),
                  ),
                if (resume != null)
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(inset, 8, inset, 0),
                    sliver: SliverToBoxAdapter(
                      child: AppleGroupedCard(
                        margin: EdgeInsets.zero,
                        child: AppleListTile(
                          key: const ValueKey<String>('podcast-continue'),
                          title: context.tr('继续播放'),
                          subtitle: resume.title,
                          leading: AppleIconTile(
                            icon: Icons.play_circle_fill_rounded,
                            color: apple.accent,
                          ),
                          showChevron: true,
                          onTap: () => unawaited(_playContinue(podcast)),
                        ),
                      ),
                    ),
                  ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(inset, 22, inset, 6),
                  sliver: SliverToBoxAdapter(
                    child: AppSectionHeader(
                      title: '节目',
                      subtitle: podcast.unplayedCount == 0
                          ? null
                          : context.tr('${podcast.unplayedCount} 集未听'),
                    ),
                  ),
                ),
                if (podcast.episodes.isEmpty)
                  SliverToBoxAdapter(
                    child: AppleEmptyState(
                      message: '这个订阅里还没有节目。',
                      icon: Icons.podcasts_rounded,
                      action: SpringOutlinedButton(
                        onPressed: _refreshing ? null : _refresh,
                        child: const TrText('刷新'),
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: EdgeInsets.symmetric(horizontal: inset),
                    sliver: SliverList.builder(
                      itemCount: podcast.episodes.length,
                      itemBuilder: (BuildContext context, int index) {
                        final PodcastEpisode episode = podcast.episodes[index];
                        return _EpisodeRow(
                          key: ValueKey<String>(
                            'podcast-episode-${episode.id}',
                          ),
                          episode: episode,
                          progress: podcast.progressOf(episode.id),
                          onTap: () => unawaited(_play(index)),
                          onMenu: (Offset position) =>
                              unawaited(_openMenu(episode, position)),
                        );
                      },
                    ),
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
}

class _EpisodeRow extends StatefulWidget {
  const _EpisodeRow({
    super.key,
    required this.episode,
    required this.progress,
    required this.onTap,
    required this.onMenu,
  });

  final PodcastEpisode episode;
  final PodcastProgress progress;
  final VoidCallback onTap;
  final ValueChanged<Offset> onMenu;

  @override
  State<_EpisodeRow> createState() => _EpisodeRowState();
}

class _EpisodeRowState extends State<_EpisodeRow>
    with BuildSafeState<_EpisodeRow> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final PodcastEpisode episode = widget.episode;
    final PodcastProgress progress = widget.progress;
    final String? date = episode.publishedAt == null
        ? null
        : _date(episode.publishedAt!);
    final String duration = episode.duration == null
        ? ''
        : formatDuration(episode.duration!);
    final String position = progress.started && !progress.played
        ? formatDuration(progress.position)
        : '';
    final String detail = <String>[
      ?date,
      if (duration.isNotEmpty) duration,
      if (position.isNotEmpty) context.tr('听到 $position'),
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
          onSecondaryTapDown: (TapDownDetails details) =>
              widget.onMenu(details.globalPosition),
          onLongPress: () {
            final RenderBox? box = context.findRenderObject() as RenderBox?;
            widget.onMenu(
              box?.localToGlobal(box.size.center(Offset.zero)) ?? Offset.zero,
            );
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            margin: const EdgeInsets.symmetric(vertical: 1),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              color: _hovering ? apple.fill : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  progress.played
                      ? Icons.check_circle_rounded
                      : Icons.play_circle_outline_rounded,
                  size: 20,
                  color: progress.played
                      ? apple.accent
                      : _hovering
                      ? apple.accent
                      : apple.tertiaryLabel,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        episode.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: widget.progress.played
                              ? apple.secondaryLabel
                              : apple.label,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (detail.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 2),
                        Text(
                          detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: apple.secondaryLabel,
                          ),
                        ),
                      ],
                      if (progress.started &&
                          !progress.played &&
                          episode.duration != null &&
                          episode.duration! > Duration.zero) ...<Widget>[
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value:
                                (progress.position.inMilliseconds /
                                        episode.duration!.inMilliseconds)
                                    .clamp(0, 1),
                            minHeight: 3,
                            backgroundColor: apple.fill,
                            color: apple.accent,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  tooltip: context.tr('更多操作'),
                  onPressed: () {
                    final RenderBox? box =
                        context.findRenderObject() as RenderBox?;
                    widget.onMenu(
                      box?.localToGlobal(box.size.center(Offset.zero)) ??
                          Offset.zero,
                    );
                  },
                  icon: Icon(
                    Icons.more_horiz_rounded,
                    size: 19,
                    color: apple.tertiaryLabel,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _date(DateTime value) {
    final DateTime local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)}';
  }
}
