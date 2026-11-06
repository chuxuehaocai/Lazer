import '../widgets/build_safe_state.dart';
import 'dart:async';

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../downloads/download_dialog.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../theme/apple_design.dart';
import '../widgets/interaction_feedback.dart';
import '../widgets/track_batch_bar.dart';
import 'widgets.dart';
import 'playlist_page.dart';

import 'home_pages.dart' show ChartLoadCard, chartEntryCover;

class AppChartPage extends StatefulWidget {
  const AppChartPage({super.key, required this.state, required this.chart});
  final AppState state;
  final MusicChart chart;

  @override
  State<AppChartPage> createState() => _AppChartPageState();
}

class _AppChartPageState extends State<AppChartPage>
    with BuildSafeState<AppChartPage> {
  MusicChart? _chart;
  bool _loading = true;
  bool _matching = false;
  int _requestSerial = 0;
  bool _selecting = false;
  final Set<String> _selected = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant AppChartPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state || oldWidget.chart != widget.chart) {
      _selecting = false;
      _selected.clear();
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final serial = ++_requestSerial;
    final source = widget.chart;
    if (mounted) {
      setState(() {
        _chart = source;
        _loading = false;
        _matching = source.entries.any((entry) => entry.track == null);
      });
    }
    if (source.entries.any((entry) => entry.track == null)) {
      unawaited(_matchInBackground(source, serial));
    }
  }

  Future<void> _matchInBackground(
    MusicChart source,
    int serial, {
    bool force = false,
  }) async {
    try {
      final matched = await widget.state.catalog.prepareChart(
        source,
        force: force,
      );
      if (!mounted || serial != _requestSerial) return;
      setState(() {
        _chart = matched;
        _matching = false;
      });
    } catch (_) {
      // Covers, ranks and source links remain usable without a NetEase match.
      if (mounted && serial == _requestSerial) {
        setState(() => _matching = false);
      }
    }
  }

  /// Re-runs the match after a board came back without a single playable row.
  Future<void> _retryMatching() async {
    if (_matching) return;
    final source = _chart ?? widget.chart;
    final serial = ++_requestSerial;
    setState(() => _matching = true);
    await _matchInBackground(source, serial, force: true);
  }

  Future<void> _selectIssue(ChartIssue issue) async {
    final current = _chart ?? widget.chart;
    if (issue.id == current.selectedIssueId || _loading) return;
    final serial = ++_requestSerial;
    setState(() {
      _loading = true;
      _matching = false;
      _selecting = false;
      _selected.clear();
    });
    try {
      final raw = await widget.state.catalog.chartIssue(current, issue);
      if (!mounted || serial != _requestSerial) return;
      setState(() {
        _chart = raw;
        _loading = false;
        _matching = raw.entries.any((entry) => entry.track == null);
      });
      unawaited(_matchInBackground(raw, serial));
    } catch (_) {
      if (mounted && serial == _requestSerial) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.tr('这一期暂时载入失败，请稍后重试。'))));
      }
    } finally {
      if (mounted && serial == _requestSerial && _loading) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final chart = _chart ?? widget.chart;
    final double inset = pageInset(context);
    final compact = MediaQuery.sizeOf(context).width < 680;
    final tracks = chart.entries
        .map((entry) => entry.track)
        .whereType<Track>()
        .toList();
    final playlist = Playlist(
      id: chart.id,
      name: chart.title,
      trackIds: tracks.map((track) => track.id).toList(),
      coverSeed: chart.id.hashCode,
      coverUrl: chart.entries.firstOrNull == null
          ? chart.logoUrl
          : chartEntryCover(chart.entries.first),
      trackCount: chart.entries.length,
      description: chart.source,
    );
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: Stack(
          fit: StackFit.expand,
          children: [
            CustomScrollView(
              slivers: <Widget>[
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(inset, 12, inset, 22),
                  sliver: SliverToBoxAdapter(
                    child: AppPlaylistHeader(
                      playlist: playlist,
                      compact: compact,
                      showShuffle: false,
                      transitionIdentity: 'chart:${chart.id}',
                      metadata: Wrap(
                        alignment: compact
                            ? WrapAlignment.center
                            : WrapAlignment.start,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          Text(
                            chart.source,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: AppleSemanticColors.of(
                                    context,
                                  ).secondaryLabel,
                                ),
                          ),
                          _ChartIssuePicker(
                            chart: chart,
                            loading: _loading,
                            onSelected: _selectIssue,
                          ),
                          TrText('${chart.entries.length} 首'),
                        ],
                      ),
                      onPlay: tracks.isEmpty
                          ? null
                          : () => widget.state.playQueue(tracks),
                      onDownload: tracks.isEmpty
                          ? null
                          : () => unawaited(
                              downloadTracks(
                                context,
                                widget.state,
                                tracks,
                                folderName: chart.title,
                              ),
                            ),
                    ),
                  ),
                ),
                if (_loading)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.only(bottom: 18),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  ),
                if (!_loading &&
                    !_matching &&
                    chart.entries.isNotEmpty &&
                    chart.entries.every((entry) => entry.track == null))
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(inset, 0, inset, 16),
                      child: ChartLoadCard(
                        loading: false,
                        message: '这些歌曲暂时匹配不到网易云，可以重新匹配', // i18n:key
                        onRetry: () => unawaited(_retryMatching()),
                      ),
                    ),
                  ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(inset, 0, inset, 6),
                  sliver: SliverToBoxAdapter(
                    child: AppSectionHeader(
                      title: '歌曲',
                      subtitle: '${chart.entries.length} 首',
                    ),
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(inset, 0, inset, 100),
                  sliver: SliverList.separated(
                    itemCount: chart.entries.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 2),
                    itemBuilder: (context, index) => _ChartTrackRow(
                      entry: chart.entries[index],
                      selectionMode: _selecting,
                      selected: _selected.contains(
                        chart.entries[index].track?.id,
                      ),
                      matching: _matching && chart.entries[index].track == null,
                      onLongPress: chart.entries[index].track == null
                          ? null
                          : () => setState(() {
                              _selecting = true;
                              _selected.add(chart.entries[index].track!.id);
                            }),
                      onMenuRequested: chart.entries[index].track == null
                          ? null
                          : (position) => unawaited(
                              showTrackActions(
                                context,
                                widget.state,
                                chart.entries[index].track!,
                                position,
                              ),
                            ),
                      onTap: chart.entries[index].track == null
                          ? null
                          : _selecting
                          ? () => setState(() {
                              final id = chart.entries[index].track!.id;
                              if (!_selected.add(id)) _selected.remove(id);
                            })
                          : () => widget.state.playQueue(
                              chart.entries
                                  .map((entry) => entry.track)
                                  .whereType<Track>()
                                  .toList(),
                              startIndex: chart.entries
                                  .take(index)
                                  .where((entry) => entry.track != null)
                                  .length,
                            ),
                    ),
                  ),
                ),
              ],
            ),
            if (_selecting)
              Positioned(
                left: 12,
                right: 12,
                bottom: 18,
                child: TrackBatchBar(
                  selectedCount: _selected.length,
                  totalCount: tracks.map((track) => track.id).toSet().length,
                  onSelectAll: () => setState(() {
                    if (_selected.length ==
                        tracks.map((track) => track.id).toSet().length) {
                      _selected.clear();
                    } else {
                      _selected.addAll(tracks.map((track) => track.id));
                    }
                  }),
                  onDownload:
                      tracks.any(
                        (track) =>
                            _selected.contains(track.id) &&
                            track.isServiceTrack,
                      )
                      ? () => unawaited(
                          downloadTracks(
                            context,
                            widget.state,
                            tracks
                                .where((track) => _selected.contains(track.id))
                                .toList(),
                            folderName: chart.title,
                          ),
                        )
                      : null,
                  onClose: () => setState(() {
                    _selecting = false;
                    _selected.clear();
                  }),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ChartIssuePicker extends StatelessWidget {
  const _ChartIssuePicker({
    required this.chart,
    required this.loading,
    required this.onSelected,
  });

  final MusicChart chart;
  final bool loading;
  final ValueChanged<ChartIssue> onSelected;

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: AppleSemanticColors.of(context).secondaryLabel,
      fontWeight: FontWeight.w600,
    );
    if (chart.issues.length < 2) {
      return TrText(chart.issueLabel, style: textStyle);
    }
    return PopupMenuButton<ChartIssue>(
      enabled: !loading,
      tooltip: context.tr('选择榜单期数'),
      onSelected: onSelected,
      itemBuilder: (context) => <PopupMenuEntry<ChartIssue>>[
        for (final issue in chart.issues)
          PopupMenuItem<ChartIssue>(
            value: issue,
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 20,
                  child: issue.id == chart.selectedIssueId
                      ? const Icon(Icons.check_rounded, size: 17)
                      : null,
                ),
                const SizedBox(width: 8),
                TrText(issue.label),
              ],
            ),
          ),
      ],
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppleSemanticColors.of(context).fill,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: AppleSemanticColors.of(context).separator,
            width: .5,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TrText(chart.issueLabel, style: textStyle),
              const SizedBox(width: 4),
              if (loading)
                SizedBox.square(
                  dimension: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: AppleSemanticColors.of(context).accent,
                  ),
                )
              else
                Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 17,
                  color: AppleSemanticColors.of(context).secondaryLabel,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChartTrackRow extends StatelessWidget {
  const _ChartTrackRow({
    required this.entry,
    this.matching = false,
    this.onTap,
    this.onLongPress,
    this.onMenuRequested,
    this.selectionMode = false,
    this.selected = false,
  });
  final ChartEntry entry;
  final bool matching;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final ValueChanged<Offset>? onMenuRequested;
  final bool selectionMode;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final apple = AppleSemanticColors.of(context);
    final roomy = MediaQuery.sizeOf(context).width >= 760;
    final int? previous = entry.previousRank;
    final IconData? trend = switch (entry.changeLabel) {
      'NEW' => Icons.fiber_new_rounded,
      '重返' || '重投' => Icons.replay_rounded, // i18n:key
      _ when previous != null && previous > entry.rank =>
        Icons.arrow_upward_rounded,
      _ when previous != null && previous < entry.rank =>
        Icons.arrow_downward_rounded,
      _ when previous != null => Icons.remove_rounded,
      _ => null,
    };
    return GestureDetector(
      onSecondaryTapDown: onMenuRequested == null
          ? null
          : (details) => onMenuRequested!(details.globalPosition),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        child: ListTile(
          minTileHeight: 60,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 3,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          tileColor: selected ? apple.accentSoft : Colors.transparent,
          onTap: onTap == null ? null : feedbackAction(context, onTap!),
          onLongPress: onLongPress,
          leading: SizedBox(
            width: 80,
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 28,
                  child: selectionMode && entry.track != null
                      ? Icon(
                          selected
                              ? Icons.check_circle_rounded
                              : Icons.radio_button_unchecked_rounded,
                          size: 21,
                          color: selected ? apple.accent : apple.tertiaryLabel,
                        )
                      : Text(
                          '${entry.rank}',
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.visible,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(color: apple.tertiaryLabel),
                        ),
                ),
                const SizedBox(width: 8),
                AppCover(
                  url: entry.track?.coverUrl ?? entry.coverUrl,
                  size: 44,
                  radius: 6,
                ),
              ],
            ),
          ),
          titleTextStyle: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: apple.label),
          subtitleTextStyle: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: apple.secondaryLabel),
          title: Text(
            entry.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            <String>[
              entry.artist.isNotEmpty
                  ? entry.artist
                  : entry.track?.artist ?? '',
              if (entry.peakRank != null) context.tr('最高 #${entry.peakRank}'),
              if (entry.weeksOnChart != null)
                context.tr('${entry.weeksOnChart} 周'),
              if (!roomy && entry.score != null)
                context.tr('${_formatChartScore(entry.score!)} 点'),
            ].where((value) => value.isNotEmpty).join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (roomy && entry.score != null) ...<Widget>[
                TrText(
                  '${_formatChartScore(entry.score!)} 点',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: apple.secondaryLabel,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 10),
              ],
              if (roomy && entry.trend.length > 1) ...<Widget>[
                SizedBox(
                  width: 64,
                  height: 28,
                  child: CustomPaint(
                    painter: _ChartSparklinePainter(
                      values: entry.trend,
                      color: apple.accent,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              if (trend != null)
                Icon(trend, size: 16, color: apple.secondaryLabel),
              if (entry.changeLabel != null) ...<Widget>[
                if (trend != null) const SizedBox(width: 3),
                TrText(
                  entry.changeLabel!,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: apple.secondaryLabel,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              if (trend != null || entry.changeLabel != null)
                const SizedBox(width: 10),
              if (matching)
                const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 1.7),
                )
              else if (entry.track == null)
                Icon(Icons.link_off_rounded, color: apple.tertiaryLabel),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatChartScore(int score) {
  final String digits = score.toString();
  final StringBuffer grouped = StringBuffer();
  for (int i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) grouped.write(',');
    grouped.write(digits[i]);
  }
  return grouped.toString();
}

class _ChartSparklinePainter extends CustomPainter {
  const _ChartSparklinePainter({required this.values, required this.color});

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final minValue = values.reduce(math.min);
    final maxValue = values.reduce(math.max);
    final span = math.max(1.0, maxValue - minValue);
    final path = Path();
    for (var index = 0; index < values.length; index++) {
      final x = size.width * index / (values.length - 1);
      final y = size.height - ((values[index] - minValue) / span * size.height);
      if (index == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_ChartSparklinePainter oldDelegate) =>
      oldDelegate.color != color || !listEquals(oldDelegate.values, values);
}
