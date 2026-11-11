import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;

import '../utils/artwork.dart';
import '../utils/media_requests.dart';

/// Browser cover loader. The native file cache stays on `dart:io`.
class ArtworkCache {
  ArtworkCache();
  static final shared = ArtworkCache();

  Future<Uint8List> bytes(String url) async {
    final key = normalizedArtworkUrl(url) ?? url;
    final uri = Uri.parse(key);
    var response = await http
        .get(uri, headers: _browserHeaders(key))
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200 && _browserHeaders(key).isNotEmpty) {
      // A header the browser could not send (a forbidden one rejected by the
      // XHR bridge) turns into a failed CORS request; retry bare.
      response = await http
          .get(uri)
          .timeout(const Duration(seconds: 15));
    }
    if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
      throw NetworkImageLoadException(statusCode: response.statusCode, uri: uri);
    }
    return response.bodyBytes;
  }

  /// Headers a browser is allowed to set on a cross-origin image request.
  /// `User-Agent` and `Referer` are forbidden and can make the XHR layer fail
  /// outright instead of being sent.
  Map<String, String> _browserHeaders(String url) {
    const forbidden = <String>{
      'user-agent',
      'referer',
      'cookie',
      'origin',
      'host',
      'content-length',
      'connection',
    };
    return <String, String>{
      for (final entry in MediaRequestRules.headers(url).entries)
        if (!forbidden.contains(entry.key.toLowerCase()))
          entry.key: entry.value,
    };
  }

  Future<ui.ImmutableBuffer> buffer(String url) async {
    return ui.ImmutableBuffer.fromUint8List(await bytes(url));
  }

  Future<void> evict(String url) async {}
}

class CachedAudioFile {
  const CachedAudioFile(this.path, this.uri);

  final String path;
  final Uri uri;
}

/// Browser stand-in for the disk-backed audio cache. Streams play straight
/// from their source URL, so there is nothing to remove.
class AudioCache {
  AudioCache({Object? disk});

  Future<CachedAudioFile?> find(
    String trackId, {
    Object? quality,
    Object? format,
  }) async => null;

  Future<CachedAudioFile?> store(
    String trackId,
    String url, {
    Object? quality,
    String? format,
    Map<String, String> headers = const <String, String>{},
    // A browser writes nothing to disk, so there is no partial file to cancel;
    // the argument stays so the shared catalogue path compiles for both targets.
    bool Function()? isCancelled,
  }) async => null;

  Future<void> removeTrack(Object trackId, {Object? exceptFile}) async {}
}
