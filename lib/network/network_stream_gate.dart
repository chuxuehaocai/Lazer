// i18n:data — interface strings declared here are translated at their render sites.
// ignore_for_file: prefer_initializing_formals — the protocol adapters keep
// private fields and stable named parameters; the lint cannot express that.
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'remote_source.dart';

/// A loopback HTTP gate in front of the network sources.
///
/// The audio engine only speaks URLs, and range requests are what make seeking
/// work. This server exposes one source-relative file (or one relayed stream)
/// under a per-launch token, forwards ranges to the protocol adapter, and
/// streams the bytes back. Nothing outside the machine can reach it: it binds
/// the IPv4 loopback interface only, and every path needs the token.
class NetworkStreamGate {
  NetworkStreamGate({
    required this.openRemote,
    required this.statRemote,
    required this.resolveRelay,
    String? token,
    this.maxConcurrent = 6,
    HttpClient Function()? httpClientFactory,
    Duration upstreamTimeout = const Duration(seconds: 20),
  }) : _token = token ?? _randomToken(),
       _httpClientFactory = httpClientFactory ?? HttpClient.new,
       _upstreamTimeout = upstreamTimeout;

  /// Opens `[start, end]` of a file inside a configured source.
  final Future<RemoteRead> Function(
    String sourceId,
    String path,
    int start,
    int? end,
  )
  openRemote;

  /// Looks a file up without opening its bytes (used by HEAD and by range
  /// negotiation).
  final Future<RemoteEntry?> Function(String sourceId, String path) statRemote;

  /// Resolves a relay id (radio station or podcast episode) to its upstream URL.
  final Future<Uri?> Function(String relayId) resolveRelay;

  final int maxConcurrent;
  final HttpClient Function() _httpClientFactory;
  final Duration _upstreamTimeout;
  final String _token;

  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;
  Future<void>? _starting;
  HttpClient? _http;
  int _active = 0;
  bool _closed = false;

  int? get port => _server?.port;
  bool get running => _server != null;

  /// The token this launch uses. Tests pass their own.
  String get token => _token;

  static String _randomToken() {
    final Random random = Random.secure();
    return List<String>.generate(
      4,
      (_) => random.nextInt(0x7fffffff).toRadixString(36).padLeft(6, '0'),
    ).join();
  }

  Uri urlForFile(String sourceId, String path) => Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: port,
    pathSegments: <String>[
      _token,
      'file',
      sourceId,
      ...remoteNormalize(
        path,
      ).split('/').where((String part) => part.isNotEmpty),
    ],
  );

  Uri urlForRelay(String relayId) => Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: port,
    pathSegments: <String>[_token, 'relay', relayId],
  );

  Future<void> ensureStarted() {
    if (_server != null) return Future<void>.value();
    if (_closed) {
      return Future<void>.error(
        const RemoteFailure(RemoteFailureKind.cancelled),
      );
    }
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<void> _start() async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    server.autoCompress = false;
    _server = server;
    _subscription = server.listen(
      _handle,
      onError: (Object _) {},
      cancelOnError: false,
    );
  }

  Future<void> _handle(HttpRequest request) async {
    final HttpResponse response = request.response;
    try {
      final List<String> segments = request.uri.pathSegments;
      if (segments.length < 3 || segments.first != _token) {
        await _plain(response, HttpStatus.forbidden, 'forbidden');
        return;
      }
      if (_active >= maxConcurrent) {
        response.headers.set(HttpHeaders.retryAfterHeader, '1');
        await _plain(response, HttpStatus.serviceUnavailable, 'busy');
        return;
      }
      _active++;
      try {
        switch (segments[1]) {
          case 'file':
            await _serveFile(request, response, segments);
          case 'relay':
            await _serveRelay(request, response, segments);
          default:
            await _plain(response, HttpStatus.notFound, 'not found');
        }
      } finally {
        _active--;
      }
    } catch (_) {
      // A listener that seeked away closed the socket mid-transfer; setting a
      // status on a committed response throws and is swallowed. An uncommitted
      // one becomes a real 500 instead of an empty 200.
      try {
        response.statusCode = HttpStatus.internalServerError;
      } catch (_) {}
      try {
        await response.close();
      } catch (_) {}
    }
  }

  Future<void> _serveFile(
    HttpRequest request,
    HttpResponse response,
    List<String> segments,
  ) async {
    if (segments.length < 4) {
      await _plain(response, HttpStatus.notFound, 'not found');
      return;
    }
    final String sourceId = segments[2];
    // `Uri.pathSegments` is already percent-decoded. Decoding again would turn
    // a literal `%` in a file name into an ArgumentError.
    final String path = remoteNormalize('/${segments.sublist(3).join('/')}');
    final bool head = request.method == 'HEAD';
    if (request.method != 'GET' && !head) {
      await _plain(response, HttpStatus.methodNotAllowed, 'method');
      return;
    }
    RemoteEntry? entry;
    try {
      entry = await statRemote(sourceId, path);
    } on RemoteFailure catch (failure) {
      await _plain(response, _statusFor(failure), failure.kind.name);
      return;
    } catch (_) {
      await _plain(response, HttpStatus.badGateway, 'unreachable');
      return;
    }
    if (entry == null || entry.isDirectory) {
      await _plain(response, HttpStatus.notFound, 'not found');
      return;
    }
    final int? total = entry.size != null && entry.size! >= 0
        ? entry.size
        : null;
    final RangeRequest? requested = RangeRequest.parse(
      request.headers.value(HttpHeaders.rangeHeader),
      total,
    );
    if (requested != null && requested.isUnsatisfiable) {
      if (total != null) {
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */$total',
        );
      }
      await _plain(response, HttpStatus.requestedRangeNotSatisfiable, '');
      return;
    }
    // A range can only be honoured when the object size is known: without it
    // there is no honest `Content-Range` to answer with, and claiming 206 would
    // leave the decoder seeking inside a file it thinks is shorter than it is.
    final bool partial = requested != null && total != null;
    final int start = partial ? requested.start : 0;
    final int? end = total == null
        ? null
        : partial
        ? (requested.end ?? total - 1).clamp(start, total - 1)
        : total - 1;
    final int? length = total == null ? null : end! - start + 1;
    if (head) {
      _writeCommonHeaders(
        response,
        entry,
        start,
        end,
        length,
        partial,
        total: total,
      );
      response.statusCode = partial
          ? HttpStatus.partialContent
          : HttpStatus.ok;
      await response.close();
      return;
    }
    // Open the upstream first: a failure still has headers to write, and once
    // a response has started there is no way back to an error status.
    final RemoteRead read;
    try {
      read = await openRemote(sourceId, path, start, end);
    } on RemoteFailure catch (failure) {
      await _plain(response, _statusFor(failure), failure.kind.name);
      return;
    } catch (_) {
      await _plain(response, HttpStatus.badGateway, 'unreachable');
      return;
    }
    try {
      _writeCommonHeaders(
        response,
        entry,
        start,
        end,
        length,
        partial,
        total: total,
      );
      final int? size = read.totalBytes ?? total;
      if (size != null && response.headers.contentLength < 0) {
        response.headers.contentLength = length ?? size - start;
      }
      response.statusCode = partial
          ? HttpStatus.partialContent
          : HttpStatus.ok;
      try {
        await response.addStream(read.bytes);
      } catch (_) {
        // The engine closed the connection (a seek or a stop); the release
        // below closes the protocol-level stream too.
      }
    } finally {
      // A throw between opening the read and streaming it must still release
      // the adapter's socket; a leaked read pins an FTP/SFTP session forever.
      try {
        await read.close();
      } catch (_) {}
      try {
        await response.close();
      } catch (_) {}
    }
  }

  void _writeCommonHeaders(
    HttpResponse response,
    RemoteEntry entry,
    int start,
    int? end,
    int? length,
    bool partial, {
    int? total,
  }) {
    response.headers.set(
      HttpHeaders.contentTypeHeader,
      audioContentType(entry.name),
    );
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    if (length != null) response.headers.contentLength = length;
    if (partial) {
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-${end ?? ''}/${total ?? '*'}',
      );
    }
    final DateTime? modified = entry.modifiedAt;
    if (modified != null) {
      response.headers.set(
        HttpHeaders.lastModifiedHeader,
        HttpDate.format(modified.toUtc()),
      );
    }
  }

  Future<void> _serveRelay(
    HttpRequest request,
    HttpResponse response,
    List<String> segments,
  ) async {
    if (segments.length != 3) {
      await _plain(response, HttpStatus.notFound, 'not found');
      return;
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      await _plain(response, HttpStatus.methodNotAllowed, 'method');
      return;
    }
    final Uri? upstream;
    try {
      upstream = await resolveRelay(segments[2]);
    } on RemoteFailure catch (failure) {
      await _plain(response, _statusFor(failure), failure.kind.name);
      return;
    } catch (_) {
      await _plain(response, HttpStatus.badGateway, 'unreachable');
      return;
    }
    if (upstream == null) {
      await _plain(response, HttpStatus.notFound, 'not found');
      return;
    }
    final HttpClient client = _http ??= _httpClientFactory()
      ..connectionTimeout = const Duration(seconds: 12)
      // Bytes are copied straight through; decompressing here would make the
      // upstream Content-Length describe a body we no longer send.
      ..autoUncompress = false;
    final HttpClientRequest upstreamRequest;
    try {
      upstreamRequest = await client
          .openUrl(request.method, upstream)
          .timeout(_upstreamTimeout);
    } catch (_) {
      await _plain(response, HttpStatus.badGateway, 'unreachable');
      return;
    }
    final String? range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      upstreamRequest.headers.set(HttpHeaders.rangeHeader, range);
    }
    upstreamRequest.headers.set(HttpHeaders.userAgentHeader, 'Lazer/2.0');
    final HttpClientResponse upstreamResponse;
    try {
      upstreamResponse = await upstreamRequest.close().timeout(
        _upstreamTimeout,
      );
    } catch (_) {
      await _plain(response, HttpStatus.gatewayTimeout, 'timeout');
      return;
    }
    response.statusCode = upstreamResponse.statusCode;
    for (final String name in const <String>[
      HttpHeaders.contentTypeHeader,
      HttpHeaders.contentLengthHeader,
      HttpHeaders.contentRangeHeader,
      HttpHeaders.acceptRangesHeader,
      HttpHeaders.lastModifiedHeader,
      HttpHeaders.etagHeader,
      HttpHeaders.contentEncodingHeader,
    ]) {
      final String? value = upstreamResponse.headers.value(name);
      if (value != null) response.headers.set(name, value);
    }
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    if (request.method == 'HEAD') {
      await upstreamResponse.drain<void>().catchError((Object _) {});
      await response.close();
      return;
    }
    try {
      await response.addStream(upstreamResponse);
    } catch (_) {
    } finally {
      try {
        await response.close();
      } catch (_) {}
    }
  }

  Future<void> _plain(HttpResponse response, int status, String body) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.text;
    response.write(body);
    await response.close();
  }

  int _statusFor(RemoteFailure failure) => switch (failure.kind) {
    RemoteFailureKind.notFound => HttpStatus.notFound,
    RemoteFailureKind.permission => HttpStatus.forbidden,
    RemoteFailureKind.auth => HttpStatus.badGateway,
    RemoteFailureKind.timeout => HttpStatus.gatewayTimeout,
    RemoteFailureKind.unsupported => HttpStatus.notImplemented,
    RemoteFailureKind.cancelled => HttpStatus.badGateway,
    RemoteFailureKind.unreachable => HttpStatus.badGateway,
    RemoteFailureKind.tls => HttpStatus.badGateway,
    RemoteFailureKind.protocol => HttpStatus.badGateway,
    RemoteFailureKind.io => HttpStatus.badGateway,
  };

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _subscription?.cancel();
    } catch (_) {}
    _subscription = null;
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
    _http?.close(force: true);
    _http = null;
  }
}
