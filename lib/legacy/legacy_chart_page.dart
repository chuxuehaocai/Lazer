import 'dart:async';

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../theme/apple_design.dart';
import '../widgets/interaction_feedback.dart';
import '../tv/tv_mode.dart';
import 'legacy_widgets.dart';

import 'legacy_home_pages.dart' show ChartLoadCard, ChartLogo, chartEntryCover;

class LegacyChartPage extends StatefulWidget {
  const LegacyChartPage({super.key, required this.state, required this.chart});
  final AppState state;
  final MusicChart chart;

  @override
  State<LegacyChartPage> createState() => _LegacyChartPageState();
}

class _LegacyChartPageState extends State<LegacyChartPage> {
  MusicChart? _chart;
  bool _loading = true;
  bool _matching = false;
  int _requestSerial = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
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
    final Color accent = Color(chart.accent);
    final double inset = legacyPageInset(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1180),
        child: CustomScrollView(
          slivers: <Widget>[
            SliverToBoxAdapter(
              child: Container(
                margin: EdgeInsets.fromLTRB(inset, 20, inset, 28),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[
                      accent,
                      Color.lerp(accent, Colors.black, .66)!,
                    ],
                  ),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: accent.withValues(alpha: .2),
                      blurRadius: 30,
                      offset: const Offset(0, 14),
                    ),
                  ],
                ),
                child: _ChartHero(
                  chart: chart,
                  loading: _loading,
                  onIssueSelected: _selectIssue,
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
              padding: EdgeInsets.fromLTRB(inset, 0, inset, 40),
              sliver: SliverList.separated(
                itemCount: chart.entries.length,
                separatorBuilder: (_, _) => const SizedBox(height: 2),
                itemBuilder: (context, index) => _ChartTrackRow(
                  entry: chart.entries[index],
                  matching: _matching && chart.entries[index].track == null,
                  onTap: chart.entries[index].track == null
                      ? null
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
      ),
    );
  }
}

class _ChartHero extends StatelessWidget {
  const _ChartHero({
    required this.chart,
    required this.loading,
    required this.onIssueSelected,
  });

  final MusicChart chart;
  final bool loading;
  final ValueChanged<ChartIssue> onIssueSelected;

  Widget _info(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      ChartLogo(chart: chart, large: true),
      const SizedBox(height: 18),
      Text(
        chart.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.displaySmall?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w900,
          letterSpacing: -1.1,
        ),
      ),
      const SizedBox(height: 9),
      Row(
        children: <Widget>[
          Flexible(
            child: _ChartIssuePicker(
              chart: chart,
              loading: loading,
              onSelected: onIssueSelected,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            context.tr('${chart.entries.length} 首'),
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
          ),
        ],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 700;
      if (compact) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 25, 24, 16),
              child: _info(context),
            ),
            SizedBox(
              height: 178,
              child: _ChartHeroArtwork(entries: chart.entries.take(3).toList()),
            ),
          ],
        );
      }
      return SizedBox(
        height: 286,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Positioned(
              top: -28,
              right: -24,
              bottom: -28,
              width: constraints.maxWidth * .61,
              child: _ChartHeroArtwork(entries: chart.entries.take(3).toList()),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: <Color>[
                    Color(0xEE16080D),
                    Color(0xC816080D),
                    Color(0x0016080D),
                  ],
                  stops: <double>[0, .47, .78],
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: constraints.maxWidth * .52,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(32, 30, 20, 30),
                  child: _info(context),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _ChartHeroArtwork extends StatelessWidget {
  const _ChartHeroArtwork({required this.entries});
  final List<ChartEntry> entries;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final covers = entries.map(chartEntryCover).toList(growable: false);
      final side = math.min(
        constraints.maxHeight * .78,
        constraints.maxWidth * .42,
      );
      return Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          for (var index = covers.length - 1; index >= 0; index--)
            Positioned(
              left: constraints.maxWidth * (.07 + index * .205),
              top: constraints.maxHeight * (.1 + index * .045),
              child: Transform.rotate(
                angle: (index - 1) * .055,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: const <BoxShadow>[
                      BoxShadow(
                        color: Color(0x66000000),
                        blurRadius: 28,
                        offset: Offset(0, 14),
                      ),
                    ],
                  ),
                  child: LegacyCover(
                    url: covers[index],
                    size: side,
                    radius: 16,
                    iconSize: 34,
                  ),
                ),
              ),
            ),
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[Color(0x00000000), Color(0xB8000000)],
                  stops: <double>[.48, 1],
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
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
      color: Colors.white,
      fontWeight: FontWeight.w700,
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
          color: Colors.white.withValues(alpha: .14),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white24, width: .5),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TrText(chart.issueLabel, style: textStyle),
              const SizedBox(width: 4),
              if (loading)
                const SizedBox.square(
                  dimension: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: Colors.white,
                  ),
                )
              else
                const Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 17,
                  color: Colors.white,
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
  });
  final ChartEntry entry;
  final bool matching;
  final VoidCallback? onTap;

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
    return ListTile(
      minTileHeight: 68,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      tileColor: apple.secondaryGroupedBackground,
      onTap: onTap == null ? null : feedbackAction(context, onTap!),
      leading: SizedBox(
        width: 84,
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 38,
              child: Text(
                '${entry.rank}',
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.visible,
                textAlign: TextAlign.right,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(width: 6),
            LegacyCover(
              url: entry.track?.coverUrl ?? entry.coverUrl,
              size: 40,
              radius: 6,
            ),
          ],
        ),
      ),
      title: Text(
        entry.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        <String>[
          entry.artist.isNotEmpty ? entry.artist : entry.track?.artist ?? '',
          if (entry.peakRank != null) context.tr('最高 #${entry.peakRank}'),
          if (entry.weeksOnChart != null) context.tr('${entry.weeksOnChart} 周'),
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
          if (trend != null) Icon(trend, size: 16, color: apple.secondaryLabel),
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
          else
            Icon(
              onTap == null ? Icons.link_off_rounded : Icons.play_arrow_rounded,
              color: onTap == null ? apple.tertiaryLabel : apple.accent,
            ),
        ],
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

/// Large recommendation hero. Album art is the content; a bottom scrim keeps
/// white typography legible over any cover.
class _FeaturedPlaylistCard extends StatefulWidget {
  const _FeaturedPlaylistCard({
    required this.playlist,
    required this.onTap,
    required this.compact,
  });

  final Playlist playlist;
  final VoidCallback onTap;
  final bool compact;

  @override
  State<_FeaturedPlaylistCard> createState() => _FeaturedPlaylistCardState();
}

class _FeaturedPlaylistCardState extends State<_FeaturedPlaylistCard> {
  bool _hovering = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final bool raised = _hovering || _focused;
    final String subtitle = <String>[
      if (widget.playlist.trackCount > 0)
        context.tr('${widget.playlist.trackCount} 首歌曲'),
      if (widget.playlist.description.isNotEmpty) widget.playlist.description,
    ].join(' · ');
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: TvTapTarget(
        onTap: widget.onTap,
        onFocusChange: (bool value) => setState(() => _focused = value),
        borderRadius: BorderRadius.circular(18),
        focusScale: 1.006,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: raised ? 1.004 : 1,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: Container(
              height: widget.compact ? 190 : 248,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: apple.separator.withValues(alpha: .4),
                  width: .5,
                ),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: .16),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  if (widget.playlist.coverUrl?.isNotEmpty ?? false)
                    LegacyCover(
                      url: widget.playlist.coverUrl,
                      size: widget.compact ? 190 : 248,
                      radius: 0,
                    )
                  else
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: <Color>[
                            apple.accent,
                            Color.lerp(
                              apple.accent,
                              AppleColors.systemPurple,
                              .38,
                            )!,
                          ],
                        ),
                      ),
                    ),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: <Color>[
                          Color(0x00000000),
                          Color(0x33000000),
                          Color(0xD9000000),
                        ],
                        stops: <double>[.2, .54, 1],
                      ),
                    ),
                  ),
                  Positioned(
                    left: widget.compact ? 18 : 24,
                    right: widget.compact ? 18 : 24,
                    bottom: widget.compact ? 16 : 22,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: <Widget>[
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Text(
                                context.tr('为你精选'),
                                style: Theme.of(context).textTheme.labelMedium
                                    ?.copyWith(
                                      color: Colors.white.withValues(
                                        alpha: .72,
                                      ),
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: .4,
                                    ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                widget.playlist.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.headlineSmall
                                    ?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: -.4,
                                    ),
                              ),
                              if (subtitle.isNotEmpty) ...<Widget>[
                                const SizedBox(height: 4),
                                Text(
                                  subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: Colors.white.withValues(
                                          alpha: .72,
                                        ),
                                      ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 16),
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(
                              alpha: raised ? 1 : .86,
                            ),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.play_arrow_rounded,
                            size: 27,
                            color: Colors.black,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
