import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/system_http.dart';
import 'biliboard_song_metadata.g.dart';
import 'models.dart';

/// Small, read-only adapter for Biliboard's public chart JSON surface.
class BiliboardClient {
  BiliboardClient({this.client});

  static const String _origin = 'https://biliboard.uk';
  static const String _weeklyArchive =
      'https://cdn.jsdelivr.net/gh/VincentZyuApps/'
      'billboard-data@main/data/bilibili/';

  /// Per-attempt budget. The origin sits behind Cloudflare and answers in well
  /// under a second through a working route, but a direct route from some
  /// networks can stall for tens of seconds, so the load falls back instead of
  /// waiting on a dead connection.
  static const Duration _attemptTimeout = Duration(seconds: 8);

  // A supplied client is retained for deterministic tests. Production calls
  // resolve the operating system's proxy and keep one connection open for the
  // whole load, because every extra handshake costs seconds on this host.
  final http.Client? client;
  Map<int, String>? _weeklyArchivePaths;

  Future<List<MusicChart>> latestCharts() async {
    final _ChartTransport transport = await _openTransport();
    try {
      final List<dynamic> boards = await _getList(
        transport,
        '/api/public/boards',
      );
      const accents = <int>[0xFF3978F6, 0xFFFF4F86, 0xFF8B5CF6];
      // Boards are independent: walking them in sequence paid a fresh
      // handshake per board and turned one slow answer into a stalled shelf.
      final List<MusicChart?> loaded =
          await Future.wait<MusicChart?>(<Future<MusicChart?>>[
            for (var index = 0; index < boards.length; index++)
              if (boards[index] case final Map<String, dynamic> board)
                _latestChart(
                  transport,
                  board,
                  accents[index % accents.length],
                ).catchError((_) => null)
              else
                Future<MusicChart?>.value(),
          ]);
      return loaded.whereType<MusicChart>().toList();
    } finally {
      transport.close();
    }
  }

  Future<MusicChart?> _latestChart(
    _ChartTransport transport,
    Map<String, dynamic> board,
    int accent,
  ) async {
    final int boardId = (board['id'] as num?)?.toInt() ?? 0;
    if (boardId <= 0) return null;
    final List<dynamic> issues = await _getList(
      transport,
      '/api/public/boards/$boardId/issues',
    );
    final parsedIssues = issues
        .whereType<Map<String, dynamic>>()
        .map(_issueFromJson)
        .where((issue) => issue.id > 0)
        .toList();
    final Map<String, dynamic>? issue = issues
        .whereType<Map<String, dynamic>>()
        .firstOrNull;
    if (issue == null) return null;
    // The ranking route expects the public issue number, not the row id.
    final int issueId = (issue['issue_id'] as num?)?.toInt() ?? 0;
    if (issueId <= 0) return null;
    final List<dynamic> ranking = await _getList(
      transport,
      '/api/public/boards/$boardId/issues/$issueId/rankings',
    );
    final entries = ranking
        .whereType<Map<String, dynamic>>()
        .map(_entryFromJson)
        .where((entry) => entry.rank > 0 && entry.title.isNotEmpty)
        .toList();
    if (entries.isEmpty) return null;
    final int year = (issue['year'] as num?)?.toInt() ?? 0;
    final int week = (issue['week'] as num?)?.toInt() ?? 0;
    return MusicChart(
      id: 'biliboard:$boardId:$issueId',
      title: board['name'] as String? ?? '术力口榜',
      source: 'Biliboard',
      issueLabel: _issueLabel(year, week),
      entries: entries,
      accent: accent,
      providerKey: 'biliboard:$boardId',
      logoUrl: null,
      issues: parsedIssues,
      selectedIssueId: issueId,
    );
  }

  Future<MusicChart> chartForIssue(MusicChart chart, ChartIssue issue) async {
    final parts = (chart.providerKey ?? '').split(':');
    if (parts.length != 2 || parts.first != 'biliboard') {
      throw ArgumentError.value(chart.providerKey, 'chart.providerKey');
    }
    final boardId = int.tryParse(parts.last) ?? 0;
    if (boardId <= 0) {
      throw ArgumentError.value(chart.providerKey, 'chart.providerKey');
    }
    final _ChartTransport transport = await _openTransport();
    try {
      if (boardId == 1) {
        final archived = await _archivedWeeklyChart(transport, chart, issue);
        if (archived != null) return archived;
      }
      final ranking = await _getList(
        transport,
        '/api/public/boards/$boardId/issues/${issue.id}/rankings',
      );
      final entries = ranking
          .whereType<Map<String, dynamic>>()
          .map(_entryFromJson)
          .where((entry) => entry.rank > 0 && entry.title.isNotEmpty)
          .toList();
      return MusicChart(
        id: 'biliboard:$boardId:${issue.id}',
        title: chart.title,
        source: chart.source,
        issueLabel: issue.label,
        entries: entries,
        accent: chart.accent,
        providerKey: chart.providerKey,
        logoUrl: chart.logoUrl,
        issues: chart.issues,
        selectedIssueId: issue.id,
      );
    } finally {
      transport.close();
    }
  }

  Future<MusicChart?> _archivedWeeklyChart(
    _ChartTransport transport,
    MusicChart chart,
    ChartIssue issue,
  ) async {
    try {
      var paths = _weeklyArchivePaths;
      if (paths == null) {
        final index = await _getJson(
          transport,
          Uri.parse('${_weeklyArchive}index.json'),
        );
        paths = <int, String>{
          for (final item in (index['issues'] as List? ?? const <Object>[]))
            if (item is Map<String, dynamic> &&
                item['issue'] is num &&
                item['path'] is String)
              (item['issue'] as num).toInt(): item['path'] as String,
        };
        _weeklyArchivePaths = paths;
      }
      final path = paths[issue.id];
      if (path == null) return null;
      final payload = await _getJson(
        transport,
        Uri.parse('$_weeklyArchive$path'),
      );
      final entries = (payload['items'] as List? ?? const <Object>[])
          .whereType<Map<String, dynamic>>()
          .map(_archiveEntryFromJson)
          .where((entry) => entry.rank > 0 && entry.title.isNotEmpty)
          .toList();
      if (entries.isEmpty) return null;
      return MusicChart(
        id: 'biliboard:1:${issue.id}',
        title: chart.title,
        source: chart.source,
        issueLabel: issue.label,
        entries: entries,
        accent: chart.accent,
        providerKey: chart.providerKey,
        logoUrl: chart.logoUrl,
        issues: chart.issues,
        selectedIssueId: issue.id,
      );
    } catch (_) {
      return null;
    }
  }

  ChartEntry _archiveEntryFromJson(Map<String, dynamic> json) {
    final meta = json['video_meta'];
    final metadata = meta is Map<String, dynamic>
        ? meta
        : const <String, dynamic>{};
    final bvid = json['bvid'] as String?;
    final catalog = biliboardSongMetadata[bvid];
    final catalogTitle = catalog == null ? '' : catalog[0];
    final catalogTitleCn = catalog == null ? '' : catalog[1];
    final catalogArtist = catalog == null ? '' : catalog[2];
    final rawCover = json['pic_url'] as String?;
    return ChartEntry(
      rank: (json['rank'] as num?)?.toInt() ?? 0,
      title: catalogTitle.isNotEmpty
          ? catalogTitle
          : json['title'] as String? ?? '',
      translatedTitle: catalogTitleCn.isEmpty ? null : catalogTitleCn,
      artist: catalogArtist.isNotEmpty
          ? catalogArtist
          : metadata['owner_name'] as String? ??
                metadata['author'] as String? ??
                '',
      coverUrl: rawCover?.replaceFirst(RegExp(r'^http:'), 'https:'),
      sourceUrl: json['url'] as String?,
    );
  }

  ChartIssue _issueFromJson(Map<String, dynamic> json) {
    final id = (json['issue_id'] as num?)?.toInt() ?? 0;
    final year = (json['year'] as num?)?.toInt() ?? 0;
    final week = (json['week'] as num?)?.toInt() ?? 0;
    return ChartIssue(id: id, label: _issueLabel(year, week));
  }

  String _issueLabel(int year, int week) {
    if (year > 0 && week > 0) return '$year · 第 $week 周'; // i18n:key
    if (week > 0) return '第 $week 期'; // i18n:key
    return '历史期数'; // i18n:key
  }

  ChartEntry _entryFromJson(Map<String, dynamic> json) {
    final producers = (json['producers'] as List? ?? const <Object>[])
        .whereType<Map<String, dynamic>>()
        .map((item) => item['name'] as String? ?? '')
        .where((name) => name.isNotEmpty)
        .toList();
    final vocalists = (json['vocalists'] as List? ?? const <Object>[])
        .whereType<Map<String, dynamic>>()
        .map((item) => item['name'] as String? ?? '')
        .where((name) => name.isNotEmpty)
        .toList();
    final String artist = producers.isNotEmpty
        ? producers.join(' / ')
        : vocalists.join(' / ');
    final String? bvid = json['bvid'] as String?;
    final String? cover = json['coverUrl'] as String?;
    final trend = (json['rateHistory'] as List? ?? const <Object>[])
        .map((item) => item is Map<String, dynamic> ? item['value'] : item)
        .whereType<num>()
        .map((value) => value.toDouble())
        .toList();
    final change = json['rankChange'];
    String? changeLabel;
    if (change is Map<String, dynamic>) {
      final kind = change['kind'] as String? ?? '';
      final diff = (change['diff'] as num?)?.toInt();
      changeLabel = switch (kind) {
        'new' => 'NEW',
        'up' => diff == null ? '上升' : '↑$diff', // i18n:key
        'down' => diff == null ? '下降' : '↓$diff', // i18n:key
        'same' => '—',
        'reentry' => '重返', // i18n:key
        'revote' => '重投', // i18n:key
        _ => null,
      };
    }
    return ChartEntry(
      rank: (json['rank'] as num?)?.toInt() ?? 0,
      title: json['title'] as String? ?? '',
      translatedTitle: json['titleCn'] as String?,
      artist: artist,
      coverUrl: cover == null
          ? null
          : cover.startsWith('http')
          ? cover
          : '$_origin$cover',
      sourceUrl: bvid == null ? null : 'https://www.bilibili.com/video/$bvid',
      previousRank: (json['lastRank'] as num?)?.toInt(),
      peakRank: (json['peakRank'] as num?)?.toInt(),
      weeksOnChart: (json['weeksOnBoard'] as num?)?.toInt(),
      score: (json['score'] as num?)?.round(),
      trend: trend,
      changeLabel: changeLabel,
    );
  }

  Future<List<dynamic>> _getList(_ChartTransport transport, String path) async {
    final value = await _getJson(transport, Uri.parse('$_origin$path'));
    if (value case <String, dynamic>{'items': final List<dynamic> items}) {
      return items;
    }
    throw const FormatException('Expected a JSON list.');
  }

  Future<dynamic> _getJson(_ChartTransport transport, Uri uri) async {
    final http.Response response = await transport.get(uri);
    if (response.statusCode != 200) {
      throw StateError('Biliboard request failed: ${response.statusCode}');
    }
    // The feed is UTF-8 but not every response advertises a charset, and the
    // package default would turn the board names into mojibake.
    final value = jsonDecode(
      utf8.decode(response.bodyBytes, allowMalformed: true),
    );
    if (value is List) return <String, dynamic>{'items': value};
    if (value is Map<String, dynamic>) return value;
    throw const FormatException('Expected JSON data.');
  }

  Future<_ChartTransport> _openTransport() async {
    final http.Client? injected = client;
    if (injected != null) return _ChartTransport.single(injected, false);
    final SystemHttpProxy? proxy = await SystemHttpProxy.resolve();
    if (proxy == null) {
      return _ChartTransport.single(
        openExternalClient(connectionTimeout: _attemptTimeout),
        true,
      );
    }
    return _ChartTransport.routed(
      openExternalClient(connectionTimeout: _attemptTimeout, proxy: proxy),
      openExternalClient(connectionTimeout: _attemptTimeout),
    );
  }
}

/// One connection pool per chart load, preferring the system proxy and falling
/// back to a direct connection so a stale proxy entry cannot empty the shelf.
class _ChartTransport {
  _ChartTransport.single(this._direct, this._owned) : _viaProxy = null;

  _ChartTransport.routed(this._viaProxy, this._direct) : _owned = true;

  static const Map<String, String> _headers = <String, String>{
    'accept': 'application/json',
    'user-agent': 'Mozilla/5.0 Lazer/1.0',
  };

  final http.Client? _viaProxy;
  final http.Client _direct;
  final bool _owned;

  Future<http.Response> get(Uri uri) async {
    final http.Client? proxy = _viaProxy;
    if (proxy != null) {
      try {
        return await proxy
            .get(uri, headers: _headers)
            .timeout(BiliboardClient._attemptTimeout);
      } catch (_) {
        // Retry directly below.
      }
    }
    return _direct
        .get(uri, headers: _headers)
        .timeout(BiliboardClient._attemptTimeout);
  }

  void close() {
    if (!_owned) return;
    _viaProxy?.close();
    _direct.close();
  }
}
