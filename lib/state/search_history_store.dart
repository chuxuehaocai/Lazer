import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences key holding the serialized search history.
const String searchHistoryKey = 'lazer_search_history_v1';

/// Most recently committed queries kept on this device.
const int searchHistoryLimit = 10;

/// Reads the serialized search history; null when nothing is saved yet.
typedef SearchHistoryReader = Future<String?> Function();

/// Persists the serialized search history.
typedef SearchHistoryWriter = Future<void> Function(String value);

/// Remembers the queries the listener committed on this device.
///
/// The search page forgets its query as soon as it is cleared or left, so a
/// query typed once has to be typed again later. This store keeps the last
/// committed queries — the ones the listener submitted or opened a result
/// from — newest first, so the empty search page can offer them back as chips
/// instead of starting from a blank field. Entries are trimmed and compared
/// case-insensitively: repeating an earlier search moves it to the front
/// rather than saving it twice, and the list is capped at
/// [searchHistoryLimit] so it stays a short list of recent searches.
///
/// Reads and writes are injectable, matching `PlaybackQueueStore`'s shape, so
/// the page can be exercised without the plugin platform channels.
class SearchHistoryStore {
  SearchHistoryStore({SearchHistoryReader? read, SearchHistoryWriter? write})
    : _read = read ?? _readPreferences,
      _write = write ?? _writePreferences;

  final SearchHistoryReader _read;
  final SearchHistoryWriter _write;

  /// Serializes read-modify-write cycles; the stored value is a single JSON
  /// array, so two overlapping writes would drop each other's entries.
  Future<void> _pending = Future<void>.value();

  /// Reads the saved history, newest first.
  ///
  /// A missing, unreadable or malformed value reads as an empty history: the
  /// list is a convenience and must never keep the page from loading.
  Future<List<String>> load() async {
    try {
      final String? raw = await _read();
      if (raw == null) {
        return const <String>[];
      }
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) {
        return const <String>[];
      }
      final List<String> queries = <String>[];
      for (final Object? entry in decoded) {
        if (entry is! String) {
          continue;
        }
        final String query = entry.trim();
        if (query.isEmpty ||
            queries.any((String saved) => _sameQuery(saved, query))) {
          continue;
        }
        queries.add(query);
        if (queries.length == searchHistoryLimit) {
          break;
        }
      }
      return queries;
    } catch (_) {
      return const <String>[];
    }
  }

  /// Saves [query] at the front, moving it up when it is already saved.
  ///
  /// Empty queries are ignored: a cleared field is not a search.
  Future<void> record(String query) {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) {
      return Future<void>.value();
    }
    return _update((List<String> queries) {
      queries.removeWhere((String saved) => _sameQuery(saved, trimmed));
      queries.insert(0, trimmed);
      if (queries.length > searchHistoryLimit) {
        queries.removeRange(searchHistoryLimit, queries.length);
      }
    });
  }

  /// Forgets [query] when it is saved; otherwise does nothing.
  Future<void> remove(String query) {
    return _update((List<String> queries) {
      queries.removeWhere((String saved) => _sameQuery(saved, query));
    });
  }

  /// Forgets every saved query.
  Future<void> clear() {
    return _update((List<String> queries) {
      queries.clear();
    });
  }

  /// Applies [change] to the saved list and persists the result.
  Future<void> _update(void Function(List<String> queries) change) {
    final Future<void> next = _pending
        .then((_) async {
          final List<String> queries = List<String>.of(await load());
          change(queries);
          await _write(jsonEncode(queries));
        })
        .catchError((Object _) {
          // Best-effort persistence, like the queue store: a failed write
          // must not stall later updates or break the page.
        });
    _pending = next;
    return next;
  }

  bool _sameQuery(String first, String second) {
    return first.trim().toLowerCase() == second.trim().toLowerCase();
  }
}

Future<void> _writePreferences(String value) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setString(searchHistoryKey, value);
}

Future<String?> _readPreferences() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  return prefs.getString(searchHistoryKey);
}
