import '../utils/media_requests.dart';
// i18n:data — these strings are keys; the download sheet renders task.error
// through context.tr.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/audio_quality.dart';
import '../data/catalog.dart';
import '../data/models.dart';
import '../local/local_library.dart';
import '../state/build_safe_notifier.dart';

// The download sheets format sizes with the same helper the local library
// uses; re-exporting keeps their existing imports working.
export '../utils/byte_format.dart' show formatBytes;

enum DownloadStatus {
  queued,
  resolving,
  downloading,
  completed,
  existing,
  failed,
  canceled,
}

/// One song in the download queue. The file name is decided once the rendition
/// is resolved because the extension follows the format the service returns.
class DownloadTask {
  DownloadTask({
    required this.id,
    required this.track,
    required this.requestedQuality,
    required this.directory,
    required this.fileBase,
    this.folderName,
  });

  final int id;
  final Track track;
  final AudioQuality requestedQuality;
  final String directory;
  final String fileBase;
  final String? folderName;

  DownloadStatus status = DownloadStatus.queued;
  AudioQuality? resolvedQuality;
  String? path;
  String? error;
  int received = 0;
  int total = 0;
  HttpClient? _client;

  bool get isActive =>
      status == DownloadStatus.queued ||
      status == DownloadStatus.resolving ||
      status == DownloadStatus.downloading;

  bool get isDone =>
      status == DownloadStatus.completed || status == DownloadStatus.existing;

  double? get progress => total > 0 ? (received / total).clamp(0.0, 1.0) : null;

  String get title => track.title;
}

/// Sanitises a name for Windows, macOS, Linux and Android alike.
String sanitizeFileName(String value) {
  String result = value
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
      .trim();
  result = result.replaceAll(RegExp(r'[. ]+$'), '');
  if (result.isEmpty) result = '未命名';
  if (result.length > 120) result = result.substring(0, 120);
  return result;
}

const Set<String> _audioExtensions = <String>{
  'mp3',
  'flac',
  'm4a',
  'aac',
  'ogg',
  'wav',
  'mp4',
};

String audioExtensionFor(AudioSource source) {
  final String? format = source.format?.toLowerCase();
  if (format != null && _audioExtensions.contains(format)) return format;
  final Uri? uri = Uri.tryParse(source.url);
  final String suffix = uri?.path.split('.').last.toLowerCase() ?? '';
  return _audioExtensions.contains(suffix) ? suffix : 'mp3';
}

/// File name used when downloading. A single song carries the artist; a batch
/// is numbered so the destination keeps the album/playlist order.
String downloadFileBase(Track track, {int? index}) {
  final String title = track.title.trim().isEmpty ? '未命名' : track.title.trim();
  if (index != null) return '${index.toString().padLeft(2, '0')}. $title';
  final String artist = track.artist.trim();
  return artist.isEmpty ? title : '$artist - $title';
}

class _DownloadCanceled implements Exception {
  const _DownloadCanceled();
}

/// Downloads resolved renditions into a user-chosen directory and records
/// completed files in [LocalLibrary].
class DownloadManager extends ChangeNotifier with BuildSafeNotifier {
  DownloadManager({
    Catalog? catalog,
    this.library,
    this.concurrency = 2,
    HttpClient Function()? clientFactory,
  }) : catalog = catalog ?? Catalog(),
       _clientFactory = clientFactory ?? HttpClient.new;

  final Catalog catalog;
  final LocalLibrary? library;
  final int concurrency;
  final HttpClient Function() _clientFactory;
  final List<DownloadTask> _tasks = <DownloadTask>[];
  int _serial = 0;
  int _running = 0;
  bool _disposed = false;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  List<DownloadTask> get tasks => List<DownloadTask>.unmodifiable(_tasks);
  int get activeCount =>
      _tasks.where((DownloadTask task) => task.isActive).length;
  int get completedCount =>
      _tasks.where((DownloadTask task) => task.isDone).length;

  /// Queues [tracks]. [folderName] creates one sub-directory (album/playlist).
  List<DownloadTask> enqueue(
    Iterable<Track> tracks, {
    required AudioQuality quality,
    required String directory,
    String? folderName,
  }) {
    final List<Track> list = tracks.toList();
    final String folder = folderName?.trim() ?? '';
    final List<DownloadTask> added = <DownloadTask>[];
    int index = 0;
    for (final Track track in list) {
      index++;
      if (_tasks.any(
        (DownloadTask task) =>
            task.isActive &&
            task.track.id == track.id &&
            task.requestedQuality == quality &&
            task.directory == directory &&
            (task.folderName ?? '') == folder,
      )) {
        continue;
      }
      final DownloadTask task = DownloadTask(
        id: ++_serial,
        track: track,
        requestedQuality: quality,
        directory: directory,
        fileBase: downloadFileBase(
          track,
          index: list.length > 1 ? index : null,
        ),
        folderName: folder.isEmpty ? null : sanitizeFileName(folder),
      );
      _tasks.add(task);
      added.add(task);
    }
    if (added.isEmpty) return added;
    notifyListeners();
    _pump();
    return added;
  }

  void cancel(DownloadTask task) {
    if (!task.isActive) return;
    task.status = DownloadStatus.canceled;
    task.error = null;
    try {
      task._client?.close(force: true);
    } catch (_) {}
    _notify(force: true);
    _pump();
  }

  void retry(DownloadTask task) {
    if (task.isActive) return;
    if (task.status != DownloadStatus.failed &&
        task.status != DownloadStatus.canceled) {
      return;
    }
    task.status = DownloadStatus.queued;
    task.error = null;
    task.received = 0;
    task.total = 0;
    task.path = null;
    task.resolvedQuality = null;
    _notify(force: true);
    _pump();
  }

  void clearFinished() {
    final int before = _tasks.length;
    _tasks.removeWhere(
      (DownloadTask task) =>
          task.isDone || task.status == DownloadStatus.canceled,
    );
    if (_tasks.length == before) return;
    _notify(force: true);
  }

  void _pump() {
    if (_disposed) return;
    while (_running < concurrency) {
      DownloadTask? next;
      for (final DownloadTask task in _tasks) {
        if (task.status == DownloadStatus.queued) {
          next = task;
          break;
        }
      }
      if (next == null) return;
      _running++;
      unawaited(_run(next));
    }
  }

  Future<void> _run(DownloadTask task) async {
    task.status = DownloadStatus.resolving;
    _notify(force: true);
    AudioSource? source;
    try {
      source = await catalog.audioSourceFor(
        task.track,
        quality: task.requestedQuality,
        useCache: false,
      );
    } catch (_) {
      _fail(task, '无法获取下载地址');
      return;
    }
    if (task.status == DownloadStatus.canceled) {
      _finishRun();
      return;
    }
    if (source == null || source.url.isEmpty) {
      _fail(task, '这首歌暂时无法下载');
      return;
    }
    task.resolvedQuality = source.quality;
    final String extension = audioExtensionFor(source);
    final File target = File(_targetPath(task, extension));
    if (await target.exists()) {
      task.path = target.path;
      task.total = await target.length();
      task.received = task.total;
      await _record(task, target);
      if (task.status != DownloadStatus.canceled) {
        task.status = DownloadStatus.existing;
      }
      _finishRun();
      return;
    }
    task.status = DownloadStatus.downloading;
    _notify(force: true);
    await _download(task, source, target);
  }

  Future<void> _download(
    DownloadTask task,
    AudioSource source,
    File target,
  ) async {
    final HttpClient client = _clientFactory();
    task._client = client;
    File? partial;
    try {
      final HttpClientRequest request = await client
          .getUrl(Uri.parse(source.url))
          .timeout(const Duration(seconds: 20));
      ({
        ...MediaRequestRules.headers(source.url),
        ...source.headers,
      }).forEach(request.headers.set);
      final HttpClientResponse response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != HttpStatus.ok) {
        _fail(task, '服务器返回 ${response.statusCode}');
        return;
      }
      task.total = response.contentLength;
      await target.parent.create(recursive: true);
      partial = File('${target.path}.part');
      final IOSink sink = partial.openWrite();
      try {
        await for (final List<int> chunk in response.timeout(
          const Duration(seconds: 30),
        )) {
          if (task.status == DownloadStatus.canceled) {
            throw const _DownloadCanceled();
          }
          sink.add(chunk);
          task.received += chunk.length;
          _notify();
        }
        await sink.flush();
        await sink.close();
      } catch (error) {
        try {
          await sink.close();
        } catch (_) {}
        if (error is _DownloadCanceled) rethrow;
        _fail(task, '下载中断，请重试');
        return;
      }
      if (task.status == DownloadStatus.canceled) {
        throw const _DownloadCanceled();
      }
      final int length = await partial.length();
      if (task.total > 0 && length != task.total) {
        _fail(task, '文件不完整，请重试');
        return;
      }
      await partial.rename(target.path);
      partial = null;
      task.path = target.path;
      task.total = length;
      task.received = length;
      // Record first: "completed" should mean the library has the file, and
      // the manifest write must not outlive the task on Windows.
      await _record(task, target);
      if (task.status == DownloadStatus.canceled) {
        _finishRun();
        return;
      }
      task.status = DownloadStatus.completed;
      task.error = null;
      _finishRun();
    } on _DownloadCanceled {
      _finishRun();
    } catch (_) {
      if (task.status != DownloadStatus.canceled) _fail(task, '下载失败，请重试');
    } finally {
      task._client = null;
      try {
        if (partial != null && await partial.exists()) await partial.delete();
      } catch (_) {}
      client.close(force: true);
    }
  }

  Future<void> _record(DownloadTask task, File file) async {
    await catalog.cacheLyrics(task.track, audioPath: file.path);
    final LocalLibrary? library = this.library;
    if (library == null) return;
    try {
      final FileStat stat = await file.stat();
      await library.addTracks(<LocalTrack>[
        LocalTrack(
          track: task.track,
          path: file.path,
          source: LocalTrackSource.download,
          quality: task.resolvedQuality ?? task.requestedQuality,
          bytes: stat.size,
          modifiedAt: stat.modified,
          addedAt: DateTime.now(),
        ),
      ]);
    } catch (_) {}
  }

  void _fail(DownloadTask task, String message) {
    if (task.status == DownloadStatus.canceled) {
      _finishRun();
      return;
    }
    task.status = DownloadStatus.failed;
    task.error = message;
    _finishRun();
  }

  void _finishRun() {
    if (_running > 0) _running--;
    _notify(force: true);
    _pump();
  }

  String _targetPath(DownloadTask task, String extension) {
    final String separator = Platform.pathSeparator;
    final String folder = task.folderName == null
        ? task.directory
        : '${task.directory}$separator${task.folderName}';
    return '$folder$separator${sanitizeFileName(task.fileBase)}.$extension';
  }

  void _notify({bool force = false}) {
    if (_disposed) return;
    final DateTime now = DateTime.now();
    if (!force &&
        now.difference(_lastNotify) < const Duration(milliseconds: 120)) {
      return;
    }
    _lastNotify = now;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final DownloadTask task in _tasks) {
      if (!task.isActive) continue;
      task.status = DownloadStatus.canceled;
      try {
        task._client?.close(force: true);
      } catch (_) {}
    }
    super.dispose();
  }
}
