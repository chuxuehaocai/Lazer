import 'dart:async';

import 'package:flutter/painting.dart';

import '../data/models.dart';
import '../utils/artwork.dart';
import '../widgets/artwork_image.dart';

/// Pins only the selected track's large, decoded cover, even with no player UI.
class CurrentArtworkCache {
  ArtworkImage? _provider;
  (String, String?)? _identity;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  Completer<void>? _ready;
  bool _disposed = false;
  bool _failed = false;

  Future<void> get ready => _ready?.future ?? Future<void>.value();

  ArtworkImage? providerFor(Track track) =>
      _identity == (track.id, track.coverUrl) ? _provider : null;

  void update(Track? track) {
    if (_disposed) return;
    final identity = track == null ? null : (track.id, track.coverUrl);
    if (_identity == identity && !_failed) return;
    final url = enlargedArtworkUrl(track?.coverUrl);
    if (url != null && url == _provider?.url && !_failed) {
      _identity = identity;
      return;
    }
    _release();
    _identity = identity;
    if (url == null) return;
    final provider = _provider = ArtworkImage(url, targetSize: 1024);
    final ready = _ready = Completer<void>();
    final stream = _stream = provider.resolve(ImageConfiguration.empty);
    _listener = ImageStreamListener(
      (info, _) {
        info.dispose();
        if (!ready.isCompleted) ready.complete();
      },
      onError: (Object error, StackTrace? stack) {
        if (identical(_stream, stream)) _failed = true;
        if (!ready.isCompleted) ready.complete();
      },
    );
    stream.addListener(_listener!);
  }

  void _release() {
    final stream = _stream;
    final listener = _listener;
    if (stream != null && listener != null) stream.removeListener(listener);
    final provider = _provider;
    if (provider != null) {
      // Existing artwork may finish its dissolve; this owner retains no old
      // decode, and unrelated thumbnails keep their own smaller cache keys.
      PaintingBinding.instance.imageCache.evict(provider, includeLive: false);
    }
    final ready = _ready;
    if (ready != null && !ready.isCompleted) ready.complete();
    _provider = null;
    _stream = null;
    _listener = null;
    _ready = null;
    _failed = false;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _release();
  }
}
