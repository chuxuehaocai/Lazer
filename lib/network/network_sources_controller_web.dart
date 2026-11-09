import 'package:flutter/foundation.dart';

import '../data/models.dart';
import '../state/build_safe_notifier.dart';
import 'network_library.dart';
import 'network_source.dart';
import 'podcast_feed.dart';
import 'radio_station.dart';
import 'remote_source.dart';

/// Browser stand-in for the network-source library.
///
/// The web build cannot open SMB/SFTP/FTP sockets or mount a local file store,
/// so every query is empty and every write reports "unsupported". The shared
/// shell still mounts the pages and reads the same surface.
class NetworkSourcesController extends ChangeNotifier with BuildSafeNotifier {
  NetworkSourcesController({
    Object? vault,
    Object? supportDirectory,
    Object? clientFactory,
  });

  bool get loaded => false;

  Future<void> load() async {}

  List<NetworkSource> get sources => const <NetworkSource>[];

  NetworkSource? sourceById(String id) => null;

  List<NetworkTrackEntry> get entries => const <NetworkTrackEntry>[];

  List<NetworkTrackEntry> entriesFor(String sourceId) =>
      const <NetworkTrackEntry>[];

  int countFor(String sourceId) => 0;

  NetworkTrackEntry? entryForTrackId(String trackId) => null;

  List<Track> get libraryTracks => const <Track>[];

  bool get scanning => false;

  String? get scanningFolder => null;

  int get scanningFiles => 0;

  void cancelScan() {}

  bool ownsTrackId(String id) => false;

  bool isLiveStream(Track track) => false;

  List<RadioStation> get stations => const <RadioStation>[];

  List<PodcastSubscription> get podcasts => const <PodcastSubscription>[];

  PodcastSubscription? podcastById(String id) => null;

  Never _unsupported() => throw UnsupportedError('浏览器不支持网络源');

  Future<NetworkSource> addSource(NetworkSourceDraft draft) async =>
      _unsupported();

  Future<NetworkSource?> updateSource(
    String id,
    NetworkSourceDraft draft, {
    String? password,
  }) async => null;

  Future<void> removeSource(String id) async {}

  Future<void> recordFailure(String id, Object error) async {}

  Future<void> clearFailure(String id) async {}

  Future<RemoteListing> testDraft(
    NetworkSourceDraft draft, {
    String? existingId,
  }) async => _unsupported();

  Future<void> disconnect(String sourceId) async {}

  Future<RemoteListing> list(String sourceId, String path) async =>
      _unsupported();

  Future<RemoteEntry?> stat(String sourceId, String path) async => null;

  Future<NetworkTrackEntry> ensureEntry(
    String sourceId,
    RemoteEntry entry, {
    bool persist = true,
    bool notify = true,
  }) async => _unsupported();

  Future<List<Track>> indexFolder(
    String sourceId,
    List<RemoteEntry> entries,
  ) async => const <Track>[];

  Future<void> removeEntry(String trackId) async {}

  Future<void> clearSourceEntries(String sourceId) async {}

  Future<NetworkScanResult> scan(String sourceId, String path) async =>
      _unsupported();

  Future<String?> resolveStream(Track track) async => null;

  Future<void> startStreamGate() async {}

  Future<RadioStation> addStation({
    required String name,
    required String url,
    String? genre,
  }) async => _unsupported();

  Future<RadioStation?> updateStation(
    String id, {
    required String name,
    required String url,
    String? genre,
  }) async => null;

  Future<void> removeStation(String id) async {}

  Future<int> importRadioPlaylist(Uri uri) async => 0;

  Future<PodcastSubscription> subscribe(String feedUrl) async => _unsupported();

  Future<PodcastSubscription> refreshPodcast(String id) async => _unsupported();

  Future<({int refreshed, int failed})> refreshAllPodcasts() async =>
      (refreshed: 0, failed: 0);

  Future<void> unsubscribe(String id) async {}

  Future<void> markEpisodePlayed(String episodeId, {bool played = true}) async {}

  Future<void> saveEpisodePosition(
    String episodeId,
    Duration position, {
    bool persist = true,
  }) async {}

  Future<void> clearEpisodeProgress(String episodeId) async {}

  void attachPlayback({
    required Track? Function() current,
    required Duration Function() position,
    required Listenable listenable,
  }) {}

  void detachPlayback() {}
}
