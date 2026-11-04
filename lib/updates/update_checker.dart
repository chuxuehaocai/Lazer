import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/system_http.dart';
import 'release_version.dart';

/// A published GitHub release reduced to what the update prompt needs.
class AppRelease {
  const AppRelease({
    required this.tag,
    required this.version,
    required this.name,
    required this.notes,
    required this.url,
    required this.prerelease,
    this.publishedAt,
  });

  /// The original tag, e.g. `v2.0.0-beta.2`.
  final String tag;

  final ReleaseVersion version;

  /// The release title GitHub shows; falls back to [tag].
  final String name;

  /// Release notes in Markdown. The prompt renders them as plain text.
  final String notes;

  /// The release page in the browser.
  final String url;

  final bool prerelease;
  final DateTime? publishedAt;

  /// Reads one entry of the GitHub releases API. Malformed or draft entries
  /// become null so one bad release cannot hide the rest.
  static AppRelease? fromJson(Map<String, dynamic> json) {
    if (json['draft'] == true) return null;
    final Object? rawTag = json['tag_name'];
    if (rawTag is! String) return null;
    final ReleaseVersion? version = ReleaseVersion.parse(rawTag);
    if (version == null) return null;
    final Object? rawName = json['name'];
    final Object? rawNotes = json['body'];
    final Object? rawUrl = json['html_url'];
    return AppRelease(
      tag: rawTag.trim(),
      version: version,
      name: rawName is String && rawName.trim().isNotEmpty
          ? rawName.trim()
          : rawTag.trim(),
      notes: rawNotes is String ? rawNotes.trim() : '',
      url: rawUrl is String && rawUrl.trim().isNotEmpty
          ? rawUrl.trim()
          : '${UpdateChecker.repositoryUrl}/releases/tag/${rawTag.trim()}',
      prerelease: json['prerelease'] == true || version.isPreRelease,
      publishedAt: DateTime.tryParse('${json['published_at'] ?? ''}'),
    );
  }
}

/// A failure while asking GitHub for releases.
class UpdateCheckException implements Exception {
  const UpdateCheckException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Finds GitHub releases newer than the running build.
///
/// The app has no account of its own and the repository is public, so the
/// unauthenticated releases endpoint is enough. It is called at most once a
/// day by [AppState]; a failure is quiet and simply retried next launch.
class UpdateChecker {
  UpdateChecker({
    Future<http.Response> Function(Uri uri)? fetch,
    Uri? endpoint,
    this.timeout = const Duration(seconds: 8),
  }) : _fetch = fetch ?? _fetchFromGitHub,
       endpoint =
           endpoint ??
           Uri.parse(
             'https://api.github.com/repos/chuxuehaocai/Lazer/releases?per_page=100',
           );

  static const String repositoryUrl = 'https://github.com/chuxuehaocai/Lazer';

  final Future<http.Response> Function(Uri uri) _fetch;
  final Uri endpoint;

  /// How long a check may take before the startup path gives up. GitHub is
  /// unreachable from some networks; an update check must never hold the app.
  final Duration timeout;

  /// The newest release newer than [current], or null when the build is
  /// already current. Pre-releases are only considered for a build that is
  /// itself a pre-release, so stable users are not pushed onto a beta.
  Future<AppRelease?> findUpdate(
    ReleaseVersion current, {
    bool includePrerelease = false,
  }) async {
    final List<AppRelease> all = await releases();
    AppRelease? best;
    for (final AppRelease release in all) {
      if (release.prerelease && !includePrerelease) continue;
      if (release.version.compareTo(current) <= 0) continue;
      if (best == null || release.version.compareTo(best.version) > 0) {
        best = release;
      }
    }
    return best;
  }

  /// Every release GitHub lists, drafts removed and malformed tags skipped.
  Future<List<AppRelease>> releases() async {
    final http.Response response = await _fetch(endpoint).timeout(timeout);
    if (response.statusCode != 200) {
      throw UpdateCheckException('GitHub 返回 HTTP ${response.statusCode}');
    }
    final Object? decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! List) {
      throw const UpdateCheckException('GitHub 返回了无法识别的数据');
    }
    final List<AppRelease> result = <AppRelease>[];
    for (final Object? item in decoded) {
      if (item is! Map<String, dynamic>) continue;
      final AppRelease? release = AppRelease.fromJson(item);
      if (release != null) result.add(release);
    }
    return result;
  }

  /// The production transport, routed through the same system proxy as the
  /// external chart hosts. Without it GitHub is unreachable on many networks
  /// that ship the app.
  static Future<http.Response> _fetchFromGitHub(Uri uri) async {
    final SystemHttpProxy? proxy = await SystemHttpProxy.resolve();
    final http.Client client = openExternalClient(proxy: proxy);
    try {
      return await client
          .get(
            uri,
            headers: const <String, String>{
              'Accept': 'application/vnd.github+json',
              'X-GitHub-Api-Version': '2022-11-28',
              'User-Agent': 'Lazer-Updater',
            },
          )
          .timeout(const Duration(seconds: 8));
    } finally {
      client.close();
    }
  }
}
