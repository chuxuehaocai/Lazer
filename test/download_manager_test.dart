import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/downloads/download_manager.dart';
import 'package:lazer_nextgen/local/local_library.dart';

Track _track(String id, [String title = '曲目']) => Track(
  id: id,
  title: title,
  artist: '音乐人',
  album: '专辑',
  duration: const Duration(minutes: 3),
  coverSeed: 0,
);

class _DownloadCatalog extends Catalog {
  _DownloadCatalog(this.base);

  final String base;
  final List<AudioQuality> requests = <AudioQuality>[];
  final Set<String> failing = <String>{};

  @override
  Future<AudioSource?> audioSourceFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
    bool useCache = true,
  }) async {
    requests.add(quality);
    if (failing.contains(track.id)) throw const SocketException('offline');
    if (track.id == 'none') return null;
    return AudioSource(
      url: '$base/${track.id}.mp3',
      quality: quality,
      format: 'mp3',
      bytes: 4096,
    );
  }
}

void main() {
  late Directory root;
  late Directory support;
  late Directory documents;
  late Directory downloads;
  late HttpServer server;
  late String base;
  final Uint8List payload = Uint8List.fromList(
    List<int>.generate(64 * 1024, (int index) => index % 251),
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lazer-download-test-');
    support = Directory('${root.path}/support');
    documents = Directory('${root.path}/documents');
    downloads = Directory('${root.path}/downloads');
    await support.create(recursive: true);
    await documents.create(recursive: true);
    await downloads.create(recursive: true);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((HttpRequest request) async {
      final String path = request.uri.path;
      if (path == '/slow.mp3') {
        request.response.contentLength = 1000000;
        for (int index = 0; index < 200; index++) {
          request.response.add(List<int>.filled(5000, index % 253));
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await request.response.close();
        return;
      }
      if (path == '/500.mp3') {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
        return;
      }
      request.response.headers.contentType = ContentType('audio', 'mpeg');
      request.response.contentLength = payload.length;
      request.response.add(payload);
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await root.delete(recursive: true);
  });

  LocalLibrary library() => LocalLibrary(
    supportDirectory: () async => support,
    documentsDirectory: () async => documents,
  );

  String native(String path) {
    String value = File(path).absolute.path;
    if (Platform.isWindows) value = value.replaceAll('/', '\\');
    return value;
  }

  Future<void> waitUntil(
    bool Function() predicate, {
    String reason = 'condition',
  }) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!predicate()) {
      if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for $reason');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('downloads one song and records it in the local library', () async {
    final LocalLibrary local = library();
    await local.load();
    final DownloadManager manager = DownloadManager(
      catalog: _DownloadCatalog(base),
      library: local,
    );
    addTearDown(manager.dispose);
    final DownloadTask task = manager
        .enqueue(
          <Track>[_track('1', '夜の歌')],
          quality: AudioQuality.lossless,
          directory: downloads.path,
        )
        .single;
    await waitUntil(
      () => task.status == DownloadStatus.completed,
      reason: 'download to finish',
    );
    await waitUntil(() => local.count == 1, reason: 'library record');
    final File file = File(task.path!);
    expect(file.path, endsWith('音乐人 - 夜の歌.mp3'));
    expect(await file.readAsBytes(), payload);
    expect(task.resolvedQuality, AudioQuality.lossless);
    expect(local.tracks.single.quality, AudioQuality.lossless);
    expect(local.tracks.single.source, LocalTrackSource.download);
    expect((await local.localFileFor(_track('1', '夜の歌')))?.path, native(file.path));
    expect(manager.completedCount, 1);
  });

  test('a batch is numbered inside the album folder', () async {
    final LocalLibrary local = library();
    await local.load();
    final DownloadManager manager = DownloadManager(
      catalog: _DownloadCatalog(base),
      library: local,
    );
    addTearDown(manager.dispose);
    final List<DownloadTask> tasks = manager.enqueue(
      <Track>[_track('1', '第一'), _track('2', '第二')],
      quality: AudioQuality.exhigh,
      directory: downloads.path,
      folderName: '专辑',
    );
    await waitUntil(
      () => tasks.every((DownloadTask task) => task.isDone),
      reason: 'batch to finish',
    );
    expect(tasks.map((DownloadTask task) => task.status), everyElement(DownloadStatus.completed));
    expect(tasks.first.path, endsWith('专辑${Platform.pathSeparator}01. 第一.mp3'));
    expect(tasks.last.path, endsWith('专辑${Platform.pathSeparator}02. 第二.mp3'));
    expect(await File(tasks.first.path!).exists(), isTrue);
    expect(await File(tasks.last.path!).exists(), isTrue);
  });

  test('an existing file is kept instead of overwritten', () async {
    final File existing = File(
      '${downloads.path}${Platform.pathSeparator}音乐人 - 曲目.mp3',
    );
    await existing.writeAsBytes(<int>[9, 9, 9]);
    final LocalLibrary local = library();
    await local.load();
    final DownloadManager manager = DownloadManager(
      catalog: _DownloadCatalog(base),
      library: local,
    );
    addTearDown(manager.dispose);
    final DownloadTask task = manager
        .enqueue(
          <Track>[_track('1')],
          quality: AudioQuality.exhigh,
          directory: downloads.path,
        )
        .single;
    await waitUntil(
      () => task.status == DownloadStatus.existing,
      reason: 'existing detection',
    );
    expect(await existing.readAsBytes(), <int>[9, 9, 9]);
    await waitUntil(() => local.count == 1, reason: 'library record');
  });

  test('a failed resolution reports an error and can be retried', () async {
    final _DownloadCatalog catalog = _DownloadCatalog(base)
      ..failing.add('1');
    final DownloadManager manager = DownloadManager(
      catalog: catalog,
      library: library(),
    );
    addTearDown(manager.dispose);
    final DownloadTask task = manager
        .enqueue(
          <Track>[_track('1')],
          quality: AudioQuality.exhigh,
          directory: downloads.path,
        )
        .single;
    await waitUntil(
      () => task.status == DownloadStatus.failed,
      reason: 'failure',
    );
    expect(task.error, isNotNull);
    expect(catalog.requests, <AudioQuality>[AudioQuality.exhigh]);
    catalog.failing.remove('1');
    manager.retry(task);
    await waitUntil(
      () => task.status == DownloadStatus.completed,
      reason: 'retry',
    );
  });

  test('a server error fails the task without leaving a partial file', () async {
    final DownloadManager manager = DownloadManager(
      catalog: _DownloadCatalog(base),
      library: library(),
    );
    addTearDown(manager.dispose);
    final DownloadTask task = manager
        .enqueue(
          <Track>[_track('500')],
          quality: AudioQuality.exhigh,
          directory: downloads.path,
        )
        .single;
    await waitUntil(
      () => task.status == DownloadStatus.failed,
      reason: 'server error',
    );
    expect(task.error, contains('500'));
    final List<FileSystemEntity> files = await downloads.list().toList();
    expect(files.whereType<File>(), isEmpty);
  });

  test('cancelling an active download removes its partial file', () async {
    final DownloadManager manager = DownloadManager(
      catalog: _DownloadCatalog(base),
      library: library(),
    );
    addTearDown(manager.dispose);
    final DownloadTask task = manager
        .enqueue(
          <Track>[_track('slow')],
          quality: AudioQuality.exhigh,
          directory: downloads.path,
        )
        .single;
    await waitUntil(
      () => task.status == DownloadStatus.downloading && task.received > 0,
      reason: 'download to start',
    );
    manager.cancel(task);
    await waitUntil(
      () => task.status == DownloadStatus.canceled && manager.activeCount == 0,
      reason: 'cancellation',
    );
    await waitUntil(
      () => downloads.listSync().whereType<File>().every(
        (File file) => !file.path.endsWith('.part'),
      ),
      reason: 'partial file cleanup',
    );
    final List<FileSystemEntity> files = await downloads.list().toList();
    expect(
      files.whereType<File>().where(
        (File file) => file.path.endsWith('.part'),
      ),
      isEmpty,
    );
  });

  test('file names drop characters the file system rejects', () {
    expect(sanitizeFileName('a/b\\c:d*e?f"g<h>i|j'), 'a_b_c_d_e_f_g_h_i_j');
    expect(sanitizeFileName('  trailing. '), 'trailing');
    expect(sanitizeFileName(''), '未命名');
    expect(downloadFileBase(_track('1', '标题')), '音乐人 - 标题');
    expect(downloadFileBase(_track('1', '标题'), index: 3), '03. 标题');
  });
}
