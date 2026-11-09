import 'package:flutter/foundation.dart';

import '../data/audio_quality.dart';
import '../data/models.dart';
import '../state/build_safe_notifier.dart';

enum PlaybackCacheMode { recent, intelligent }

/// Browser stand-in: streams are not downloaded to a disk cache, but the same
/// history and policy surface stays available to the shared UI.
class PlaybackCacheController extends ChangeNotifier with BuildSafeNotifier {
  PlaybackCacheController({
    required Object audioCache,
    required Object library,
    Object? supportDirectory,
    DateTime Function()? now,
  });

  static const String modeKey = 'lazer_playback_cache_mode';
  static const String limitKey = 'lazer_playback_cache_limit';
  static const int defaultMaximumTracks = 50;
  static const Duration historyWindow = Duration(days: 30);

  final ChangeNotifier _library = ChangeNotifier();
  PlaybackCacheMode _mode = PlaybackCacheMode.recent;
  int _maximumTracks = defaultMaximumTracks;

  PlaybackCacheMode get mode => _mode;
  int get maximumTracks => _maximumTracks;
  int get cachedCount => 0;

  /// The library listenable shown by the cache settings rows.
  Listenable get library => _library;

  Future<void> load() async {}

  Future<void> recordPlayed(Track track, {AudioQuality? quality}) async {}

  Future<void> flushHistory() async {}

  Future<void> setMode(PlaybackCacheMode mode) async {
    _mode = mode;
    notifyListeners();
  }

  Future<void> setMaximumTracks(int value) async {
    _maximumTracks = value;
    notifyListeners();
  }

  Future<void> clear() async {}

  @override
  void dispose() {
    _library.dispose();
    super.dispose();
  }
}
