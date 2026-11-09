enum CacheBucket { audio, artwork, data }

class CachedJson {
  const CachedJson(this.data, this.savedAt);

  final Map<String, dynamic> data;
  final DateTime savedAt;

  bool fresh(Duration ttl) => DateTime.now().difference(savedAt) < ttl;

  bool get invalidated => savedAt.millisecondsSinceEpoch == 0;
}

/// The browser has no filesystem; cache callers get "not cached" and writes
/// are dropped. Playback itself streams from the source URL.
class DiskCache {
  DiskCache({Object? directory, Map<CacheBucket, int>? limits})
    : limits = limits ?? const <CacheBucket, int>{};

  static final shared = DiskCache();

  final Map<CacheBucket, int> limits;

  void retainFile(Object file) {}
  void releaseFile(Object file) {}

  Future<Object?> find(
    CacheBucket bucket,
    String key, {
    String? extension,
    Map<String, String>? headers,
  }) async => null;

  Future<void> remove(
    CacheBucket bucket,
    String key, {
    String? extension,
  }) async {}

  Future<Object?> put(
    CacheBucket bucket,
    String key,
    Stream<List<int>> Function() source, {
    required String extension,
    int? expectedLength,
    int? maxBytes,
  }) async => null;

  Future<CachedJson?> readJson(String key) async => null;

  Future<void> writeJson(
    String key,
    Map<String, dynamic> data, {
    DateTime? savedAt,
  }) async {}

  Future<void> expireJson(String key) async {}
}
