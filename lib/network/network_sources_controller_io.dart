// i18n:data — interface strings declared here are translated at their render sites.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/models.dart';
import '../local/coalescing_writer.dart';
import '../state/build_safe_notifier.dart';
import '../storage/app_storage.dart';
import 'credentials_vault.dart';
import 'ftp_source.dart';
import 'network_http.dart';
import 'network_library.dart';
import 'network_source.dart';
import 'network_stream_gate.dart';
import 'podcast_feed.dart';
import 'radio_station.dart';
import 'remote_source.dart';
import 'sftp_source.dart';
import 'smb_source.dart';
import 'webdav_source.dart';

/// Builds the protocol adapter for a connection. Injected by tests, which hand
/// back a fake client instead of opening a socket.
Future<RemoteSourceClient> defaultNetworkClientFactory(
  RemoteSourceConnection connection,
) async {
  switch (connection.kind) {
    case NetworkSourceKind.webdav:
      return WebDavSourceClient.fromConnection(connection);
    case NetworkSourceKind.ftp:
      return FtpSourceClient.fromConnection(connection);
    case NetworkSourceKind.sftp:
      final SftpSession session = await DartSftpSession.connect(connection);
      return SftpSourceClient(session: session, basePath: connection.path);
    case NetworkSourceKind.smb:
      final (String share, String basePath) = smbSplitShare(connection.path);
      final SmbSession session = await SmbConnectSession.connect(connection);
      return SmbSourceClient(
        session: session,
        share: share,
        basePath: basePath,
      );
  }
}

/// Owns everything under 音乐库 → 网络源: the saved sources and their
/// credentials, the pooled protocol clients, the loopback stream gate, the
/// indexed tracks, radio stations and podcast subscriptions.
///
/// The controller is the only place that knows a remote path becomes a URL the
/// audio engine can play; the rest of the app asks it for a stream and shows
/// what it reports.
class NetworkSourcesController extends ChangeNotifier with BuildSafeNotifier {
  NetworkSourcesController({
    NetworkCredentialsVault? vault,
    Future<Directory> Function()? supportDirectory,
    RemoteSourceClientFactory? clientFactory,
    NetworkTextFetcher? textFetcher,
    DateTime Function()? clock,
    String? streamToken,
    HttpClient Function()? gateHttpClientFactory,
    this.maxScanFiles = 20000,
    this.idleClientTimeout = const Duration(minutes: 5),
    this.streamUrlCacheFor = const Duration(minutes: 10),
    this.persist = true,
  }) : _supportDirectory = supportDirectory ?? appSupportDirectory,
       // Keep the vault beside the manifests it belongs to: a caller that
       // redirects storage (tests, a custom data root) must not leave
       // credentials in the default profile directory.
       _vault =
           vault ??
           NetworkCredentialsVault(
             supportDirectory: supportDirectory ?? appSupportDirectory,
           ),
       _clientFactory = clientFactory ?? defaultNetworkClientFactory,
       _textFetcher = textFetcher ?? fetchNetworkText,
       _clock = clock ?? DateTime.now {
    _gate = NetworkStreamGate(
      openRemote: _openRemote,
      statRemote: _statRemote,
      resolveRelay: _resolveRelay,
      token: streamToken,
      httpClientFactory: gateHttpClientFactory,
    );
  }

  final NetworkCredentialsVault _vault;
  final Future<Directory> Function() _supportDirectory;
  final RemoteSourceClientFactory _clientFactory;
  final NetworkTextFetcher _textFetcher;
  final DateTime Function() _clock;

  /// Ceiling for one scan pass; a mistaken root selection cannot index a whole
  /// archive for an hour.
  final int maxScanFiles;

  /// How long a protocol session may stay idle before its socket is closed.
  final Duration idleClientTimeout;

  /// How long a resolved radio playlist URL is reused before it is fetched
  /// again. A station can rotate its stream URL.
  final Duration streamUrlCacheFor;

  /// Whether stores are written to disk. Widget tests turn this off: they run
  /// in a fake-async zone where file writes never complete, and the store
  /// behaviour is covered by the plain unit tests instead.
  final bool persist;

  late final NetworkStreamGate _gate;

  final List<NetworkSource> _sources = <NetworkSource>[];
  final List<NetworkTrackEntry> _entries = <NetworkTrackEntry>[];
  final List<RadioStation> _stations = <RadioStation>[];
  final List<PodcastSubscription> _podcasts = <PodcastSubscription>[];

  final Map<String, _PooledClient> _pool = <String, _PooledClient>{};
  final Map<String, Uri> _resolvedStreams = <String, Uri>{};
  final Map<String, DateTime> _resolvedStreamAt = <String, DateTime>{};
  final Map<String, DateTime> _lastEpisodeSave = <String, DateTime>{};

  Map<String, int>? _entryIndexes;
  bool _loaded = false;
  Future<void>? _loading;
  bool _disposed = false;

  Timer? _idleTimer;

  // Scan progress.
  String? _scanningSourceId;
  String? _scanningFolder;
  int _scanningFiles = 0;
  NetworkScanCancel? _scanCancel;

  // Playback progress binding.
  Listenable? _playbackListenable;
  Track? Function()? _playbackCurrent;
  Duration Function()? _playbackPosition;

  late final CoalescingWriter _sourcesWriter = CoalescingWriter(
    () async {
      if (!persist) return;
      await _writeJson('network_sources.json', <String, Object?>{
      'version': 1,
      'sources': <Map<String, Object?>>[
          for (final NetworkSource source in _sources) source.toJson(),
        ],
      });
    },
  );
  late final CoalescingWriter _libraryWriter = CoalescingWriter(
    () async {
      if (!persist) return;
      await _writeJson('network_library.json', <String, Object?>{
      'version': 1,
      'tracks': <Map<String, Object?>>[
          for (final NetworkTrackEntry entry in _entries) entry.toJson(),
        ],
      });
    },
  );
  late final CoalescingWriter _radioWriter = CoalescingWriter(
    () async {
      if (!persist) return;
      await _writeJson('network_radio.json', <String, Object?>{
      'version': 1,
      'stations': <Map<String, Object?>>[
          for (final RadioStation station in _stations) station.toJson(),
        ],
      });
    },
  );
  late final CoalescingWriter _podcastWriter = CoalescingWriter(
    () async {
      if (!persist) return;
      await _writeJson('network_podcasts.json', <String, Object?>{
      'version': 1,
      'subscriptions': <Map<String, Object?>>[
          for (final PodcastSubscription podcast in _podcasts) podcast.toJson(),
        ],
      });
    },
  );

  // ---------------------------------------------------------------------------
  // Loading and persistence
  // ---------------------------------------------------------------------------

  bool get loaded => _loaded;

  /// Reads every store once. No network calls happen here.
  Future<void> load() {
    final Future<void>? pending = _loading;
    if (pending != null) return pending;
    if (_loaded) return Future<void>.value();
    final Future<void> loading = _load();
    _loading = loading;
    return loading.whenComplete(() {
      if (identical(_loading, loading)) _loading = null;
    });
  }

  Future<void> _load() async {
    try {
      await Future.wait<void>(<Future<void>>[
        _vault.load(),
        _loadSources(),
        _loadLibrary(),
        _loadRadio(),
        _loadPodcasts(),
      ]);
    } finally {
      _loaded = true;
      if (!_disposed) notifyListeners();
    }
  }

  Future<String?> _readFile(String name) async {
    try {
      final Directory directory = await _supportDirectory();
      final File file = File('${directory.path}${Platform.pathSeparator}$name');
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeJson(String name, Map<String, Object?> value) async {
    try {
      final Directory directory = await _supportDirectory();
      await directory.create(recursive: true);
      final File file = File('${directory.path}${Platform.pathSeparator}$name');
      final File temporary = File('${file.path}.tmp');
      await temporary.writeAsString(jsonEncode(value), flush: true);
      await temporary.rename(file.path);
    } catch (_) {
      // A failed settings write must not stop playback.
    }
  }

  Future<void> _loadSources() async {
    final Map<String, dynamic>? json = _decodeMap(await _readFile('network_sources.json'));
    for (final Object? item in json?['sources'] as List<Object?>? ?? const []) {
      if (item is! Map<String, dynamic>) continue;
      try {
        final NetworkSource source = NetworkSource.fromJson(item);
        if (source.id.isEmpty) continue;
        _sources.add(source);
      } catch (_) {
        // One corrupt entry must not take the whole list down.
      }
    }
  }

  Future<void> _loadLibrary() async {
    final Map<String, dynamic>? json = _decodeMap(await _readFile('network_library.json'));
    for (final Object? item in json?['tracks'] as List<Object?>? ?? const []) {
      if (item is! Map<String, dynamic>) continue;
      try {
        final NetworkTrackEntry entry = NetworkTrackEntry.fromJson(item);
        if (entry.id.isEmpty || !entry.id.startsWith('network:')) continue;
        _entries.add(entry);
      } catch (_) {}
    }
    _entryIndexes = null;
  }

  Future<void> _loadRadio() async {
    final Map<String, dynamic>? json = _decodeMap(await _readFile('network_radio.json'));
    for (final Object? item in json?['stations'] as List<Object?>? ?? const []) {
      if (item is! Map<String, dynamic>) continue;
      try {
        final RadioStation station = RadioStation.fromJson(item);
        if (station.id.isEmpty || station.url.isEmpty) continue;
        _stations.add(station);
      } catch (_) {}
    }
  }

  Future<void> _loadPodcasts() async {
    final Map<String, dynamic>? json = _decodeMap(await _readFile('network_podcasts.json'));
    for (final Object? item in json?['subscriptions'] as List<Object?>? ?? const []) {
      if (item is! Map<String, dynamic>) continue;
      try {
        final PodcastSubscription podcast = PodcastSubscription.fromJson(item);
        if (podcast.id.isEmpty || podcast.feedUrl.isEmpty) continue;
        _podcasts.add(podcast);
      } catch (_) {}
    }
  }

  static Map<String, dynamic>? _decodeMap(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final Object? value = jsonDecode(raw);
      return value is Map<String, dynamic> ? value : null;
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Sources
  // ---------------------------------------------------------------------------

  List<NetworkSource> get sources => List<NetworkSource>.unmodifiable(_sources);

  NetworkSource? sourceById(String id) {
    for (final NetworkSource source in _sources) {
      if (source.id == id) return source;
    }
    return null;
  }

  Future<String> _passwordFor(NetworkSource source) async {
    await _vault.load();
    return _vault.secretFor(source.id) ?? '';
  }

  /// Adds a source and stores its password. Returns the saved model.
  Future<NetworkSource> addSource(
    NetworkSourceDraft draft, {
    String? password,
  }) async {
    await load();
    final NetworkSource source = draft.toSource(
      id: newNetworkSourceId(),
      now: _clock(),
    );
    _sources.add(source);
    final String secret = password ?? draft.password;
    if (secret.isNotEmpty) await _vault.put(source.id, secret);
    notifyListeners();
    await _sourcesWriter.request();
    return source;
  }

  /// Applies an edit. An empty password field keeps the stored secret; pass
  /// [clearPassword] to remove it.
  Future<NetworkSource?> updateSource(
    String id,
    NetworkSourceDraft draft, {
    String? password,
    bool clearPassword = false,
  }) async {
    await load();
    final int index = _sources.indexWhere((NetworkSource source) => source.id == id);
    if (index < 0) return null;
    final NetworkSource previous = _sources[index];
    NetworkSource updated = draft.toSource(
      id: id,
      previous: previous,
      now: _clock(),
    );
    if (previous.kind != updated.kind || previous.host != updated.host) {
      updated = updated.copyWith(clearHostKey: true);
    }
    _sources[index] = updated.copyWith(clearLastError: true);
    final String secret = password ?? draft.password;
    if (clearPassword) {
      await _vault.remove(id);
    } else if (secret.isNotEmpty) {
      await _vault.put(id, secret);
    }
    await _disconnect(id);
    notifyListeners();
    await _sourcesWriter.request();
    return _sources[index];
  }

  /// Removes the source, its saved secret and every track indexed from it.
  Future<void> removeSource(String id) async {
    await load();
    final int before = _sources.length;
    _sources.removeWhere((NetworkSource source) => source.id == id);
    if (_sources.length == before) return;
    await _vault.remove(id);
    await _disconnect(id);
    _entries.removeWhere((NetworkTrackEntry entry) => entry.sourceId == id);
    _entryIndexes = null;
    _bumpLibraryRevision();
    _resolvedStreams.clear();
    _resolvedStreamAt.clear();
    notifyListeners();
    await Future.wait<void>(<Future<void>>[
      _sourcesWriter.request(),
      _libraryWriter.request(),
    ]);
  }

  /// Exchanges a connection failure for a persisted `lastError` on the source.
  Future<void> recordFailure(String id, Object error) async {
    final int index = _sources.indexWhere((NetworkSource source) => source.id == id);
    if (index < 0) return;
    final String message = error is RemoteFailure
        ? error.message
        : error is PodcastFeedException
        ? error.message
        : '连接失败，请稍后重试。';
    _sources[index] = _sources[index].copyWith(
      lastCheckedAt: _clock(),
      lastError: message,
    );
    notifyListeners();
    await _sourcesWriter.request();
  }

  Future<void> clearFailure(String id) async {
    final int index = _sources.indexWhere((NetworkSource source) => source.id == id);
    if (index < 0) return;
    if (_sources[index].lastError == null) return;
    _sources[index] = _sources[index].copyWith(
      lastCheckedAt: _clock(),
      clearLastError: true,
    );
    notifyListeners();
    await _sourcesWriter.request();
  }

  /// Opens and closes a throwaway session, returning the source root listing.
  ///
  /// [existingId] lets the editor test the saved password when the field was
  /// left untouched.
  Future<RemoteListing> testDraft(
    NetworkSourceDraft draft, {
    String? existingId,
    String? password,
  }) async {
    await load();
    final NetworkSource? previous = existingId == null
        ? null
        : sourceById(existingId);
    final NetworkSource probe = draft.toSource(
      id: existingId ?? 'probe',
      previous: previous,
      now: _clock(),
    );
    final String secret;
    if (password != null && password.isNotEmpty) {
      secret = password;
    } else if (draft.password.isNotEmpty) {
      secret = draft.password;
    } else if (previous != null) {
      secret = await _passwordFor(previous);
    } else {
      secret = '';
    }
    String? hostKey;
    final RemoteSourceConnection connection = probe.connection(
      password: secret,
      // Record only. The SSH client itself refuses a mismatch (it compares the
      // fingerprint), and throwing from this callback would surface as an
      // internal SSH error instead of the clean TLS failure.
      onHostKey: (String value) => hostKey = value,
    );
    final RemoteSourceClient client = await _clientFactory(connection);
    try {
      final RemoteListing listing = await client.list(probe.rootPath);
      if (hostKey != null && previous != null && previous.hostKey == null) {
        final int index = _sources.indexWhere(
          (NetworkSource source) => source.id == previous.id,
        );
        if (index >= 0) {
          _sources[index] = _sources[index].copyWith(hostKey: hostKey);
          await _sourcesWriter.request();
        }
      }
      await clearFailure(probe.id);
      return listing;
    } finally {
      await client.close();
    }
  }

  // ---------------------------------------------------------------------------
  // Clients
  // ---------------------------------------------------------------------------

  Future<_PooledClient> _pooledFor(String sourceId) {
    final _PooledClient? existing = _pool[sourceId];
    if (existing != null && !existing.closed) {
      existing.lastUsed = _clock();
      return existing.ready;
    }
    final NetworkSource? source = sourceById(sourceId);
    if (source == null) {
      return Future<_PooledClient>.error(
        const RemoteFailure(RemoteFailureKind.notFound),
      );
    }
    final _PooledClient pooled = _PooledClient();
    pooled.ready = _createClient(source, pooled).then((RemoteSourceClient client) {
      // The pool entry can be dropped while a slow handshake is in flight
      // (edited or removed source). Close the late session instead of leaking
      // it into a map nobody reads again.
      if (!identical(_pool[sourceId], pooled) || _disposed) {
        unawaited(client.close().catchError((Object _) {}));
        throw const RemoteFailure(RemoteFailureKind.cancelled);
      }
      pooled.client = client;
      return pooled;
    });
    _pool[sourceId] = pooled;
    _ensureIdleTimer();
    // A failed first connection must not be cached forever.
    unawaited(
      pooled.ready.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          if (identical(_pool[sourceId], pooled)) _pool.remove(sourceId);
        },
      ),
    );
    return pooled.ready;
  }

  Future<RemoteSourceClient> _createClient(
    NetworkSource source,
    _PooledClient pooled,
  ) async {
    final String password = await _passwordFor(source);
    String? presentedKey;
    final RemoteSourceConnection connection = source.connection(
      password: password,
      // Record only: the SSH client refuses a changed key itself.
      onHostKey: (String value) => presentedKey = value,
    );
    final RemoteSourceClient client = await _clientFactory(connection);
    if (presentedKey != null && presentedKey != source.hostKey) {
      // Only trust-on-first-use for the source this handshake was started for.
      // Editing the host or deleting the source while the handshake runs must
      // not write the old server's fingerprint onto the new configuration.
      final NetworkSource? current = sourceById(source.id);
      final bool sameHost =
          current != null &&
          current.host == source.host &&
          current.kind == source.kind &&
          current.port == source.port;
      if (identical(_pool[source.id], pooled) && sameHost) {
        final int index = _sources.indexWhere(
          (NetworkSource entry) => entry.id == source.id,
        );
        if (index >= 0) {
          _sources[index] = _sources[index].copyWith(hostKey: presentedKey);
          unawaited(_sourcesWriter.request());
        }
      }
    }
    return client;
  }

  void _ensureIdleTimer() {
    if (_idleTimer != null || _disposed) return;
    _idleTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      final DateTime now = _clock();
      for (final MapEntry<String, _PooledClient> entry in _pool.entries.toList()) {
        final _PooledClient pooled = entry.value;
        if (pooled.client == null || pooled.active > 0) continue;
        if (now.difference(pooled.lastUsed) < idleClientTimeout) continue;
        _pool.remove(entry.key);
        unawaited(pooled.client!.close().catchError((Object _) {}));
      }
      if (_pool.isEmpty) {
        _idleTimer?.cancel();
        _idleTimer = null;
      }
    });
  }

  /// Closes the pooled session for a source and forgets resolved radio URLs.
  /// Called when the source is edited, and available to the editor's "reconnect"
  /// path so the next browse opens a fresh session.
  Future<void> disconnect(String sourceId) => _disconnect(sourceId);

  Future<void> _disconnect(String sourceId) async {
    final _PooledClient? pooled = _pool.remove(sourceId);
    pooled?.closed = true;
    if (pooled?.client case final RemoteSourceClient client) {
      try {
        await client.close();
      } catch (_) {}
    }
    _resolvedStreams.clear();
    _resolvedStreamAt.clear();
  }

  Future<RemoteListing> list(String sourceId, String path) async {
    final _PooledClient pooled = await _pooledFor(sourceId);
    final RemoteListing listing = await pooled.client!.list(path);
    await clearFailure(sourceId);
    return listing;
  }

  Future<RemoteEntry?> stat(String sourceId, String path) async {
    final _PooledClient pooled = await _pooledFor(sourceId);
    return pooled.client!.stat(path);
  }

  Future<RemoteRead> _openRemote(
    String sourceId,
    String path,
    int start,
    int? end,
  ) async {
    final _PooledClient pooled = await _pooledFor(sourceId);
    pooled.active++;
    pooled.lastUsed = _clock();
    try {
      final RemoteRead read = await pooled.client!.open(path, start: start, end: end);
      return RemoteRead(
        bytes: read.bytes,
        totalBytes: read.totalBytes,
        close: () async {
          try {
            await read.close();
          } catch (_) {
          } finally {
            pooled.active--;
            pooled.lastUsed = _clock();
          }
        },
      );
    } catch (_) {
      pooled.active--;
      rethrow;
    }
  }

  Future<RemoteEntry?> _statRemote(String sourceId, String path) async {
    final _PooledClient pooled = await _pooledFor(sourceId);
    return pooled.client!.stat(path);
  }

  // ---------------------------------------------------------------------------
  // Library index
  // ---------------------------------------------------------------------------

  List<NetworkTrackEntry> get entries => List<NetworkTrackEntry>.unmodifiable(_entries);

  List<NetworkTrackEntry> entriesFor(String sourceId) => List<NetworkTrackEntry>.unmodifiable(
    _entries.where((NetworkTrackEntry entry) => entry.sourceId == sourceId),
  );

  int _countRevision = -1;
  Map<String, int> _counts = const <String, int>{};

  /// How many tracks are indexed for [sourceId], without filtering the list.
  int countFor(String sourceId) {
    if (_countRevision != _libraryRevision) {
      final Map<String, int> counts = <String, int>{};
      for (final NetworkTrackEntry entry in _entries) {
        counts[entry.sourceId] = (counts[entry.sourceId] ?? 0) + 1;
      }
      _counts = counts;
      _countRevision = _libraryRevision;
    }
    return _counts[sourceId] ?? 0;
  }

  NetworkTrackEntry? entryForTrackId(String trackId) {
    final Map<String, int> indexes = _entryIndexes ??= <String, int>{
      for (int i = _entries.length - 1; i >= 0; i--) _entries[i].id: i,
    };
    final int? index = indexes[trackId];
    return index == null ? null : _entries[index];
  }

  int _libraryRevision = 0;
  int _libraryCacheRevision = -1;
  List<Track> _libraryCache = const <Track>[];

  /// Every indexed track, newest first. Cached: the page rebuilds on every
  /// controller notification (scan progress), and sorting thousands of entries
  /// there would make the banner expensive.
  List<Track> get libraryTracks {
    if (_libraryCacheRevision == _libraryRevision) return _libraryCache;
    final List<NetworkTrackEntry> sorted = <NetworkTrackEntry>[..._entries];
    sorted.sort((NetworkTrackEntry a, NetworkTrackEntry b) {
      return b.addedAt.compareTo(a.addedAt);
    });
    _libraryCache = List<Track>.unmodifiable(
      <Track>[for (final NetworkTrackEntry entry in sorted) entry.toTrack()],
    );
    _libraryCacheRevision = _libraryRevision;
    return _libraryCache;
  }

  void _bumpLibraryRevision() {
    _libraryRevision++;
    _libraryCacheRevision = -1;
  }

  /// Indexes one file, returning its entry. Used when a file is played or
  /// queued straight from the browser.
  Future<NetworkTrackEntry> ensureEntry(
    String sourceId,
    RemoteEntry entry, {
    bool persist = true,
    bool notify = true,
  }) async {
    await load();
    final NetworkSource? source = sourceById(sourceId);
    final DateTime now = _clock();
    final NetworkTrackEntry created = NetworkTrackEntry.fromRemote(
      sourceId,
      entry,
      albumFallback: source?.displayName ?? '网络音乐',
      now: now,
    );
    final Map<String, int> indexes = _entryIndexes ??= <String, int>{
      for (int i = _entries.length - 1; i >= 0; i--) _entries[i].id: i,
    };
    final int? existing = indexes[created.id];
    if (existing == null) {
      _entries.insert(0, created);
      _entryIndexes = null;
      _bumpLibraryRevision();
      if (notify) notifyListeners();
      if (persist) await _libraryWriter.request();
      return created;
    }
    final NetworkTrackEntry previous = _entries[existing];
    if (previous.title == created.title &&
        previous.artist == created.artist &&
        previous.album == created.album &&
        previous.bytes == created.bytes &&
        previous.modifiedAt == created.modifiedAt) {
      // Playing a folder that is already indexed must not re-notify or rewrite
      // the manifest for every file in it.
      return previous;
    }
    final NetworkTrackEntry updated = NetworkTrackEntry(
      id: previous.id,
      sourceId: previous.sourceId,
      path: previous.path,
      title: created.title,
      artist: created.artist,
      album: created.album,
      duration: previous.duration,
      addedAt: previous.addedAt,
      bytes: created.bytes ?? previous.bytes,
      modifiedAt: created.modifiedAt ?? previous.modifiedAt,
    );
    _entries[existing] = updated;
    _bumpLibraryRevision();
    if (notify) notifyListeners();
    if (persist) await _libraryWriter.request();
    return updated;
  }

  /// Indexes a folder's files in one pass and returns their tracks, in the
  /// order the folder listing gave them. Used when a file is played straight
  /// from the browser, so the queue and the library agree about the ids.
  Future<List<Track>> indexFolder(
    String sourceId,
    List<RemoteEntry> entries,
  ) async {
    await load();
    final List<Track> tracks = <Track>[];
    for (final RemoteEntry entry in entries) {
      final NetworkTrackEntry indexed = await ensureEntry(
        sourceId,
        entry,
        persist: false,
        notify: false,
      );
      tracks.add(indexed.toTrack());
    }
    notifyListeners();
    await _libraryWriter.request();
    return tracks;
  }

  Future<void> removeEntry(String trackId) async {
    await load();
    final int before = _entries.length;
    _entries.removeWhere((NetworkTrackEntry entry) => entry.id == trackId);
    if (_entries.length == before) return;
    _entryIndexes = null;
    _bumpLibraryRevision();
    notifyListeners();
    await _libraryWriter.request();
  }

  Future<void> clearSourceEntries(String sourceId) async {
    await load();
    final int before = _entries.length;
    _entries.removeWhere((NetworkTrackEntry entry) => entry.sourceId == sourceId);
    if (_entries.length == before) return;
    _entryIndexes = null;
    _bumpLibraryRevision();
    notifyListeners();
    await _libraryWriter.request();
  }

  // ---------------------------------------------------------------------------
  // Scanning
  // ---------------------------------------------------------------------------

  bool get scanning => _scanningSourceId != null;
  String? get scanningSourceId => _scanningSourceId;
  String? get scanningFolder => _scanningFolder;
  int get scanningFiles => _scanningFiles;

  void cancelScan() {
    _scanCancel?.cancel();
  }

  /// Walks [path] and indexes every audio file it finds.
  ///
  /// Folders are visited breadth-first, one listing at a time, so a slow NAS
  /// stays responsive and the progress counter moves. Hidden folders are
  /// skipped, the depth and the file count are capped by [maxScanFiles].
  Future<NetworkScanResult> scan(
    String sourceId,
    String path, {
    bool recursive = true,
    NetworkScanCancel? cancel,
  }) async {
    await load();
    if (_scanningSourceId != null) {
      throw const RemoteFailure(
        RemoteFailureKind.protocol,
        detail: 'a scan is already running',
      );
    }
    _scanningSourceId = sourceId;
    _scanningFolder = remoteNormalize(path);
    _scanningFiles = 0;
    _scanCancel = cancel ?? NetworkScanCancel();
    notifyListeners();
    NetworkScanResult result = NetworkScanResult.empty;
    try {
      final List<(String folder, int depth)> queue = <(String, int)>[
        (remoteNormalize(path), 0),
      ];
      final Set<String> visited = <String>{};
      bool limitReached = false;
      while (queue.isNotEmpty) {
        if (_scanCancel?.cancelled ?? false) {
          result = result.copyWith(cancelled: true);
          break;
        }
        final (String folder, int depth) = queue.removeAt(0);
        if (!visited.add(folder)) continue;
        _scanningFolder = folder;
        notifyListeners();
        RemoteListing listing;
        try {
          listing = await list(sourceId, folder);
        } on RemoteFailure {
          result = result.merge(const NetworkScanResult(failed: 1));
          continue;
        }
        for (final RemoteEntry entry in listing.entries) {
          if (_scanCancel?.cancelled ?? false) break;
          if (entry.isDirectory) {
            if (recursive && depth < 12 && !entry.name.startsWith('.')) {
              queue.add((entry.path, depth + 1));
            }
            continue;
          }
          if (!entry.isAudio) continue;
          if (_scanningFiles >= maxScanFiles) {
            result = result.copyWith(cancelled: true);
            limitReached = true;
            break;
          }
          _scanningFiles++;
          final bool existed = entryForTrackId(
                networkTrackId(sourceId, entry.path),
              ) !=
              null;
          await ensureEntry(
            sourceId,
            entry,
            persist: false,
            notify: false,
          );
          result = existed
              ? result.copyWith(updated: result.updated + 1)
              : result.copyWith(added: result.added + 1);
        }
        // One notification per folder: a thousand-file scan must not rebuild
        // the page a thousand times.
        notifyListeners();
        if (limitReached) break;
      }
    } finally {
      _scanningSourceId = null;
      _scanningFolder = null;
      _scanCancel = null;
      notifyListeners();
      await _libraryWriter.request();
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // Stream resolution
  // ---------------------------------------------------------------------------

  /// The playable URL for a track the controller owns, or null when the id does
  /// not belong to it.
  Future<String?> resolveStream(Track track) async {
    await load();
    final String id = track.id;
    if (id.startsWith('network:')) {
      final (String sourceId, String path)? target = decodeNetworkTrackId(id);
      if (target == null || sourceById(target.$1) == null) return null;
      await _gate.ensureStarted();
      return _gate.urlForFile(target.$1, target.$2).toString();
    }
    if (id.startsWith('radio:')) {
      final String? stationId = radioStationIdOf(id);
      if (stationId == null || !_stations.any((RadioStation s) => s.id == stationId)) {
        return null;
      }
      await _gate.ensureStarted();
      return _gate.urlForRelay('radio:$stationId').toString();
    }
    if (id.startsWith('podcast:')) {
      final String? episodeId = podcastEpisodeIdOf(id);
      if (episodeId == null || _subscriptionForEpisode(episodeId) == null) {
        return null;
      }
      await _gate.ensureStarted();
      return _gate.urlForRelay('podcast:$episodeId').toString();
    }
    return null;
  }

  bool ownsTrackId(String id) => isNetworkOwnedTrackId(id);

  /// Live radio has no duration and no end: the player must start it at once
  /// instead of waiting for the ten-second startup buffer an on-demand stream
  /// gets.
  bool isLiveStream(Track track) => radioStationIdOf(track.id) != null;

  /// True for `localhost`, `127.0.0.0/8` and `::1`. Private LAN addresses stay
  /// allowed: that is where a listener's own NAS and radio lives.
  static bool _isLoopbackHost(String host) {
    final String value = host.trim().toLowerCase();
    if (value.isEmpty) return true;
    if (value == 'localhost' || value.endsWith('.localhost')) return true;
    final String bare = value.replaceAll('[', '').replaceAll(']', '');
    final InternetAddress? address = InternetAddress.tryParse(bare);
    if (address == null) return false;
    final List<int> bytes = address.rawAddress;
    if (bytes.length == 4) return bytes[0] == 127 || bytes[0] == 0;
    return bytes.length == 16 &&
        bytes.sublist(0, 15).every((int byte) => byte == 0) &&
        bytes[15] == 1;
  }

  /// Binds the loopback gate without a track. The player starts it lazily; the
  /// UI tests start it before a fake-async test body so its socket is real.
  Future<void> startStreamGate() => _gate.ensureStarted();

  /// The port the gate is listening on, or null before it starts.
  int? get streamPort => _gate.port;

  Future<Uri?> _resolveRelay(String relayId) async {
    if (relayId.startsWith('radio:')) {
      final String? stationId = radioStationIdOf(relayId);
      if (stationId == null) return null;
      final RadioStation? station = stationById(stationId);
      if (station == null) return null;
      return _resolvePlayableStream(station.url);
    }
    if (relayId.startsWith('podcast:')) {
      final String? episodeId = podcastEpisodeIdOf(relayId);
      if (episodeId == null) return null;
      final PodcastEpisode? episode = _episodeById(episodeId);
      if (episode == null) return null;
      final Uri? uri = Uri.tryParse(episode.audioUrl);
      if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
        return null;
      }
      // An untrusted feed must not turn the gate into a reader for this
      // machine's loopback services.
      if (_isLoopbackHost(uri.host)) return null;
      return uri;
    }
    return null;
  }

  /// A radio URL may point at a playlist instead of a stream; resolve it once
  /// and reuse the answer for a few minutes.
  Future<Uri> _resolvePlayableStream(String url) async {
    final Uri? parsed = Uri.tryParse(url);
    if (parsed == null || (parsed.scheme != 'http' && parsed.scheme != 'https')) {
      throw const RemoteFailure(
        RemoteFailureKind.unsupported,
        detail: 'radio url',
      );
    }
    if (_isLoopbackHost(parsed.host)) {
      throw const RemoteFailure(
        RemoteFailureKind.unsupported,
        detail: 'loopback stream',
      );
    }
    if (!looksLikeRadioPlaylist(url)) return parsed;
    final Uri? cached = _resolvedStreams[url];
    final DateTime? cachedAt = _resolvedStreamAt[url];
    if (cached != null &&
        cachedAt != null &&
        _clock().difference(cachedAt) < streamUrlCacheFor) {
      return cached;
    }
    final NetworkText text = await _textFetcher(parsed);
    final List<RadioPlaylistEntry> entries = parseRadioPlaylist(
      text.body,
      fallbackName: parsed.host,
    );
    for (final RadioPlaylistEntry entry in entries) {
      final Uri? candidate = Uri.tryParse(text.uri.resolve(entry.url).toString());
      if (candidate == null) continue;
      if (candidate.scheme != 'http' && candidate.scheme != 'https') continue;
      if (_isLoopbackHost(candidate.host)) continue;
      _resolvedStreams[url] = candidate;
      _resolvedStreamAt[url] = _clock();
      return candidate;
    }
    throw const RemoteFailure(
      RemoteFailureKind.notFound,
      detail: 'playlist has no stream',
    );
  }

  // ---------------------------------------------------------------------------
  // Radio
  // ---------------------------------------------------------------------------

  List<RadioStation> get stations => List<RadioStation>.unmodifiable(_stations);

  RadioStation? stationById(String id) {
    for (final RadioStation station in _stations) {
      if (station.id == id) return station;
    }
    return null;
  }

  RadioStation? stationForTrackId(String trackId) {
    final String? id = radioStationIdOf(trackId);
    return id == null ? null : stationById(id);
  }

  Future<RadioStation> addStation({
    required String name,
    required String url,
    String genre = '',
    String homepage = '',
  }) async {
    await load();
    final Uri? parsed = Uri.tryParse(url.trim());
    if (parsed == null || (parsed.scheme != 'http' && parsed.scheme != 'https')) {
      throw const RemoteFailure(
        RemoteFailureKind.unsupported,
        detail: 'radio url',
      );
    }
    final RadioStation station = RadioStation(
      id: newRadioStationId(),
      name: name.trim().isEmpty ? parsed.host : name.trim(),
      url: url.trim(),
      genre: genre.trim(),
      homepage: homepage.trim(),
      addedAt: _clock(),
    );
    _stations.insert(0, station);
    notifyListeners();
    await _radioWriter.request();
    return station;
  }

  Future<RadioStation?> updateStation(
    String id, {
    String? name,
    String? url,
    String? genre,
    String? homepage,
  }) async {
    await load();
    final int index = _stations.indexWhere((RadioStation station) => station.id == id);
    if (index < 0) return null;
    final RadioStation updated = _stations[index].copyWith(
      name: name?.trim(),
      url: url?.trim(),
      genre: genre?.trim(),
      homepage: homepage?.trim(),
    );
    _stations[index] = updated;
    _resolvedStreams.remove(updated.url);
    _resolvedStreamAt.remove(updated.url);
    notifyListeners();
    await _radioWriter.request();
    return updated;
  }

  Future<void> removeStation(String id) async {
    await load();
    final int before = _stations.length;
    _stations.removeWhere((RadioStation station) => station.id == id);
    if (_stations.length == before) return;
    notifyListeners();
    await _radioWriter.request();
  }

  /// Fetches a playlist URL and adds every station inside it. Returns how many
  /// entries were added.
  Future<int> importRadioPlaylist(Uri uri) async {
    await load();
    final NetworkText text = await _textFetcher(uri);
    final List<RadioPlaylistEntry> entries = parseRadioPlaylist(
      text.body,
      fallbackName: text.uri.host,
    );
    if (entries.isEmpty) {
      throw const RemoteFailure(
        RemoteFailureKind.notFound,
        detail: 'playlist has no stations',
      );
    }
    int added = 0;
    for (final RadioPlaylistEntry entry in entries) {
      final Uri resolved = text.uri.resolve(entry.url);
      if (resolved.scheme != 'http' && resolved.scheme != 'https') continue;
      final String url = resolved.toString();
      if (_stations.any((RadioStation station) => station.url == url)) continue;
      _stations.insert(
        0,
        RadioStation(
          id: newRadioStationId(),
          name: entry.name.trim().isEmpty ? resolved.host : entry.name.trim(),
          url: url,
          addedAt: _clock(),
        ),
      );
      added++;
    }
    if (added > 0) {
      notifyListeners();
      await _radioWriter.request();
    }
    return added;
  }

  // ---------------------------------------------------------------------------
  // Podcasts
  // ---------------------------------------------------------------------------

  List<PodcastSubscription> get podcasts =>
      List<PodcastSubscription>.unmodifiable(_podcasts);

  PodcastSubscription? podcastById(String id) {
    for (final PodcastSubscription podcast in _podcasts) {
      if (podcast.id == id) return podcast;
    }
    return null;
  }

  PodcastEpisode? _episodeById(String episodeId) {
    for (final PodcastSubscription podcast in _podcasts) {
      final PodcastEpisode? episode = podcast.episode(episodeId);
      if (episode != null) return episode;
    }
    return null;
  }

  PodcastSubscription? _subscriptionForEpisode(String episodeId) {
    for (final PodcastSubscription podcast in _podcasts) {
      if (podcast.episode(episodeId) != null) return podcast;
    }
    return null;
  }

  PodcastSubscription? podcastForTrackId(String trackId) {
    final String? episodeId = podcastEpisodeIdOf(trackId);
    return episodeId == null ? null : _subscriptionForEpisode(episodeId);
  }

  PodcastEpisode? episodeForTrackId(String trackId) {
    final String? episodeId = podcastEpisodeIdOf(trackId);
    return episodeId == null ? null : _episodeById(episodeId);
  }

  PodcastProgress progressForTrackId(String trackId) {
    final String? episodeId = podcastEpisodeIdOf(trackId);
    if (episodeId == null) return const PodcastProgress();
    final PodcastSubscription? podcast = _subscriptionForEpisode(episodeId);
    return podcast?.progressOf(episodeId) ?? const PodcastProgress();
  }

  PodcastSubscription? podcastForFeed(String feedUrl) {
    final String normalized = _normalizeFeedUrl(feedUrl);
    for (final PodcastSubscription podcast in _podcasts) {
      if (podcast.feedUrl == normalized) return podcast;
    }
    return null;
  }

  String _normalizeFeedUrl(String raw) {
    String value = raw.trim();
    if (value.isEmpty) return value;
    if (!value.contains('://')) value = 'https://$value';
    final Uri? uri = Uri.tryParse(value);
    if (uri == null) return value;
    return uri.toString();
  }

  /// Subscribes to [feedUrl], or refreshes the existing subscription for it.
  Future<PodcastSubscription> subscribe(String feedUrl) async {
    await load();
    final String normalized = _normalizeFeedUrl(feedUrl);
    final Uri? uri = Uri.tryParse(normalized);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const PodcastFeedException('请填写播客的 RSS 地址。');
    }
    final NetworkText text = await _fetchFeed(uri);
    final PodcastFeed feed = const PodcastFeedParser().parse(
      text.body,
      feedUrl: text.uri.toString(),
    );
    final PodcastSubscription? existing = podcastForFeed(text.uri.toString()) ??
        podcastForFeed(normalized);
    final PodcastSubscription subscription;
    if (existing == null) {
      subscription = PodcastSubscription(
        id: newPodcastSubscriptionId(text.uri.toString()),
        feedUrl: text.uri.toString(),
        title: feed.title,
        description: feed.description,
        imageUrl: feed.imageUrl,
        author: feed.author,
        lastFetchedAt: _clock(),
        episodes: feed.episodes,
      );
      _podcasts.insert(0, subscription);
    } else {
      subscription = _mergeFeed(existing, feed, text.uri.toString());
      final int index = _podcasts.indexWhere(
        (PodcastSubscription podcast) => podcast.id == existing.id,
      );
      _podcasts[index] = subscription;
    }
    notifyListeners();
    await _podcastWriter.request();
    return subscription;
  }

  /// Refreshes one subscription. On failure the error is kept on the model and
  /// rethrown so the page can toast it.
  Future<PodcastSubscription> refreshPodcast(String id) async {
    await load();
    final int index = _podcasts.indexWhere(
      (PodcastSubscription podcast) => podcast.id == id,
    );
    if (index < 0) throw const PodcastFeedException('这个订阅已经不存在了。');
    final PodcastSubscription current = _podcasts[index];
    try {
      final Uri uri = Uri.parse(current.feedUrl);
      final NetworkText text = await _fetchFeed(uri);
      final PodcastFeed feed = const PodcastFeedParser().parse(
        text.body,
        feedUrl: text.uri.toString(),
      );
      final PodcastSubscription updated = _mergeFeed(
        current,
        feed,
        text.uri.toString(),
      );
      _podcasts[index] = updated;
      notifyListeners();
      await _podcastWriter.request();
      return updated;
    } catch (error) {
      final String message = error is PodcastFeedException
          ? error.message
          : error is RemoteFailure
          ? error.message
          : '订阅刷新失败。';
      _podcasts[index] = current.copyWith(error: message);
      notifyListeners();
      await _podcastWriter.request();
      rethrow;
    }
  }

  /// Refreshes every subscription in order. Returns how many succeeded and how
  /// many failed, so the page can report a partial failure as a failure.
  Future<({int refreshed, int failed})> refreshAllPodcasts() async {
    await load();
    int refreshed = 0;
    int failed = 0;
    for (final PodcastSubscription podcast
        in List<PodcastSubscription>.of(_podcasts)) {
      try {
        await refreshPodcast(podcast.id);
        refreshed++;
      } catch (_) {
        failed++;
      }
    }
    return (refreshed: refreshed, failed: failed);
  }

  Future<void> unsubscribe(String id) async {
    await load();
    final int before = _podcasts.length;
    _podcasts.removeWhere((PodcastSubscription podcast) => podcast.id == id);
    if (_podcasts.length == before) return;
    notifyListeners();
    await _podcastWriter.request();
  }

  Future<NetworkText> _fetchFeed(Uri uri) => _textFetcher(uri);

  PodcastSubscription _mergeFeed(
    PodcastSubscription existing,
    PodcastFeed feed,
    String feedUrl,
  ) {
    final Set<String> available = <String>{
      for (final PodcastEpisode episode in feed.episodes) episode.id,
    };
    final Map<String, PodcastProgress> kept = <String, PodcastProgress>{};
    for (final MapEntry<String, PodcastProgress> entry
        in existing.progress.entries) {
      if (available.contains(entry.key)) kept[entry.key] = entry.value;
    }
    return existing.copyWith(
      title: feed.title,
      description: feed.description,
      imageUrl: feed.imageUrl.isEmpty ? existing.imageUrl : feed.imageUrl,
      author: feed.author,
      lastFetchedAt: _clock(),
      clearError: true,
      episodes: feed.episodes,
      progress: kept,
      feedUrl: feedUrl.isEmpty ? existing.feedUrl : feedUrl,
    );
  }

  /// Marks an episode played/unplayed and drops its resume point.
  Future<void> markEpisodePlayed(String episodeId, {bool played = true}) async {
    await load();
    final PodcastSubscription? podcast = _subscriptionForEpisode(episodeId);
    if (podcast == null) return;
    final int index = _podcasts.indexWhere(
      (PodcastSubscription entry) => entry.id == podcast.id,
    );
    final Map<String, PodcastProgress> progress = <String, PodcastProgress>{
      ..._podcasts[index].progress,
    };
    progress[episodeId] = played
        ? PodcastProgress(played: true, updatedAt: _clock())
        : PodcastProgress(updatedAt: _clock());
    _podcasts[index] = _podcasts[index].copyWith(progress: progress);
    notifyListeners();
    await _podcastWriter.request();
  }

  /// Saves a resume point. Called from the playback binding, throttled.
  Future<void> saveEpisodePosition(
    String episodeId,
    Duration position, {
    bool persist = true,
  }) async {
    final PodcastSubscription? podcast = _subscriptionForEpisode(episodeId);
    if (podcast == null) return;
    final int index = _podcasts.indexWhere(
      (PodcastSubscription entry) => entry.id == podcast.id,
    );
    final PodcastProgress previous = _podcasts[index].progressOf(episodeId);
    if (previous.position == position) return;
    final Map<String, PodcastProgress> progress = <String, PodcastProgress>{
      ..._podcasts[index].progress,
    };
    progress[episodeId] = previous.copyWith(
      position: position,
      played: false,
      updatedAt: _clock(),
    );
    _podcasts[index] = _podcasts[index].copyWith(progress: progress);
    notifyListeners();
    if (persist) await _podcastWriter.request();
  }

  Future<void> clearEpisodeProgress(String episodeId) async {
    final PodcastSubscription? podcast = _subscriptionForEpisode(episodeId);
    if (podcast == null) return;
    final int index = _podcasts.indexWhere(
      (PodcastSubscription entry) => entry.id == podcast.id,
    );
    final Map<String, PodcastProgress> progress = <String, PodcastProgress>{
      ..._podcasts[index].progress,
    }..remove(episodeId);
    _podcasts[index] = _podcasts[index].copyWith(progress: progress);
    notifyListeners();
    await _podcastWriter.request();
  }

  // ---------------------------------------------------------------------------
  // Playback binding
  // ---------------------------------------------------------------------------

  /// Watches the player so a podcast keeps its resume point across launches.
  ///
  /// The listener is throttled to one save per ten seconds; the position is
  /// written through the coalescing writer, so it never blocks a frame.
  void attachPlayback({
    required Track? Function() current,
    required Duration Function() position,
    required Listenable listenable,
  }) {
    detachPlayback();
    _playbackCurrent = current;
    _playbackPosition = position;
    _playbackListenable = listenable;
    listenable.addListener(_onPlaybackTick);
  }

  void detachPlayback() {
    _playbackListenable?.removeListener(_onPlaybackTick);
    _playbackListenable = null;
    _playbackCurrent = null;
    _playbackPosition = null;
  }

  void _onPlaybackTick() {
    if (_disposed) return;
    final Track? track = _playbackCurrent?.call();
    if (track == null) return;
    final String? episodeId = podcastEpisodeIdOf(track.id);
    if (episodeId == null) return;
    final PodcastSubscription? podcast = _subscriptionForEpisode(episodeId);
    if (podcast == null) return;
    final Duration position = _playbackPosition?.call() ?? Duration.zero;
    if (position <= Duration.zero) return;
    final Duration duration = track.duration;
    if (duration > Duration.zero &&
        position >= duration - const Duration(seconds: 20)) {
      final PodcastProgress progress = podcast.progressOf(episodeId);
      if (!progress.played) {
        unawaited(markEpisodePlayed(episodeId));
      }
      return;
    }
    final DateTime now = _clock();
    final DateTime? saved = _lastEpisodeSave[episodeId];
    if (saved != null &&
        now.difference(saved) < const Duration(seconds: 10)) {
      return;
    }
    _lastEpisodeSave[episodeId] = now;
    unawaited(saveEpisodePosition(episodeId, position));
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    detachPlayback();
    _idleTimer?.cancel();
    _idleTimer = null;
    for (final _PooledClient pooled in _pool.values) {
      pooled.closed = true;
      final RemoteSourceClient? client = pooled.client;
      if (client != null) {
        unawaited(client.close().catchError((Object _) {}));
      }
    }
    _pool.clear();
    unawaited(_gate.close());
    super.dispose();
  }
}

class _PooledClient {
  RemoteSourceClient? client;
  late Future<_PooledClient> ready;
  DateTime lastUsed = DateTime.now();
  int active = 0;
  bool closed = false;
}
