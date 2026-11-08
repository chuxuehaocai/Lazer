import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

/// Reads the public Billboard Hot 100 page so the chart keeps all 100 rows,
/// artwork and published movement metadata instead of inheriting the shorter
/// music provider mirror.
class BillboardClient {
  BillboardClient({http.Client? client}) : _client = client ?? http.Client();

  static final Uri _hot100 = Uri.parse(
    'https://www.billboard.com/charts/hot-100/',
  );
  static const String _historyArchive =
      'https://raw.githubusercontent.com/mhollingshead/'
      'billboard-hot-100/main/date/';
  final http.Client _client;

  Future<MusicChart?> latestChart() => _loadChart(_hot100);

  Future<MusicChart> chartForIssue(MusicChart chart, ChartIssue issue) async {
    final date = _dateFromId(issue.id);
    if (date == null) throw ArgumentError.value(issue.id, 'issue.id');
    final loaded = await _loadChart(
      Uri.parse('https://www.billboard.com/charts/hot-100/${_isoDate(date)}/'),
      inheritedIssues: chart.issues,
      selectedIssueId: issue.id,
    );
    if (loaded == null) throw StateError('Billboard issue is empty.');
    return loaded;
  }

  /// Adds the uninterrupted weekly run ending at [chart]'s selected issue.
  /// Billboard's page exposes only last week, so the compact JSON archive is
  /// used for prior snapshots while the current chart remains authoritative.
  Future<MusicChart> withHistory(MusicChart chart) async {
    final selected = chart.selectedIssueId;
    final issueDate = selected == null
        ? _parseIssueDate(chart.issueLabel)
        : _dateFromId(selected);
    if (issueDate == null || chart.entries.isEmpty) return chart;

    var lookback = 0;
    for (final entry in chart.entries) {
      final weeks = entry.weeksOnChart ?? 1;
      if (weeks - 1 > lookback) lookback = weeks - 1;
    }
    if (lookback <= 0) return chart;
    // The longest Hot 100 runs fit comfortably inside this defensive bound;
    // malformed upstream metadata must not fan out into unlimited requests.
    if (lookback > 120) lookback = 120;

    final snapshots = <_BillboardWeek?>[];
    for (var start = 1; start <= lookback; start += 8) {
      final end = (start + 8 <= lookback + 1) ? start + 8 : lookback + 1;
      snapshots.addAll(
        await Future.wait<_BillboardWeek?>([
          for (var offset = start; offset < end; offset++)
            _tryLoadHistoryWeek(issueDate.subtract(Duration(days: offset * 7))),
        ]),
      );
    }

    final entries = <ChartEntry>[
      for (final entry in chart.entries)
        if (entry.weeksOnChart == null || entry.weeksOnChart! <= 1)
          entry.copyWith(trend: <double>[(101 - entry.rank).toDouble()])
        else
          entry.copyWith(trend: _currentRun(entry, snapshots)),
    ];
    return MusicChart(
      id: chart.id,
      title: chart.title,
      source: chart.source,
      issueLabel: chart.issueLabel,
      entries: entries,
      accent: chart.accent,
      providerKey: chart.providerKey,
      logoUrl: chart.logoUrl,
      issues: chart.issues,
      selectedIssueId: chart.selectedIssueId,
    );
  }

  Future<_BillboardWeek> _loadHistoryWeek(DateTime date) async {
    final response = await _client
        .get(
          Uri.parse('$_historyArchive${_isoDate(date)}.json'),
          headers: const <String, String>{
            'accept': 'application/json',
            'user-agent': 'Mozilla/5.0 Lazer/1.0',
          },
        )
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw StateError(
        'Billboard history request failed: ${response.statusCode}',
      );
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Expected Billboard history JSON.');
    }
    return _BillboardWeek.fromJson(decoded);
  }

  Future<_BillboardWeek?> _tryLoadHistoryWeek(DateTime date) async {
    try {
      return await _loadHistoryWeek(date);
    } catch (_) {
      return null;
    }
  }

  static List<double> _currentRun(
    ChartEntry entry,
    List<_BillboardWeek?> snapshots,
  ) {
    final newestFirst = <double>[(101 - entry.rank).toDouble()];
    for (final snapshot in snapshots) {
      if (snapshot == null) continue;
      final rank = snapshot.rankFor(entry.title, entry.artist);
      if (rank == null) break;
      newestFirst.add((101 - rank).toDouble());
      if (newestFirst.length >= (entry.weeksOnChart ?? 1)) break;
    }
    return newestFirst.reversed.toList();
  }

  Future<MusicChart?> _loadChart(
    Uri uri, {
    List<ChartIssue>? inheritedIssues,
    int? selectedIssueId,
  }) async {
    final response = await _client
        .get(
          uri,
          headers: const <String, String>{
            'accept': 'text/html,application/xhtml+xml',
            'user-agent': 'Mozilla/5.0 Lazer/1.0',
          },
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw StateError('Billboard request failed: ${response.statusCode}');
    }

    final html = response.body;
    final entries = <ChartEntry>[];
    for (final segment
        in html.split('o-chart-results-list-row-container').skip(1)) {
      final rank = int.tryParse(_capture(segment, _rankPattern) ?? '');
      final title = _clean(_capture(segment, _titlePattern) ?? '');
      if (rank == null || title.isEmpty) continue;
      final cover = _decodeEntities(_capture(segment, _coverPattern) ?? '');
      final previousText = _capture(segment, _lastWeekPattern);
      final previousRank = int.tryParse(previousText ?? '');
      final changeLabel = previousText == '-'
          ? 'NEW'
          : previousRank == null
          ? null
          : previousRank > rank
          ? '↑${previousRank - rank}'
          : previousRank < rank
          ? '↓${rank - previousRank}'
          : '—';
      entries.add(
        ChartEntry(
          rank: rank,
          title: title,
          artist: _clean(_stripTags(_capture(segment, _artistPattern) ?? '')),
          coverUrl: cover.isEmpty ? null : cover,
          previousRank: previousRank,
          peakRank: int.tryParse(_capture(segment, _peakPattern) ?? ''),
          weeksOnChart: int.tryParse(_capture(segment, _weeksPattern) ?? ''),
          trend: previousRank == null
              ? const <double>[]
              : <double>[
                  (101 - previousRank).toDouble(),
                  (101 - rank).toDouble(),
                ],
          changeLabel: changeLabel,
        ),
      );
      if (entries.length == 100) break;
    }
    if (entries.isEmpty) return null;
    final issue = _clean(
      _capture(html, _issuePattern) ?? 'Current chart',
    ).replaceFirst(RegExp(r'^Week of\s+', caseSensitive: false), '');
    final issueDate = _parseIssueDate(issue);
    final issues =
        inheritedIssues ??
        (issueDate == null ? const <ChartIssue>[] : _issuesFrom(issueDate));
    final selected =
        selectedIssueId ?? (issueDate == null ? null : _dateId(issueDate));
    return MusicChart(
      id: 'billboard:hot-100:$issue',
      title: '美国 Billboard Hot 100',
      source: 'Billboard',
      issueLabel: issue,
      entries: entries,
      accent: 0xFFE7384F,
      providerKey: 'billboard:hot-100',
      issues: issues,
      selectedIssueId: selected,
    );
  }

  static List<ChartIssue> _issuesFrom(DateTime latest) => <ChartIssue>[
    for (var offset = 0; offset < 52; offset++)
      if (latest.subtract(Duration(days: offset * 7)) case final date)
        ChartIssue(
          id: _dateId(date),
          label: '${date.year} · ${date.month}月${date.day}日', // i18n:key
        ),
  ];

  static DateTime? _parseIssueDate(String value) {
    final match = RegExp(
      r'([A-Za-z]+)\s+(\d{1,2}),\s+(\d{4})',
    ).firstMatch(value);
    if (match == null) return null;
    const months = <String>[
      'january',
      'february',
      'march',
      'april',
      'may',
      'june',
      'july',
      'august',
      'september',
      'october',
      'november',
      'december',
    ];
    final month = months.indexOf(match.group(1)!.toLowerCase()) + 1;
    if (month <= 0) return null;
    return DateTime.utc(
      int.parse(match.group(3)!),
      month,
      int.parse(match.group(2)!),
    );
  }

  static int _dateId(DateTime date) =>
      date.year * 10000 + date.month * 100 + date.day;

  static DateTime? _dateFromId(int id) {
    final year = id ~/ 10000;
    final month = id ~/ 100 % 100;
    final day = id % 100;
    if (year < 1958 || month < 1 || month > 12 || day < 1 || day > 31) {
      return null;
    }
    final date = DateTime.utc(year, month, day);
    return date.year == year && date.month == month && date.day == day
        ? date
        : null;
  }

  static String _isoDate(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  static final RegExp _rankPattern = RegExp(
    r'<span class="c-label[^>]*>\s*(\d+)\s*</span>',
    multiLine: true,
  );
  static final RegExp _titlePattern = RegExp(
    r'<h3[^>]*>\s*([^<]+?)\s*</h3>',
    multiLine: true,
  );
  static final RegExp _artistPattern = RegExp(
    r'<span class="[^"]*a-no-trucate[^"]*"[^>]*>([\s\S]*?)</span>',
  );
  static final RegExp _coverPattern = RegExp(r'<img[^>]+src="([^"]+)"');
  static final RegExp _lastWeekPattern = _metricPattern('LW');
  static final RegExp _peakPattern = _metricPattern('PEAK');
  static final RegExp _weeksPattern = _metricPattern('WEEKS ON CHART');
  static final RegExp _issuePattern = RegExp(
    r'(Week of\s+[A-Z][a-z]+\s+\d{1,2},\s+\d{4})',
  );

  static RegExp _metricPattern(String label) => RegExp(
    '>\\s*${RegExp.escape(label)}\\s*</span>[\\s\\S]{0,1800}?'
    r'<span class="c-label[^>]*>\s*([\d-]+)',
  );

  static String? _capture(String input, RegExp pattern) {
    final match = pattern.firstMatch(input);
    return match == null || match.groupCount < 1 ? null : match.group(1);
  }

  static String _stripTags(String value) =>
      value.replaceAll(RegExp(r'<[^>]+>'), '');

  static String _clean(String value) =>
      _decodeEntities(value).replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _decodeEntities(String value) => value
      .replaceAll('&#039;', "'")
      .replaceAll('&#8217;', '’')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&nbsp;', ' ');
}

class _BillboardWeek {
  _BillboardWeek(this.byIdentity, this.byUniqueTitle);

  factory _BillboardWeek.fromJson(Map<String, dynamic> json) {
    final byIdentity = <String, int>{};
    final titleRanks = <String, List<int>>{};
    for (final row in (json['data'] as List? ?? const <Object>[])) {
      if (row is! Map<String, dynamic>) continue;
      final title = row['song'] as String? ?? '';
      final artist = row['artist'] as String? ?? '';
      final rank = (row['this_week'] as num?)?.toInt();
      if (title.isEmpty || rank == null) continue;
      byIdentity[_billboardIdentity(title, artist)] = rank;
      (titleRanks[_billboardText(title)] ??= <int>[]).add(rank);
    }
    return _BillboardWeek(byIdentity, <String, int>{
      for (final item in titleRanks.entries)
        if (item.value.length == 1) item.key: item.value.single,
    });
  }

  final Map<String, int> byIdentity;
  final Map<String, int> byUniqueTitle;

  int? rankFor(String title, String artist) =>
      byIdentity[_billboardIdentity(title, artist)] ??
      byUniqueTitle[_billboardText(title)];
}

String _billboardIdentity(String title, String artist) =>
    '${_billboardText(title)}|${_billboardText(artist)}';

String _billboardText(String value) => value
    .toLowerCase()
    .replaceAll('&amp;', 'and')
    .replaceAll('&', 'and')
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .trim();
