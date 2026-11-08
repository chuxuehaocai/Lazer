import '../widgets/build_safe_state.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../listening/listening_statistics.dart';
import '../theme/apple_design.dart';
import '../widgets/apple_ui.dart';
import '../widgets/settings_detail.dart';
import '../widgets/ui_scaling.dart';
import 'widgets.dart';

/// The device's own listening history, including local and streamed music.
class AppListeningStatisticsPage extends StatefulWidget {
  const AppListeningStatisticsPage({super.key, required this.statistics});

  final ListeningStatisticsController statistics;

  @override
  State<AppListeningStatisticsPage> createState() =>
      _AppListeningStatisticsPageState();
}

class _AppListeningStatisticsPageState extends State<AppListeningStatisticsPage>
    with BuildSafeState<AppListeningStatisticsPage> {
  ListeningRange _range = ListeningRange.last7Days;

  Widget _content(BuildContext context) {
    final inset = pageInset(context);
    return AnimatedBuilder(
      animation: widget.statistics,
      builder: (context, _) {
        final data = widget.statistics.snapshot(_range);
        final date = data.firstRecordedAt == null
            ? null
            : _date(data.firstRecordedAt!);
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: adaptiveContentMaxWidth(context, 1100),
            ),
            child: ListView(
              key: const PageStorageKey('listening-statistics-scroll'),
              padding: EdgeInsets.fromLTRB(inset, 8, inset, 32),
              children: <Widget>[
                ApplePageTitle(
                  title: '你的音乐足迹',
                  subtitle: date == null ? '记录从首次播放开始' : '开始记录于 $date',
                  padding: const EdgeInsets.only(top: 12, bottom: 20),
                ),
                _RangeSelector(
                  selected: _range,
                  onChanged: (value) => setState(() => _range = value),
                ),
                const SizedBox(height: 20),
                if (!widget.statistics.loaded)
                  const Padding(
                    padding: EdgeInsets.all(40),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else ...<Widget>[
                  _Summary(data: data),
                  const SizedBox(height: 20),
                  if (data.totalDuration == Duration.zero &&
                      data.playCount == 0)
                    AppleGroupedCard(
                      key: const ValueKey('listening-statistics-empty'),
                      margin: EdgeInsets.zero,
                      child: const AppleEmptyState(
                        message: '这段时间还没有听歌记录。播放一首喜欢的歌，让音乐足迹慢慢积累。',
                        icon: Icons.insights_rounded,
                      ),
                    )
                  else ...<Widget>[
                    _HourlyCard(
                      key: ValueKey(_range),
                      durations: data.hourlyDuration,
                      peakHour: data.peakHour,
                    ),
                    const SizedBox(height: 20),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final skipped = _RankingCard(
                          title: '最常切走的歌',
                          subtitle: '按主动切歌次数排序',
                          tracks: data.mostSkipped.take(5).toList(),
                          skipped: true,
                        );
                        final played = _RankingCard(
                          title: '最常播放的歌',
                          subtitle: '按播放次数排序',
                          tracks: data.mostPlayed.take(5).toList(),
                          skipped: false,
                        );
                        if (constraints.maxWidth < 740) {
                          return Column(
                            children: <Widget>[
                              skipped,
                              const SizedBox(height: 20),
                              played,
                            ],
                          );
                        }
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Expanded(child: skipped),
                            const SizedBox(width: 20),
                            Expanded(child: played),
                          ],
                        );
                      },
                    ),
                  ],
                  const SizedBox(height: 24),
                  const _CountingNotes(),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final content = _content(context);
    if (SettingsDetailHost.isEmbedded(context)) {
      return SettingsDetailScaffold(title: '听歌统计', child: content);
    }
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: false,
      appBar: AppBar(
        title: const TrText('听歌统计'),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      body: SafeArea(top: false, child: content),
    );
  }
}

String _date(DateTime value) =>
    '${value.year}/${value.month.toString().padLeft(2, '0')}/${value.day.toString().padLeft(2, '0')}';

String _rangeLabel(ListeningRange range) => switch (range) {
  ListeningRange.today => '今天', // i18n:key
  ListeningRange.last7Days => '近 7 天', // i18n:key
  ListeningRange.last30Days => '近 30 天', // i18n:key
  ListeningRange.allTime => '全部', // i18n:key
};

class _RangeSelector extends StatelessWidget {
  const _RangeSelector({required this.selected, required this.onChanged});
  final ListeningRange selected;
  final ValueChanged<ListeningRange> onChanged;

  @override
  Widget build(BuildContext context) {
    // A wrap keeps every period available at large accessibility text sizes.
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final range in ListeningRange.values)
          ChoiceChip(
            key: ValueKey('listening-range-${range.name}'),
            label: TrText(_rangeLabel(range)),
            selected: range == selected,
            showCheckmark: false,
            onSelected: (_) => onChanged(range),
          ),
      ],
    );
  }
}

String _listeningDuration(BuildContext context, Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds;
  if (duration.inHours > 0) {
    final minutes = duration.inMinutes % 60;
    return context.tr('$hours 小时 $minutes 分钟');
  }
  if (duration.inMinutes > 0) return context.tr('$minutes 分钟');
  return context.tr('$seconds 秒');
}

String _hour(int value) => '${value.toString().padLeft(2, '0')}:00';
String _hourRange(int value) => '${_hour(value)}–${_hour((value + 1) % 24)}';

class _Summary extends StatelessWidget {
  const _Summary({required this.data});
  final ListeningStatisticsSnapshot data;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 12.0;
        final columns = constraints.maxWidth >= 740 ? 4 : 2;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: <Widget>[
            for (final metric in <(String, String, IconData)>[
              (
                '听歌时长', // i18n:key
                _listeningDuration(context, data.totalDuration),
                Icons.headphones_rounded,
              ),
              (
                '播放次数', // i18n:key
                '${data.playCount}',
                Icons.play_arrow_rounded,
              ),
              (
                '主动切歌', // i18n:key
                '${data.skipCount}',
                Icons.skip_next_rounded,
              ),
              (
                '最爱听歌时段', // i18n:key
                data.peakHour == null ? '—' : _hour(data.peakHour!),
                Icons.schedule_rounded,
              ),
            ])
              SizedBox(
                width: width,
                child: _MetricCard(
                  label: metric.$1,
                  value: metric.$2,
                  icon: metric.$3,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.icon,
  });
  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final apple = AppleSemanticColors.of(context);
    final text = Theme.of(context).textTheme;
    return Semantics(
      container: true,
      label: '${context.tr(label)}, $value',
      excludeSemantics: true,
      child: AppleGroupedCard(
        margin: EdgeInsets.zero,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(icon, color: apple.accent, size: 23),
            const SizedBox(height: 14),
            SizedBox(
              height: 40,
              child: FittedBox(
                alignment: AlignmentDirectional.centerStart,
                fit: BoxFit.scaleDown,
                child: Text(
                  value,
                  style: text.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: apple.label,
                    letterSpacing: -.7,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            TrText(
              label,
              style: text.bodySmall?.copyWith(color: apple.secondaryLabel),
            ),
          ],
        ),
      ),
    );
  }
}

class _HourlyCard extends StatefulWidget {
  const _HourlyCard({
    super.key,
    required this.durations,
    required this.peakHour,
  });
  final List<Duration> durations;
  final int? peakHour;

  @override
  State<_HourlyCard> createState() => _HourlyCardState();
}

class _HourlyCardState extends State<_HourlyCard>
    with BuildSafeState<_HourlyCard> {
  int? _selected;
  bool _focused = false;

  void _select(int value) => setState(() => _selected = value.clamp(0, 23));

  @override
  Widget build(BuildContext context) {
    final apple = AppleSemanticColors.of(context);
    final text = Theme.of(context).textTheme;
    final selected = _selected ?? widget.peakHour ?? 0;
    final duration = widget.durations[selected];
    final maximum = widget.durations.fold<int>(
      1,
      (value, duration) => math.max(value, duration.inMilliseconds),
    );
    final detail =
        '${_hourRange(selected)} · ${_listeningDuration(context, duration)}';
    String detailFor(int hour) =>
        '${_hourRange(hour)} · ${_listeningDuration(context, widget.durations[hour])}';
    return AppleGroupedCard(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const AppSectionHeader(title: '一天中的音乐时光'),
          const SizedBox(height: 6),
          TrText(
            '按本地小时累计实际听歌时长',
            style: text.bodySmall?.copyWith(color: apple.secondaryLabel),
          ),
          const SizedBox(height: 18),
          Text(
            detail,
            key: const ValueKey('listening-hour-detail'),
            style: text.titleMedium?.copyWith(
              color: apple.accent,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 18),
          CallbackShortcuts(
            bindings: <ShortcutActivator, VoidCallback>{
              const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                  _select(selected - 1),
              const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                  _select(selected + 1),
            },
            child: Focus(
              onFocusChange: (value) => setState(() => _focused = value),
              child: Semantics(
                key: const ValueKey('listening-hour-chart'),
                container: true,
                label: context.tr('每小时听歌时长'),
                value: detail,
                increasedValue: selected < 23 ? detailFor(selected + 1) : null,
                decreasedValue: selected > 0 ? detailFor(selected - 1) : null,
                hint: context.tr('左右调整查看不同时段'),
                slider: true,
                onIncrease: selected < 23 ? () => _select(selected + 1) : null,
                onDecrease: selected > 0 ? () => _select(selected - 1) : null,
                excludeSemantics: true,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: _focused ? apple.accent : Colors.transparent,
                    ),
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      void selectAt(Offset position) => _select(
                        (position.dx / constraints.maxWidth * 24).floor(),
                      );
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (details) => selectAt(details.localPosition),
                        onHorizontalDragUpdate: (details) =>
                            selectAt(details.localPosition),
                        child: SizedBox(
                          height: 150,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: <Widget>[
                              for (int hour = 0; hour < 24; hour++)
                                Expanded(
                                  child: Tooltip(
                                    message:
                                        '${_hourRange(hour)} · ${_listeningDuration(context, widget.durations[hour])}',
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 2,
                                      ),
                                      child: Container(
                                        height: math.max(
                                          3,
                                          widget
                                                  .durations[hour]
                                                  .inMilliseconds /
                                              maximum *
                                              146,
                                        ),
                                        decoration: BoxDecoration(
                                          color: hour == selected
                                              ? apple.accent
                                              : widget.durations[hour] ==
                                                    Duration.zero
                                              ? apple.tertiaryFill
                                              : apple.accent.withValues(
                                                  alpha: .38,
                                                ),
                                          borderRadius: BorderRadius.circular(
                                            3,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              for (final hour
                  in MediaQuery.textScalerOf(context).scale(1) > 1.3
                      ? <int>[0, 12, 23]
                      : <int>[0, 6, 12, 18, 23])
                Text(
                  _hour(hour),
                  style: text.labelSmall?.copyWith(color: apple.secondaryLabel),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RankingCard extends StatelessWidget {
  const _RankingCard({
    required this.title,
    required this.subtitle,
    required this.tracks,
    required this.skipped,
  });
  final String title;
  final String subtitle;
  final List<ListeningTrackStatistics> tracks;
  final bool skipped;

  @override
  Widget build(BuildContext context) {
    final apple = AppleSemanticColors.of(context);
    final text = Theme.of(context).textTheme;
    return AppleGroupedCard(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                AppSectionHeader(title: title),
                const SizedBox(height: 6),
                TrText(
                  subtitle,
                  style: text.bodySmall?.copyWith(color: apple.secondaryLabel),
                ),
              ],
            ),
          ),
          if (tracks.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 24),
              child: TrText(
                skipped ? '这段时间没有主动切歌记录。' : '播放记录正在慢慢积累。',
                style: text.bodyMedium?.copyWith(color: apple.secondaryLabel),
              ),
            ),
          for (int index = 0; index < tracks.length; index++) ...<Widget>[
            if (index > 0)
              Divider(
                height: .5,
                thickness: .5,
                indent: 20,
                endIndent: 20,
                color: apple.separator,
              ),
            _RankingRow(
              entry: tracks[index],
              rank: index + 1,
              skipped: skipped,
            ),
          ],
        ],
      ),
    );
  }
}

class _RankingRow extends StatelessWidget {
  const _RankingRow({
    required this.entry,
    required this.rank,
    required this.skipped,
  });
  final ListeningTrackStatistics entry;
  final int rank;
  final bool skipped;

  @override
  Widget build(BuildContext context) {
    final apple = AppleSemanticColors.of(context);
    final text = Theme.of(context).textTheme;
    final count = skipped ? entry.skipCount : entry.playCount;
    final countLabel = skipped
        ? context.tr('切歌 $count 次')
        : context.tr('播放 $count 次');
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 20,
              child: Text(
                '$rank',
                style: text.bodyMedium?.copyWith(color: apple.secondaryLabel),
              ),
            ),
            const SizedBox(width: 8),
            ExcludeSemantics(
              child: AppCover(url: entry.track.coverUrl, size: 42, radius: 7),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    entry.track.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    entry.track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(
                      color: apple.secondaryLabel,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '$countLabel · ${_listeningDuration(context, entry.duration)}',
                    style: text.labelSmall?.copyWith(
                      color: apple.secondaryLabel,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CountingNotes extends StatelessWidget {
  const _CountingNotes();

  @override
  Widget build(BuildContext context) {
    final apple = AppleSemanticColors.of(context);
    final style = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: apple.secondaryLabel, height: 1.6);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        TrText(
          '关于这些记录',
          style: style?.copyWith(
            fontWeight: FontWeight.w600,
            color: apple.label,
          ),
        ),
        const SizedBox(height: 6),
        TrText('只统计本机从此功能启用后的播放，不回填历史记录。', style: style),
        TrText(
          '时长按实际播放累计，暂停、缓冲和拖动进度不计入。实际听满 1 秒计为一次播放，暂停后继续不重复计数。',
          style: style,
        ),
        TrText('主动切到另一首歌计为切歌；自然播完、播放失败和切换音质不计入。', style: style),
      ],
    );
  }
}
