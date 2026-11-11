import 'dart:collection';
import 'dart:async';
import 'dart:convert';

class AppLog {
  AppLog({this.maximumLines = 1500, this.maximumCharacters = 512 * 1024});
  static final shared = AppLog();
  final int maximumLines, maximumCharacters;
  final ListQueue<String> _lines = ListQueue();
  int _characters = 0;
  int revision = 0;
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;

  /// Structured lifecycle records; callers must omit request bodies and secrets.
  void event(
    String scope,
    String event, [
    Map<String, Object?> fields = const {},
  ]) {
    record('[$scope] $event ${jsonEncode(fields)}');
  }

  static final _headers = RegExp(
    r'(authorization|set-cookie|cookie)\s*[:=][^\r\n]*',
    caseSensitive: false,
  );
  static final _credentials = RegExp(
    r'(music_u|__csrf|password|token)\s*[:=]\s*[^\r\n;]+',
    caseSensitive: false,
  );
  static final _urls = RegExp(r'https?://[^\s<>]+');

  static String redact(String text) => text
      .replaceAllMapped(_headers, (match) => '${match.group(1)}=[redacted]')
      .replaceAllMapped(_credentials, (match) => '${match.group(1)}=[redacted]')
      .replaceAllMapped(_urls, (match) {
        final uri = Uri.tryParse(match.group(0)!);
        return uri == null
            ? '[url]'
            : uri
                  .replace(
                    userInfo: '',
                    query: uri.hasQuery ? 'redacted' : null,
                  )
                  .toString();
      });

  void record(Object? message) {
    final entry =
        '${DateTime.now().toUtc().toIso8601String()} ${redact('$message')}';
    final bounded = entry.length > maximumCharacters
        ? entry.substring(0, maximumCharacters)
        : entry;
    _lines.addLast(bounded);
    _characters += bounded.length;
    while (_lines.length > maximumLines || _characters > maximumCharacters) {
      _characters -= _lines.removeFirst().length;
    }
    revision++;
    if (_changes.hasListener) _changes.add(null);
  }

  String snapshot() => _lines.join('\n');

  void clear() {
    _lines.clear();
    _characters = 0;
    revision++;
    if (_changes.hasListener) _changes.add(null);
  }
}
