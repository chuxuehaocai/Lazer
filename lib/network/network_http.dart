// i18n:data — interface strings declared here are translated at their render sites.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'remote_source.dart';

/// A text resource fetched for a feed or a playlist, with the URL that finally
/// served it (after redirects) so relative links inside it can resolve.
class NetworkText {
  const NetworkText({
    required this.body,
    required this.uri,
    this.statusCode = 200,
  });

  final String body;
  final Uri uri;
  final int statusCode;
}

/// Fetches a small text resource over HTTP(S).
typedef NetworkTextFetcher =
    Future<NetworkText> Function(Uri uri, {Duration timeout});

/// The production fetcher: bounded, redirect-aware and gzip-friendly.
///
/// Feeds are untrusted input from the internet, so the body is capped and the
/// connection is closed as soon as the cap is reached instead of reading
/// whatever a misbehaving server wants to send.
Future<NetworkText> fetchNetworkText(
  Uri uri, {
  Duration timeout = const Duration(seconds: 20),
  int maxBytes = 4 * 1024 * 1024,
  HttpClient Function()? clientFactory,
}) async {
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    throw const RemoteFailure(
      RemoteFailureKind.unsupported,
      detail: 'Only http(s) feeds are supported',
    );
  }
  final HttpClient client = (clientFactory ?? HttpClient.new)()
    ..connectionTimeout = const Duration(seconds: 12)
    ..userAgent = 'Lazer/2.0 (podcast)'
    ..autoUncompress = true;
  try {
    final HttpClientRequest request = await client.getUrl(uri).timeout(timeout);
    request.headers.set(HttpHeaders.acceptHeader, '*/*');
    final HttpClientResponse response = await request.close().timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.drain<void>().catchError((Object _) {});
      throw RemoteFailure(
        response.statusCode == HttpStatus.unauthorized ||
                response.statusCode == HttpStatus.forbidden
            ? RemoteFailureKind.permission
            : RemoteFailureKind.protocol,
        detail: 'HTTP ${response.statusCode}',
      );
    }
    final Uri finalUri = response.redirects.isEmpty
        ? uri
        : response.redirects.last.location;
    final String? charset = response.headers.contentType?.charset;
    final List<int> bytes = <int>[];
    await for (final List<int> chunk in response.timeout(timeout)) {
      bytes.addAll(chunk);
      if (bytes.length >= maxBytes) break;
    }
    final int length = bytes.length > maxBytes ? maxBytes : bytes.length;
    final String body = _decode(
      bytes.length > length ? bytes.sublist(0, length) : bytes,
      charset,
    );
    return NetworkText(body: body, uri: finalUri, statusCode: response.statusCode);
  } on RemoteFailure {
    rethrow;
  } on TimeoutException {
    throw const RemoteFailure(RemoteFailureKind.timeout);
  } catch (error) {
    throw RemoteFailure.from(error, fallback: RemoteFailureKind.unreachable);
  } finally {
    client.close(force: true);
  }
}

String _decode(List<int> bytes, String? charset) {
  final String name = (charset ?? '').toLowerCase().trim();
  try {
    if (name == 'windows-1252' || name == 'cp1252') {
      return _decodeCp1252(bytes);
    }
    if (name == 'iso-8859-1' || name == 'latin1' || name == 'latin-1') {
      return latin1.decode(bytes, allowInvalid: true);
    }
    return utf8.decode(bytes, allowMalformed: true);
  } catch (_) {
    return utf8.decode(bytes, allowMalformed: true);
  }
}

/// Windows-1252 is Latin-1 except for 0x80–0x9F, where it puts typographic
/// punctuation instead of control characters. Feeds from old publishers still
/// declare it, and decoding those bytes as Latin-1 turns quotes into garbage.
String _decodeCp1252(List<int> bytes) {
  const Map<int, int> high = <int, int>{
    0x80: 0x20AC,
    0x82: 0x201A,
    0x83: 0x0192,
    0x84: 0x201E,
    0x85: 0x2026,
    0x86: 0x2020,
    0x87: 0x2021,
    0x88: 0x02C6,
    0x89: 0x2030,
    0x8A: 0x0160,
    0x8B: 0x2039,
    0x8C: 0x0152,
    0x8E: 0x017D,
    0x91: 0x2018,
    0x92: 0x2019,
    0x93: 0x201C,
    0x94: 0x201D,
    0x95: 0x2022,
    0x96: 0x2013,
    0x97: 0x2014,
    0x98: 0x02DC,
    0x99: 0x2122,
    0x9A: 0x0161,
    0x9B: 0x203A,
    0x9C: 0x0153,
    0x9E: 0x017E,
    0x9F: 0x0178,
  };
  final StringBuffer buffer = StringBuffer();
  for (final int byte in bytes) {
    buffer.writeCharCode(high[byte] ?? byte);
  }
  return buffer.toString();
}
