// i18n:data — interface strings declared here are translated at their render sites.
// ignore_for_file: prefer_initializing_formals — the protocol adapters keep
// private fields and stable named parameters; the lint cannot express that.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

import 'remote_source.dart';

/// A WebDAV source: a NAS share, Nextcloud, or any DAV server behind HTTP(S).
///
/// The adapter talks DAV itself instead of mounting anything: `PROPFIND` for
/// listings and metadata, `GET` with a `Range` header for playback. Seeking
/// works because the range is forwarded to the server, and credentials stay in
/// the app instead of in the operating system's credential store.
class WebDavSourceClient implements RemoteSourceClient {
  WebDavSourceClient({
    required Uri baseUri,
    String? username,
    String? password,
    bool allowSelfSignedCertificate = false,
    Duration timeout = const Duration(seconds: 20),
    HttpClient? httpClient,
  }) : _baseUri = _normalizeBase(baseUri),
       _username = username ?? '',
       _password = password ?? '',
       _timeout = timeout,
       _http = httpClient ?? _createHttpClient(allowSelfSignedCertificate);

  factory WebDavSourceClient.fromConnection(RemoteSourceConnection connection) {
    final String scheme = connection.secure ? 'https' : 'http';
    final List<String> segments = remoteNormalize(
      connection.path,
    ).split('/').where((String part) => part.isNotEmpty).toList();
    final Uri base = Uri(
      scheme: scheme,
      host: connection.host,
      port: connection.port == 0 ? null : connection.port,
      pathSegments: segments,
    );
    return WebDavSourceClient(
      baseUri: base,
      username: connection.username,
      password: connection.password,
      allowSelfSignedCertificate: connection.allowSelfSignedCertificate,
      timeout: connection.connectTimeout < const Duration(seconds: 20)
          ? const Duration(seconds: 20)
          : connection.connectTimeout,
    );
  }

  static const String propFindBody =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:"><d:prop>'
      '<d:resourcetype/><d:getcontentlength/><d:getlastmodified/>'
      '<d:displayname/><d:getcontenttype/>'
      '</d:prop></d:propfind>';

  final Uri _baseUri;
  final String _username;
  final String _password;
  final Duration _timeout;
  final HttpClient _http;
  bool _closed = false;

  @override
  NetworkSourceKind get kind => NetworkSourceKind.webdav;

  static HttpClient _createHttpClient(bool allowSelfSigned) {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12)
      ..idleTimeout = const Duration(seconds: 25)
      ..userAgent = 'Lazer/2.0';
    if (allowSelfSigned) {
      client.badCertificateCallback =
          (X509Certificate certificate, String host, int port) => true;
    }
    return client;
  }

  static Uri _normalizeBase(Uri uri) {
    final List<String> segments = uri.pathSegments
        .where((String part) => part.isNotEmpty)
        .toList();
    return uri.replace(pathSegments: segments, query: null, fragment: null);
  }

  /// Absolute URL for [path], which is relative to the configured base.
  Uri urlFor(String path) {
    final List<String> base = _baseUri.pathSegments
        .where((String part) => part.isNotEmpty)
        .toList();
    final List<String> extra = remoteNormalize(
      path,
    ).split('/').where((String part) => part.isNotEmpty).toList();
    return _baseUri.replace(pathSegments: <String>[...base, ...extra]);
  }

  /// The remote path [absolute] refers to, relative to the configured base.
  String relativePathFor(Uri absolute) {
    final List<String> base = _baseUri.pathSegments
        .where((String part) => part.isNotEmpty)
        .toList();
    final List<String> parts = absolute.pathSegments
        .where((String part) => part.isNotEmpty)
        .toList();
    if (base.isNotEmpty &&
        parts.length >= base.length &&
        _sameSegments(parts.sublist(0, base.length), base)) {
      return remoteNormalize('/${parts.sublist(base.length).join('/')}');
    }
    // A server that answers with a path outside the base still gets a usable
    // entry: its own tail is the best identity available.
    return remoteNormalize('/${parts.join('/')}');
  }

  static bool _sameSegments(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Future<RemoteListing> list(String path) async {
    final String normalized = remoteNormalize(path);
    return guardRemote(() async {
      _ensureOpen();
      final HttpClientResponse response = await _propFind(normalized, depth: 1);
      final String body = await response
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      final List<_DavEntry> parsed = _parseMultiStatus(body);
      final List<RemoteEntry> entries = <RemoteEntry>[];
      final Set<String> seen = <String>{};
      for (final _DavEntry entry in parsed) {
        final String relative = relativePathFor(entry.url);
        if (relative == normalized && entry.isDirectory) continue;
        if (!seen.add(relative)) continue;
        entries.add(
          RemoteEntry(
            name: entry.name.isEmpty ? remoteName(relative) : entry.name,
            path: relative,
            isDirectory: entry.isDirectory,
            size: entry.size,
            modifiedAt: entry.modifiedAt,
          ),
        );
      }
      entries.sort(byFolderThenName);
      return RemoteListing(path: normalized, entries: entries);
    });
  }

  @override
  Future<RemoteEntry?> stat(String path) async {
    final String normalized = remoteNormalize(path);
    try {
      return await guardRemote(() async {
        _ensureOpen();
        final HttpClientResponse response = await _propFind(
          normalized,
          depth: 0,
        );
        final String body = await response
            .transform(const Utf8Decoder(allowMalformed: true))
            .join();
        final List<_DavEntry> parsed = _parseMultiStatus(body);
        if (parsed.isEmpty) return null;
        final _DavEntry entry = parsed.first;
        return RemoteEntry(
          name: entry.name.isEmpty ? remoteName(normalized) : entry.name,
          path: normalized,
          isDirectory: entry.isDirectory,
          size: entry.size,
          modifiedAt: entry.modifiedAt,
        );
      });
    } on RemoteFailure catch (failure) {
      if (failure.kind == RemoteFailureKind.notFound) return null;
      rethrow;
    }
  }

  /// Reads `[start, end]`. A server that ignores `Range` still yields the right
  /// bytes: the leading portion is discarded while streaming.
  @override
  Future<RemoteRead> open(String path, {int start = 0, int? end}) async {
    final String normalized = remoteNormalize(path);
    return guardRemote(() async {
      _ensureOpen();
      final Uri uri = urlFor(normalized);
      final HttpClientRequest request = await _http.getUrl(uri).timeout(
        _timeout,
      );
      _authorize(request);
      request.headers.set(HttpHeaders.acceptHeader, '*/*');
      if (start > 0 || end != null) {
        request.headers.set(
          HttpHeaders.rangeHeader,
          'bytes=$start-${end ?? ''}',
        );
      }
      final HttpClientResponse response = await request.close().timeout(
        _timeout,
      );
      if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
        await response.drain<void>().catchError((Object _) {});
        throw const RemoteFailure(
          RemoteFailureKind.protocol,
          detail: 'HTTP 416',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final int status = response.statusCode;
        await response.drain<void>().catchError((Object _) {});
        _throwForStatus(status, uri);
      }
      final bool partial = response.statusCode == HttpStatus.partialContent;
      final int? total = partial
          ? totalFromContentRange(response.headers.value('content-range'))
          : contentLengthOf(response);
      Stream<List<int>> stream = response;
      if (!partial && start > 0) stream = skipBytes(stream, start);
      if (end != null) stream = limitedBytes(stream, end - start + 1);
      return RemoteRead.fromStream(stream, totalBytes: total);
    });
  }

  Future<HttpClientResponse> _propFind(
    String path, {
    required int depth,
  }) async {
    Uri uri = urlFor(path);
    for (var attempt = 0; attempt < 3; attempt++) {
      final HttpClientRequest request = await _http
          .openUrl('PROPFIND', uri)
          .timeout(_timeout);
      _authorize(request);
      request.headers.set('Depth', '$depth');
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/xml; charset=utf-8',
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/xml, text/xml');
      final List<int> body = utf8.encode(propFindBody);
      request.headers.contentLength = body.length;
      request.add(body);
      final HttpClientResponse response = await request.close().timeout(
        _timeout,
      );
      if (_isRedirect(response.statusCode)) {
        // Dart only follows redirects for GET/HEAD/POST, and several DAV
        // servers answer a trailing-slash-less collection with a 301.
        final String? location = response.headers.value(
          HttpHeaders.locationHeader,
        );
        await response.drain<void>().catchError((Object _) {});
        final Uri? next = location == null ? null : uri.resolve(location);
        if (next == null || next == uri) break;
        uri = next;
        continue;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final int status = response.statusCode;
        await response.drain<void>().catchError((Object _) {});
        _throwForStatus(status, uri);
      }
      return response;
    }
    throw RemoteFailure(
      RemoteFailureKind.protocol,
      detail: 'PROPFIND redirect loop ${uri.path}',
    );
  }

  static bool _isRedirect(int status) =>
      status == HttpStatus.movedPermanently ||
      status == HttpStatus.found ||
      status == HttpStatus.seeOther ||
      status == HttpStatus.temporaryRedirect ||
      status == 308;

  void _authorize(HttpClientRequest request) {
    if (_username.isEmpty && _password.isEmpty) return;
    final String token = base64Encode(utf8.encode('$_username:$_password'));
    request.headers.set(HttpHeaders.authorizationHeader, 'Basic $token');
  }

  Never _throwForStatus(int status, Uri uri) {
    switch (status) {
      case HttpStatus.unauthorized:
        throw const RemoteFailure(RemoteFailureKind.auth, detail: 'HTTP 401');
      case HttpStatus.forbidden:
        throw const RemoteFailure(
          RemoteFailureKind.permission,
          detail: 'HTTP 403',
        );
      case HttpStatus.notFound:
        throw const RemoteFailure(
          RemoteFailureKind.notFound,
          detail: 'HTTP 404',
        );
      default:
        throw RemoteFailure(
          RemoteFailureKind.protocol,
          detail: 'HTTP $status ${uri.path}',
        );
    }
  }

  static int? contentLengthOf(HttpClientResponse response) {
    final int length = response.contentLength;
    return length >= 0 ? length : null;
  }

  /// `bytes 0-99/1234` -> 1234; `bytes 0-99/*` -> null.
  static int? totalFromContentRange(String? header) {
    if (header == null) return null;
    final int slash = header.lastIndexOf('/');
    if (slash < 0) return null;
    return int.tryParse(header.substring(slash + 1).trim());
  }

  /// Parses a DAV multistatus body. Element lookup is by local name so a
  /// server using an unusual prefix (or no namespace at all) still works.
  List<_DavEntry> _parseMultiStatus(String body) {
    final XmlDocument document;
    try {
      document = XmlDocument.parse(body);
    } catch (error) {
      throw RemoteFailure(RemoteFailureKind.protocol, detail: '$error');
    }
    final List<_DavEntry> entries = <_DavEntry>[];
    for (final XmlElement response
        in document.descendants.whereType<XmlElement>()) {
      if (response.name.local != 'response') continue;
      String? href;
      bool directory = false;
      int? size;
      DateTime? modified;
      for (final XmlElement element
          in response.descendants.whereType<XmlElement>()) {
        switch (element.name.local) {
          case 'href':
            href ??= element.innerText.trim();
          case 'collection':
            directory = true;
          case 'getcontentlength':
            size = int.tryParse(element.innerText.trim()) ?? size;
          case 'getlastmodified':
            modified = parseHttpDate(element.innerText.trim()) ?? modified;
        }
      }
      if (href == null || href.isEmpty) continue;
      final Uri? url = Uri.tryParse(href);
      if (url == null) continue;
      entries.add(
        _DavEntry(
          url: url,
          name: url.pathSegments.isEmpty
              ? ''
              : _lastSegment(url.pathSegments),
          isDirectory: directory || href.endsWith('/'),
          size: size,
          modifiedAt: modified,
        ),
      );
    }
    return entries;
  }

  static String _lastSegment(List<String> segments) {
    for (int i = segments.length - 1; i >= 0; i--) {
      if (segments[i].isNotEmpty) return segments[i];
    }
    return '';
  }

  static DateTime? parseHttpDate(String value) {
    if (value.isEmpty) return null;
    try {
      return HttpDate.parse(value);
    } catch (_) {
      return null;
    }
  }

  void _ensureOpen() {
    if (_closed) throw const RemoteFailure(RemoteFailureKind.cancelled);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _http.close(force: true);
  }
}

class _DavEntry {
  const _DavEntry({
    required this.url,
    required this.name,
    required this.isDirectory,
    required this.size,
    required this.modifiedAt,
  });

  final Uri url;
  final String name;
  final bool isDirectory;
  final int? size;
  final DateTime? modifiedAt;
}
