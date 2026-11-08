import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/cache/disk_cache.dart';
import 'package:lazer_nextgen/cache/media_cache.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';

class _QualityGateway extends MusicGateway {
  @override
  MusicProvider get provider =>
      const MusicProvider(id: 'fixture', name: 'Fixture');
  @override
  String get connectionId => 'quality';
  @override
  MusicUser? get user => null;
  @override
  Set<MusicCapability> get capabilities => const {};
  final levels = <MusicStreamQuality>[];
  final available = <MusicStreamQuality>{};
  bool offline = false, rateLimited = false;
  int? granted;
  @override
  Future<MusicStream> stream(
    MusicId song, {
    MusicStreamQuality quality = MusicStreamQuality.original,
  }) async {
    levels.add(quality);
    if (offline) {
      throw const SocketException('offline');
    }
    if (rateLimited) {
      throw const MusicGatewayException('fixture', 'stream', httpStatus: 429);
    }
    if (!available.contains(quality)) {
      throw const MusicGatewayException('fixture', 'stream', code: 70);
    }
    return MusicStream(
      uri: Uri.parse('https://audio.test/song.mp3'),
      suffix: 'mp3',
      bitRate: granted,
      headers: const {'X-Audio': 'fixture'},
    );
  }
}

Track _track(_QualityGateway gateway) => Track(
  id: gateway.id(MusicEntityKind.song, '42').cacheKey,
  title: 'Song',
  artist: 'Artist',
  album: 'Album',
  duration: Duration.zero,
  coverSeed: 0,
);

void main() {
  group('AudioQuality', () {
    test('exposes the four upstream levels and their bitrate requests', () {
      expect(
        AudioQuality.values.map((AudioQuality quality) => quality.level),
        <String>['standard', 'higher', 'exhigh', 'lossless'],
      );
      expect(
        AudioQuality.values.map((AudioQuality quality) => quality.bitrate),
        <int>[128000, 192000, 320000, 999000],
      );
      expect(AudioQuality.lossless.requiresVip, isTrue);
      expect(AudioQuality.exhigh.requiresVip, isFalse);
    });

    test('degrades from the requested tier down to standard', () {
      expect(AudioQuality.lossless.fallbackChain, <AudioQuality>[
        AudioQuality.lossless,
        AudioQuality.exhigh,
        AudioQuality.higher,
        AudioQuality.standard,
      ]);
      expect(AudioQuality.higher.fallbackChain, <AudioQuality>[
        AudioQuality.higher,
        AudioQuality.standard,
      ]);
      expect(AudioQuality.standard.fallbackChain, <AudioQuality>[
        AudioQuality.standard,
      ]);
    });

    test('parses persisted names and live service levels', () {
      expect(AudioQualityInfo.parse('lossless'), AudioQuality.lossless);
      expect(AudioQualityInfo.parse('unknown'), AudioQuality.exhigh);
      expect(AudioQualityInfo.parse(null), AudioQuality.exhigh);
      expect(AudioQualityInfo.fromLevel('exhigh'), AudioQuality.exhigh);
      expect(AudioQualityInfo.fromLevel('lossless'), AudioQuality.lossless);
      expect(AudioQualityInfo.fromLevel('dolby'), isNull);
    });

    test('reads the granted tier from the returned bitrate', () {
      expect(AudioQualityInfo.fromBitrate(null), isNull);
      expect(AudioQualityInfo.fromBitrate(0), isNull);
      expect(AudioQualityInfo.fromBitrate(128000), AudioQuality.standard);
      expect(AudioQualityInfo.fromBitrate(192000), AudioQuality.higher);
      expect(AudioQualityInfo.fromBitrate(320000), AudioQuality.exhigh);
      expect(AudioQualityInfo.fromBitrate(999000), AudioQuality.lossless);
    });

    test('estimates a file size from the duration and bitrate', () {
      const Duration duration = Duration(minutes: 1);
      expect(AudioQuality.standard.estimatedBytes(duration), 960000);
      expect(AudioQuality.lossless.estimatedBytes(duration), 10584000);
    });
  });

  group('quality-aware audio cache', () {
    late Directory directory;
    late DiskCache disk;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'lazer-quality-cache-test-',
      );
      disk = DiskCache(directory: () async => directory);
    });
    tearDown(() async => directory.delete(recursive: true));

    test('keys entries by track and quality', () async {
      expect(AudioCache.cacheKey('42', AudioQuality.lossless), '42:lossless');
      final AudioCache cache = AudioCache(disk: disk);
      final File? lossless = await disk.put(
        CacheBucket.audio,
        AudioCache.cacheKey('42', AudioQuality.lossless),
        () => Stream<List<int>>.value(<int>[1, 2, 3]),
        extension: 'flac',
      );
      expect(
        (await cache.find('42', quality: AudioQuality.lossless))?.path,
        lossless?.path,
      );
      expect(await cache.find('42', quality: AudioQuality.exhigh), isNull);
      expect((await cache.findAny('42'))?.path, lossless?.path);
    });

    test('adopts a legacy track-id entry only for exhigh', () async {
      final AudioCache cache = AudioCache(disk: disk);
      final File? legacy = await disk.put(
        CacheBucket.audio,
        '42',
        () => Stream<List<int>>.value(<int>[1, 2, 3]),
        extension: 'mp3',
      );
      expect((await cache.find('42'))?.path, legacy?.path);
      expect(
        (await cache.find('42', quality: AudioQuality.exhigh))?.path,
        legacy?.path,
      );
      expect(await cache.find('42', quality: AudioQuality.higher), isNull);
      expect(await cache.find('42', quality: AudioQuality.lossless), isNull);
    });
  });

  group('catalogue degradation', () {
    test(
      'a granted rendition preserves the requested tier and request headers',
      () async {
        final gateway = _QualityGateway()
          ..available.add(MusicStreamQuality.original);
        final source = await Catalog(gateway: gateway).audioSourceFor(
          _track(gateway),
          quality: AudioQuality.lossless,
          useCache: false,
        );
        expect(source!.quality, AudioQuality.lossless);
        expect(source.headers['X-Audio'], 'fixture');
        expect(gateway.levels, [MusicStreamQuality.original]);
      },
    );
    test('missing renditions fall through the lower tiers', () async {
      final gateway = _QualityGateway()..available.add(MusicStreamQuality.low);
      final source = await Catalog(gateway: gateway).audioSourceFor(
        _track(gateway),
        quality: AudioQuality.lossless,
        useCache: false,
      );
      expect(source!.quality, AudioQuality.standard);
      expect(gateway.levels, [
        MusicStreamQuality.original,
        MusicStreamQuality.high,
        MusicStreamQuality.medium,
        MusicStreamQuality.low,
      ]);
    });
    test('returned bitrate identifies a downgraded rendition', () async {
      final gateway = _QualityGateway()
        ..available.add(MusicStreamQuality.original)
        ..granted = 128000;
      final source = await Catalog(gateway: gateway).audioSourceFor(
        _track(gateway),
        quality: AudioQuality.lossless,
        useCache: false,
      );
      expect(source!.quality, AudioQuality.standard);
    });
    test('transport failures stop repeated remote requests', () async {
      final gateway = _QualityGateway()..offline = true;
      await expectLater(
        Catalog(gateway: gateway).audioSourceFor(
          _track(gateway),
          quality: AudioQuality.lossless,
          useCache: false,
        ),
        throwsA(isA<SocketException>()),
      );
      expect(gateway.levels, hasLength(1));
    });
    test(
      'rate limits remain retryable and never become unavailable-song errors',
      () async {
        final gateway = _QualityGateway()..rateLimited = true;
        await expectLater(
          Catalog(gateway: gateway).audioSourceFor(
            _track(gateway),
            quality: AudioQuality.lossless,
            useCache: false,
          ),
          throwsA(predicate(Catalog.isRateLimited)),
        );
        expect(gateway.levels, hasLength(4));
      },
    );
    test('lower-tier disk audio plays after a transport failure', () async {
      final directory = await Directory.systemTemp.createTemp(
        'audio-fallback-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final disk = DiskCache(directory: () async => directory);
      final gateway = _QualityGateway()..offline = true;
      final track = _track(gateway);
      await disk.put(
        CacheBucket.audio,
        AudioCache.cacheKey(track.id, AudioQuality.standard),
        () => Stream.value([1, 2, 3]),
        extension: 'mp3',
      );
      final source = await Catalog(
        gateway: gateway,
        cache: disk,
      ).audioSourceFor(track, quality: AudioQuality.lossless);
      expect(source!.quality, AudioQuality.standard);
      expect(source.url, startsWith('file:'));
      expect(gateway.levels, hasLength(1));
    });
  });
}
