// i18n:data — interface strings declared here are translated at their render sites.
import 'dart:convert';
import 'package:xml/xml.dart';

import '../data/models.dart';

/// One internet radio station the listener added.
class RadioStation {
  const RadioStation({
    required this.id,
    required this.name,
    required this.url,
    this.genre = '',
    this.homepage = '',
    this.addedAt,
  });

  final String id;
  final String name;
  final String url;
  final String genre;
  final String homepage;
  final DateTime? addedAt;

  String get trackId => radioTrackIdOf(id);

  String get displayGenre => genre.trim().isEmpty ? '网络电台' : genre.trim();

  Track toTrack() => Track(
    id: trackId,
    title: name,
    artist: displayGenre,
    album: '网络电台',
    duration: Duration.zero,
    coverSeed: radioCoverSeed(id),
  );

  RadioStation copyWith({
    String? name,
    String? url,
    String? genre,
    String? homepage,
  }) => RadioStation(
    id: id,
    name: name ?? this.name,
    url: url ?? this.url,
    genre: genre ?? this.genre,
    homepage: homepage ?? this.homepage,
    addedAt: addedAt,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'url': url,
    'genre': genre,
    'homepage': homepage,
    'addedAt': addedAt?.millisecondsSinceEpoch,
  };

  factory RadioStation.fromJson(Map<String, dynamic> json) => RadioStation(
    id: json['id'] as String? ?? newRadioStationId(),
    name: json['name'] as String? ?? '',
    url: json['url'] as String? ?? '',
    genre: json['genre'] as String? ?? '',
    homepage: json['homepage'] as String? ?? '',
    addedAt: json['addedAt'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            (json['addedAt'] as num).toInt(),
          ),
  );
}

String radioTrackIdOf(String stationId) => 'radio:$stationId';

String? radioStationIdOf(String trackId) {
  if (!trackId.startsWith('radio:')) return null;
  final String value = trackId.substring(6);
  return value.isEmpty ? null : value;
}

int radioCoverSeed(String stationId) {
  var hash = 0;
  for (final int unit in utf8.encode(stationId)) {
    hash = (hash * 31 + unit) & 0xffffff;
  }
  return hash;
}

String newRadioStationId() =>
    'rs-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

/// One station parsed from an M3U, PLS, ASX or XSPF playlist.
class RadioPlaylistEntry {
  const RadioPlaylistEntry({required this.name, required this.url});
  final String name;
  final String url;
}

/// Parses the playlist formats radio sites hand out.
///
/// Unknown lines are skipped: a vendor playlist with extra metadata still
/// imports its stations instead of failing the whole import.
List<RadioPlaylistEntry> parseRadioPlaylist(
  String text, {
  String fallbackName = '网络电台',
}) {
  final List<RadioPlaylistEntry> entries = <RadioPlaylistEntry>[];
  final String trimmed = text.trimLeft();
  if (trimmed.startsWith('[') || trimmed.contains('File1=')) {
    entries.addAll(_parsePls(text, fallbackName));
  } else if (trimmed.startsWith('<')) {
    entries.addAll(_parseXmlPlaylist(text, fallbackName));
  } else {
    entries.addAll(_parseM3u(text, fallbackName));
  }
  // Deduplicate by URL: M3U files sometimes repeat a stream in a group.
  final Set<String> seen = <String>{};
  final List<RadioPlaylistEntry> unique = <RadioPlaylistEntry>[];
  for (final RadioPlaylistEntry entry in entries) {
    if (entry.url.isEmpty || !seen.add(entry.url)) continue;
    unique.add(entry);
  }
  return unique;
}

List<RadioPlaylistEntry> _parseM3u(String text, String fallbackName) {
  final List<RadioPlaylistEntry> entries = <RadioPlaylistEntry>[];
  String? pendingName;
  for (final String raw in const LineSplitter().convert(text)) {
    final String line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#')) {
      final int comma = line.indexOf(',');
      if (line.startsWith('#EXTINF') && comma > 0) {
        pendingName = line.substring(comma + 1).trim();
      }
      continue;
    }
    // A playlist may carry absolute URLs or paths relative to the file it
    // came from; either is a station URL once the caller resolves it.
    entries.add(
      RadioPlaylistEntry(
        name: pendingName == null || pendingName.isEmpty
            ? fallbackName
            : pendingName,
        url: line,
      ),
    );
    pendingName = null;
  }
  return entries;
}

List<RadioPlaylistEntry> _parsePls(String text, String fallbackName) {
  final Map<int, String> urls = <int, String>{};
  final Map<int, String> names = <int, String>{};
  for (final String raw in const LineSplitter().convert(text)) {
    final String line = raw.trim();
    final int equals = line.indexOf('=');
    if (equals <= 0) continue;
    final String key = line.substring(0, equals).trim().toLowerCase();
    final String value = line.substring(equals + 1).trim();
    final RegExpMatch? match = RegExp(r'^(file|title)(\d+)$').firstMatch(key);
    if (match == null) continue;
    final int index = int.tryParse(match.group(2)!) ?? 0;
    if (match.group(1) == 'file') {
      urls[index] = value;
    } else {
      names[index] = value;
    }
  }
  final List<int> order = urls.keys.toList()..sort();
  return <RadioPlaylistEntry>[
    for (final int index in order)
      if (urls[index]!.isNotEmpty)
        RadioPlaylistEntry(
          name: names[index] ?? fallbackName,
          url: urls[index]!,
        ),
  ];
}

List<RadioPlaylistEntry> _parseXmlPlaylist(String text, String fallbackName) {
  final XmlDocument document;
  try {
    document = XmlDocument.parse(text);
  } catch (_) {
    return const <RadioPlaylistEntry>[];
  }
  final List<RadioPlaylistEntry> entries = <RadioPlaylistEntry>[];
  // ASX: <entry><title>..</title><ref href="..."/></entry>
  for (final XmlElement entry in document.descendants.whereType<XmlElement>()) {
    if (entry.name.local.toLowerCase() != 'entry') continue;
    String? title;
    String? url;
    for (final XmlElement child in entry.descendants.whereType<XmlElement>()) {
      final String local = child.name.local.toLowerCase();
      if (local == 'title') title = child.innerText.trim();
      if (local == 'ref') url = child.getAttribute('href')?.trim();
    }
    if (url != null && url.isNotEmpty) {
      entries.add(
        RadioPlaylistEntry(
          name: title == null || title.isEmpty ? fallbackName : title,
          url: url,
        ),
      );
    }
  }
  // XSPF: <track><title>..</title><location>http://...</location></track>
  for (final XmlElement track in document.descendants.whereType<XmlElement>()) {
    if (track.name.local.toLowerCase() != 'track') continue;
    String? title;
    String? url;
    for (final XmlElement child in track.descendants.whereType<XmlElement>()) {
      final String local = child.name.local.toLowerCase();
      if (local == 'title') title = child.innerText.trim();
      if (local == 'location') url = child.innerText.trim();
    }
    if (url != null && url.isNotEmpty) {
      entries.add(
        RadioPlaylistEntry(
          name: title == null || title.isEmpty ? fallbackName : title,
          url: url,
        ),
      );
    }
  }
  return entries;
}

/// True when [url] looks like a playlist rather than a stream. The player
/// resolves those before handing anything to the audio engine.
bool looksLikeRadioPlaylist(String url) {
  final String path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
  return path.endsWith('.m3u') ||
      path.endsWith('.m3u8') ||
      path.endsWith('.pls') ||
      path.endsWith('.asx') ||
      path.endsWith('.xspf');
}
